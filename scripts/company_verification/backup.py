"""Snapshot every Aurora table to local JSON before anything is changed.

    python3 scripts/company_verification/backup.py [out_dir]

Writes <out_dir>/<timestamp>/<table>.json plus manifest.json (row counts and
sha256). Defaults to db_backups/ at the repo root, which is git-ignored: the
dumps hold people's addresses and sent mail.
"""
import datetime
import hashlib
import json
import sys
from pathlib import Path

import supabase

TABLES = {  # table -> stable sort order (tables without an id sort on their key)
    "companies": "id.asc",
    "recruiters": "id.asc",
    "mail_sends": "id.asc",
    "profiles": "email.asc",
    "templates": "id.asc",
    "tracked_companies": "user_email.asc,company_id.asc",
    "user_companies": "user_email.asc,company_id.asc",
}
REPO = Path(__file__).resolve().parents[2]


def backup(root=REPO / "db_backups", label=""):
    out = Path(root) / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + label)
    out.mkdir(parents=True)
    manifest = {}
    for table, order in TABLES.items():
        rows = supabase.get_all(table, order=order)
        path = out / f"{table}.json"
        path.write_text(json.dumps(rows, indent=1, ensure_ascii=False))
        manifest[table] = {"rows": len(rows), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        print(f"  {table:18} {len(rows):6} rows", flush=True)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"backup -> {out}")
    return out


if __name__ == "__main__":
    backup(*(sys.argv[1:2] or []))
