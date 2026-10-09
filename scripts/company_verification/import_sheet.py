"""Import recruiter contacts from the CDC master spreadsheet.

    python3 import_sheet.py extract <xlsx>     # every address in the sheet, with provenance
    python3 import_sheet.py plan               # classify against a fresh backup -> plan + report
    python3 import_sheet.py apply              # back up, write the plan, re-verify
    python3 import_sheet.py verify             # independent check of the live DB against the sheet

Outputs live in data_verification/cdc_import/ (git-ignored: people's addresses).
Judgement calls (which company owns a new domain, its sector, names the sheet
gets wrong) are recorded with their reasons in data_verification/cdc_import/
cdc_review.py (git-ignored: it names people), never inferred
silently: a work domain that isn't owned by a catalog company and isn't in the
review stops the plan.
"""
import collections
import csv
import json
import re
import sys
from pathlib import Path

import xlsx_read
import backup as backup_mod

# The review names real people and addresses, so it lives with the other
# personal data in the git-ignored data_verification/ folder.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "data_verification" / "cdc_import"))
import cdc_review as R  # noqa: E402
import supabase
from domains import clean, is_personal, registrable
from verify_companies import DECISIONS, State, dead_hosts, ilike_exact, load_live, load_snapshot, verify
from verify_names import ROLE, address_name, tokens

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / "data_verification" / "cdc_import"

# sheet -> column indexes. `mail` is the address column; the HR name on the
# same row belongs to it. Other cells are scanned for addresses too.
SHEETS = {
    "UG IRs (executives)":     dict(company=0, status=1, name=2, mail=4, notes=[6, 7]),
    "UG PRs + OCs":            dict(company=0, status=1, name=2, mail=4, notes=[6, 7]),
    "PG PRs + OCs":            dict(company=0, status=1, name=2, mail=4, notes=[7, 8, 10]),
    "IIT Delhi":               dict(company=0, status=3, name=4, mail=6, notes=[8]),
    "IIT BHU":                 dict(company=0, status=1, name=2, mail=4, notes=[6]),
    "IIT Gandhinagar (Daksh)": dict(company=0, status=2, name=3, mail=5, notes=[7, 8]),
    "Product+Tech (Daksh)":    dict(company=0, status=1, name=2, mail=4, notes=[6, 7]),
    "IIT Indore (Manasvi)":    dict(company=0, status=1, name=2, mail=4, notes=[6]),
    "Sheet24":                 dict(company=0, status=1, name=2, mail=4, notes=[6]),
    "IIT Dhanbad (Kuldeep)":   dict(company=0, status=1, name=2, mail=4, notes=[7, 8]),
    "Chemical Core":           dict(company=0, status=1, name=2, mail=4, notes=[6, 7]),
}
# Not contact lists: company names only, or the CDC student team's own addresses.
SKIPPED_SHEETS = {"Past Recruiters", "Data ScienceAnalyst", "IIT Ropar", "IIT Patna",
                  "MNIT Jaipur (Paaras)", "Product", "Material Core", "Bio Core", "Civil Core",
                  "Potential Companies for Placeme", "Electrical Core", "Sandstone",
                  "Team Contacts"}

LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
EMAIL = re.compile(r"[A-Za-z0-9._%+'-]+@" + LABEL + r"(?:\." + LABEL + r")+")


def cell(r, i):
    return (r[i] if i is not None and i < len(r) else None) or None


def extract(path):
    book = xlsx_read.read(path)
    unknown = set(book) - set(SHEETS) - SKIPPED_SHEETS
    if unknown:
        sys.exit(f"sheets not classified: {unknown}")
    for s in SKIPPED_SHEETS:
        # A skipped sheet must not hide addresses we'd lose (Team Contacts is
        # the student team: iitj.ac.in only).
        hits = {m.lower() for row in book[s] for c in row if c for m in EMAIL.findall(str(c))}
        if s != "Team Contacts" and hits:
            sys.exit(f"skipped sheet {s} has addresses: {sorted(hits)[:5]}")
        if s == "Team Contacts" and any(not h.endswith("@iitj.ac.in") for h in hits):
            sys.exit("Team Contacts has a non-IITJ address")
    items = []
    for sheet, cols in SHEETS.items():
        company = None
        for i, row in enumerate(book[sheet]):
            if i == 0:
                continue
            if cell(row, cols["company"]):
                company = str(row[cols["company"]]).strip()
            notes = " | ".join(str(cell(row, c)) for c in cols["notes"] if cell(row, c))
            for j, c in enumerate(row):
                if not c:
                    continue
                found = EMAIL.findall(str(c))
                for k, m in enumerate(found):
                    items.append({
                        "sheet": sheet, "row": i + 1, "col": j, "raw_cell": str(c),
                        "email_raw": m, "company_sheet": company,
                        "company_cell": cell(row, cols["company"]),
                        "status": (str(cell(row, cols["status"]) or "")).strip(),
                        "hr_name": (str(cell(row, cols["name"]) or "")).strip(),
                        "in_mail_col": j == cols["mail"],
                        "addresses_in_cell": len(found),
                        "notes": notes,
                    })
    return items



# ----------------------------------------------------------------------------
# Names

HONORIFIC = re.compile(r"^(mr|mrs|ms|miss|dr|prof|major|capt|col|er|ca|cs|adv)\.?\s+", re.I)


def people(cell_text):
    """The person names in an HR-name cell ("Dr. Neha Rao, Amit Das")."""
    if not cell_text:
        return []
    text = re.sub(r"\(.*?\)", "", cell_text)
    out = []
    for p in re.split(r"\s*(?:,|/|;|\n|\band\b|&|\|)\s*", text):
        p = HONORIFIC.sub("", p.strip()).strip(" .-")
        if p and re.search(r"[A-Za-z]{2}", p) and not re.search(r"linkedin|http|@|\d", p, re.I):
            out.append(p)
    return out


def tidy(name):
    """Case and punctuation as people write their names: "NEha KR" -> "Neha KR"."""
    words = []
    for w in name.replace(".", " ").split():
        w = w.strip("-")
        if not w:
            continue
        parts = []
        for part in w.split("-"):
            if part.islower() or (part.isupper() and len(part) > 2) or re.fullmatch(r"[A-Z]{2}[a-z]+", part):
                part = part[:1].upper() + part[1:].lower()
            parts.append(part)
        words.append("-".join(parts))
    return " ".join(words)


def explained(local, name):
    """Can the mailbox be spelt out of the name's words, initials and prefixes?

    `nmathur` <- Neha Mathur (initial + word), `ravisharm` <- Ravi Sharma
    (prefixes), `amit.kumar2` <- Neha Mathur: no. Every letter of the
    mailbox must be accounted for; digits and separators are ignored.
    """
    words = [w for w in re.findall(r"[a-z]+", name.lower()) if w]
    if not words:
        return False
    for chunk in [t for t in re.split(r"[^a-z]+", local.lower()) if t]:
        ok = [True] + [False] * len(chunk)
        for i in range(len(chunk)):
            if not ok[i]:
                continue
            for w in words:
                if chunk[i] == w[0]:
                    ok[i + 1] = True
                for n in {len(w), *range(3, len(w) + 1)}:
                    if chunk.startswith(w[:n], i):
                        ok[i + n] = True
        if not ok[-1]:
            return False
    return True


# Tags mail systems add to a mailbox (`n.rao.ext@`, `amitdas1.wv@`,
# `ravi.iyer.contractor@`): not part of anyone's name.
SYSTEM_TAGS = {"contractor", "ext", "external", "fut", "wv", "consultant", "contr", "temp", "vendor"}


def person_part(local):
    parts = [t for t in re.split(r"([._-])", local)]
    keep, i = [], 0
    toks = [t for t in re.split(r"[._-]", local) if t]
    kept = [t for t in toks if re.sub(r"\d", "", t.lower()) not in SYSTEM_TAGS]
    return ".".join(kept) if kept else local


def initials_case(name):
    """`Neha Pv` -> `Neha PV`: a short word with no vowel after its first letter is initials."""
    return " ".join(w.upper() if 1 < len(w) <= 3 and not re.search(r"[aeiou]", w.lower()[1:]) else w
                    for w in name.split())


def initials_only(local, sheet_names):
    """`ad@`, `ks1@`, `t-d@`: a mailbox that is only initials looks truncated.
    A role word (`hr@`, `ta@`) or the person's whole first name (`ram@` for
    Ram Iyer) is a real mailbox."""
    letters = re.sub(r"[^a-z]", "", local.lower())
    if len(letters) > 3 or letters in ROLE:
        return False
    return not (len(letters) == 3 and any(letters in re.findall(r"[a-z]+", n.lower()) for n in sheet_names))


# ----------------------------------------------------------------------------
# Planning

def domain_rules():
    """Host-level company rules: the pipeline's domain_moves plus this import's."""
    rules = {h: r for h, r in DECISIONS["domain_moves"].items()}
    for host, (name, sector, why) in R.HOST_MOVES.items():
        rules[host] = {"create": name, "why": why, "_sector": sector}
    return rules


def owners(st):
    """registrable domain (or ruled host) -> company ids that hold it today."""
    test = {st.resolve(n, required=False) for n in DECISIONS["test_companies"]} - {None}
    rules = domain_rules()
    own = collections.defaultdict(set)
    hosts = [(clean(r["email"] or ""), r["company_id"]) for r in st.recruiters]
    hosts += [(h, c["id"]) for c in st.companies.values() for h in (c.get("domains") or [])]
    for h, cid in hosts:
        if not h or is_personal(h) or cid in test:
            continue
        own[h if h in rules else registrable(h)].add(cid)
    return own


def plan(snapshot):
    tables = load_snapshot(snapshot)
    st = State(tables)
    items = json.loads((OUT / "extracted.json").read_text())
    dns = json.loads((OUT / "dns.json").read_text())
    own = owners(st)
    rules = domain_rules()
    relay = set(DECISIONS["relay_domains"])
    existing = {r["email"].strip().lower(): r for r in tables["recruiters"]}
    names_lower = {c["name"].lower(): cid for cid, c in st.companies.items()}
    by_company_local = collections.defaultdict(list)
    for r in tables["recruiters"]:
        e = r["email"].strip().lower()
        by_company_local[(r["company_id"], e.split("@")[0])].append(e)

    new_by_reg = {}
    for cname, spec in R.NEW.items():
        for reg in spec[1]:
            new_by_reg[reg] = cname
    for reg, (cid, _) in R.EXISTING.items():
        if cid not in st.companies:
            sys.exit(f"cdc_review.EXISTING: company {cid} for {reg} is gone")
        if reg in own and own[reg] != {cid}:
            sys.exit(f"cdc_review.EXISTING: {reg} is already held by {own[reg]}")
    for reg in list(new_by_reg) + list(R.EXCLUDE_DOMAINS):
        if reg in own:
            sys.exit(f"cdc_review: {reg} is already held by a catalog company; it can't be new or excluded")
    for cname in list(R.NEW) + [v[0] for v in R.HOST_MOVES.values()]:
        if cname.lower() in names_lower:
            sys.exit(f"cdc_review: new company {cname!r} clashes with an existing catalog name")

    occ = collections.defaultdict(list)
    for x in items:
        occ[x["email_raw"].strip().lower()].append(x)

    contacts, excluded, already, needs_review = [], [], [], []
    for email, xs in sorted(occ.items()):
        prov = [f"{x['sheet']}!R{x['row']}C{x['col'] + 1}" for x in xs]
        sheet_cos = sorted({x["company_sheet"] or "" for x in xs})
        host = clean(email)
        reg = registrable(host) if host else None
        local = email.split("@")[0]

        def out(reason):
            excluded.append({"email": email, "reason": reason, "sheet_company": sheet_cos, "where": prov})

        if not host:
            out("not a valid address"); continue
        if is_personal(host):
            out("personal mailbox (not a work address)"); continue
        if any(x["status"] == "Wrong Mail Id" for x in xs):
            out("the sheet marks this address 'Wrong Mail Id'"); continue
        if email in R.EXCLUDE_EMAILS:
            out(R.EXCLUDE_EMAILS[email]); continue
        if host in R.EXCLUDE_HOSTS:
            out(R.EXCLUDE_HOSTS[host]); continue
        if reg in R.EXCLUDE_DOMAINS or host in R.EXCLUDE_DOMAINS:
            out(R.EXCLUDE_DOMAINS.get(reg) or R.EXCLUDE_DOMAINS[host]); continue
        d = dns.get(host, {})
        has_mx = any(v["mx"] and v["mx"] != ["0 ."] for v in d.get("resolvers", {}).values())
        if not has_mx:
            out(f"{host} can't receive mail (DNS: {d.get('verdict', 'unchecked')})"); continue
        if host in dead_hosts() or reg in dead_hosts():
            out(f"{host} is on the catalog's dead-domain list"); continue
        sheet_names = sorted({p for x in xs if x["in_mail_col"] for p in people(x["hr_name"])})
        if initials_only(local, sheet_names) and email not in R.TEAM:
            out("initials-only mailbox (looks truncated); can't tell it's real"); continue
        if email in existing:
            r = existing[email]
            already.append({"email": email, "company_id": r["company_id"],
                            "company": st.companies[r["company_id"]]["name"], "name": r["name"], "where": prov})
            continue
        if reg in relay:
            sys.exit(f"{email}: recruiting-agency domain; needs a decision")

        # Company: a ruled host, then the domain's catalog owner, then the review.
        key = host if host in rules else reg
        if host in rules:
            rule = rules[host]
            if "create" in rule:
                hit = names_lower.get(rule["create"].lower())
                company, how = (hit, "existing") if hit else ("new:" + rule["create"], "new")
            else:
                company, how = st.resolve(rule["to"]), "existing"
            why = rule["why"]
        elif own.get(reg):
            if len(own[reg]) != 1:
                sys.exit(f"{reg} is split across {own[reg]} in the catalog")
            company, how, why = next(iter(own[reg])), "owned", f"{reg} is this company's domain in the catalog"
        elif reg in R.EXISTING:
            company, how = R.EXISTING[reg][0], "existing"
            why = R.EXISTING[reg][1]
        elif reg in new_by_reg:
            cname = new_by_reg[reg]
            company, how = "new:" + cname, "new"
            why = (R.NEW[cname][2] if len(R.NEW[cname]) > 2 else f"{reg} is {cname}'s domain")
        else:
            needs_review.append(f"{email}: domain {reg} isn't owned by a catalog company and isn't in cdc_review")
            continue

        # The same mailbox already filed under this company on another of its
        # domains (first.last@q2.com vs @q2ebanking.com) is the same person.
        twin = [e for e in by_company_local.get((company, local), []) if e != email]
        if twin:
            out(f"same person already in the catalog as {twin[0]}"); continue

        # Name: the sheet's, when the mailbox can be spelt from it; else the address's.
        sheet_names = sorted({p for x in xs if x["in_mail_col"] for p in people(x["hr_name"])})
        if email in R.TEAM:
            name, source = "Team", "role mailbox"
        elif email in R.NAME:
            name, source = R.NAME[email], "reviewed (see cdc_review.NAME)"
        else:
            core = person_part(local)
            fits = [n for n in sheet_names if explained(core, n)]
            d_name, _ = address_name(core + "@" + host)
            if d_name and d_name != "Team":
                d_name = initials_case(d_name)
            if d_name == "Team":
                name, source = "Team", "role mailbox"
            elif fits:
                name, source = tidy(max(fits, key=len)), "sheet"
            elif d_name:
                name, source = d_name, ("address (sheet name doesn't match it)" if sheet_names else "address")
            else:
                needs_review.append(f"{email}: sheet {sheet_names}, and the address spells no name out")
                continue
        contacts.append({"email": email, "host": host, "domain": key, "company": company, "how": how,
                         "why": why, "name": name, "greeting_name": None, "name_source": source,
                         "sheet_names": sheet_names, "sheet_company": sheet_cos, "where": prov})

    if needs_review:
        print("\n".join(needs_review))
        sys.exit(f"{len(needs_review)} addresses need a decision in cdc_review")

    # Companies to create and domains to add.
    hosts_for = collections.defaultdict(set)
    for c in contacts:
        hosts_for[c["company"]].add(c["host"])
    creates = []
    for cid in sorted(k for k in hosts_for if k.startswith("new:")):
        cname = cid[4:]
        if cname in R.NEW:
            sector, why = R.S[R.NEW[cname][0]], (R.NEW[cname][2] if len(R.NEW[cname]) > 2 else "")
        else:
            host_rule = next(v for v in R.HOST_MOVES.values() if v[0] == cname)
            sector, why = R.S[host_rule[1]], host_rule[2]
        creates.append({"key": cid, "name": cname, "sector": sector, "domains": sorted(hosts_for[cid]), "why": why})
    unused = set(R.NEW) - {c["name"] for c in creates}
    domain_adds = {}
    for cid, hosts in hosts_for.items():
        if cid.startswith("new:"):
            continue
        have = st.companies[cid].get("domains") or []
        add = sorted(hosts - set(have))
        if add:
            domain_adds[cid] = {"name": st.companies[cid]["name"], "before": have, "after": have + add}
    p = {"snapshot": str(snapshot), "contacts": contacts, "creates": creates, "domain_adds": domain_adds,
         "excluded": excluded, "already": already, "unused_review_companies": sorted(unused)}
    p["simulated"] = simulate(tables, p)
    return p


def simulate(tables, p):
    """The catalog as it would be after the import, checked by the pipeline's own rules."""
    import copy
    t = copy.deepcopy(tables)
    ids = {}
    for c in p["creates"]:
        ids[c["key"]] = "sim-" + c["key"]
        t["companies"].append({"id": ids[c["key"]], "name": c["name"], "sector": c["sector"], "domains": c["domains"]})
    for cid, d in p["domain_adds"].items():
        next(c for c in t["companies"] if c["id"] == cid)["domains"] = d["after"]
    for i, c in enumerate(p["contacts"]):
        t["recruiters"].append({"id": f"sim-r{i}", "company_id": ids.get(c["company"], c["company"]),
                                "name": c["name"], "email": c["email"], "position": None, "phone": None,
                                "is_valid": True, "greeting_name": c["greeting_name"]})
    before_v, before_w = verify(State(tables))
    after_v, after_w = verify(State(t))
    return {"violations_before": before_v, "violations_after": after_v,
            "new_warnings": sorted(set(after_w) - set(before_w))}


def write_plan(p):
    (OUT / "plan.json").write_text(json.dumps(p, indent=1, ensure_ascii=False))
    with open(OUT / "contacts_to_add.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["email", "name", "greeting", "name_source", "company", "company_how", "why_this_company",
                    "sheet_company", "sheet_names", "where"])
        cname = {c["key"]: c["name"] for c in p["creates"]}
        names = {cid: d["name"] for cid, d in p["domain_adds"].items()}
        snap = load_snapshot(p["snapshot"])
        allnames = {c["id"]: c["name"] for c in snap["companies"]}
        for c in p["contacts"]:
            w.writerow([c["email"], c["name"], c["greeting_name"], c["name_source"],
                        cname.get(c["company"]) or allnames[c["company"]], c["how"], c["why"],
                        "; ".join(c["sheet_company"]), "; ".join(c["sheet_names"]), " ".join(c["where"])])
    with open(OUT / "excluded.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["email", "reason", "sheet_company", "where"])
        for e in p["excluded"]:
            w.writerow([e["email"], e["reason"], "; ".join(e["sheet_company"]), " ".join(e["where"])])
    with open(OUT / "already_in_catalog.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["email", "catalog_company", "catalog_name", "where"])
        for e in p["already"]:
            w.writerow([e["email"], e["company"], e["name"], " ".join(e["where"])])
    sim = p["simulated"]
    print(f"contacts to add: {len(p['contacts'])}  new companies: {len(p['creates'])}  "
          f"companies gaining a domain: {len(p['domain_adds'])}")
    print(f"already in catalog: {len(p['already'])}  excluded: {len(p['excluded'])}")
    print(f"simulated violations: before {len(sim['violations_before'])}, after {len(sim['violations_after'])}")
    for v in sim["violations_after"][:20]:
        print("  !", v)
    print(f"new warnings: {len(sim['new_warnings'])}")
    for v in sim["new_warnings"][:40]:
        print("  ~", v)
    if p["unused_review_companies"]:
        print("review companies with no contact:", p["unused_review_companies"])



# ----------------------------------------------------------------------------
# Applying

def comparable(p):
    return (sorted((c["email"], c["company"], c["name"], c["greeting_name"]) for c in p["contacts"]),
            sorted((c["name"], c["sector"], tuple(c["domains"])) for c in p["creates"]),
            sorted((k, tuple(v["after"])) for k, v in p["domain_adds"].items()))


def apply():
    reviewed = json.loads((OUT / "plan.json").read_text())
    if reviewed["simulated"]["violations_after"]:
        sys.exit("the reviewed plan has simulated violations")
    snap = backup_mod.backup(label="-pre-cdc-import")
    fresh = plan(snap)
    if comparable(fresh) != comparable(reviewed):
        sys.exit("the catalog changed since the plan was reviewed: re-run `plan` and review it again")
    log = {"pre_backup": str(snap), "companies": {}, "domain_adds": {}, "recruiters": []}
    logf = OUT / "applied.json"

    def save():
        logf.write_text(json.dumps(log, indent=1, ensure_ascii=False))

    ids = {}
    for c in fresh["creates"]:
        if supabase.get("companies", {"name": ilike_exact(c["name"])}, "id"):
            sys.exit(f"company {c['name']!r} appeared in the catalog during the import; stopping")
        row = supabase.write("POST", "companies", body={"name": c["name"], "sector": c["sector"],
                                                         "domains": c["domains"]})
        assert len(row) == 1
        ids[c["key"]] = row[0]["id"]
        log["companies"][row[0]["id"]] = c["name"]
        save()
    for cid, d in fresh["domain_adds"].items():
        now = supabase.get("companies", {"id": f"eq.{cid}"}, "domains")[0]["domains"] or []
        if now != d["before"]:
            sys.exit(f"{d['name']}: domains changed during the import ({now})")
        got = supabase.write("PATCH", "companies", {"id": f"eq.{cid}"}, {"domains": d["after"]})
        assert len(got) == 1
        log["domain_adds"][cid] = d
        save()
    rows = [{"company_id": ids.get(c["company"], c["company"]), "name": c["name"], "email": c["email"],
             "greeting_name": c["greeting_name"], "position": None, "phone": None, "is_valid": True}
            for c in fresh["contacts"]]
    for i in range(0, len(rows), 100):
        batch = rows[i:i + 100]
        got = supabase.write("POST", "recruiters", body=batch)
        assert len(got) == len(batch), f"batch {i}: wrote {len(got)} of {len(batch)}"
        log["recruiters"] += [g["id"] for g in got]
        save()
    log["post_backup"] = str(backup_mod.backup(label="-post-cdc-import"))
    save()
    print(f"created {len(log['companies'])} companies, extended domains on {len(log['domain_adds'])}, "
          f"added {len(log['recruiters'])} contacts")


def rollback():
    """Undo an apply from its log: contacts first, then the companies it created."""
    log = json.loads((OUT / "applied.json").read_text())
    for i in range(0, len(log["recruiters"]), 100):
        supabase.write("DELETE", "recruiters", {"id": supabase.in_filter(log["recruiters"][i:i + 100])})
    for cid, d in log["domain_adds"].items():
        supabase.write("PATCH", "companies", {"id": f"eq.{cid}"}, {"domains": d["before"]})
    for cid in log["companies"]:
        if supabase.get("recruiters", {"company_id": f"eq.{cid}"}, "id"):
            print(f"keeping {log['companies'][cid]!r}: it has contacts the import didn't add")
            continue
        supabase.write("DELETE", "companies", {"id": f"eq.{cid}"})
    print("rolled back")


def main():
    cmd = sys.argv[1]
    OUT.mkdir(parents=True, exist_ok=True)
    if cmd == "extract":
        items = extract(sys.argv[2])
        (OUT / "extracted.json").write_text(json.dumps(items, indent=1, ensure_ascii=False))
        print(f"{len(items)} address occurrences from {len({(x['sheet'], x['row']) for x in items})} rows")
    elif cmd == "plan":
        snap = sys.argv[2] if len(sys.argv) > 2 else max(str(p) for p in (REPO / "db_backups").iterdir())
        write_plan(plan(snap))
    elif cmd == "apply":
        apply()
    elif cmd == "rollback":
        rollback()


if __name__ == "__main__":
    main()
