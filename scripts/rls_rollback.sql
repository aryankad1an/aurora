-- Undo rls_migration.sql: back to the publishable key reading and writing
-- every table, as before. Only for getting an older build working again —
-- it reopens every row to anyone holding the key.

do $$
declare
  t text;
  p record;
begin
  foreach t in array array['companies', 'company_sources', 'recruiters', 'mail_sends', 'profiles',
                           'templates', 'tracked_companies', 'user_companies', 'vaults', 'vault_grants'] loop
    if to_regclass('public.' || t) is null then continue; end if;
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
    execute format('create policy "open" on public.%I for all to anon, authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop trigger if exists recruiters_guard on recruiters;

do $$
begin
  if to_regprocedure('public.companies_known_as(text)') is not null then
    grant execute on function public.companies_known_as(text) to anon, authenticated;
  end if;
end $$;

notify pgrst, 'reload schema';
