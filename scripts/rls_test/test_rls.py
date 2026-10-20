"""Checks scripts/rls_migration.sql against a throwaway local Postgres.

Starts a temporary cluster (initdb + pg_ctl from PATH, e.g. Homebrew's
postgresql@14), loads a stand-in for the Supabase project (its roles, auth.jwt()
and the app's tables, from supabase_standin.sql), runs vault_migration.sql and
rls_migration.sql twice, then tries each rule as the owner, someone who
imported the vault, an outsider, the bare publishable key and the secret key.
Never touches the real database.

    python3 scripts/rls_test/test_rls.py
"""
import atexit, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
PORT = "54329"

if not shutil.which("initdb") or not shutil.which("pg_ctl"):
    sys.exit("Needs Postgres's initdb and pg_ctl on PATH (brew install postgresql@14).")
data = tempfile.mkdtemp(prefix="aurora-rls-")
subprocess.run(["initdb", "-D", data, "-U", "postgres", "-A", "trust"], check=True, capture_output=True)
# TCP only: the socket path under a temporary directory can be too long.
subprocess.run(["pg_ctl", "-D", data, "-o", f"-p {PORT} -k '' -c listen_addresses=127.0.0.1",
                "-l", os.path.join(data, "log"), "-w", "start"], check=True, capture_output=True)
atexit.register(lambda: (subprocess.run(["pg_ctl", "-D", data, "-m", "fast", "stop"], capture_output=True),
                         shutil.rmtree(data, ignore_errors=True)))

def load(path):
    subprocess.run(["psql", "-h", "127.0.0.1", "-p", PORT, "-U", "postgres", "-q", "-v", "ON_ERROR_STOP=1",
                    "-f", str(path)], check=True, capture_output=True)

load(HERE / "supabase_standin.sql")
load(SCRIPTS / "vault_migration.sql")
load(SCRIPTS / "rls_migration.sql")
load(SCRIPTS / "rls_migration.sql")   # safe to re-run

def psql(sql):
    r = subprocess.run(["psql", "-h", "127.0.0.1", "-p", "54329", "-U", "postgres", "-tAq", "-v", "ON_ERROR_STOP=1"],
                       input=sql, capture_output=True, text=True)
    return r.stdout.strip(), r.stderr.strip()

OWNER, BOB, CAROL = "realaryankadian@gmail.com", "bob@example.com", "carol@example.com"
AURORA = psql("select id from vaults where code='AURORA'")[0]
A1, A2 = "00000000-0000-0000-0000-0000000000a1", "00000000-0000-0000-0000-0000000000a2"
C1, C2, C3 = ("00000000-0000-0000-0000-0000000000c%d" % i for i in (1, 2, 3))
# Setup as the SQL editor: Bob has his own vault with a contact at Bolt, and has imported AURORA.
psql(f"""insert into vaults (id, code, owner_email) values ('00000000-0000-0000-0000-0000000000b0', 'BOBV', '{BOB}');
update recruiters set vault_id='00000000-0000-0000-0000-0000000000b0' where id='{A2}';
insert into vault_grants values ('{OWNER}', '{AURORA}', gen_random_uuid(), 'k'), ('{BOB}', '{AURORA}', gen_random_uuid(), 'k');""")
BOBV = "00000000-0000-0000-0000-0000000000b0"

failures = 0
def case(who, sql, expect, label):
    global failures
    role = {"anon": "anon", "service": "service_role"}.get(who, "authenticated")
    claims = '{"email":"%s"}' % who if role == "authenticated" else "{}"
    out, err = psql(f"begin; set local role {role}; set local request.jwt.claims = '{claims}'; {sql}; commit;")
    got = "ERR" if err and "ERROR" in err else out.splitlines()[-1] if out else ""
    ok = got == str(expect)
    failures += not ok
    print(("  ✓ " if ok else "  ✗ ") + f"{label}: {got}" + ("" if ok else f" (expected {expect}) {err[:160]}"))

n = lambda stmt: f"with r as ({stmt} returning 1) select count(*) from r"

print("bare key")
case("anon", "select count(*) from companies", "ERR", "can't read the catalog")
case("anon", "select count(*) from mail_sends", "ERR", "can't read sends")
case("anon", n(f"update recruiters set is_valid=false where id='{A1}'"), "ERR", "can't touch contacts")
case("anon", n("delete from vault_grants"), "ERR", "can't delete grants")
case("anon", "select count(*) from companies_known_as('labs')", "ERR", "can't search other names")

print("owner")
case(OWNER, "select count(*) from mail_sends", 1, "reads only their own sends")
case(OWNER, "select count(*) from profiles", 1, "reads only their own profile")
case(OWNER, n(f"update profiles set name='x' where email='{BOB}'"), 0, "can't change someone else's profile")
case(OWNER, n(f"insert into templates (user_email, name, subject, content) values ('{BOB}','n','s','c')"), "ERR", "can't write a template as someone else")
case(OWNER, n(f"insert into templates (user_email, name, subject, content) values ('{OWNER}','n2','s','c')"), 1, "writes their own template")
case(OWNER, n(f"update recruiters set name='edited', sealed='s' where id='{A1}'"), 1, "edits their own contact")
case(OWNER, n(f"insert into recruiters (id, company_id, vault_id, sealed) values (gen_random_uuid(), '{C1}', '{AURORA}', 's')"), 1, "adds a contact to their vault")
case(OWNER, n(f"insert into recruiters (id, company_id, vault_id, sealed) values (gen_random_uuid(), '{C1}', '{BOBV}', 's')"), "ERR", "can't add to Bob's vault")
case(OWNER, n(f"insert into recruiters (id, company_id, vault_id, sealed) values ('{A1}', '{C1}', '{AURORA}', 'resealed') on conflict (id) do update set sealed = excluded.sealed"), 1, "reseals in place (upsert)")
case(OWNER, n(f"update recruiters set vault_id='{BOBV}' where id='{A1}'"), "ERR", "can't hand a contact to Bob's vault")
case(OWNER, n(f"update recruiters set name='z' where id='{A2}'"), 0, "can't edit Bob's contact")
case(OWNER, n(f"delete from recruiters where id='{A2}'"), 0, "can't delete Bob's contact")
case(OWNER, f"select count(*) from recruiters where company_id='{C2}' and vault_id <> '{AURORA}'", 1, "counts other people's contacts under a company")
case(OWNER, n(f"update vaults set updated_at=now() where code='AURORA'"), 1, "changes their own vault")
case(OWNER, n(f"update vaults set code='MINE' where code='BOBV'"), 0, "can't change Bob's vault")
case(OWNER, n(f"delete from companies where id='{C2}'"), 0, "can't delete a company where Bob has contacts")
case(OWNER, n(f"update companies set sector='Tech' where id='{C2}'"), 1, "corrects the shared catalog")
case(OWNER, n(f"delete from companies where id='{C3}'"), 1, "deletes a company no one else uses")
case(OWNER, n("insert into companies (name) values ('New Co')"), 1, "adds a company")

print("importer (Bob, holds a key to AURORA)")
case(BOB, f"select count(*) from recruiters where vault_id='{AURORA}'", 2, "reads AURORA's sealed contacts")
case(BOB, n(f"update recruiters set is_valid=false where id='{A1}'"), 1, "marks an imported contact invalid")
case(BOB, n(f"update recruiters set sealed='mine' where id='{A1}'"), "ERR", "can't edit an imported contact")
case(BOB, n(f"update recruiters set is_valid=true, vault_id='{BOBV}' where id='{A1}'"), "ERR", "can't take one over")
case(BOB, n(f"delete from recruiters where id='{A1}'"), 0, "can't delete an imported contact")
case(BOB, n(f"delete from companies where id='{C1}'"), 0, "can't delete a company with AURORA's contacts")
case(BOB, "select count(*) from vault_grants", 1, "reads only his own grants")
case(BOB, n(f"insert into vault_grants values ('{CAROL}', '{AURORA}', gen_random_uuid(), 'k')"), "ERR", "can't grant Carol a key")
case(BOB, n(f"delete from vault_grants where account_email='{OWNER}'"), 0, "can't delete the owner's grant")
case(BOB, n(f"insert into mail_sends (user_email, subject, body) values ('{OWNER}', 's', 'b')"), "ERR", "can't record a send as the owner")
case(BOB, n(f"update mail_sends set body='x' where user_email='{OWNER}'"), 0, "can't change the owner's sends")
case(BOB, n(f"delete from tracked_companies where user_email='{BOB}'"), 1, "untracks his own company")
case(BOB, "select count(*) from companies_known_as('labs')", 1, "searches other names")

print("outsider (Carol, no key)")
case(CAROL, n(f"update recruiters set is_valid=true where id='{A1}'"), 0, "can't mark a contact she can't read")
case(CAROL, "select count(*) from vaults where code='AURORA'", 1, "looks a vault up by its code")
case(CAROL, n(f"insert into vaults (code, owner_email) values ('CAROL', '{CAROL}')"), 1, "makes her own vault")
case(CAROL, n(f"insert into vaults (code, owner_email) values ('FAKE', '{BOB}')"), "ERR", "can't make a vault in Bob's name")
case(CAROL, n(f"update vaults set sealed_key='x' where code='AURORA'"), 0, "can't change AURORA")
case(CAROL, n(f"insert into profiles (email, name) values ('{CAROL}', 'C') on conflict (email) do update set name = excluded.name"), 1, "upserts her profile")

print("secret key")
case("service", n(f"update recruiters set sealed='script' where id='{A1}'"), 1, "scripts can still write")
case("service", "select count(*) from mail_sends", 2, "and read everything")

print("rollback")
load(SCRIPTS / "rls_rollback.sql")
case("anon", "select count(*) from companies", 3, "the bare key reads again")
load(SCRIPTS / "rls_migration.sql")
case("anon", "select count(*) from companies", "ERR", "and is refused once it's re-applied")

print("All passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
