-- A company's LinkedIn, X and Facebook pages, kept per vault (Aurora 2.3).
-- Safe to re-run, before or after rls_migration.sql.
--
-- The catalog itself stays shared and plain. These links are each vault's
-- own: sealed under the vault's key like its contacts (`l`, `x` and `f` in
-- `sealed`), so only the vault's owner and the accounts that imported its code
-- can open them. One row per vault and company.

create table if not exists company_links (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies (id) on delete cascade,
  vault_id    uuid not null references vaults (id) on delete cascade,
  key_id      uuid not null,
  sealed      text not null,
  updated_at  timestamptz not null default now(),
  unique (company_id, vault_id)
);
create index if not exists company_links_vault_idx on company_links (vault_id);

alter table company_links enable row level security;

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

do $$
declare
  p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'company_links' loop
    execute format('drop policy %I on public.company_links', p.policyname);
  end loop;

  if to_regprocedure('public.owned_vaults()') is null then
    -- Before rls_migration.sql: open to the app's key, like every other table;
    -- the sealing keeps them private.
    grant select, insert, update, delete on company_links to anon, authenticated;
    create policy "links are sealed" on company_links
      for all to anon, authenticated using (true) with check (true);
  else
    -- After it: the same rules rls_migration.sql gives this table.
    revoke all on company_links from anon;
    grant select, insert, update, delete on company_links to authenticated;
    create policy "links: read the vaults you hold" on company_links for select to authenticated
      using (vault_id in (select public.owned_vaults()) or vault_id in (select public.granted_vaults()));
    create policy "links: write your own" on company_links for all to authenticated
      using (vault_id in (select public.owned_vaults()))
      with check (vault_id in (select public.owned_vaults()));
    -- Deleting a company takes its links with it, so no one may delete one
    -- holding another vault's links.
    drop policy if exists "catalog: delete when no one else has contacts there" on companies;
    create policy "catalog: delete when no one else has contacts there" on companies for delete to authenticated
      using (not exists (
        select 1 from recruiters r
        where r.company_id = companies.id
          and (r.vault_id is null or r.vault_id not in (select public.owned_vaults()))
      ) and not public.company_links_elsewhere(companies.id));
  end if;
end $$;

notify pgrst, 'reload schema';
