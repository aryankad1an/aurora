-- Until rls_migration.sql runs: a phone signed in with Google gets what the
-- publishable key already has. Safe to re-run; rls_migration.sql replaces it.
--
-- Turning on Google sign-in makes the app send its session, so requests come
-- in as `authenticated`, not `anon`. Three tables' old policies named `anon`
-- alone: a signed-in phone saw no profile (and offered to set one up), no sent
-- mail, and was refused every write to them.

alter policy "anon all" on public.profiles to anon, authenticated;
alter policy "anon all" on public.mail_sends to anon, authenticated;
alter policy "anon all" on public.user_companies to anon, authenticated;

grant select, insert, update, delete on public.profiles, public.mail_sends, public.user_companies
  to authenticated;

notify pgrst, 'reload schema';
