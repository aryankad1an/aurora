-- Fresher hiring: links, logos, routes and sources for each company.
-- Safe to re-run. Run it in the Supabase SQL editor before the import.

-- What a company's own site says about it, and how it hires freshers.
alter table companies
  add column if not exists website        text,
  add column if not exists website_source text,     -- how the website was found
  add column if not exists careers_url    text,
  add column if not exists careers_source text,     -- how the careers page was found
  add column if not exists logo_url       text,     -- a square PNG on the company's own site
  add column if not exists is_fresher     boolean not null default false,
  add column if not exists ledger_ids     text[]  not null default '{}',  -- Fresher Hiring Ledger ids
  add column if not exists company_type   text,     -- Product / MNC, IT services / consulting, …
  add column if not exists route_category text,     -- off_campus | route_unclear | on_campus_or_intern_only
  add column if not exists hiring_routes  text[]  not null default '{}',
  add column if not exists open_now       boolean not null default false,
  add column if not exists usually_opens  text,     -- e.g. "Sep, Dec"
  add column if not exists batches        text[]  not null default '{}',
  add column if not exists fresher_roles  text[]  not null default '{}';

create index if not exists companies_is_fresher_idx on companies (name) where is_fresher;

-- The evidence behind a company's fresher hiring: a job post, an offer
-- write-up, a placement page. Each carries the package it states, if any.
-- `is_valid` is shared, like a contact's: a source shown to be wrong is wrong
-- for everyone, and an invalid source no longer counts toward the package.
create table if not exists company_sources (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies (id) on delete cascade,
  ledger_id     text,                 -- the ledger company it came from; null when added in the app
  route         text not null,        -- off_campus_opening, on_campus, intern_conversion_or_ppo, …
  role          text,
  location      text,
  batch         text,
  source_code   text,                 -- lc, tg, jt, … (null when added in the app)
  source_label  text,                 -- "LeetCode offer post"
  url           text,
  proof_url     text,                 -- a permanent snapshot of the posting
  posted_on     text,                 -- YYYY-MM-DD, or YYYY-MM when only the month is known
  confidence    text,
  open_now      boolean not null default false,
  package_lpa   numeric,              -- lakh INR a year, when it's one number
  package_text  text,                 -- when it's a range or has notes ("₹4–4.5L")
  is_valid      boolean not null default true,
  fingerprint   text,                 -- identifies an imported row, so a re-import updates it
  edited_at     timestamptz,          -- set when edited in the app; a re-import leaves it alone
  created_at    timestamptz not null default now(),
  unique (company_id, fingerprint)
);
alter table company_sources add column if not exists edited_at timestamptz;
create index if not exists company_sources_company_idx on company_sources (company_id);

-- Shared like the rest of the catalog: anyone using the app can read and
-- correct it, the same access `recruiters` gives.
grant select, insert, update, delete on company_sources to anon, authenticated;
alter table company_sources enable row level security;
drop policy if exists "company_sources are shared" on company_sources;
create policy "company_sources are shared" on company_sources
  for all to anon, authenticated using (true) with check (true);
