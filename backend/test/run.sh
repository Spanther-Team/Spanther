#!/usr/bin/env bash
# Runs the migration on a throwaway Postgres in Docker and checks who can read and change what.
#   backend/test/run.sh          (PG_IMAGE=postgres:16 by default)
set -euo pipefail
cd "$(dirname "$0")/.."
name=spanther-backend-test
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -e POSTGRES_PASSWORD=test "${PG_IMAGE:-postgres:16}" >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
# Over TCP: the image's first, setup-only server listens on the socket alone.
for _ in $(seq 60); do
    docker exec "$name" psql -U postgres -h 127.0.0.1 -qtc 'select 1' >/dev/null 2>&1 && break
    sleep 1
done
run() { docker exec -i "$name" psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 -q "$@"; }
run < test/auth_stub.sql
run < supabase/migrations/20261126200000_profiles.sql
run < test/rls_test.sql
