#!/usr/bin/env bash
# The app's sign-in and sync (GazeCore Backend) against the real Supabase Auth (GoTrue) and PostgREST, with a
# mailbox that catches the emails with codes, all in Docker:
#   backend/test/e2e.sh          (EXPIRY_WAIT=40 also waits for tokens to run out, about a minute and a half)
# Images: PG_IMAGE, AUTH_IMAGE, REST_IMAGE, MAIL_IMAGE, SWIFT_IMAGE.
set -euo pipefail
cd "$(dirname "$0")/.."
backend=$PWD
core=$(cd ../SpantherGaze/GazeCore && pwd)
net=spanther-e2e
names=(spanther-e2e-db spanther-e2e-mail spanther-e2e-templates spanther-e2e-auth spanther-e2e-rest)
cleanup() {
    docker rm -f "${names[@]}" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
}
cleanup
trap cleanup EXIT
docker network create "$net" >/dev/null
jwt_secret=local-e2e-jwt-secret-with-at-least-32-characters

pg=${PG_IMAGE:-postgres:16}
docker run -d --name spanther-e2e-db --network "$net" --network-alias db -e POSTGRES_PASSWORD=test "$pg" >/dev/null
for _ in $(seq 60); do
    docker exec spanther-e2e-db psql -U postgres -h 127.0.0.1 -qtc 'select 1' >/dev/null 2>&1 && break
    sleep 1
done
psql() { docker exec -i spanther-e2e-db psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 -q "$@"; }
psql < test/e2e_roles.sql

docker run -d --name spanther-e2e-mail --network "$net" --network-alias mailpit \
    "${MAIL_IMAGE:-axllent/mailpit:v1.27}" >/dev/null
# The email templates, served the way Supabase Auth reads them (a URL each).
docker run -d --name spanther-e2e-templates --network "$net" --network-alias templates \
    -v "$backend/supabase/templates:/srv:ro" --entrypoint perl "$pg" -MIO::Socket::INET -e '
    my $s = IO::Socket::INET->new(LocalPort => 80, Listen => 5, ReuseAddr => 1) or die $!;
    while (my $c = $s->accept) {
        my $line = <$c> // ""; my ($f) = $line =~ m{^GET /([\w.-]+)};
        while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
        if ($f && open(my $fh, "<", "/srv/$f")) { local $/; my $b = <$fh>;
            print $c "HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " . length($b) . "\r\n\r\n$b";
        } else { print $c "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n" }
        close $c;
    }' >/dev/null

docker run -d --name spanther-e2e-auth --network "$net" --network-alias gotrue \
    -e GOTRUE_API_HOST=0.0.0.0 -e PORT=9999 -e API_EXTERNAL_URL=http://gotrue:9999 \
    -e GOTRUE_SITE_URL=http://localhost:3000 \
    -e GOTRUE_DB_DRIVER=postgres \
    -e "GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:auth@db:5432/postgres?sslmode=disable" \
    -e GOTRUE_JWT_SECRET=$jwt_secret -e GOTRUE_JWT_EXP=${JWT_EXP:-5} -e GOTRUE_JWT_AUD=authenticated \
    -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated -e GOTRUE_JWT_ADMIN_ROLES=service_role \
    -e GOTRUE_DISABLE_SIGNUP=false -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=false \
    -e GOTRUE_PASSWORD_MIN_LENGTH=8 -e GOTRUE_MAILER_OTP_EXP=3600 -e GOTRUE_MAILER_OTP_LENGTH=6 \
    -e GOTRUE_SMTP_HOST=mailpit -e GOTRUE_SMTP_PORT=1025 -e GOTRUE_SMTP_ADMIN_EMAIL=noreply@spanther.test \
    -e GOTRUE_SMTP_SENDER_NAME=SPANTHER -e GOTRUE_SMTP_MAX_FREQUENCY=1s -e GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 \
    -e GOTRUE_MAILER_TEMPLATES_CONFIRMATION=http://templates/confirmation.html \
    -e GOTRUE_MAILER_TEMPLATES_RECOVERY=http://templates/recovery.html \
    -e "GOTRUE_MAILER_SUBJECTS_CONFIRMATION=SPANTHER: код" -e "GOTRUE_MAILER_SUBJECTS_RECOVERY=SPANTHER: код" \
    "${AUTH_IMAGE:-supabase/gotrue:v2.177.0}" >/dev/null
# Auth makes its own tables first; the app's migrations come after, like on Supabase.
for _ in $(seq 90); do
    [ "$(psql -tAc "select to_regclass('auth.identities') is not null and to_regclass('auth.flow_state') is not null")" = t ] && break
    sleep 1
done
sleep 3
psql -c 'grant usage on schema auth to anon, authenticated, service_role;'
for f in supabase/migrations/*.sql; do psql < "$f"; done

docker run -d --name spanther-e2e-rest --network "$net" --network-alias rest \
    -e "PGRST_DB_URI=postgres://authenticator:rest@db:5432/postgres" -e PGRST_DB_SCHEMAS=public \
    -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET=$jwt_secret -e PGRST_SERVER_PORT=3000 \
    "${REST_IMAGE:-postgrest/postgrest:v12.2.12}" >/dev/null

status=0
docker run --rm --network "$net" -e EXPIRY_WAIT="${EXPIRY_WAIT:-0}" -v "$core:/src" -w /src \
    "${SWIFT_IMAGE:-swift:6.1-noble}" bash -c 'swift build --product BackendCheck >/dev/null && .build/debug/BackendCheck' \
    || status=$?
if [ $status -ne 0 ]; then
    echo "--- auth log"; docker logs --tail 40 spanther-e2e-auth 2>&1
    echo "--- rest log"; docker logs --tail 20 spanther-e2e-rest 2>&1
    exit $status
fi
# What the database holds after the run: only the adults left and their players, the log untouched.
[ "$(psql -tAc "select count(*) from public.accounts")" = 2 ] || { echo 'FAIL accounts left'; exit 1; }
[ "$(psql -tAc "select count(*) from public.accounts where email = 'aziz@e2e.example.com'")" = 0 ] \
    || { echo 'FAIL the deleted account is still there'; exit 1; }
[ "$(psql -tAc "select count(*) from public.profiles p left join public.accounts a on a.id = p.account_id where a.id is null")" = 0 ] \
    || { echo 'FAIL players without an account'; exit 1; }
[ "$(psql -tAc "select count(*) from public.plays")" = 0 ] || { echo 'FAIL plays of the deleted account'; exit 1; }
echo "ok   the database holds only what is left"
