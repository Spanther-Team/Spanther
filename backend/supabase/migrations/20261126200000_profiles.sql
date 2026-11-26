-- SPANTHER: accounts, players (profiles), plays and the admin's log.
--
-- One adult account holds the players of a family or a specialist. The phone keeps everything itself and works
-- without the network; after sign-in it sends what changed and takes what is newer (backend/README.md).
-- Never here: camera video, a player's calibration or gaze model, session CSVs, the clinic's children.
--
-- The same file runs on Supabase Cloud and on our own Supabase (auth.users and auth.uid() come from Supabase Auth).
-- The app reaches the tables with the public (anon) key and the user's sign-in token; the rows of other accounts
-- are closed by row level security below. The service_role key never goes into the app.

-- MARK: Accounts

create table public.accounts (
    id            uuid primary key references auth.users (id) on delete cascade,
    language      text not null default 'ru' check (language in ('ru', 'kk', 'en')),
    role          text not null default 'user' check (role in ('user', 'admin')),
    premium_until timestamptz,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Every sign-up gets its account row; role and premium start at user and none.
create function public.handle_new_user() returns trigger
    language plpgsql security definer set search_path = '' as $$
begin
    insert into public.accounts (id) values (new.id) on conflict (id) do nothing;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- True for the signed-in admin. Security definer, so the accounts policy can call it without looping.
create function public.is_admin() returns boolean
    language sql stable security definer set search_path = '' as $$
    select exists (select 1 from public.accounts where id = auth.uid() and role = 'admin');
$$;

alter table public.accounts enable row level security;

create policy "accounts: own row, admins all" on public.accounts
    for select to authenticated using (id = auth.uid() or public.is_admin());

-- The owner may change only the language; role and premium change through set_role and set_premium.
create policy "accounts: owner updates" on public.accounts
    for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke insert, update, delete on public.accounts from anon, authenticated;
revoke all on public.accounts from anon;
grant update (language) on public.accounts to authenticated;

-- MARK: Players

create table public.profiles (
    id                uuid primary key,            -- made on the phone (PlayerProfile.id)
    account_id        uuid not null default auth.uid() references public.accounts (id) on delete cascade,
    -- The app cuts a name to 24 letters; a letter can take several code points (emoji), hence the room.
    name              text not null check (char_length(name) between 1 and 64),
    avatar            smallint not null default 0 check (avatar between 0 and 15),
    birth_year        smallint check (birth_year between 1900 and 2100),
    -- Game progress, a flat object of strings: {"winkbeat.hardOpen": "1", "winkbeat.lastDifficulty": "normal"}.
    progress          jsonb not null default '{}' check (jsonb_typeof(progress) = 'object'),
    created_at        timestamptz not null,        -- the phone's clocks
    updated_at        timestamptz not null,
    deleted_at        timestamptz,                 -- a tombstone, so a deletion reaches every phone
    server_updated_at timestamptz not null default now()  -- the server's clock: what a phone pulls after its last sync
);

create index profiles_pull on public.profiles (account_id, server_updated_at);

-- A second phone that was offline must not undo newer changes, and an open level never closes again:
--   * the newer updated_at wins for name, colour and birth year;
--   * progress keys from both sides stay, the newer side's value wins a key both have;
--   * a deleted player stays deleted;
--   * a write that changes nothing is skipped, so the other phones do not pull the row again.
create function public.profiles_merge() returns trigger
    language plpgsql set search_path = '' as $$
begin
    new.id := old.id;
    new.account_id := old.account_id;
    new.created_at := old.created_at;
    if new.updated_at < old.updated_at then
        new.name := old.name;
        new.avatar := old.avatar;
        new.birth_year := old.birth_year;
        new.progress := new.progress || old.progress;
        new.updated_at := old.updated_at;
    else
        new.progress := old.progress || new.progress;
    end if;
    new.deleted_at := coalesce(old.deleted_at, new.deleted_at);
    if (new.name, new.avatar, new.birth_year, new.progress, new.updated_at, new.deleted_at)
        is not distinct from (old.name, old.avatar, old.birth_year, old.progress, old.updated_at, old.deleted_at) then
        return null;
    end if;
    new.server_updated_at := now();
    return new;
end $$;

create trigger profiles_merge
    before update on public.profiles
    for each row execute function public.profiles_merge();

create function public.profiles_stamp() returns trigger
    language plpgsql set search_path = '' as $$
begin
    new.server_updated_at := now();
    return new;
end $$;

create trigger profiles_stamp
    before insert on public.profiles
    for each row execute function public.profiles_stamp();

alter table public.profiles enable row level security;

-- Only the account's owner. No delete: a player leaves a tombstone (deleted_at); deleting the account removes all.
create policy "profiles: owner reads" on public.profiles
    for select to authenticated using (account_id = auth.uid());
create policy "profiles: owner adds" on public.profiles
    for insert to authenticated with check (account_id = auth.uid());
create policy "profiles: owner changes" on public.profiles
    for update to authenticated using (account_id = auth.uid()) with check (account_id = auth.uid());
revoke delete on public.profiles from anon, authenticated;
revoke all on public.profiles from anon;

-- MARK: Plays

-- One play's result. Only added, never changed: sending the same play again (same id) does nothing.
create table public.plays (
    id                uuid primary key,            -- made on the phone, like SessionSummary.id
    account_id        uuid not null default auth.uid() references public.accounts (id) on delete cascade,
    profile_id        uuid not null references public.profiles (id) on delete cascade,
    game              text not null check (game ~ '^[a-z0-9-]{1,32}$'),  -- meteors, winkbeat, pursuit, ...
    difficulty        text check (char_length(difficulty) <= 32),
    by_eye            boolean not null,
    started_at        timestamptz not null,
    duration_sec      real not null check (duration_sec >= 0),
    score             integer,
    accuracy          real check (accuracy between 0 and 1),  -- the share of targets hit
    hits              integer check (hits >= 0),
    misses            integer check (misses >= 0),
    build             text check (char_length(build) <= 40),  -- "1.0.4 (10)"
    server_created_at timestamptz not null default now()
);

create index plays_by_profile on public.plays (profile_id, started_at);
create index plays_pull on public.plays (account_id, server_created_at);

alter table public.plays enable row level security;

create policy "plays: owner reads" on public.plays
    for select to authenticated using (account_id = auth.uid());
create policy "plays: owner adds for own players" on public.plays
    for insert to authenticated with check (
        account_id = auth.uid()
        and exists (select 1 from public.profiles p where p.id = profile_id and p.account_id = auth.uid())
    );
revoke update, delete on public.plays from anon, authenticated;
revoke all on public.plays from anon;

-- MARK: The admin

-- What the admins changed and when. It outlives a deleted account, so target_id has no reference.
create table public.admin_log (
    id        bigint generated always as identity primary key,
    at        timestamptz not null default now(),
    admin_id  uuid references public.accounts (id) on delete set null,
    target_id uuid not null,
    action    text not null,
    detail    jsonb not null default '{}'
);

alter table public.admin_log enable row level security;

create policy "admin_log: admins read" on public.admin_log
    for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.admin_log from anon, authenticated;
revoke all on public.admin_log from anon;

-- Every change of premium or role goes into the log, made through the functions below or by hand in the
-- Supabase panel (there the admin is not signed in, so admin_id stays empty).
create function public.accounts_log() returns trigger
    language plpgsql security definer set search_path = '' as $$
begin
    if new.premium_until is distinct from old.premium_until then
        insert into public.admin_log (admin_id, target_id, action, detail)
            values (auth.uid(), new.id, 'premium', jsonb_build_object('from', old.premium_until, 'until', new.premium_until));
    end if;
    if new.role is distinct from old.role then
        insert into public.admin_log (admin_id, target_id, action, detail)
            values (auth.uid(), new.id, 'role', jsonb_build_object('from', old.role, 'role', new.role));
    end if;
    return null;
end $$;

create trigger accounts_log
    after update on public.accounts
    for each row execute function public.accounts_log();

-- Premium until a date (null takes it away). Admins only.
create function public.set_premium(target uuid, until timestamptz) returns void
    language plpgsql security definer set search_path = '' as $$
begin
    if not public.is_admin() then
        raise exception 'admin only' using errcode = '42501';
    end if;
    update public.accounts set premium_until = until, updated_at = now() where id = target;
    if not found then
        raise exception 'no account %', target using errcode = 'P0002';
    end if;
end $$;

-- User or admin. Admins only, and an admin cannot take their own role away (there is always one left).
create function public.set_role(target uuid, new_role text) returns void
    language plpgsql security definer set search_path = '' as $$
begin
    if not public.is_admin() then
        raise exception 'admin only' using errcode = '42501';
    end if;
    if target = auth.uid() and new_role <> 'admin' then
        raise exception 'an admin cannot drop their own role' using errcode = '42501';
    end if;
    update public.accounts set role = new_role, updated_at = now() where id = target;
    if not found then
        raise exception 'no account %', target using errcode = 'P0002';
    end if;
end $$;

revoke execute on function public.set_premium(uuid, timestamptz) from public, anon;
revoke execute on function public.set_role(uuid, text) from public, anon;
grant execute on function public.set_premium(uuid, timestamptz) to authenticated;
grant execute on function public.set_role(uuid, text) to authenticated;
