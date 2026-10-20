-- Private contacts, end-to-end encrypted (Aurora 2.1). Safe to re-run.
--
-- Contacts belong to a vault: one per user, found by its public code
-- ("AURORA") and opened with its private key, which never leaves the phone.
-- The app seals a contact's name, address, position, phone and greeting into
-- `recruiters.sealed`; the plain columns are emptied once it has. A user's
-- mail history, templates and profile are sealed the same way under their
-- account key, which is kept in iCloud Keychain and backed up by a recovery
-- phrase.
--
-- What stays readable: companies (a shared public catalog), which company a
-- contact is filed under, whether it's marked invalid, and when mail was sent
-- or answered — so "already mailed" survives even a lost account key.

create table if not exists vaults (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,          -- the public code, upper case
  owner_email         text not null unique,          -- the Gmail account that owns it
  -- The current data key, sealed under a key made from the private key
  -- (PBKDF2-SHA256). Null until the owner sets a private key.
  key_id              uuid,
  kdf_salt            text,
  kdf_rounds          int,
  sealed_key          text,
  -- A private-key change in progress: the new key, so it can finish after a
  -- crash without the new private key being typed again.
  pending_key_id      uuid,
  pending_kdf_salt    text,
  pending_kdf_rounds  int,
  pending_sealed_key  text,
  -- The owner's account key, sealed under their recovery phrase.
  recovery_salt       text,
  recovery_rounds     int,
  sealed_account_key  text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Each account's way into a vault: the vault's key sealed under the account
-- key. One for the owner's own vault, one per import.
create table if not exists vault_grants (
  account_email  text not null,
  vault_id       uuid not null references vaults (id) on delete cascade,
  key_id         uuid not null,
  sealed_key     text not null,
  created_at     timestamptz not null default now(),
  primary key (account_email, vault_id, key_id)
);

-- Contacts: who owns each one, and the sealed fields.
alter table recruiters
  add column if not exists vault_id uuid references vaults (id),
  add column if not exists key_id   uuid,
  add column if not exists sealed   text;
create index if not exists recruiters_vault_idx on recruiters (vault_id);
alter table recruiters alter column name drop not null,
                       alter column email drop not null;

-- Mail history: subject and body in `sealed`, who answered and what they
-- said in `sealed_reply`.
alter table mail_sends
  add column if not exists sealed       text,
  add column if not exists sealed_reply text;
alter table mail_sends alter column subject drop not null,
                       alter column body drop not null;

alter table templates add column if not exists sealed text;
alter table templates alter column name drop not null,
                      alter column subject drop not null,
                      alter column content drop not null;

alter table profiles add column if not exists sealed text;
alter table profiles alter column name drop not null;

-- The contacts on file today are realaryankadian@gmail.com's, under the code
-- AURORA. The private key is chosen in the app at the first sign-in after
-- this, which then seals every one of them.
insert into vaults (code, owner_email)
values ('AURORA', 'realaryankadian@gmail.com')
on conflict do nothing;
update recruiters
set vault_id = (select id from vaults where owner_email = 'realaryankadian@gmail.com')
where vault_id is null;

-- Readable and writable with the app's key, like every other table: what
-- keeps them private is the sealing, not the server.
grant select, insert, update, delete on vaults, vault_grants to anon, authenticated;
alter table vaults enable row level security;
alter table vault_grants enable row level security;
drop policy if exists "vaults are sealed" on vaults;
create policy "vaults are sealed" on vaults
  for all to anon, authenticated using (true) with check (true);
drop policy if exists "vault grants are sealed" on vault_grants;
create policy "vault grants are sealed" on vault_grants
  for all to anon, authenticated using (true) with check (true);

notify pgrst, 'reload schema';
