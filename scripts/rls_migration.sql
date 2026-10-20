-- Per-account access (Aurora 2.2). Safe to re-run.
--
-- Until now every request went out under the app's publishable key, which
-- ships in the app and is in this repository, so the server couldn't tell one
-- account from another: anyone holding the key could delete or overwrite any
-- row. Sealing (vault_migration.sql) already keeps the contents private; this
-- closes the write side. The app now signs in to Supabase with the account's
-- Google sign-in, and these rules key on the address in that session:
--
--   * Your sends, templates, profile, tracked companies and vault grants: only
--     you can read or change them.
--   * Contacts: anyone signed in can read the sealed rows (counting other
--     people's contacts under a company needs it); only a vault's owner can
--     add, edit or delete its contacts; someone who imported a vault can mark
--     its contacts valid or invalid, and nothing else.
--   * Vaults: readable by anyone signed in (an import looks one up by its
--     code); only the owner can change theirs.
--   * Companies and their sources stay a shared catalog anyone signed in can
--     correct. A company can only be deleted when no one else has contacts
--     or company links under it.
--   * Company links (company_links_migration.sql): only the accounts holding
--     a vault's key can read its rows; only the owner can change them.
--   * The publishable key alone (no session) is refused everything.
--
-- Run it only after:
--   1. Authentication → Sign In / Providers → Google is enabled, with the app's
--      iOS client ID (AppConfig.googleClientID) under "Client IDs".
--   2. Every phone has this build and has opened it once: Authentication →
--      Users lists each account. An older build sends no session, and after
--      this it can't read or write anything.
-- The Python scripts then need the project's secret key: set
-- SUPABASE_SERVICE_KEY (Project Settings → API Keys). It bypasses these rules,
-- so keep it out of the repository.
--
-- To undo: rls_rollback.sql.

-- The signed-in account's address, lower-cased. Null without a session.
create or replace function public.auth_email() returns text
language sql stable as $$
  select lower(nullif(auth.jwt() ->> 'email', ''))
$$;

-- The vaults the signed-in account owns, and the ones it holds a key to.
create or replace function public.owned_vaults() returns setof uuid
language sql stable as $$
  select id from public.vaults where lower(owner_email) = public.auth_email()
$$;

create or replace function public.granted_vaults() returns setof uuid
language sql stable as $$
  select vault_id from public.vault_grants where lower(account_email) = public.auth_email()
$$;

-- Whether a company holds another vault's links. Runs as its owner: the
-- signed-in account can't see those rows, so a rule asking itself would
-- always find none.
create or replace function public.company_links_elsewhere(cid uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  return exists (select 1 from public.company_links l
                 where l.company_id = cid and l.vault_id not in (select public.owned_vaults()));
end $$;
revoke execute on function public.company_links_elsewhere(uuid) from anon, public;
grant execute on function public.company_links_elsewhere(uuid) to authenticated;

-- Start every table from nothing: no access for the bare key, and none of the
-- old allow-everything policies (policies add up, so one left behind would
-- let everything through again).
do $$
declare
  t text;
  p record;
begin
  foreach t in array array['companies', 'company_sources', 'recruiters', 'mail_sends', 'profiles',
                           'templates', 'tracked_companies', 'user_companies', 'vaults', 'vault_grants',
                           'company_links'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
  end loop;
end $$;
grant usage on all sequences in schema public to authenticated;

-- `admins` (one address) isn't used by the app or the scripts, and its old
-- rules let the publishable key rewrite it. Only the secret key reaches it now.
do $$
declare
  p record;
begin
  if to_regclass('public.admins') is not null then
    alter table public.admins enable row level security;
    revoke all on public.admins from anon, authenticated;
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'admins' loop
      execute format('drop policy %I on public.admins', p.policyname);
    end loop;
  end if;
end $$;

-- The shared catalog.
create policy "catalog: read" on companies for select to authenticated using (true);
create policy "catalog: add" on companies for insert to authenticated with check (true);
create policy "catalog: correct" on companies for update to authenticated using (true) with check (true);
create policy "catalog: delete when no one else has contacts there" on companies for delete to authenticated
  using (not exists (
    select 1 from recruiters r
    where r.company_id = companies.id
      and (r.vault_id is null or r.vault_id not in (select public.owned_vaults()))
  ));

create policy "sources: shared" on company_sources for all to authenticated using (true) with check (true);

-- Contacts.
create policy "contacts: read sealed" on recruiters for select to authenticated using (true);
create policy "contacts: add to your vault" on recruiters for insert to authenticated
  with check (vault_id in (select public.owned_vaults()));
create policy "contacts: change ones you can read" on recruiters for update to authenticated
  using (vault_id in (select public.owned_vaults()) or vault_id in (select public.granted_vaults()))
  with check (vault_id in (select public.owned_vaults()) or vault_id in (select public.granted_vaults()));
create policy "contacts: delete yours" on recruiters for delete to authenticated
  using (vault_id in (select public.owned_vaults()));

-- Row rules can't name columns, so a trigger does: someone who imported a
-- vault may flip a contact's validity, and nothing else; its owner may change
-- anything but can't hand the contact to another vault.
create or replace function public.recruiters_guard() returns trigger
language plpgsql as $$
begin
  -- The secret key and the SQL editor aren't signed-in users.
  if current_user not in ('anon', 'authenticated') then
    return new;
  end if;
  if exists (select 1 from public.owned_vaults() v where v = old.vault_id) then
    if new.vault_id is distinct from old.vault_id
       and not exists (select 1 from public.owned_vaults() v where v = new.vault_id) then
      raise exception 'A contact can only move between your own vaults.' using errcode = '42501';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - 'is_valid' - 'updated_at') is distinct from (to_jsonb(old) - 'is_valid' - 'updated_at') then
    raise exception 'Only the person who added this contact can change it.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists recruiters_guard on recruiters;
create trigger recruiters_guard before update on recruiters
  for each row execute function public.recruiters_guard();

-- Each account's own rows.
create policy "sends: yours" on mail_sends for all to authenticated
  using (lower(user_email) = public.auth_email()) with check (lower(user_email) = public.auth_email());
create policy "profile: yours" on profiles for all to authenticated
  using (lower(email) = public.auth_email()) with check (lower(email) = public.auth_email());
create policy "templates: yours" on templates for all to authenticated
  using (lower(user_email) = public.auth_email()) with check (lower(user_email) = public.auth_email());
create policy "tracked: yours" on tracked_companies for all to authenticated
  using (lower(user_email) = public.auth_email()) with check (lower(user_email) = public.auth_email());
do $$
begin
  if to_regclass('public.user_companies') is not null then
    create policy "tracked (old): yours" on user_companies for all to authenticated
      using (lower(user_email) = public.auth_email()) with check (lower(user_email) = public.auth_email());
  end if;
end $$;

-- Vaults and the keys into them.
create policy "vaults: look up" on vaults for select to authenticated using (true);
create policy "vaults: make yours" on vaults for insert to authenticated
  with check (lower(owner_email) = public.auth_email());
create policy "vaults: change yours" on vaults for update to authenticated
  using (lower(owner_email) = public.auth_email()) with check (lower(owner_email) = public.auth_email());
create policy "vaults: delete yours" on vaults for delete to authenticated
  using (lower(owner_email) = public.auth_email());

create policy "grants: yours" on vault_grants for all to authenticated
  using (lower(account_email) = public.auth_email()) with check (lower(account_email) = public.auth_email());

-- Each vault's sealed company links (company_links_migration.sql): readable
-- by the accounts holding the vault's key, written only by its owner. A
-- company holding another vault's links can't be deleted, since its links
-- would go with it.
do $$
begin
  if to_regclass('public.company_links') is not null then
    create policy "links: read the vaults you hold" on company_links for select to authenticated
      using (vault_id in (select public.owned_vaults()) or vault_id in (select public.granted_vaults()));
    create policy "links: write your own" on company_links for all to authenticated
      using (vault_id in (select public.owned_vaults()))
      with check (vault_id in (select public.owned_vaults()));
    drop policy "catalog: delete when no one else has contacts there" on companies;
    create policy "catalog: delete when no one else has contacts there" on companies for delete to authenticated
      using (not exists (
        select 1 from recruiters r
        where r.company_id = companies.id
          and (r.vault_id is null or r.vault_id not in (select public.owned_vaults()))
      ) and not public.company_links_elsewhere(companies.id));
  end if;
end $$;

-- Searching other names goes through a function: signed-in only, like the table.
do $$
begin
  if to_regprocedure('public.companies_known_as(text)') is not null then
    revoke execute on function public.companies_known_as(text) from anon, public;
    grant execute on function public.companies_known_as(text) to authenticated;
  end if;
end $$;

notify pgrst, 'reload schema';
