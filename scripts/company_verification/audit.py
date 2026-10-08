"""Independent audit of what the pipeline changed: original snapshot vs now.

    python3 audit.py <original_backup_dir>            # vs the live DB
    python3 audit.py <original_backup_dir> <other>    # vs another backup

Deliberately shares no planning code with verify_companies.py / verify_names.py:
it only reads the two states and checks, row by row, that every difference is
one the rules allow. A bug in the pipeline's logic can't hide here by being
repeated.
"""
import collections
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TABLES = ["companies", "recruiters", "mail_sends", "tracked_companies", "user_companies"]
DECISIONS = json.loads((HERE / "decisions.json").read_text())


def load(path):
    return {t: json.loads((Path(path) / f"{t}.json").read_text()) for t in TABLES}


def load_live():
    import supabase
    order = {"tracked_companies": "user_email.asc,company_id.asc", "user_companies": "user_email.asc,company_id.asc"}
    return {t: supabase.get_all(t, order=order.get(t, "id.asc")) for t in TABLES}


def host(email):
    return (email or "").strip().lower().rsplit("@", 1)[-1]


def letters(s):
    return re.sub(r"[^a-z]", "", (s or "").lower())


def audit(old, new):
    problems, notes = [], collections.Counter()
    oc = {c["id"]: c for c in old["companies"]}
    nc = {c["id"]: c for c in new["companies"]}
    orr = {r["id"]: r for r in old["recruiters"]}
    nr = {r["id"]: r for r in new["recruiters"]}
    ids = {k: v for k, v in DECISIONS["_ids"].items() if not k.startswith("_")}
    junk = {ids[n] for n in DECISIONS["junk_companies"]}
    test = {ids[n] for n in DECISIONS["test_companies"]}

    # 1. Contacts: none invented; only junk (and, once that rule runs,
    #    personal-mailbox contacts) may disappear; email never changes.
    from domains import is_personal  # the verified personal-mailbox list (data, not planning logic)
    personal_deleted = DECISIONS.get("personal_contacts", {}).get("action") == "delete"
    old_sends = collections.Counter(m["recruiter_id"] for m in old["mail_sends"])
    dead = {h for h in DECISIONS.get("dead_domains", {}) if not h.startswith("_")}
    deletable = lambda r: not old_sends[r["id"]] and (
        (personal_deleted and is_personal(host(r["email"]))) or host(r["email"]) in dead)
    for rid, r in orr.items():
        if rid not in nr:
            if r["company_id"] in junk:
                notes["contact deleted: junk"] += 1
            elif personal_deleted and is_personal(host(r["email"])) and not old_sends[rid]:
                notes["contact deleted: personal mailbox (no sends)"] += 1
            elif host(r["email"]) in dead and not old_sends[rid]:
                notes["contact deleted: domain can't receive mail (no sends)"] += 1
            elif personal_deleted and is_personal(host(r["email"])):
                problems.append(f"personal contact {r['email']} was deleted although it had sends")
            else:
                problems.append(f"contact {r['email']} disappeared")
            continue
        n = nr[rid]
        typo_fix = None
        if host(r["email"]) in DECISIONS["typo_domains"]:
            local = r["email"].strip().rsplit("@", 1)[0]
            typo_fix = f"{local}@{DECISIONS['typo_domains'][host(r['email'])]}"
        if typo_fix and n.get("email") == typo_fix:
            notes["contact email corrected (typo domain)"] += 1
        for field in r:
            if field in ("company_id", "name", "greeting_name", "is_valid"):
                continue
            if field == "email" and typo_fix and n.get("email") == typo_fix:
                continue
            if r[field] != n.get(field):
                problems.append(f"contact {r['email']}: {field} changed {r[field]!r} -> {n.get(field)!r}")
        if r.get("is_valid", True) and not n.get("is_valid", True):
            problems.append(f"contact {r['email']} was marked invalid")
        if not r.get("is_valid", True) and n.get("is_valid", True) and not typo_fix:
            problems.append(f"contact {r['email']} was flipped back to valid")
    for rid in nr.keys() - orr.keys():
        problems.append(f"contact {nr[rid]['email']} is new")

    # 2. Company moves: each must be explained by a rule or by the domain.
    new_by_company = collections.defaultdict(list)
    for r in nr.values():
        new_by_company[r["company_id"]].append(r)
    reg = lambda h: ".".join(h.split(".")[-3:]) if re.search(r"\.(co|ac|org|net|gov|edu|ind|com)\.[a-z]{2}$", h) else ".".join(h.split(".")[-2:])
    merged_sources = {ids[s]: ids[m["into"]] for m in DECISIONS["merges"] for s in m["from"]}
    for rid, r in orr.items():
        if rid not in nr or r["company_id"] == nr[rid]["company_id"]:
            continue
        src, dst, h = r["company_id"], nr[rid]["company_id"], host(r["email"])
        if dst not in nc:
            problems.append(f"contact {r['email']} points at a missing company")
            continue
        why = None
        if merged_sources.get(src) == dst or (merged_sources.get(src) and merged_sources.get(merged_sources[src]) == dst):
            why = "explicit merge"
        elif h in DECISIONS["typo_domains"]:
            why = "typo domain"
        elif h in DECISIONS["domain_moves"] or reg(h) in DECISIONS["domain_moves"]:
            why = "domain move"
        else:
            # Domain evidence: the destination already holds this domain from
            # contacts that were there before any change.
            peers = {reg(host(x["email"])) for x in old["recruiters"] if x["company_id"] == dst}
            if reg(h) in peers:
                why = "domain owned by destination"
        if why is None:
            problems.append(f"contact {r['email']} moved {oc[src]['name']!r} -> {nc[dst]['name']!r} with no rule or domain evidence")
        else:
            notes[f"contact moved: {why}"] += 1

    # 3. Deleted companies: junk, or everything they held went to ONE place.
    for cid, c in oc.items():
        if cid in nc:
            continue
        dests = {nr[r["id"]]["company_id"] for r in old["recruiters"] if r["company_id"] == cid and r["id"] in nr}
        if cid in junk:
            notes["company deleted: junk"] += 1
        elif cid in test:
            problems.append(f"test company {c['name']!r} was deleted")
        elif len(dests) > 1:
            problems.append(f"deleted company {c['name']!r} was split across {len(dests)} companies")
        elif not dests and cid not in merged_sources:
            # Allowed only on evidence: everything it ever held was a personal
            # mailbox with no sends, and all of it was deleted.
            held = [r for r in old["recruiters"] if r["company_id"] == cid]
            if held and all(deletable(r) and r["id"] not in nr for r in held):
                notes["company deleted: every contact was a deleted personal/dead address"] += 1
            else:
                problems.append(f"company {c['name']!r} deleted but it was neither junk nor a merge source")
        else:
            notes["company deleted: folded into another"] += 1
    for cid in nc.keys() - oc.keys():
        if nc[cid]["name"] not in {r.get("create") for r in DECISIONS["domain_moves"].values()}:
            problems.append(f"company {nc[cid]['name']!r} is new without a rule creating it")

    # 4. Sent mail: every send survives, still pointing at the same address.
    osend = {m["id"]: m for m in old["mail_sends"]}
    nsend = {m["id"]: m for m in new["mail_sends"]}
    for sid, m in osend.items():
        if sid not in nsend:
            r = orr.get(m["recruiter_id"])
            problems.append(f"send {sid} to {r and r['email']} was lost")
        elif m != nsend[sid]:
            problems.append(f"send {sid} was modified")
        elif m["recruiter_id"] not in nr:
            problems.append(f"send {sid} lost its contact")
    for sid in nsend.keys() - osend.keys():
        notes["sends made since the snapshot"] += 1

    # 5. Tracking: whoever tracked a company still tracks it or its successor.
    succ = {}
    for cid in oc:
        if cid in nc:
            succ[cid] = cid
        else:
            dests = {nr[r["id"]]["company_id"] for r in old["recruiters"] if r["company_id"] == cid and r["id"] in nr}
            succ[cid] = dests.pop() if len(dests) == 1 else merged_sources.get(cid)
            while succ[cid] and succ[cid] not in nc:
                succ[cid] = merged_sources.get(succ[cid])
    for table in ("tracked_companies", "user_companies"):
        now = {(t["user_email"], t["company_id"]) for t in new[table]}
        for t in old[table]:
            if (t["user_email"], succ.get(t["company_id"])) not in now:
                problems.append(f"{table}: {t['user_email']} lost {oc[t['company_id']]['name']!r}")

    # 6. Names: a changed name must be read off the address, never invented.
    for rid, r in orr.items():
        if rid not in nr:
            continue
        n = nr[rid]
        local = letters(r["email"].split("@")[0])
        for field in ("name", "greeting_name"):
            if (r.get(field) or "") == (n.get(field) or ""):
                continue
            notes[f"{field} changed"] += 1
            val = n.get(field) or ""
            if val == "Team":
                continue
            old_val = letters(r.get(field))
            if not val and field == "greeting_name" and (old_val == local or len(old_val) <= 2):
                continue  # an importer's copy of the mailbox, or a fragment
            if not val:
                problems.append(f"{r['email']}: {field} was cleared")
            elif letters(val) not in local and not all(letters(w) in local for w in val.split()):
                problems.append(f"{r['email']}: new {field} {val!r} isn't in the address")
        g, nm = (n.get("greeting_name") or ""), (n.get("name") or "")
        if g and g != "Team" and nm and letters(g) not in {letters(w) for w in nm.split()} and n != r:
            if (r.get("greeting_name"), r.get("name")) != (n.get("greeting_name"), n.get("name")):
                problems.append(f"{r['email']}: greeting {g!r} isn't a word of name {nm!r}")
    return problems, notes


if __name__ == "__main__":
    old = load(sys.argv[1])
    new = load(sys.argv[2]) if len(sys.argv) > 2 else load_live()
    problems, notes = audit(old, new)
    for k, v in sorted(notes.items()):
        print(f"  {v:6}  {k}")
    print(f"PROBLEMS: {len(problems)}")
    for p in problems:
        print("  !", p)
    sys.exit(1 if problems else 0)
