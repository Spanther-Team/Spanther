-- Who can read and change what, after the migration. Each failed check stops the run with its message.
-- Two adults: A (a parent, later the admin) and B. Run by test/run.sh.

\set A '''a0000000-0000-4000-8000-000000000001'''
\set B '''b0000000-0000-4000-8000-000000000002'''
\set MIRA '''c0000000-0000-4000-8000-000000000001'''
\set GONE '''c0000000-0000-4000-8000-000000000002'''

-- Sign-ups make accounts.
set role supabase_auth_admin;
insert into auth.users (id, email) values (:A, 'a@test'), (:B, 'b@test');
reset role;
do $$ begin
    assert (select count(*) from public.accounts where role = 'user') = 2, 'every sign-up gets a user account';
    assert (select email from public.accounts where id = 'b0000000-0000-4000-8000-000000000002') = 'b@test',
           'the account keeps the sign-in email';
end $$;
set role supabase_auth_admin;
update auth.users set email = 'b2@test' where id = :B;
reset role;
do $$ begin
    assert (select email from public.accounts where id = 'b0000000-0000-4000-8000-000000000002') = 'b2@test',
           'a changed sign-in email is copied';
end $$;

-- A adds two players. B neither sees them nor takes them.
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
insert into public.profiles (id, name, avatar, progress, created_at, updated_at) values
    (:MIRA, 'Мира', 1, '{"winkbeat.hardOpen": "1"}', '2026-11-26 10:00Z', '2026-11-26 10:00Z'),
    (:GONE, 'Тимур', 2, '{}', '2026-11-26 10:00Z', '2026-11-26 10:00Z');
do $$ begin assert (select count(*) from public.profiles) = 2, 'A sees her players'; end $$;

set request.jwt.claim.sub = 'b0000000-0000-4000-8000-000000000002';
do $$ begin assert (select count(*) from public.profiles) = 0, 'B does not see the players of A'; end $$;
do $$ begin
    begin
        insert into public.profiles (id, account_id, name, created_at, updated_at)
            values ('c0000000-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000001', 'X', now(), now());
        raise exception 'B added a player to the account of A';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        insert into public.profiles (id, name, created_at, updated_at)
            values ('c0000000-0000-4000-8000-000000000001', 'Чужой', now(), now())
            on conflict (id) do update set name = excluded.name, updated_at = excluded.updated_at;
        raise exception 'B took a player of A by its id';
    exception when insufficient_privilege then null;
    end;
end $$;

-- Two phones of A: an older write from the one that was offline does not undo the newer name, and its progress
-- keys still count.
set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
update public.profiles set name = 'Мира старая', progress = '{"winkbeat.lastDifficulty": "easy"}',
    updated_at = '2026-11-26 09:00Z' where id = :MIRA;
do $$ declare p public.profiles; begin
    select * into p from public.profiles where id = 'c0000000-0000-4000-8000-000000000001';
    assert p.name = 'Мира', 'an older write does not undo a newer name';
    assert p.progress = '{"winkbeat.hardOpen": "1", "winkbeat.lastDifficulty": "easy"}', 'its progress keys still count';
    assert p.updated_at = '2026-11-26 10:00Z', 'the newer time stays';
end $$;

-- A newer write wins its fields and values, and an open level stays open.
update public.profiles set name = 'Мирочка', progress = '{"winkbeat.lastDifficulty": "normal"}',
    updated_at = '2026-11-26 11:00Z' where id = :MIRA;
do $$ declare p public.profiles; begin
    select * into p from public.profiles where id = 'c0000000-0000-4000-8000-000000000001';
    assert p.name = 'Мирочка', 'a newer write wins';
    assert p.progress ->> 'winkbeat.lastDifficulty' = 'normal', 'the newer value wins a key both sides have';
    assert p.progress ->> 'winkbeat.hardOpen' = '1', 'an open level never closes';
end $$;

-- The same write again changes nothing, so the other phones do not pull it again.
create temp table seen as select server_updated_at from public.profiles where id = :MIRA;
select pg_sleep(0.05) \g /dev/null
update public.profiles set name = 'Мирочка', updated_at = '2026-11-26 11:00Z' where id = :MIRA;
do $$ begin
    assert (select server_updated_at from seen) =
           (select server_updated_at from public.profiles where id = 'c0000000-0000-4000-8000-000000000001'),
           'a write that changes nothing is skipped';
end $$;
-- A real change moves the pull mark.
update public.profiles set avatar = 3, updated_at = '2026-11-26 11:30Z' where id = :MIRA;
do $$ begin
    assert (select server_updated_at from seen) <
           (select server_updated_at from public.profiles where id = 'c0000000-0000-4000-8000-000000000001'),
           'a change moves server_updated_at';
end $$;

-- A deleted player stays deleted, and rows are never deleted by the app.
update public.profiles set deleted_at = '2026-11-26 12:00Z', updated_at = '2026-11-26 12:00Z' where id = :GONE;
update public.profiles set deleted_at = null, name = 'Тимур снова', updated_at = '2026-11-26 13:00Z' where id = :GONE;
do $$ begin
    assert (select deleted_at from public.profiles where id = 'c0000000-0000-4000-8000-000000000002') = '2026-11-26 12:00Z',
           'a deleted player stays deleted';
end $$;
do $$ begin
    begin
        delete from public.profiles where id = 'c0000000-0000-4000-8000-000000000002';
        raise exception 'the app deleted a player row';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        update public.profiles set account_id = 'b0000000-0000-4000-8000-000000000002',
            updated_at = '2026-11-26 14:00Z' where id = 'c0000000-0000-4000-8000-000000000001';
    exception when insufficient_privilege then null;
    end;
    assert (select account_id from public.profiles where id = 'c0000000-0000-4000-8000-000000000001')
           = 'a0000000-0000-4000-8000-000000000001', 'a player never moves to another account';
end $$;

-- Plays: added once, never changed.
insert into public.plays (id, profile_id, game, difficulty, by_eye, started_at, duration_sec, score, accuracy, hits,
                          misses, build)
    values ('d0000000-0000-4000-8000-000000000001', :MIRA, 'winkbeat', 'normal', true, '2026-11-26 10:05Z', 92.5,
            18200, 0.86, 43, 7, '1.0.4 (10)');
insert into public.plays (id, profile_id, game, difficulty, by_eye, started_at, duration_sec, score, accuracy, hits,
                          misses, build)
    values ('d0000000-0000-4000-8000-000000000001', :MIRA, 'winkbeat', 'normal', true, '2026-11-26 10:05Z', 92.5,
            18200, 0.86, 43, 7, '1.0.4 (10)')
    on conflict (id) do nothing;
do $$ begin assert (select count(*) from public.plays) = 1, 'the same play sent twice is kept once'; end $$;
do $$ begin
    begin
        update public.plays set score = 1;
        raise exception 'a play was changed';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        delete from public.plays;
        raise exception 'a play was deleted';
    exception when insufficient_privilege then null;
    end;
end $$;

set request.jwt.claim.sub = 'b0000000-0000-4000-8000-000000000002';
do $$ begin assert (select count(*) from public.plays) = 0, 'B sees no plays of A'; end $$;
do $$ begin
    begin
        insert into public.plays (id, profile_id, game, by_eye, started_at, duration_sec)
            values ('d0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000001', 'meteors', true,
                    now(), 60);
        raise exception 'B added a play for a player of A';
    exception when insufficient_privilege then null;
    end;
end $$;

-- An account: the owner changes the language, never the role or premium.
set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
update public.accounts set language = 'kk' where id = :A;
do $$ begin
    assert (select language from public.accounts where id = 'a0000000-0000-4000-8000-000000000001') = 'kk',
           'the owner changes the language';
    assert (select count(*) from public.accounts) = 1, 'a user sees only their own account';
end $$;
do $$ begin
    begin
        update public.accounts set premium_until = now() + interval '1 year'
            where id = 'a0000000-0000-4000-8000-000000000001';
        raise exception 'a user gave themselves premium';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        update public.accounts set email = 'other@test' where id = 'a0000000-0000-4000-8000-000000000001';
        raise exception 'a user changed the copied email';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        update public.accounts set role = 'admin' where id = 'a0000000-0000-4000-8000-000000000001';
        raise exception 'a user made themselves admin';
    exception when insufficient_privilege then null;
    end;
end $$;
do $$ begin
    begin
        perform public.set_premium('a0000000-0000-4000-8000-000000000001', now() + interval '1 year');
        raise exception 'set_premium let a user in';
    exception when insufficient_privilege then null;
    end;
end $$;

-- The admin: made once in the SQL editor, then gives premium through set_premium; each change is logged.
reset role;
set request.jwt.claim.sub = '';
update public.accounts set role = 'admin' where id = :A;
set role authenticated;
set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
select public.set_premium(:B, '2027-11-26Z') \g /dev/null
do $$ begin
    assert (select premium_until from public.accounts where id = 'b0000000-0000-4000-8000-000000000002') = '2027-11-26Z',
           'the admin gives premium';
    assert (select count(*) from public.accounts) = 2, 'the admin sees every account';
    assert (select id from public.accounts where lower(email) = 'b2@test') = 'b0000000-0000-4000-8000-000000000002',
           'the admin finds a person by email';
    assert (select count(*) from public.admin_log
            where action = 'premium' and admin_id = 'a0000000-0000-4000-8000-000000000001') = 1, 'the change is in the log';
    assert (select count(*) from public.admin_log where action = 'role' and admin_id is null) = 1,
           'a change made by hand in the panel is logged too';
end $$;
do $$ begin
    begin
        perform public.set_role('a0000000-0000-4000-8000-000000000001', 'user');
        raise exception 'an admin dropped their own role';
    exception when insufficient_privilege then null;
    end;
end $$;

set request.jwt.claim.sub = 'b0000000-0000-4000-8000-000000000002';
do $$ begin
    assert (select premium_until from public.accounts) = '2027-11-26Z', 'B sees their premium';
    assert (select count(*) from public.admin_log) = 0, 'B cannot read the log';
end $$;

-- Without sign-in nothing at all.
set role anon;
set request.jwt.claim.sub = '';
do $$ begin
    begin
        perform count(*) from public.profiles;
        raise exception 'anon read the players';
    exception when insufficient_privilege then null;
    end;
    begin
        perform count(*) from public.accounts;
        raise exception 'anon read the accounts';
    exception when insufficient_privilege then null;
    end;
    begin
        perform count(*) from public.plays;
        raise exception 'anon read the plays';
    exception when insufficient_privilege then null;
    end;
end $$;

-- Deleting the account from the app: only one's own, only signed in.
do $$ begin
    begin
        perform public.delete_my_account();
        raise exception 'anon deleted an account';
    exception when insufficient_privilege then null;
    end;
end $$;
set role authenticated;
do $$ begin
    begin
        perform public.delete_my_account();
        raise exception 'delete_my_account ran without a signed-in user';
    exception when insufficient_privilege then null;
    end;
end $$;
set request.jwt.claim.sub = 'b0000000-0000-4000-8000-000000000002';
select public.delete_my_account() \g /dev/null
reset role;
do $$ begin
    assert (select count(*) from auth.users where id = 'b0000000-0000-4000-8000-000000000002') = 0, 'B deleted their sign-in';
    assert (select count(*) from public.accounts where id = 'b0000000-0000-4000-8000-000000000002') = 0,
           'and with it their account';
    assert (select count(*) from public.accounts where id = 'a0000000-0000-4000-8000-000000000001') = 1,
           'the account of A stays';
    assert (select count(*) from public.profiles) = 2, 'the players of A stay';
end $$;

-- Deleting the account (as delete_my_account or the Supabase panel do) removes its players and plays at once;
-- the log keeps the change, without the admin.
set request.jwt.claim.sub = '';
set role supabase_auth_admin;
delete from auth.users where id = :A;
reset role;
do $$ begin
    assert (select count(*) from public.accounts where id = 'a0000000-0000-4000-8000-000000000001') = 0, 'the account goes';
    assert (select count(*) from public.profiles) = 0, 'its players go';
    assert (select count(*) from public.plays) = 0, 'its plays go';
    assert (select count(*) from public.admin_log where action = 'premium' and admin_id is null) = 1,
           'the log stays, without the admin';
end $$;

\echo 'backend checks passed'
