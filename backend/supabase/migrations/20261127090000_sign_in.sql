-- SPANTHER, stage 2: sign-in by email and password, and deleting the account from the app.
-- Runs after 20261126200000_profiles.sql, also on a database that already has accounts.

-- MARK: The sign-in email on the account

-- A copy of the sign-in email, so an admin finds a person by it (auth.users is not open to the app's key).
alter table public.accounts add column email text;
create index accounts_email on public.accounts (lower(email));
update public.accounts a set email = u.email from auth.users u where u.id = a.id;

create or replace function public.handle_new_user() returns trigger
    language plpgsql security definer set search_path = '' as $$
begin
    insert into public.accounts (id, email) values (new.id, new.email) on conflict (id) do nothing;
    return new;
end $$;

-- A changed sign-in email is copied too.
create function public.handle_user_email() returns trigger
    language plpgsql security definer set search_path = '' as $$
begin
    update public.accounts set email = new.email, updated_at = now() where id = new.id;
    return new;
end $$;

create trigger on_auth_user_email
    after update of email on auth.users
    for each row when (new.email is distinct from old.email)
    execute function public.handle_user_email();

-- MARK: Deleting the account from the app

-- The signed-in adult deletes their own account at once (App Store guideline 5.1.1(v)): the sign-in goes, and with
-- it the account, its players and their plays (on delete cascade). The admin's log keeps its lines without the
-- admin. Only the caller's own account: the function takes no id.
create function public.delete_my_account() returns void
    language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null then
        raise exception 'sign in first' using errcode = '42501';
    end if;
    delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
