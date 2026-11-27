-- What every Supabase project has, cut to what the migration uses: the API roles, auth.users and auth.uid().
-- Only for test/run.sh: on Supabase these come with the project.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_auth_admin nologin;

create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, supabase_auth_admin;
grant execute on function auth.uid() to anon, authenticated;
grant select, insert, update, delete on auth.users to supabase_auth_admin;

-- Supabase grants the API roles everything on new tables in public and leaves the rest to row level security.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
