"""Contacts (`recruiters`) as the scripts read and write them, sealed or not.

Since vault_migration.sql, Aurora seals a contact's name, email, position,
phone and greeting into `recruiters.sealed` under its vault's key and empties
the plain columns (see ../vault_crypto.py). This module hides that from the
pipeline:

- Reading: `open_rows` turns rows as stored into rows as the scripts always
  saw them: the five fields filled in, the storage columns (vault_id, key_id,
  sealed) dropped. Rows still plain (a DB without the migration, or contacts
  the app hasn't sealed yet) pass through. Rows in a vault this key can't open
  read as blank and are counted in `locked`; nothing rewrites their fields.
- Writing: `insert` and `update` seal the fields into the vault named by
  AURORA_VAULT_CODE (default AURORA), write vault_id, key_id and sealed, and
  leave the plain columns null. Without the migration they write plain rows,
  exactly as before.

The vault's key is opened with its private key, read from AURORA_PRIVATE_KEY
or typed at a hidden prompt the first time a sealed row needs it — never from
the command line or a file.
"""
import getpass
import json
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import vault_crypto  # noqa: E402
import supabase  # noqa: E402

FIELDS = tuple(vault_crypto.CONTACT_FIELDS)        # name, email, position, phone, greeting_name
STORAGE = ("vault_id", "key_id", "sealed")
CODE_ENV = "AURORA_VAULT_CODE"
# The vault tables: backed up with the rest, but not part of any pipeline's tables.
VAULT_TABLES = ("vaults", "vault_grants")


def canonical(row):
    """The five fields the way both storage forms read: name and email as
    text ("" when absent), the optional three as None when empty — so a row
    the app sealed compares equal to the plain row it came from."""
    for f in ("name", "email"):
        row[f] = row.get(f) or ""
    for f in ("position", "phone", "greeting_name"):
        row[f] = row.get(f) or None
    return row


class Session:
    """One run's view of the vaults: whether the DB has them, the keys opened
    so far, and which contacts couldn't be read."""

    def __init__(self, api=supabase, environ=None, prompt=getpass.getpass, log=None):
        self.api = api
        self.environ = os.environ if environ is None else environ
        self.prompt = prompt
        self.log = log or (lambda msg: print(msg, file=sys.stderr, flush=True))
        self.code = "".join((self.environ.get(CODE_ENV) or "AURORA").upper().split())
        self.keys = {}          # key_id -> vault key
        self.locked = set()     # contact ids in vaults this key can't open
        self._migrated = None
        self._live_vault = None
        self._writing = None
        self._secret = None

    # -- the DB ---------------------------------------------------------------

    def migrated(self):
        """True once vault_migration.sql has run (the `vaults` table exists)."""
        if self._migrated is None:
            self._migrated = self.api.has_table("vaults")
        return self._migrated

    def live_vault(self, refresh=False):
        if self._live_vault is None or refresh:
            rows = self.api.get("vaults", {"code": f"eq.{self.code}"})
            if not rows:
                raise SystemExit(f"no vault has the code {self.code} (set {CODE_ENV} to choose another)")
            self._live_vault = rows[0]
        return self._live_vault

    def select(self, columns="*"):
        """A recruiters `select` that also fetches what opening a row needs."""
        if columns == "*" or not self.migrated():
            return columns
        have = [c.strip() for c in columns.split(",")]
        return ",".join(have + [c for c in STORAGE if c not in have])

    # -- keys -----------------------------------------------------------------

    def _private_key(self):
        if self._secret is None:
            self._secret = vault_crypto.read_private_key(self.code, self.environ, self.prompt)
        return self._secret

    def _unlock(self, vault):
        key_id = (vault.get("key_id") or "").lower()
        if key_id and key_id not in self.keys:
            try:
                kid, key = vault_crypto.unlock_vault(vault, self._private_key())
            except vault_crypto.CannotOpen as e:
                raise SystemExit(str(e)) from None
            self.keys[kid] = key
        return self.keys.get(key_id)

    def _key_for(self, key_id, vaults):
        """The key a row of our vault was sealed with: from a snapshot's vault
        row first, then the live one (the key may have changed since)."""
        key_id = (key_id or "").lower()
        if key_id in self.keys:
            return self.keys[key_id]
        candidates = list(vaults)
        if self.migrated():
            candidates.append(self.live_vault())
        for v in candidates:
            if (v.get("key_id") or "").lower() == key_id:
                return self._unlock(v)
        pending = any((v.get("pending_key_id") or "").lower() == key_id for v in candidates)
        raise SystemExit(f"a contact in {self.code} is sealed under key {key_id}, which its private key doesn't open"
                         + (": a private-key change is in progress; finish it in the app first" if pending else ""))

    # -- reading --------------------------------------------------------------

    def open_rows(self, rows, vaults=None):
        """Rows as stored -> rows as the scripts read them (see the module note).
        `vaults` are the vault rows saved with a backup, when opening one."""
        mine = [v for v in (vaults or []) if v.get("code") == self.code]
        own_ids = {v["id"].lower() for v in mine}
        out, locked = [], 0
        for r in rows:
            row = dict(r)
            sealed = row.pop("sealed", None)
            vault_id = (row.pop("vault_id", None) or "").lower()
            key_id = row.pop("key_id", None)
            if sealed:
                if not own_ids:
                    own_ids = {self.live_vault()["id"].lower()} if self.migrated() else set()
                if vault_id in own_ids:
                    key = self._key_for(key_id, mine)
                    try:
                        row.update(vault_crypto.open_contact(sealed, key, row["id"], vault_id))
                    except (vault_crypto.CannotOpen, vault_crypto.Malformed) as e:
                        raise SystemExit(f"contact {row['id']} in {self.code} doesn't open: {e}") from None
                else:
                    row.update({f: None for f in FIELDS})
                    self.locked.add(row["id"])
                    locked += 1
            out.append(canonical(row))
        if locked:
            self.log(f"note: {locked} contacts are in other people's vaults; they read as blank and are never rewritten")
        return out

    def read_live(self, select="*", order="id.asc"):
        return self.open_rows(self.api.get_all("recruiters", order=order, select=self.select(select)))

    def open_backup(self, path, rows=None):
        """A backup's recruiters, opened with the vault rows saved beside them."""
        path = Path(path)
        if rows is None:
            rows = json.loads((path / "recruiters.json").read_text())
        vaults = path / "vaults.json"
        return self.open_rows(rows, json.loads(vaults.read_text()) if vaults.exists() else None)

    def emails_in_use(self):
        """Every readable contact's address (lower case) -> its ids, read fresh.
        The server can't search sealed addresses, so duplicate checks happen here."""
        index = {}
        for r in self.read_live(select="id,email"):
            if r["email"]:
                index.setdefault(r["email"].strip().lower(), set()).add(r["id"])
        return index

    # -- writing --------------------------------------------------------------

    def writing_vault(self):
        """(vault, key_id, key) that new and changed contacts are sealed into.
        key is None while the vault has no private key yet: rows then go in
        plain under it, and the app seals them at its owner's next sign-in."""
        if self._writing is None:
            vault = self.live_vault(refresh=True)
            if vault.get("pending_key_id"):
                raise SystemExit(f"a private-key change for {self.code} is in progress; "
                                 "open the app to finish it, then run this again")
            if not vault.get("sealed_key"):
                self.log(f"note: {self.code} has no private key yet; contacts are written plain under it "
                         "and the app seals them at its owner's next sign-in")
                self._writing = (vault, None, None)
            else:
                self._writing = (vault, vault["key_id"].lower(), self._unlock(vault))
        return self._writing

    def sealed_body(self, row):
        """A contact row as it's stored: the fields sealed, the plain columns null."""
        vault, key_id, key = self.writing_vault()
        body = {k: v for k, v in row.items() if k not in STORAGE}
        body["id"] = str(body.get("id") or uuid.uuid4()).lower()
        body["vault_id"] = vault["id"]
        if key is None:
            return body
        body["key_id"] = key_id
        body["sealed"] = vault_crypto.seal_contact(row, key, body["id"], vault["id"])
        body.update({f: None for f in FIELDS})
        return body

    def insert(self, rows, prefer="return=representation"):
        """POST contacts. Sealed rows get their id here: it's part of the seal."""
        if not self.migrated():
            return self.api.write("POST", "recruiters", body=rows, prefer=prefer)
        return self.api.write("POST", "recruiters", body=[self.sealed_body(r) for r in rows], prefer=prefer)

    def update(self, contact_id, changes):
        """Change one contact. Field changes re-seal the whole row, and the write
        only lands if the row is still what was read (another phone may have
        changed it). Returns the written rows, like `supabase.write`."""
        if not self.migrated():
            return self.api.write("PATCH", "recruiters", {"id": f"eq.{contact_id}"}, changes)
        fields = {k: v for k, v in changes.items() if k in FIELDS}
        if not fields:  # company, validity: outside the seal
            return self.api.write("PATCH", "recruiters", {"id": f"eq.{contact_id}"}, changes)
        vault, key_id, key = self.writing_vault()
        found = self.api.get("recruiters", {"id": f"eq.{contact_id}"},
                             select=",".join(("id",) + STORAGE + FIELDS))
        if not found:
            return []
        row = found[0]
        if (row.get("vault_id") or "").lower() != vault["id"].lower():
            raise SystemExit(f"contact {contact_id} isn't in {self.code}: only its owner can change it")
        filters = {"id": f"eq.{contact_id}", "vault_id": f"eq.{vault['id']}",
                   "sealed": f"eq.{row['sealed']}" if row.get("sealed") else "is.null"}
        if row.get("sealed"):
            current = self.open_rows([row], [vault])[0]
        else:
            current = canonical({f: row.get(f) for f in FIELDS})
        if key is None:
            body = dict(changes)
        else:
            merged = {**{f: current.get(f) for f in FIELDS}, **fields}
            body = {**{k: v for k, v in changes.items() if k not in FIELDS}, "key_id": key_id,
                    "sealed": vault_crypto.seal_contact(merged, key, contact_id, vault["id"]),
                    **{f: None for f in FIELDS}}
        got = self.api.write("PATCH", "recruiters", filters, body)
        if not got:
            raise SystemExit(f"contact {contact_id} changed while it was being updated; run this again")
        return got


_session = None


def session():
    global _session
    if _session is None:
        _session = Session()
    return _session


def open_rows(rows, vaults=None):
    return session().open_rows(rows, vaults)


def read_live(select="*", order="id.asc"):
    return session().read_live(select, order)


def open_backup(path, rows=None):
    return session().open_backup(path, rows)


def insert(rows, prefer="return=representation"):
    return session().insert(rows, prefer)


def update(contact_id, changes):
    return session().update(contact_id, changes)


def emails_in_use():
    return session().emails_in_use()
