"""Independent proof that the CDC sheet import is correct.

    python3 verify_import.py <pre_backup_dir> [<post_backup_dir>]   # post defaults to the live DB

Shares no planning code with import_sheet.py. It re-reads the spreadsheet's raw
XML, the two catalog states and live DNS, and checks:

  1. Coverage: every address in the sheet is accounted for exactly once:
     added, already in the catalog, or excluded with a reason.
  2. Nothing else changed: every pre-existing company, contact, send and
     tracked row is byte-identical, except domains appended to companies that
     received contacts; every new row is one the import planned.
  3. Domain -> company: each added address's domain belongs to exactly one
     company in the whole catalog (its own), that company lists the mail host,
     no other company lists it, and it is not a personal mailbox.
  4. Email: each added address is well formed, unique in the catalog, and its
     host has live MX records (re-queried now on two public resolvers).
  5. Name: each added name is spelt out by its own mailbox (letters in order);
     the few that aren't are exactly the reviewed exceptions, listed.
  6. Company vs sheet: how each added contact's company relates to the
     company the sheet filed it under.
  7. The pipeline's own invariants (verify_companies.verify) hold: 0 violations.
"""
import collections
import json
import re
import subprocess
import sys
import zipfile
from concurrent.futures import ThreadPoolExecutor
from itertools import permutations
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / "data_verification" / "cdc_import"
TABLES = ["companies", "recruiters", "mail_sends", "tracked_companies", "user_companies", "profiles", "templates"]
ADDR = re.compile(r"[A-Za-z0-9._%+'-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+")
WELL_FORMED = re.compile(r"^[a-z0-9](?:[a-z0-9._'+-]*[a-z0-9])?@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$")
TAGS = {"contractor", "ext", "external", "fut", "wv", "consultant", "contr", "temp", "vendor"}


def load(path):
    return {t: json.loads((Path(path) / f"{t}.json").read_text()) for t in TABLES}


def sheet_addresses(xlsx):
    """Every address in the workbook, straight from its XML (no cell model)."""
    z = zipfile.ZipFile(xlsx)
    found = collections.Counter()
    for n in z.namelist():
        if n.startswith("xl/") and n.endswith(".xml"):
            text = z.read(n).decode("utf-8", "replace")
            # One string per <si>/<is>/<c>; rich-text runs inside it are joined
            # without spaces ("neha.r" + "@example.com" is one address).
            text = re.sub(r"</(si|is|c|v|row)>", " ", text)
            text = re.sub(r"<[^>]+>", "", text).replace("&amp;", "&")
            for m in ADDR.findall(text):
                found[m.lower()] += 1
    return found


def lcs(a, b):
    prev = [0] * (len(b) + 1)
    for ch in a:
        cur = [0]
        for j, cb in enumerate(b):
            cur.append(prev[j] + 1 if ch == cb else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def name_fit(name, email):
    """Share of the mailbox's letters that appear, in order, in the name."""
    local = email.split("@")[0].lower()
    toks = [t for t in re.split(r"[^a-z]+", local) if t and t not in TAGS]
    letters = "".join(toks)
    words = re.findall(r"[a-z]+", name.lower())
    if not letters or not words:
        return 0.0
    best = 0
    for perm in permutations(words[:5]):
        best = max(best, lcs(letters, "".join(perm)))
    return best / len(letters)


def mx(host):
    out = {}
    for server in ("8.8.8.8", "9.9.9.9"):
        for _ in range(3):
            p = subprocess.run(["dig", "+time=4", "+tries=2", f"@{server}", host, "MX", "+noall", "+answer", "+comments"],
                               capture_output=True, text=True)
            st = re.search(r"status: (\w+)", p.stdout)
            if st:
                recs = [l.split()[-1] for l in p.stdout.splitlines() if "\tMX\t" in l or " MX " in l]
                out[server] = (st.group(1), recs)
                break
        else:
            out[server] = ("TIMEOUT", [])
    return host, out


def main():
    sys.path.insert(0, str(HERE))
    from domains import is_personal, registrable  # verified data lists, not planning logic
    pre_dir = sys.argv[1]
    pre = load(pre_dir)
    if len(sys.argv) > 2:
        post = load(sys.argv[2])
    else:
        import supabase
        order = {"tracked_companies": "user_email.asc,company_id.asc", "user_companies": "user_email.asc,company_id.asc",
                 "profiles": "email.asc"}
        post = {t: supabase.get_all(t, order=order.get(t, "id.asc")) for t in TABLES}
    plan = json.loads((OUT / "plan.json").read_text())
    problems, notes = [], collections.Counter()
    report = {}

    # 1. Coverage.
    sheet = sheet_addresses(OUT / "source.xlsx")
    team_sheet = {e for e in sheet if e.endswith("@iitj.ac.in") and re.match(r"^[bmd]\d{2}[a-z]{2,4}\d{3,4}@", e)}
    sheet_set = set(sheet) - team_sheet  # the CDC student team's own addresses (Team Contacts sheet)
    added = {c["email"]: c for c in plan["contacts"]}
    already = {a["email"]: a for a in plan["already"]}
    excluded = {e["email"]: e for e in plan["excluded"]}
    buckets = [set(added), set(already), set(excluded)]
    for i in range(3):
        for j in range(i + 1, 3):
            if buckets[i] & buckets[j]:
                problems.append(f"addresses in two outcomes: {sorted(buckets[i] & buckets[j])[:5]}")
    accounted = set().union(*buckets)
    missing = sheet_set - accounted
    extra = accounted - sheet_set
    for e in sorted(missing):
        problems.append(f"sheet address not accounted for: {e}")
    for e in sorted(extra):
        problems.append(f"outcome for an address that isn't in the sheet: {e}")
    report["coverage"] = {"sheet_addresses": len(sheet_set), "student_team_addresses_skipped": len(team_sheet),
                          "added": len(added), "already_in_catalog": len(already), "excluded": len(excluded),
                          "unaccounted": len(missing)}

    # 2. Nothing else changed.
    oc = {c["id"]: c for c in pre["companies"]}
    nc = {c["id"]: c for c in post["companies"]}
    orr = {r["id"]: r for r in pre["recruiters"]}
    nr = {r["id"]: r for r in post["recruiters"]}
    domain_adds = plan["domain_adds"]
    for cid, c in oc.items():
        if cid not in nc:
            problems.append(f"company {c['name']!r} disappeared"); continue
        n = nc[cid]
        for f in c:
            if f == "domains" and cid in domain_adds:
                if (n["domains"] or []) != domain_adds[cid]["after"] or (c["domains"] or []) != domain_adds[cid]["before"]:
                    problems.append(f"{c['name']}: domains {c['domains']} -> {n['domains']}, planned {domain_adds[cid]}")
                continue
            if c[f] != n.get(f):
                problems.append(f"company {c['name']!r}: {f} changed {c[f]!r} -> {n.get(f)!r}")
    for rid, r in orr.items():
        if nr.get(rid) != r:
            problems.append(f"existing contact {r['email']} changed or disappeared")
    for t in ("mail_sends", "tracked_companies", "user_companies", "profiles", "templates"):
        key = (lambda x: json.dumps(x, sort_keys=True))
        if sorted(map(key, pre[t])) != sorted(map(key, post[t])):
            gone = len(set(map(key, pre[t])) - set(map(key, post[t])))
            if gone:
                problems.append(f"{t}: {gone} pre-existing rows changed or disappeared")
            else:
                notes[f"{t}: rows added since the backup (app use, not this import)"] += len(post[t]) - len(pre[t])
    new_companies = {cid: c for cid, c in nc.items() if cid not in oc}
    new_contacts = {rid: r for rid, r in nr.items() if rid not in orr}
    planned_names = {c["name"] for c in plan["creates"]}
    if sorted(c["name"] for c in new_companies.values()) != sorted(planned_names):
        problems.append(f"new companies differ from the plan: {sorted(set(c['name'] for c in new_companies.values()) ^ planned_names)[:10]}")
    for c in plan["creates"]:
        hit = [x for x in new_companies.values() if x["name"] == c["name"]]
        if len(hit) != 1 or hit[0]["sector"] != c["sector"] or (hit[0]["domains"] or []) != c["domains"]:
            problems.append(f"new company {c['name']!r} isn't as planned: {hit}")
    by_email = collections.defaultdict(list)
    for r in post["recruiters"]:
        by_email[r["email"].strip().lower()].append(r)
    new_by_email = {r["email"].strip().lower(): r for r in new_contacts.values()}
    if set(new_by_email) != set(added):
        problems.append(f"new contacts differ from the plan: +{sorted(set(new_by_email) - set(added))[:5]} "
                        f"-{sorted(set(added) - set(new_by_email))[:5]}")
    report["changes"] = {"companies_before": len(oc), "companies_after": len(nc), "companies_created": len(new_companies),
                         "companies_with_domains_appended": len(domain_adds),
                         "contacts_before": len(orr), "contacts_after": len(nr), "contacts_created": len(new_contacts)}

    # 3 & 4. Domain -> company, and the address itself.
    test_names = set(json.loads((HERE / "decisions.json").read_text())["test_companies"])
    dec = json.loads((HERE / "decisions.json").read_text())
    ruled = set(dec["domain_moves"])
    relay = set(dec["relay_domains"])
    holders = collections.defaultdict(set)
    for r in post["recruiters"]:
        h = r["email"].strip().lower().rsplit("@", 1)[-1]
        c = nc.get(r["company_id"])
        if not c or c["name"] in test_names or is_personal(h) or registrable(h) in relay:
            continue
        holders[h if h in ruled else registrable(h)].add(r["company_id"])
    listers = collections.defaultdict(set)
    for c in nc.values():
        for h in c.get("domains") or []:
            listers[h].add(c["id"])
    hosts = set()
    rows = []
    for email, r in sorted(new_by_email.items()):
        h = email.rsplit("@", 1)[1]
        hosts.add(h)
        key = h if h in ruled else registrable(h)
        c = nc.get(r["company_id"])
        if not c:
            problems.append(f"{email}: company missing"); continue
        if not WELL_FORMED.match(email):
            problems.append(f"{email}: malformed address")
        if r["email"] != email:
            problems.append(f"{email}: stored with different case/whitespace {r['email']!r}")
        if len(by_email[email]) != 1:
            problems.append(f"{email}: appears {len(by_email[email])} times in the catalog")
        if is_personal(h):
            problems.append(f"{email}: personal mailbox added")
        if holders[key] != {c["id"]}:
            problems.append(f"{email}: domain {key} is held by {[nc[x]['name'] for x in holders[key]]}")
        if h not in (c.get("domains") or []):
            problems.append(f"{email}: {c['name']!r} doesn't list {h}")
        if listers[h] != {c["id"]}:
            problems.append(f"{email}: {h} is listed on {[nc[x]['name'] for x in listers[h]]}")
        if not r["is_valid"]:
            problems.append(f"{email}: added as invalid")
        rows.append((email, r, c))
    with ThreadPoolExecutor(16) as ex:
        dns = dict(ex.map(mx, sorted(hosts)))
    dns_both = 0
    for h, res in dns.items():
        ok = [s for s, (st, recs) in res.items() if st == "NOERROR" and recs and recs != ["."]]
        if any(st == "NXDOMAIN" for st, _ in res.values()) or not ok:
            problems.append(f"{h}: no MX now ({res})")
        dns_both += len(ok) == 2
    report["dns"] = {"hosts": len(dns), "mx_on_both_resolvers": dns_both,
                     "mx_on_one_resolver_only": len(dns) - dns_both}

    # 5. Names.
    reviewed = {}
    sys.path.insert(0, str(OUT))
    import cdc_review
    for e, n in cdc_review.NAME.items():
        reviewed[e] = n
    low = []
    fits = collections.Counter()
    for email, r, c in rows:
        name, greet = r["name"], r["greeting_name"]
        if not name or not greet:
            problems.append(f"{email}: empty name/greeting"); continue
        if name == "Team":
            fits["role mailbox -> Team"] += 1
            if greet != "Team":
                problems.append(f"{email}: Team with greeting {greet!r}")
            continue
        if greet not in name.split():
            problems.append(f"{email}: greeting {greet!r} isn't a word of {name!r}")
        f = name_fit(name, email)
        if f >= 0.85:
            fits["name spelt out by its mailbox (>=85% of letters, in order)"] += 1
        else:
            low.append((email, name, round(f, 2)))
            if email not in reviewed:
                problems.append(f"{email}: name {name!r} doesn't match the mailbox ({f:.2f}) and wasn't reviewed")
    report["names"] = dict(fits)
    report["names"]["reviewed exceptions (mailbox doesn't spell the name)"] = len(low)
    report["name_exceptions"] = low

    # 6. Company vs the sheet's company column.
    def norm(s):
        s = re.sub(r"\(.*?\)", " ", (s or "").lower())
        return re.sub(r"[^a-z0-9]", "", re.sub(r"\b(pvt|private|ltd|limited|inc|llc|llp|plc|india|the|group|technologies|technology|solutions|services)\b", " ", s))
    rel = collections.Counter()
    differs = []
    for email, r, c in rows:
        sheet_cos = added[email]["sheet_company"]
        cn = norm(c["name"])
        brand = norm(registrable(email.rsplit("@", 1)[1]).split(".")[0])
        same = any(s and (norm(s) and (norm(s) in cn or cn in norm(s) or brand in norm(s) or norm(s) in brand)) for s in sheet_cos)
        if same:
            rel["same as the sheet's company"] += 1
        else:
            rel["differs from the sheet: filed by the address's domain, reason recorded"] += 1
            differs.append((email, c["name"], sheet_cos, added[email]["why"]))
    report["company_vs_sheet"] = dict(rel)
    report["company_differs"] = differs

    # 7. Pipeline invariants.
    from verify_companies import State, verify
    v, w = verify(State(post))
    report["pipeline_violations"] = len(v)
    for x in v:
        problems.append("pipeline: " + x)

    report["problems"] = problems
    report["notes"] = dict(notes)
    (OUT / "proof.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    for k in ("coverage", "changes", "dns", "names", "company_vs_sheet"):
        print(k, json.dumps(report[k], indent=1))
    print("pipeline violations:", len(v))
    for k, n in notes.items():
        print(f"note: {k}: {n}")
    print(f"PROBLEMS: {len(problems)}")
    for p in problems[:50]:
        print("  !", p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
