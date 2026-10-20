-- A stand-in for the Supabase project, for test_rls.py only: it drops and
-- rebuilds the whole schema, so never run it against a real database. Its
-- roles, auth.jwt(), and the app's tables as they were before the vault
-- migration (columns from a backup).
drop schema if exists public cascade; drop schema if exists auth cascade;
create schema public; create schema auth;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public, auth to anon, authenticated, service_role;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;

create table companies (id uuid primary key default gen_random_uuid(), name text not null unique, sector text,
  domains text[] default '{}', also_known_as text[] not null default '{}');
create table company_sources (id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade, route text not null, is_valid boolean default true);
create table recruiters (id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null, email text not null, position text, phone text, greeting_name text, is_valid boolean default true,
  updated_at timestamptz default now());
create table mail_sends (id uuid primary key default gen_random_uuid(), user_email text not null,
  recruiter_id uuid references recruiters(id) on delete cascade, sent_at timestamptz default now(),
  subject text not null, body text not null, gmail_message_id text, gmail_thread_id text, replied_at timestamptz,
  reply_from text, reply_snippet text);
create table profiles (email text primary key, name text not null, college text, updated_at timestamptz);
create table templates (id uuid primary key default gen_random_uuid(), user_email text not null,
  name text not null, subject text not null, content text not null, updated_at timestamptz);
create table tracked_companies (user_email text, company_id uuid references companies(id) on delete cascade,
  added_at timestamptz default now(), primary key (user_email, company_id));
create table user_companies (user_email text, company_id uuid references companies(id) on delete cascade,
  added_at timestamptz default now(), primary key (user_email, company_id));
create function companies_known_as(q text) returns setof companies language sql stable as $$
  select * from companies c where exists (select 1 from unnest(c.also_known_as) a where a ilike '%' || q || '%') $$;
grant execute on function companies_known_as(text) to anon, authenticated;
-- An old allow-everything policy, as the project may have.
alter table templates enable row level security;
create policy "Enable all" on templates for all using (true) with check (true);
-- Old policies naming anon alone, as the live project had (rls_bridge.sql widens them).
do $$ declare t text; begin
  foreach t in array array['profiles', 'mail_sends', 'user_companies'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "anon all" on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;
-- An unused table anyone could rewrite.
create table admins (email text primary key);
alter table admins enable row level security;
create policy "anon write admins" on admins for all using (true) with check (true);
insert into admins values ('someone@example.com');

-- Data: realaryankadian owns AURORA (the vault migration files every contact there).
insert into companies (id, name, also_known_as) values
  ('00000000-0000-0000-0000-0000000000c1', 'Acme', '{Acme Labs}'),
  ('00000000-0000-0000-0000-0000000000c2', 'Bolt', '{}'),
  ('00000000-0000-0000-0000-0000000000c3', 'Empty Co', '{}');
insert into recruiters (id, company_id, name, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1', 'x', 'x@acme.example'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000c2', 'y', 'y@bolt.example');
insert into mail_sends (user_email, recruiter_id, subject, body) values
  ('realaryankadian@gmail.com', '00000000-0000-0000-0000-0000000000a1', 's', 'b'),
  ('bob@example.com', '00000000-0000-0000-0000-0000000000a1', 's', 'b');
insert into profiles values ('realaryankadian@gmail.com', 'A'), ('bob@example.com', 'B');
insert into templates (user_email, name, subject, content) values ('realaryankadian@gmail.com', 'n', 's', 'c'), ('bob@example.com', 'n', 's', 'c');
insert into tracked_companies values ('bob@example.com', '00000000-0000-0000-0000-0000000000c1');
