-- What a Supabase project's database has before Supabase Auth makes its tables: the API roles and the auth schema.
-- Only for test/e2e.sh: on Supabase these come with the project.
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role authenticator login noinherit password 'rest';
grant anon, authenticated, service_role to authenticator;
create role supabase_auth_admin login noinherit createrole password 'auth';
create schema auth authorization supabase_auth_admin;
grant create on database postgres to supabase_auth_admin;
alter role supabase_auth_admin set search_path = auth;

-- Supabase grants the API roles everything on new tables in public and leaves the rest to row level security.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
