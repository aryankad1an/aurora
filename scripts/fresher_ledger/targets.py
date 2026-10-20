"""Write the crawl's targets: every ledger company's website, and the mail
domain of every catalog company the ledger doesn't cover.

    python3 targets.py <companies.json> <db_backups/stamp> <targets.json>
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ledger import is_personal, load_ledger, match, registrable  # noqa: E402
import contacts  # noqa: E402  (ledger put company_verification on the path)

DEAD = set(json.loads((Path(__file__).resolve().parent.parent / "company_verification" / "decisions.json")
                      .read_text())["dead_domains"])


def main(ledger_path, backup, out):
    _, ledger = load_ledger(ledger_path)
    companies = json.loads((Path(backup) / "companies.json").read_text())
    recruiters = contacts.open_backup(backup)  # sealed addresses opened with the backup's vault rows
    matches, _ = match(ledger, companies, recruiters)
    matched = {cid for cid, _ in matches.values() if cid}
    targets = [{"key": "ledger:" + c["id"], "url": c["website"], "name": c["name"]} for c in ledger]
    for c in companies:
        doms = [registrable(d) for d in c.get("domains") or []
                if not is_personal(d) and registrable(d) not in DEAD]
        if c["id"] not in matched and doms:
            targets.append({"key": "co:" + c["id"], "url": "https://" + doms[0], "name": c["name"]})
    Path(out).write_text(json.dumps(targets, indent=1))
    print(f"{len(targets)} targets -> {out}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
