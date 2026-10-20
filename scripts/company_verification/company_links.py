"""Company links (`company_links`) as the scripts read and write them.

A company's LinkedIn, X and Facebook pages aren't catalog columns: each vault
keeps its own, one row per company, sealed under the vault's key like its
contacts (../company_links_migration.sql, ../vault_crypto.py). Only the vault
named by AURORA_VAULT_CODE (default AURORA) is read or written, with the
private key `contacts` asks for. Links are never written unsealed.

- `read_live()` / `open_backup(path)`: {company_id: {"id", "linkedin", "x",
  "facebook"}} for that vault.
- `save(company_id, links, row_id=None)`: seal and upsert one company's links.
- `move(src, dst)`: before `src` is merged into `dst` and deleted (which would
  take its links with it): every vault's row moves across. Where `dst` already
  has a row for the same vault, ours are merged field by field (dst's win) and
  someone else's — which can't be opened — stop the merge.
"""
import json
import uuid
from pathlib import Path

import contacts
import supabase
from contacts import vault_crypto

TABLE = "company_links"
FIELDS = tuple(vault_crypto.COMPANY_LINK_FIELDS)   # linkedin, x, facebook


def exists(api=None):
    """True once company_links_migration.sql has run."""
    return (api or contacts.session().api).has_table(TABLE)


def _open(rows, vaults, s):
    mine = [v for v in vaults if v.get("code") == s.code] or [s.live_vault()]
    own = {v["id"].lower() for v in mine}
    out = {}
    for r in rows:
        if (r.get("vault_id") or "").lower() not in own:
            continue
        key = s._key_for(r["key_id"], mine)
        try:
            links = vault_crypto.open_company_links(r["sealed"], key, r["id"], r["vault_id"])
        except (vault_crypto.CannotOpen, vault_crypto.Malformed) as e:
            raise SystemExit(f"company links {r['id']} in {s.code} don't open: {e}") from None
        out[r["company_id"]] = {"id": r["id"], **links}
    return out


def read_live(s=None):
    s = s or contacts.session()
    if not exists(s.api):
        return {}
    return _open(s.api.get_all(TABLE, order="id.asc"), [], s)


def open_backup(path, s=None):
    s = s or contacts.session()
    path = Path(path)
    rows = path / f"{TABLE}.json"
    if not rows.exists():
        return {}
    vaults = path / "vaults.json"
    return _open(json.loads(rows.read_text()), json.loads(vaults.read_text()) if vaults.exists() else [], s)


def _body(company_id, links, row_id, s):
    vault, key_id, key = s.writing_vault()
    if key is None:
        raise SystemExit(f"{s.code} has no private key yet, and company links are only ever stored sealed")
    row_id = str(row_id or uuid.uuid4()).lower()
    return {"id": row_id, "company_id": company_id, "vault_id": vault["id"], "key_id": key_id,
            "sealed": vault_crypto.seal_company_links(links, key, row_id, vault["id"])}


def save(company_id, links, row_id=None, s=None):
    """Seal `links` (by field name) into our vault's row for the company."""
    s = s or contacts.session()
    return s.api.write("POST", TABLE, {"on_conflict": "company_id,vault_id"},
                       _body(company_id, {f: links.get(f) for f in FIELDS}, row_id, s),
                       prefer="return=representation,resolution=merge-duplicates")


def move(src, dst, s=None):
    """Every vault's links at `src` -> `dst`. Returns how many rows moved."""
    s = s or contacts.session()
    if not exists(s.api):
        return 0
    at_src = s.api.get(TABLE, {"company_id": f"eq.{src}"})
    if not at_src:
        return 0
    at_dst = {r["vault_id"].lower(): r for r in s.api.get(TABLE, {"company_id": f"eq.{dst}"})}
    moved = 0
    for r in at_src:
        theirs = at_dst.get(r["vault_id"].lower())
        if theirs is None:
            s.api.write("PATCH", TABLE, {"id": f"eq.{r['id']}"}, {"company_id": dst}, prefer="return=minimal")
            moved += 1
            continue
        if r["vault_id"].lower() != s.writing_vault()[0]["id"].lower():
            raise SystemExit(f"both companies hold links from another vault ({r['vault_id']}); "
                             "only that vault's owner can merge them")
        both = _open([r, theirs], [], s)
        merged = {f: both[dst].get(f) or both[src].get(f) for f in FIELDS}
        save(dst, merged, row_id=theirs["id"], s=s)
        s.api.write("DELETE", TABLE, {"id": f"eq.{r['id']}"}, prefer="return=minimal")
        moved += 1
    return moved


def count_at(company_id, api=None):
    """How many vaults hold links for a company (any vault: the secret key reads them all)."""
    api = api or contacts.session().api
    if not exists(api):
        return 0
    return len(api.get(TABLE, {"company_id": f"eq.{company_id}"}, select="id"))
