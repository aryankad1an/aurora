"""Store the other names companies go by (`companies.also_known_as`).

    python3 set_aliases.py ../../data_verification/aliases/aliases_by_id.json           # dry run
    python3 set_aliases.py ../../data_verification/aliases/aliases_by_id.json --apply

The file maps a company id to {"name", "aliases"}: ids, not names, since
renames have made name lookups hit the wrong row before. Each alias was checked
two ways (the company's own site or a filing, and a second source) before it
went in the file. Aliases are added to what a company already has, never
replacing it; a name that is the company's own, or another catalog company's,
is refused. Every row written is re-read.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "company_verification"))
import supabase  # noqa: E402


def main(path, apply):
    plan = json.loads(Path(path).read_text())
    rows = supabase.get_all("companies", select="id,name,also_known_as")
    by_id = {r["id"]: r for r in rows}
    names = {}
    for r in rows:
        names.setdefault(r["name"].lower(), set()).add(r["id"])
    writes = []
    for cid, entry in plan.items():
        row = by_id.get(cid)
        if row is None or row["name"] != entry["name"]:
            sys.exit(f"{cid}: expected {entry['name']!r}, catalog has {row and row['name']!r} — stopping")
        have = list(row["also_known_as"] or [])
        for alias in entry["aliases"]:
            other = names.get(alias.lower(), set()) - {cid}
            if alias.lower() == row["name"].lower() or other:
                print(f"  refused {alias!r} for {row['name']}: "
                      f"{'its own name' if not other else 'another company is called that'}")
            elif alias.lower() not in {h.lower() for h in have}:
                have.append(alias)
        if have != (row["also_known_as"] or []):
            writes.append((cid, row["name"], row["also_known_as"], have))
    for cid, name, before, after in writes:
        print(f"  {name}: {before or []} -> {after}")
    print(f"{len(writes)} companies to update")
    if not apply:
        return
    bad = []
    for cid, _, _, after in writes:
        supabase.write("PATCH", "companies", {"id": "eq." + cid}, {"also_known_as": after})
    now = {r["id"]: r for r in supabase.get(
        "companies", {"id": supabase.in_filter([w[0] for w in writes])}, "id,also_known_as")} if writes else {}
    bad = [w[1] for w in writes if now[w[0]]["also_known_as"] != w[3]]
    print(f"wrote {len(writes)}; re-read mismatches: {len(bad)} {bad}")


if __name__ == "__main__":
    main(sys.argv[1], "--apply" in sys.argv)
