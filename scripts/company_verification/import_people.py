"""Import a list of people that has no addresses: name, job title, LinkedIn,
location and company (the "1800+ Talent Acquisition Database" sheet, and lists
shaped like it).

    python3 import_people.py plan <csv> [backup]   # match against a backup -> plan + report
    python3 import_people.py plan <csv> --companies-only   # the company side alone, no private key
    python3 import_people.py apply <csv>           # back up, re-plan, refuse if anything moved, write
    python3 import_people.py verify <csv>          # independent check of the live DB against the sheet
    python3 import_people.py rollback              # undo an apply from its log
    python3 import_people.py refile                # move people to hr_review.PERSON_COMPANY's company
    python3 import_people.py links plan|apply|verify <csv>   # companies' LinkedIn, X and Facebook
    python3 import_people.py links rollback

People go into the vault AURORA_VAULT_CODE names (default AURORA), sealed: a
name, the job title as position, and LinkedIn and location, which only exist
sealed. With no address they can't be mailed until one is added in the app.

Companies are matched to the catalog by the website's domain (against each
company's mail domains and website), then by name and also-known-as. A name
match whose domain contradicts the sheet's, a domain several companies hold,
or a new company with no sector stops the plan until hr_review.py decides it.
Matched companies only gain what they lack: a sector, a website (never over
one someone edited). New companies get the sheet's website and no mail
domains: those come from the addresses of people later added to them.

A person already in the vault at the same company under the same name is the
same person: their LinkedIn and location are filled in (and their position,
if it's empty), and nothing else about them changes. Someone whose LinkedIn
is already on file is skipped, which makes re-running an import harmless.

`links` runs after an apply: each company the sheet's people went to gets
the company LinkedIn, X and Facebook pages its rows give (told apart by host,
whatever the column; the one most rows agree on), sealed into our vault's
company links. Only links a company doesn't have yet are filled in.

Outputs and the apply log live in data_verification/hr_import/ (git-ignored:
they name people), with the judgement calls in hr_review.py beside them.
"""
import collections
import copy
import csv
import json
import re
import sys
import urllib.parse
from pathlib import Path

import backup as backup_mod
import company_links
import contacts
import supabase
from domains import clean, registrable
from verify_companies import State, ilike_exact, load_snapshot, verify

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / "data_verification" / "hr_import"

sys.path.insert(0, str(OUT))
try:
    import hr_review as R  # noqa: E402
except ImportError:
    R = None

COLUMNS = ("Name", "Job Title", "Linkedin URL", "Company Name", "Company Website", "Location", "Company Niche")
SOURCE = "talent_sheet"   # companies.website_source for websites this fills in

# Hosts that are a profile or a shortener, not the company's own website.
NOT_A_WEBSITE = {"linkedin.com", "facebook.com", "twitter.com", "x.com", "instagram.com", "youtube.com",
                 "page.link", "goo.gl", "bit.ly", "google.com", "medium.com", "wixsite.com", "blogspot.com",
                 "linktr.ee"}

# LinkedIn's industry labels -> the catalog's sectors. None: the label is too
# broad (or too often wrong) to go on; hr_review.SECTOR decides those.
NICHE = {
    "Information Technology & Services": "Enterprise software",
    "Computer & Network Security": "Enterprise software",
    "Marketing & Advertising": "Enterprise software",
    "Human Resources": "Staffing and HR services",
    "Staffing & Recruiting": "Staffing and HR services",
    "Financial Services": "Fintech and financial technology",
    "Insurance": "Fintech and financial technology",
    "Accounting": "Fintech and financial technology",
    "Banking": "Banks and financial institutions",
    "Management Consulting": "Consulting and IT services",
    "Hospital & Health Care": "Healthcare and life sciences",
    "Health, Wellness & Fitness": "Healthcare and life sciences",
    "Pharmaceuticals": "Healthcare and life sciences",
    "Biotechnology": "Healthcare and life sciences",
    "Medical Devices": "Healthcare and life sciences",
    "Medical Practice": "Healthcare and life sciences",
    "Higher Education": "Education",
    "E-learning": "Education",
    "Education Management": "Education",
    "Online Media": "Internet and consumer products",
    "Internet": "Internet and consumer products",
    "Consumer Services": "Internet and consumer products",
    "Transportation/trucking/railroad": "E-commerce and logistics",
    "Warehousing": "E-commerce and logistics",
    "Retail": "E-commerce and logistics",
    "Wholesale": "E-commerce and logistics",
    "Farming": "E-commerce and logistics",
    "Entertainment": "Media and publishing",
    "Media Production": "Media and publishing",
    "Computer Games": "Gaming",
    "Food & Beverages": "Consumer goods",
    "Apparel & Fashion": "Consumer goods",
    "Consumer Goods": "Consumer goods",
    "Furniture": "Consumer goods",
    "Automotive": "Automotive and mobility",
    "Aviation & Aerospace": "Aerospace, defense and space",
    "Semiconductors": "Semiconductors",
    "Telecommunications": "Telecommunications",
    "Renewables & Environment": "Energy and utilities",
    "Electrical/electronic Manufacturing": "Industrial manufacturing",
    "Government Administration": None, "Research": None, "Design": None, "Hospitality": None,
    "Real Estate": None, "Legal Services": None, "Venture Capital & Private Equity": None,
    "Mechanical Or Industrial Engineering": None, "Computer Hardware": None, "": None,
}


def review(name, default):
    return getattr(R, name, default) if R else default


# ----------------------------------------------------------------------------
# Reading the sheet

PRONOUNS = re.compile(r"\s*\(?\b(?:she|he|they)\s*/\s*(?:her|hers|him|his|them|theirs)\b\)?", re.I)
HONORIFIC = re.compile(r"^(?:mr|mrs|ms|miss|dr|prof)\.?\s+", re.I)


def person_name(raw):
    """"Pratikshya She/Her" -> "Pratikshya"; spacing tidied. Nothing guessed."""
    text = PRONOUNS.sub("", raw or "")
    text = HONORIFIC.sub("", " ".join(text.split()))
    return text.strip(" ,|-")


def name_key(name):
    """Two spellings of one name compare equal: case, dots and spacing aside."""
    return " ".join(re.sub(r"[.\s]+", " ", (name or "").lower()).split())


def linkedin(raw):
    """A profile link as stored: https://www.linkedin.com/in/<id>, no query or
    trailing slash. None when it isn't a LinkedIn profile."""
    text = (raw or "").strip()
    if not text:
        return None
    if "://" not in text:
        text = "https://" + text
    u = urllib.parse.urlsplit(text)
    host = (u.hostname or "").lower()
    if not (host == "linkedin.com" or host.endswith(".linkedin.com")):
        return None
    path = re.sub(r"/+$", "", u.path)
    if not re.fullmatch(r"/in/[^/]+", path):
        return None
    return "https://www.linkedin.com" + path


def linkedin_key(url):
    """One key per profile. A profile's address ends in an ID LinkedIn gives it
    ("-5a15434a") that stays when its owner renames the rest, so lists often
    hold one person twice ("sai-charan-m-5a15434a", "saicharan-manipatruni-
    5a15434a"); the ID is the key when there is one."""
    slug = urllib.parse.unquote(url or "").lower().rstrip("/").rsplit("/in/", 1)[-1]
    if not slug:
        return None
    m = re.search(r"-([0-9a-f]{8,12})$", slug)
    return "id:" + m.group(1) if m else slug


def fullest(rows):
    """Of one person's rows, the one with the most of their name."""
    return max(rows, key=lambda r: (len(re.sub(r"[^a-z]", "", person_name(r["Name"]).lower())), -r["_row"]))


def website(raw):
    """(website as stored, its registrable domain), or (None, None) for none or a profile page."""
    host = clean(re.sub(r":\d+(?=/|$)", "", (raw or "").strip()))
    if not host:
        return None, None
    reg = registrable(host)
    if reg in NOT_A_WEBSITE or host in NOT_A_WEBSITE or host.endswith(".wixsite.com"):
        return None, None
    return "https://" + ("www." + host if host == reg else host), reg


def read_sheet(path):
    """Rows as dicts by header. The header is the first row naming the columns
    (the file may open with a banner)."""
    with open(path, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.reader(f))
    for i, row in enumerate(rows):
        if all(c in row for c in COLUMNS):
            header = [h.strip() for h in row]
            out = []
            for n, r in enumerate(rows[i + 1:], start=i + 2):
                if not any(c.strip() for c in r):
                    continue
                d = {h: (r[j].strip() if j < len(r) else "") for j, h in enumerate(header)}
                d["_row"] = n
                out.append(d)
            return out
    sys.exit(f"{path}: no header row with the columns {COLUMNS}")


# ----------------------------------------------------------------------------
# Companies

LEGAL = re.compile(r"[\s,]+(?:pvt\.?\s*ltd\.?|private\s+limited|pte\.?\s*ltd\.?|limited|ltd\.?|inc\.?|llc|llp|lp|"
                   r"plc|corp\.?|corporation)$", re.I)


def company_name(raw):
    """The sheet's company name as the catalog would hold it: no legal suffix,
    no tagline, no "(formerly …)"."""
    name = review("NAME", {}).get(raw)
    if name:
        return name
    text = re.sub(r"\((?:formerly|previously)[^)]*\)", "", raw, flags=re.I)
    text = re.split(r"\s+[-|:]\s+|:\s+", text)[0]
    prev = None
    while prev != text:
        prev, text = text, LEGAL.sub("", text.strip()).strip(" ,")
    return " ".join(text.split())


def company_key(n):
    """The pipeline's similar-names key (verify_companies.verify)."""
    n = re.sub(r"\(.*?\)", "", n.lower()).replace("&", " and ")
    n = re.sub(r"[^a-z0-9 ]", " ", n.replace("'", ""))
    n = re.sub(r"\b(ltd|limited|pvt|private|inc|llc|llp|plc|corp|corporation|company|co|"
               r"technologies|technology|tech|solutions|services|group|india|global|the)\b", " ", n)
    return re.sub(r"\s+", "", n)


class Catalog:
    def __init__(self, companies):
        self.companies = {c["id"]: c for c in companies}
        self.by_domain = collections.defaultdict(set)
        self.by_key = collections.defaultdict(set)
        for c in companies:
            for n in [c["name"]] + list(c.get("also_known_as") or []):
                if company_key(n):
                    self.by_key[company_key(n)].add(c["id"])
            for reg in self.domains(c):
                self.by_domain[reg].add(c["id"])

    @staticmethod
    def domains(c):
        regs = {registrable(h) or h for h in (c.get("domains") or [])}
        if c.get("website"):
            _, reg = website(c["website"])
            if reg:
                regs.add(reg)
        return regs


def resolve(sheet_company, rows, cat):
    """-> (decision, problem). decision: {"how", "id" | "new", "why"}."""
    decided = review("COMPANY", {}).get(sheet_company)
    if decided:
        kind = decided[0]
        if kind == "skip":
            return {"how": "skip", "why": decided[1]}, None
        if kind == "id":
            if decided[1] not in cat.companies:
                return None, f"hr_review.COMPANY: {sheet_company!r} -> {decided[1]}, which is gone"
            return {"how": "reviewed", "id": decided[1], "why": decided[2]}, None
        return {"how": "new", "new": decided[1], "why": decided[2]}, None

    sites = {website(r["Company Website"])[1] for r in rows} - {None}
    if len(sites) > 1:
        return None, f"{sheet_company!r}: the sheet gives several websites {sorted(sites)}"
    reg = next(iter(sites), None)
    by_domain = cat.by_domain.get(reg, set()) if reg else set()
    by_name = cat.by_key.get(company_key(company_name(sheet_company)), set()) | \
        cat.by_key.get(company_key(sheet_company), set())

    if by_domain:
        both = by_domain & by_name
        if len(both) == 1:
            return {"how": "domain+name", "id": next(iter(both)), "why": f"{reg} and the name"}, None
        if len(by_domain) == 1:
            cid = next(iter(by_domain))
            return {"how": "domain", "id": cid, "why": f"{reg} is {cat.companies[cid]['name']}'s"}, None
        return None, f"{sheet_company!r}: {reg} is held by several companies " \
                     f"{sorted(cat.companies[i]['name'] for i in by_domain)}"
    if by_name:
        if len(by_name) > 1:
            return None, f"{sheet_company!r}: the name matches several companies " \
                         f"{sorted(cat.companies[i]['name'] for i in by_name)}"
        cid = next(iter(by_name))
        theirs = cat.domains(cat.companies[cid])
        if reg and theirs and reg not in theirs:
            return None, f"{sheet_company!r} ({reg}) has the name of {cat.companies[cid]['name']!r} " \
                         f"({sorted(theirs)}): the same company, or another one?"
        return {"how": "name", "id": cid, "why": "the name (the catalog row has no other domain)" if not theirs
                else "the name"}, None
    return {"how": "new", "new": company_name(sheet_company), "why": "not in the catalog"}, None


def person_company(row):
    """hr_review.PERSON_COMPANY's company for this row's person, when the sheet
    files people at two companies under one name: {LinkedIn key: (id, why)}."""
    got = review("PERSON_COMPANY", {}).get(linkedin_key(linkedin(row["Linkedin URL"])) or "")
    return got[0] if got else None


def sector_for(sheet_company, rows):
    fixed = review("SECTOR", {}).get(sheet_company)
    if fixed:
        return fixed, "hr_review.SECTOR"
    niches = {r["Company Niche"] for r in rows}
    sectors = {NICHE.get(n) for n in niches}
    if len(sectors) == 1 and None not in sectors:
        return next(iter(sectors)), f"LinkedIn niche {next(iter(niches))!r}"
    return None, f"LinkedIn niche {sorted(niches)}"


# ----------------------------------------------------------------------------
# Planning

def plan(csv_path, snapshot, companies_only=False):
    sheet = read_sheet(csv_path)
    snapshot = Path(snapshot)
    if companies_only:
        tables = {"companies": json.loads((snapshot / "companies.json").read_text())}
    else:
        tables = load_snapshot(snapshot)
    cat = Catalog(tables["companies"])
    problems = []

    by_company = collections.defaultdict(list)
    for r in sheet:
        by_company[r["Company Name"]].append(r)

    # 1. Each sheet company -> a catalog company, a new one, or left out.
    decisions, creates = {}, {}
    for sc, rows in by_company.items():
        d, problem = resolve(sc, rows, cat)
        if problem:
            problems.append(problem)
            continue
        if d["how"] == "new":
            key = company_key(d["new"])
            clash = cat.by_key.get(key)
            if clash:
                problems.append(f"new company {d['new']!r} (from {sc!r}) has the name of "
                                f"{sorted(cat.companies[i]['name'] for i in clash)}: decide it in hr_review.COMPANY")
                continue
            site = next((website(r["Company Website"]) for r in rows if website(r["Company Website"])[0]), (None, None))
            sector, sector_why = sector_for(sc, rows)
            if not sector:
                problems.append(f"new company {d['new']!r} (from {sc!r}): no sector — {sector_why}")
                continue
            ckey = "new:" + d["new"]
            if ckey in creates:
                if creates[ckey]["domain"] != site[1]:
                    problems.append(f"{sc!r} and {creates[ckey]['sheet']} both clean to {d['new']!r} "
                                    "with different websites")
                    continue
                creates[ckey]["sheet"].append(sc)
            else:
                creates[ckey] = {"key": ckey, "name": d["new"], "sector": sector, "sector_why": sector_why,
                                 "website": site[0], "domain": site[1], "sheet": [sc], "why": d["why"]}
            d["id"] = ckey
        decisions[sc] = d

    # 2. What matched companies gain: renames, other names, a sector, a website.
    patches = {}

    def patch(cid):
        c = cat.companies[cid]
        return patches.setdefault(cid, {"name": c["name"], "before": {}, "after": {}, "why": []})

    for cid, (expected, new, why) in review("RENAME", {}).items():
        c = cat.companies.get(cid)
        if not c:
            problems.append(f"hr_review.RENAME: {cid} ({expected}) is gone")
            continue
        if c["name"] != expected:
            if c["name"] == new:
                continue   # done by an earlier run
            problems.append(f"hr_review.RENAME: {cid} is now {c['name']!r}, not {expected!r}")
            continue
        clash = (cat.by_key.get(company_key(new), set()) | {i for i, x in cat.companies.items()
                                                            if x["name"].lower() == new.lower()}) - {cid}
        if clash:
            problems.append(f"hr_review.RENAME: {new!r} is already {sorted(cat.companies[i]['name'] for i in clash)}")
            continue
        p = patch(cid)
        p["before"]["name"], p["after"]["name"] = c["name"], new
        aliases = list(c.get("also_known_as") or [])
        if c["name"] not in aliases:
            p["before"]["also_known_as"], p["after"]["also_known_as"] = aliases, aliases + [c["name"]]
        p["why"].append(f"renamed: {why}")
    for cid, names in review("ALIASES", {}).items():
        c = cat.companies.get(cid)
        if not c:
            problems.append(f"hr_review.ALIASES: {cid} is gone")
            continue
        p = patch(cid)
        have = p["after"].get("also_known_as", list(c.get("also_known_as") or []))
        add = [n for n in names if n not in have]
        if add:
            p["before"].setdefault("also_known_as", list(c.get("also_known_as") or []))
            p["after"]["also_known_as"] = have + add
            p["why"].append(f"also known as {add}")
    for cid, (expected, new, why) in review("SECTOR_FIX", {}).items():
        c = cat.companies.get(cid)
        if c and c.get("sector") == expected:
            p = patch(cid)
            p["before"]["sector"], p["after"]["sector"] = expected, new
            p["why"].append(f"sector corrected: {why}")
    for sc, d in decisions.items():
        cid = d.get("id")
        if not cid or cid.startswith("new:"):
            continue
        c = cat.companies[cid]
        rows = by_company[sc]
        sector, sector_why = sector_for(sc, rows)
        if not c.get("sector") and sector and "sector" not in patches.get(cid, {}).get("after", {}):
            p = patch(cid)
            p["before"]["sector"], p["after"]["sector"] = None, sector
            p["why"].append(f"sector from {sector_why}")
        site, reg = next((website(r["Company Website"]) for r in rows if website(r["Company Website"])[0]),
                         (None, None))
        theirs = {registrable(h) or h for h in (c.get("domains") or [])}
        if (site and not c.get("website") and c.get("website_source") != "edited"
                and (not theirs or reg in theirs) and "website" not in patches.get(cid, {}).get("after", {})):
            p = patch(cid)
            p["before"].update(website=None, website_source=c.get("website_source"))
            p["after"].update(website=site, website_source=SOURCE)
            p["why"].append("website from the sheet")

    # 3. People.
    people, excluded, already, merges = [], [], [], []
    existing = [] if companies_only else [r for r in tables["recruiters"] if r["id"] not in contacts.session().locked]
    by_li = collections.defaultdict(list)
    by_name_at = collections.defaultdict(list)
    for r in existing:
        if r.get("linkedin"):
            by_li[linkedin_key(r["linkedin"])].append(r)
        by_name_at[(r["company_id"], name_key(r["name"]))].append(r)
    seen_li, seen_name = {}, {}
    dup_rules = review("DUPLICATES", {})
    profiles = collections.defaultdict(list)
    for r in sheet:
        profiles[linkedin_key(linkedin(r["Linkedin URL"])) or f"row:{r['_row']}"].append(r)
    keep = {fullest(rows)["_row"]: rows for rows in profiles.values()}
    for r in sheet:
        sc = r["Company Name"]
        d = decisions.get(sc)
        where = f"row {r['_row']}"
        name = person_name(r["Name"])
        li = linkedin(r["Linkedin URL"])
        if d is None:
            continue   # its company is a problem above
        if d["how"] == "skip":
            excluded.append({"name": name, "company": sc, "why": d["why"], "where": where})
            continue
        if not name:
            excluded.append({"name": r["Name"], "company": sc, "why": "no name", "where": where})
            continue
        if not li and r["Linkedin URL"]:
            problems.append(f"{where}: {r['Linkedin URL']!r} isn't a LinkedIn profile link")
            continue
        cid = person_company(r) or d["id"]
        if cid not in cat.companies and not cid.startswith("new:"):
            problems.append(f"{where}: hr_review.PERSON_COMPANY -> {cid}, which is gone")
            continue
        person = {"name": name, "position": " ".join(r["Job Title"].split()) or None, "linkedin": li,
                  "location": " ".join(r["Location"].split()) or None, "company": cid, "sheet_company": sc,
                  "where": where}
        lk = linkedin_key(li)
        if r["_row"] not in keep:
            kept = next(k for k, rows in keep.items() if r in rows)
            excluded.append({"name": name, "company": sc, "where": where,
                             "why": f"the same LinkedIn profile as row {kept}, under an older or newer name"})
            continue
        if lk and lk in seen_li:
            excluded.append({"name": name, "company": sc, "why": f"same LinkedIn as {seen_li[lk]}", "where": where})
            continue
        nk = (d["id"], name_key(name))
        if nk in seen_name:
            rule = dup_rules.get(f"{name}|{sc}")
            if rule == "same":
                excluded.append({"name": name, "company": sc, "why": f"same person as {seen_name[nk]} "
                                 "(hr_review.DUPLICATES)", "where": where})
                continue
            if rule != "different":
                problems.append(f"{where}: {name!r} at {sc!r} is also {seen_name[nk]}, with another LinkedIn: "
                                f"one person or two? (hr_review.DUPLICATES[{name + '|' + sc!r}])")
                continue
        if lk:
            seen_li[lk] = where
        seen_name.setdefault(nk, where)

        on_file = by_li.get(lk, []) if lk else []
        if on_file:
            already.append({**person, "contact": on_file[0]["id"], "filed_under": on_file[0]["company_id"]})
            continue
        same = [] if d["id"].startswith("new:") else by_name_at.get(nk, [])
        why_this_one = None
        if len(same) > 1:
            pick = review("SAME_NAME", {}).get(f"{name}|{sc}")
            working = [x for x in same if x.get("is_valid") is not False and x.get("email")]
            if pick == "new":
                people.append({**person, "note": "namesakes there are other people (hr_review.SAME_NAME)"})
                continue
            if pick:
                same = [x for x in same if x["id"] == pick]
                if not same:
                    problems.append(f"{where}: hr_review.SAME_NAME[{name + '|' + sc!r}] is {pick}, "
                                    "not one of the contacts it could be")
                    continue
                why_this_one = "chosen in hr_review.SAME_NAME"
            elif len(working) == 1:
                same, why_this_one = working, "the only one of the namesakes whose address still works"
            else:
                listed = "; ".join(f"{x['id']} {x.get('email') or 'no address'}"
                                   f"{' (bounced)' if x.get('is_valid') is False else ''}"
                                   f", {x.get('position') or 'no position'}" for x in same)
                problems.append(f"{where}: {name!r} matches {len(same)} contacts at {sc!r}: which one? {listed} "
                                f"(hr_review.SAME_NAME[{name + '|' + sc!r}] = <id> or \"new\")")
                continue
        if same:
            ex = same[0]
            if ex.get("linkedin") and linkedin_key(ex["linkedin"]) != lk:
                people.append({**person, "note": "a namesake there has another LinkedIn"})
                continue
            changes = {"linkedin": li} if li else {}
            if person["location"] and not ex.get("location"):
                changes["location"] = person["location"]
            if person["position"] and not ex.get("position"):
                changes["position"] = person["position"]
            if changes:
                merges.append({"contact": ex["id"], "company": d["id"], "name": ex["name"], "sheet": person,
                               "before": {k: ex.get(k) for k in changes}, "changes": changes,
                               **({"why": why_this_one} if why_this_one else {})})
            else:
                already.append({**person, "contact": ex["id"], "filed_under": ex["company_id"]})
            continue
        people.append(person)

    if problems:
        print("\n".join(problems))
        sys.exit(f"{len(problems)} things need a decision in {OUT / 'hr_review.py'}")

    p = {"csv": str(csv_path), "snapshot": str(snapshot), "companies_only": companies_only,
         "decisions": decisions, "creates": sorted(creates.values(), key=lambda c: c["name"]),
         "patches": patches, "people": people, "merges": merges, "already": already, "excluded": excluded}
    if not companies_only:
        p["simulated"] = simulate(tables, p)
    return p


def simulate(tables, p):
    """The catalog after the import, checked by the pipeline's own rules."""
    t = copy.deepcopy(tables)
    for c in p["creates"]:
        t["companies"].append({"id": c["key"], "name": c["name"], "sector": c["sector"], "domains": [],
                               "website": c["website"], "also_known_as": []})
    by_id = {c["id"]: c for c in t["companies"]}
    for cid, x in p["patches"].items():
        by_id[cid].update(x["after"])
    for i, x in enumerate(p["people"]):
        t["recruiters"].append({"id": f"sim-{i}", "company_id": x["company"], "name": x["name"], "email": "",
                                "position": x["position"], "phone": None, "greeting_name": None, "is_valid": True,
                                "linkedin": x["linkedin"], "location": x["location"]})
    before_v, before_w = verify(State(tables))
    after_v, after_w = verify(State(t))
    return {"violations_before": before_v, "violations_after": after_v,
            "new_violations": sorted(set(after_v) - set(before_v)),
            "new_warnings": sorted(set(after_w) - set(before_w))}


def write_plan(p):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "plan.json").write_text(json.dumps(p, indent=1, ensure_ascii=False))
    names = {c["key"]: c["name"] for c in p["creates"]}
    snap = json.loads((Path(p["snapshot"]) / "companies.json").read_text())
    names.update({c["id"]: c["name"] for c in snap})
    with open(OUT / "companies.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["sheet_company", "people", "outcome", "catalog_company", "why"])
        counts = collections.Counter(x["sheet_company"] for x in p["people"] + [m["sheet"] for m in p["merges"]])
        for sc, d in sorted(p["decisions"].items()):
            w.writerow([sc, counts[sc], d["how"], names.get(d.get("id"), ""), d["why"]])
    with open(OUT / "company_changes.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["company", "change", "before", "after", "why"])
        for c in p["creates"]:
            w.writerow([c["name"], "create", "", f"{c['sector']} · {c['website'] or 'no website'}",
                        f"{c['why']}; sector from {c['sector_why']}; sheet: {'; '.join(c['sheet'])}"])
        for cid, x in sorted(p["patches"].items(), key=lambda kv: kv[1]["name"]):
            for k in x["after"]:
                w.writerow([x["name"], k, x["before"].get(k), x["after"][k], "; ".join(x["why"])])
    with open(OUT / "people.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["outcome", "name", "position", "location", "linkedin", "company", "sheet_company", "where", "note"])
        for x in p["people"]:
            w.writerow(["add", x["name"], x["position"], x["location"], x["linkedin"], names.get(x["company"]),
                        x["sheet_company"], x["where"], x.get("note", "")])
        for m in p["merges"]:
            x = m["sheet"]
            w.writerow(["fill in " + ", ".join(m["changes"]), m["name"], x["position"], x["location"], x["linkedin"],
                        names.get(m["company"]), x["sheet_company"], x["where"], ""])
        for x in p["already"]:
            w.writerow(["already on file", x["name"], x["position"], x["location"], x["linkedin"],
                        names.get(x["filed_under"]), x["sheet_company"], x["where"], ""])
        for x in p["excluded"]:
            w.writerow(["left out", x["name"], "", "", "", "", x["company"], x["where"], x["why"]])
    hows = collections.Counter(d["how"] for d in p["decisions"].values())
    print(f"sheet companies: {len(p['decisions'])} ({', '.join(f'{k} {v}' for k, v in sorted(hows.items()))})")
    print(f"new companies: {len(p['creates'])}  catalog companies changed: {len(p['patches'])}")
    print(f"people to add: {len(p['people'])}  to fill in: {len(p['merges'])}  "
          f"already on file: {len(p['already'])}  left out: {len(p['excluded'])}")
    sim = p.get("simulated")
    if sim:
        print(f"simulated violations: before {len(sim['violations_before'])}, after {len(sim['violations_after'])}, "
              f"new {len(sim['new_violations'])}")
        for v in sim["new_violations"][:20]:
            print("  !", v)
        print(f"new warnings: {len(sim['new_warnings'])}")
        for v in sim["new_warnings"][:40]:
            print("  ~", v)
    print(f"review: {OUT}/companies.csv, company_changes.csv, people.csv")


# ----------------------------------------------------------------------------
# Applying

def comparable(p):
    return (sorted((x["linkedin"] or "", x["name"], x["company"], x["position"] or "", x["location"] or "")
                   for x in p["people"]),
            sorted((m["contact"], json.dumps(m["changes"], sort_keys=True)) for m in p["merges"]),
            sorted((c["name"], c["sector"], c["website"] or "") for c in p["creates"]),
            sorted((k, json.dumps(v["after"], sort_keys=True)) for k, v in p["patches"].items()))


def apply(csv_path):
    reviewed = json.loads((OUT / "plan.json").read_text())
    if reviewed.get("companies_only"):
        sys.exit("plan.json is a companies-only plan: run `plan <csv>` (with the private key) and review it")
    if reviewed["simulated"]["new_violations"]:
        sys.exit("the reviewed plan has new simulated violations")
    snap = backup_mod.backup(label="-pre-hr-import")
    fresh = plan(csv_path, snap)
    if comparable(fresh) != comparable(reviewed):
        sys.exit("the catalog changed since the plan was reviewed: re-run `plan` and review it again")
    log = {"pre_backup": str(snap), "companies": {}, "patches": {}, "inserted": [], "merged": {}}
    logf = OUT / "applied.json"
    if logf.exists():
        sys.exit(f"{logf} exists: an earlier apply's log. Roll it back or move it aside first")

    def save():
        logf.write_text(json.dumps(log, indent=1, ensure_ascii=False))

    ids = {}
    for c in fresh["creates"]:
        if supabase.get("companies", {"name": ilike_exact(c["name"])}, "id"):
            sys.exit(f"company {c['name']!r} appeared in the catalog during the import; stopping")
        row = supabase.write("POST", "companies", body={
            "name": c["name"], "sector": c["sector"], "domains": [], "also_known_as": [],
            "website": c["website"], "website_source": SOURCE if c["website"] else None})
        assert len(row) == 1
        ids[c["key"]] = row[0]["id"]
        log["companies"][row[0]["id"]] = c["name"]
        save()
    for cid, x in fresh["patches"].items():
        cols = ",".join(x["after"])
        now = supabase.get("companies", {"id": f"eq.{cid}"}, cols)[0]
        if any(now.get(k) != v for k, v in x["before"].items()):
            sys.exit(f"{x['name']}: changed during the import ({now})")
        got = supabase.write("PATCH", "companies", {"id": f"eq.{cid}"}, x["after"])
        assert len(got) == 1
        log["patches"][cid] = x
        save()
    rows = [{"company_id": ids.get(x["company"], x["company"]), "name": x["name"], "email": None,
             "position": x["position"], "phone": None, "greeting_name": None, "is_valid": True,
             "linkedin": x["linkedin"], "location": x["location"]} for x in fresh["people"]]
    for i in range(0, len(rows), 100):
        batch = rows[i:i + 100]
        got = contacts.insert(batch)
        assert len(got) == len(batch), f"batch {i}: wrote {len(got)} of {len(batch)}"
        log["inserted"] += [g["id"] for g in got]
        save()
    for m in fresh["merges"]:
        got = contacts.update(m["contact"], m["changes"])
        assert len(got) == 1
        log["merged"][m["contact"]] = m["before"]
        save()
    log["post_backup"] = str(backup_mod.backup(label="-post-hr-import"))
    save()
    print(f"created {len(log['companies'])} companies, changed {len(log['patches'])}, "
          f"added {len(log['inserted'])} people, filled in {len(log['merged'])}")


def refile():
    """Move people an earlier apply filed under their sheet company to the one
    hr_review.PERSON_COMPANY now gives them. Backs up first; logs to refiled.json."""
    wanted = review("PERSON_COMPANY", {})
    live = contacts.read_live()
    moves = []
    for lk, (cid, why) in sorted(wanted.items()):
        hits = [r for r in live if r.get("linkedin") and linkedin_key(r["linkedin"]) == lk]
        if len(hits) != 1:
            sys.exit(f"hr_review.PERSON_COMPANY: {len(hits)} contacts have the LinkedIn {lk}")
        if not supabase.get("companies", {"id": f"eq.{cid}"}, "id"):
            sys.exit(f"hr_review.PERSON_COMPANY: {cid} isn't in the catalog")
        if hits[0]["company_id"] != cid:
            moves.append({"contact": hits[0]["id"], "from": hits[0]["company_id"], "to": cid, "why": why})
    if not moves:
        print("everyone is where hr_review.PERSON_COMPANY puts them")
        return
    logf = OUT / "refiled.json"
    log = json.loads(logf.read_text()) if logf.exists() else []
    log.append({"backup": str(backup_mod.backup(label="-pre-refile")), "moves": moves})
    for m in moves:
        got = supabase.write("PATCH", "recruiters", {"id": f"eq.{m['contact']}", "company_id": f"eq.{m['from']}"},
                             {"company_id": m["to"]})
        assert len(got) == 1, f"contact {m['contact']} changed since it was read"
    logf.write_text(json.dumps(log, indent=1))
    print(f"moved {len(moves)} people")


def rollback():
    """Undo an apply from its log: people first, then company changes, then the
    companies it created (unless someone has since added people to them)."""
    logf = OUT / "applied.json"
    log = json.loads(logf.read_text())
    for i in range(0, len(log["inserted"]), 100):
        supabase.write("DELETE", "recruiters", {"id": supabase.in_filter(log["inserted"][i:i + 100])})
    for cid, before in log["merged"].items():
        contacts.update(cid, before)
    for cid, x in log["patches"].items():
        supabase.write("PATCH", "companies", {"id": f"eq.{cid}"}, x["before"])
    for cid, name in log["companies"].items():
        if supabase.get("recruiters", {"company_id": f"eq.{cid}"}, "id"):
            print(f"keeping {name!r}: it has contacts the import didn't add")
            continue
        supabase.write("DELETE", "companies", {"id": f"eq.{cid}"})
    logf.rename(logf.with_name("rolled_back.json"))
    print("rolled back")


# ----------------------------------------------------------------------------
# Verifying

def later_changes(since):
    """What the company pass and `refile` have legitimately changed since the
    backup named `since`: ({folded company id: id it went into}, {contact id:
    (company it left, company it went to)})."""
    stamp = Path(since).name[:15]
    folds = {}
    for plan_file in sorted((REPO / "data_verification").glob("*/plan.json")):
        # Only runs that were applied: those leave an `after` snapshot, dry runs don't.
        if plan_file.parent.name[:15] > stamp and (plan_file.parent / "after").is_dir():
            folds.update(json.loads(plan_file.read_text()).get("fold_into", {}))
    refiled = {}
    logf = OUT / "refiled.json"
    for run in json.loads(logf.read_text()) if logf.exists() else []:
        if Path(run["backup"]).name[:15] > stamp:
            refiled.update({m["contact"]: (m["from"], m["to"]) for m in run["moves"]})
    return folds, refiled


def folded_into(cid, folds):
    seen = set()
    while cid in folds and cid not in seen:
        seen.add(cid)
        cid = folds[cid]
    return cid


def check(csv_path):
    """Independent of the plan: read the sheet again, the live DB and the
    backup from before the apply, and prove that every person is on file
    exactly once, under a company the sheet's own data points to, with the
    sheet's details — and that nothing else in the DB changed."""
    log = json.loads((OUT / "applied.json").read_text())
    pre = Path(log["pre_backup"])
    sheet = read_sheet(csv_path)
    before = load_snapshot(pre)
    live_companies = {c["id"]: c for c in supabase.get_all("companies", order="id.asc")}
    live = contacts.read_live()
    bad = []

    by_li = collections.defaultdict(list)
    for r in live:
        if r.get("linkedin"):
            by_li[linkedin_key(r["linkedin"])].append(r)
    company_rules = review("COMPANY", {})
    renamed = {cid: old for cid, (old, _, _) in review("RENAME", {}).items()}
    # A profile listed twice (renamed vanity link) was added once, from its
    # fullest row: the details to expect are that row's.
    profiles = collections.defaultdict(list)
    for row in sheet:
        profiles[linkedin_key(linkedin(row["Linkedin URL"])) or f"row:{row['_row']}"].append(row)
    details = {row["_row"]: fullest(rows) for rows in profiles.values() for row in rows}
    found = 0
    for row in sheet:
        sc = row["Company Name"]
        rule = company_rules.get(sc)
        li = linkedin(row["Linkedin URL"])
        hits = by_li.get(linkedin_key(li), [])
        if rule and rule[0] == "skip":
            if hits:
                bad.append(f"row {row['_row']}: left out on purpose, but on file")
            continue
        if len(hits) != 1:
            bad.append(f"row {row['_row']}: {len(hits)} contacts have its LinkedIn")
            continue
        found += 1
        r = hits[0]
        c = live_companies.get(r["company_id"])
        if not c:
            bad.append(f"row {row['_row']}: filed under a missing company")
            continue
        site_reg = website(row["Company Website"])[1]
        names = {company_key(n) for n in [c["name"]] + list(c.get("also_known_as") or []) + [renamed.get(c["id"], "")]}
        if person_company(row):
            ok = c["id"] == person_company(row)
        elif rule and rule[0] == "id":
            ok = c["id"] == rule[1]
        elif rule and rule[0] == "new":
            ok = c["name"] == rule[1]
        else:
            ok = (bool(site_reg) and site_reg in Catalog.domains(c)) or \
                 company_key(sc) in names or company_key(company_name(sc)) in names
        if not ok:
            bad.append(f"row {row['_row']}: filed under {c['name']!r}, which nothing in the sheet points to")
        src = details[row["_row"]]
        if name_key(r["name"]) != name_key(person_name(src["Name"])):
            bad.append(f"row {row['_row']}: the name on file differs from the sheet's")
        title = " ".join(src["Job Title"].split()) or None
        if r["position"] != title and r["id"] in log["inserted"]:
            bad.append(f"row {row['_row']}: position differs")
        loc = " ".join(src["Location"].split()) or None
        if r.get("location") != loc and r["id"] in log["inserted"]:
            bad.append(f"row {row['_row']}: location differs")
        if r["id"] in log["inserted"] and (r["email"] or r["phone"] or r["greeting_name"]):
            bad.append(f"row {row['_row']}: an added person has an address, phone or greeting")

    # Nothing else moved: every contact from before is still there with the
    # same fields, except the ones filled in; nothing new besides the log's.
    pre_rows = {r["id"]: r for r in before["recruiters"]}
    live_rows = {r["id"]: r for r in live}
    # A company folded into another since, or a person refiled, isn't damage:
    # the company pass and `refile` back up and verify their own changes.
    folds, refiled = later_changes(pre)
    folds = {src: dst for src, dst in folds.items() if src not in live_companies}
    moved_on = 0
    for rid, r in pre_rows.items():
        now = live_rows.get(rid)
        if now is None:
            bad.append(f"contact {rid} from before the import is gone")
            continue
        allowed = set(log["merged"].get(rid, {}))
        diff = {k for k in set(r) | set(now) if k not in allowed and r.get(k) != now.get(k)}
        if diff == {"company_id"} and (folded_into(r["company_id"], folds) == now["company_id"]
                                       or refiled.get(rid) == (r["company_id"], now["company_id"])):
            moved_on += 1
            continue
        if diff:
            bad.append(f"contact {rid} changed outside the import: {sorted(diff)}")
    if moved_on:
        print(f"note: {moved_on} contacts have since moved with a company merge or `refile`")
    extra = set(live_rows) - set(pre_rows) - set(log["inserted"])
    if extra:
        print(f"note: {len(extra)} contacts were added since, not by the import")
    missing = set(log["inserted"]) - set(live_rows)
    if missing:
        bad.append(f"{len(missing)} added contacts are gone")
    pre_companies = {c["id"]: c for c in before["companies"]}
    for cid, c in pre_companies.items():
        now = live_companies.get(cid)
        if now is None:
            if folded_into(cid, folds) in live_companies:
                print(f"note: {c['name']!r} was since merged into {live_companies[folded_into(cid, folds)]['name']!r}")
            else:
                bad.append(f"company {c['name']!r} is gone")
            continue
        allowed = set(log["patches"].get(cid, {}).get("after", {}))
        diff = {k for k in c if k not in allowed and c.get(k) != now.get(k)}
        if diff:
            print(f"note: {c['name']!r} changed outside the import: {sorted(diff)}")
    for cid in log["companies"]:
        if cid not in live_companies:
            bad.append(f"created company {log['companies'][cid]!r} is gone")
    st = State({**before, "companies": list(live_companies.values()), "recruiters": live})
    violations, _ = verify(st)
    before_v, _ = verify(State(before))
    new_v = sorted(set(violations) - set(before_v))
    for v in new_v:
        bad.append(f"pipeline violation: {v}")
    print(f"sheet rows on file: {found}; problems: {len(bad)}")
    for b in bad[:50]:
        print("  !", b)
    sys.exit(1 if bad else 0)


# ----------------------------------------------------------------------------
# Company links: the sheet's company LinkedIn, X and Facebook pages, sealed
# into our vault's `company_links` (company_links.py).

LINK_COLUMNS = ("Company Linkedin", "Company Social", "Company Twitter")
LINKS_LOG = "links_applied.json"
X_NOT_AN_ACCOUNT = {"home", "share", "intent", "search", "hashtag", "i", "explore", "login", "signup",
                    "settings", "messages", "notifications"}
FACEBOOK_NOT_A_PAGE = {"sharer", "sharer.php", "share.php", "login", "login.php", "dialog", "plugins", "home.php",
                       "help", "policies", "watch", "events", "marketplace"}


def company_link(raw):
    """(field, link as stored) for a company's LinkedIn page, X account or
    Facebook page — told apart by host, whichever column it's in — or None.
    Twitter links become x.com ones; queries, tabs ("/about", "/jobs") and
    trailing slashes go."""
    text = (raw or "").strip()
    if not text:
        return None
    if "://" not in text:
        text = "https://" + text
    u = urllib.parse.urlsplit(text)
    host = (u.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    path = urllib.parse.unquote(u.path)
    if u.fragment.startswith("!/"):   # twitter.com/#!/acme
        path = u.fragment[1:]
    parts = [x for x in path.split("/") if x]

    def on(domain):
        return host == domain or host.endswith("." + domain)

    if on("linkedin.com"):
        if len(parts) >= 2 and parts[0] in ("company", "school", "showcase") and re.fullmatch(r"[\w.&'-]+", parts[1]):
            return "linkedin", f"https://www.linkedin.com/{parts[0]}/{parts[1].lower()}"
        return None
    if on("twitter.com") or on("x.com"):
        if parts and re.fullmatch(r"\w{1,15}", parts[0]) and parts[0].lower() not in X_NOT_AN_ACCOUNT:
            return "x", f"https://x.com/{parts[0]}"
        return None
    if on("facebook.com") or host == "fb.com":
        if not parts or parts[0].lower() in FACEBOOK_NOT_A_PAGE:
            return None
        if parts[0] == "profile.php":
            ids = urllib.parse.parse_qs(u.query).get("id", [])
            return ("facebook", f"https://www.facebook.com/profile.php?id={ids[0]}") \
                if ids and ids[0].isdigit() else None
        if parts[0] in ("pages", "people"):
            return ("facebook", "https://www.facebook.com/" + "/".join(parts)) if len(parts) >= 2 else None
        if re.fullmatch(r"[\w.-]+", parts[0]):
            return "facebook", f"https://www.facebook.com/{parts[0]}"
    return None


def sheet_companies():
    """Sheet company -> catalog id, from the reviewed people plan and the
    apply's log (the companies it created)."""
    p = json.loads((OUT / "plan.json").read_text())
    created = {name: cid for cid, name in json.loads((OUT / "applied.json").read_text())["companies"].items()}
    out = {}
    for sc, d in p["decisions"].items():
        cid = d.get("id")
        if cid and cid.startswith("new:"):
            cid = created.get(cid[4:])
        if cid:
            out[sc] = cid
    return out


def sheet_links(sheet, companies, names):
    """-> ({company id: {field: link}}, {company id: {field: why}}, problems).
    A company's link is the one most of its rows give; a tie needs
    hr_review.LINKS ({sheet company: {field: link or None}})."""
    fixed = review("LINKS", {})
    seen = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    spelling, rows_at, sheet_names = {}, collections.Counter(), collections.defaultdict(set)
    for r in sheet:
        cid = person_company(r) or companies.get(r["Company Name"])
        if not cid or cid not in names:
            continue
        rows_at[cid] += 1
        sheet_names[cid].add(r["Company Name"])
        found = {}
        for col in LINK_COLUMNS:
            got = company_link(r.get(col))
            if got and got[0] not in found:
                found[got[0]] = got[1]
        for field, link in found.items():
            seen[cid][field][link.lower()] += 1
            spelling.setdefault(link.lower(), link)
    links, why, problems = {}, {}, []
    for cid, fields in seen.items():
        for field, counts in fields.items():
            top = counts.most_common()
            decided = next((fixed[sc] for sc in sorted(sheet_names[cid]) if field in fixed.get(sc, {})), None)
            if decided is not None:
                choice = decided[field]
                if choice:
                    links.setdefault(cid, {})[field] = choice
                    why.setdefault(cid, {})[field] = "hr_review.LINKS"
                continue
            if len(top) > 1 and top[0][1] == top[1][1]:
                problems.append(f"{names.get(cid, cid)}: the sheet's rows split between "
                                f"{sorted(spelling[k] for k, n in top if n == top[0][1])} for {field}: "
                                "decide it in hr_review.LINKS")
                continue
            links.setdefault(cid, {})[field] = spelling[top[0][0]]
            why.setdefault(cid, {})[field] = f"{top[0][1]} of {rows_at[cid]} rows"
    return links, why, problems


def links_plan(csv_path, on_file=None, live_companies=None):
    """What each company gains: only the links it doesn't have yet."""
    sheet = read_sheet(csv_path)
    companies = sheet_companies()
    if live_companies is None:
        live_companies = {c["id"]: c["name"] for c in supabase.get_all("companies", order="id.asc", select="id,name")}
    if on_file is None:
        on_file = company_links.read_live()
    problems = [f"{sc!r} -> {cid}, which is no longer in the catalog (merged since?)"
                for sc, cid in sorted(companies.items()) if cid not in live_companies]
    companies = {sc: cid for sc, cid in companies.items() if cid in live_companies}
    links, why, more = sheet_links(sheet, companies, live_companies)
    problems += more
    fills, kept = {}, []
    for cid, wanted in sorted(links.items()):
        have = on_file.get(cid) or {}
        before = {f: have.get(f) for f in company_links.FIELDS}
        after = dict(before)
        for field, link in wanted.items():
            if not before.get(field):
                after[field] = link
            elif before[field].lower() != link.lower():
                kept.append(f"{live_companies[cid]}: keeps its {field} {before[field]} (the sheet has {link})")
        if after != before:
            fills[cid] = {"name": live_companies[cid], "row": have.get("id"),
                          "before": before if have else None, "after": after,
                          "why": {f: why[cid][f] for f in after if after[f] != before[f]}}
    return {"csv": str(csv_path), "fills": fills, "kept": kept, "problems": problems}


def write_links_plan(p):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "links_plan.json").write_text(json.dumps(p, indent=1, ensure_ascii=False))
    gained = collections.Counter(f for x in p["fills"].values() for f in x["after"] if x["after"][f] != (x["before"] or {}).get(f))
    lines = [f"{len(p['fills'])} companies gain links: " + ", ".join(f"{n} {f}" for f, n in sorted(gained.items())),
             f"{len(p['kept'])} keep a different link already on file", f"{len(p['problems'])} problems", ""]
    lines += ["PROBLEMS"] + [f"  {x}" for x in p["problems"]] + ["", "KEPT"] + [f"  {x}" for x in p["kept"]]
    lines += ["", "FILLS"] + [f"  {x['name']}: " + ", ".join(f"{f} {x['after'][f]} ({x['why'][f]})" for f in x["why"])
                             for x in sorted(p["fills"].values(), key=lambda x: x["name"].lower())]
    (OUT / "links_report.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:3]))
    print(f"-> {OUT / 'links_plan.json'}, {OUT / 'links_report.txt'}")


def links_apply(csv_path):
    reviewed = json.loads((OUT / "links_plan.json").read_text())
    if reviewed["problems"]:
        sys.exit("the reviewed links plan has problems: settle them in hr_review.LINKS and re-plan")
    if not company_links.exists():
        sys.exit("company_links doesn't exist yet: run scripts/company_links_migration.sql first")
    logf = OUT / LINKS_LOG
    if logf.exists():
        sys.exit(f"{logf} exists: an earlier apply's log. Roll it back or move it aside first")
    snap = backup_mod.backup(label="-pre-hr-links")
    fresh = links_plan(csv_path)
    if fresh["fills"] != reviewed["fills"]:
        sys.exit("the links on file changed since the plan was reviewed: re-run `links plan` and review it again")
    log = {"pre_backup": str(snap), "saved": {}}
    for cid, x in fresh["fills"].items():
        got = company_links.save(cid, x["after"], row_id=x["row"])
        assert len(got) == 1, f"{x['name']}: wrote {len(got)} rows"
        log["saved"][cid] = {"row": got[0]["id"], "before": x["before"]}
        logf.write_text(json.dumps(log, indent=1, ensure_ascii=False))
    log["post_backup"] = str(backup_mod.backup(label="-post-hr-links"))
    logf.write_text(json.dumps(log, indent=1, ensure_ascii=False))
    print(f"saved links for {len(log['saved'])} companies")


def links_rollback():
    logf = OUT / LINKS_LOG
    log = json.loads(logf.read_text())
    for cid, x in log["saved"].items():
        if x["before"] is None:
            supabase.write("DELETE", company_links.TABLE, {"id": f"eq.{x['row']}"}, prefer="return=minimal")
        else:
            company_links.save(cid, x["before"], row_id=x["row"])
    logf.rename(logf.with_name("links_rolled_back.json"))
    print("rolled back")


def links_check(csv_path):
    """Independent of the plan: every company the sheet gives a link for
    holds it, unless it already held a different one before the apply, and
    no other company's links changed."""
    log = json.loads((OUT / LINKS_LOG).read_text())
    # A company merged since takes its links into the one it went into, which
    # keeps its own where both have one (company_links.move).
    folds, _ = later_changes(log["pre_backup"])
    before = {}
    for cid, links in sorted(company_links.open_backup(log["pre_backup"]).items(), key=lambda x: x[0] in folds):
        into = before.setdefault(folded_into(cid, folds), {})
        for f in company_links.FIELDS:
            into[f] = into.get(f) or links.get(f)
    live = company_links.read_live()
    names = {c["id"]: c["name"] for c in supabase.get_all("companies", order="id.asc", select="id,name")}
    companies = {sc: folded_into(cid, folds) for sc, cid in sheet_companies().items()}
    companies = {sc: cid for sc, cid in companies.items() if cid in names}
    wanted, _, problems = sheet_links(read_sheet(csv_path), companies, names)
    bad = list(problems)
    for cid in sorted(set(wanted) | set(before) | set(live)):
        was = {f: (before.get(cid) or {}).get(f) for f in company_links.FIELDS}
        now = {f: (live.get(cid) or {}).get(f) for f in company_links.FIELDS}
        for f in company_links.FIELDS:
            expect = was[f] or (wanted.get(cid) or {}).get(f)
            if now[f] != expect:
                bad.append(f"{names.get(cid, cid)}: {f} is {now[f]!r}, expected {expect!r}")
            if now[f] and now[f] != was[f] and company_link(now[f]) != (f, now[f]):
                bad.append(f"{names.get(cid, cid)}: {f} {now[f]!r} isn't a tidy {f} link")
    print(f"{sum(1 for c in live if any(live[c].get(f) for f in company_links.FIELDS))} companies hold links; "
          f"{len(bad)} problems")
    for x in bad:
        print("  " + x)
    if bad:
        sys.exit(1)


def links(args):
    sub = args[0] if args else ""
    if sub == "plan":
        write_links_plan(links_plan(args[1]))
    elif sub == "apply":
        links_apply(args[1])
    elif sub == "verify":
        links_check(args[1])
    elif sub == "rollback":
        links_rollback()
    else:
        sys.exit(__doc__)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    if R is None and cmd in ("plan", "apply", "verify", "refile", "links"):
        sys.exit(f"needs {OUT / 'hr_review.py'} (the judgement calls)")
    if cmd == "plan":
        rest = [a for a in args[2:] if not a.startswith("--")]
        snap = rest[0] if rest else max(str(p) for p in (REPO / "db_backups").iterdir() if p.is_dir())
        write_plan(plan(args[1], snap, companies_only="--companies-only" in args))
    elif cmd == "apply":
        apply(args[1])
    elif cmd == "verify":
        check(args[1])
    elif cmd == "rollback":
        rollback()
    elif cmd == "refile":
        refile()
    elif cmd == "links":
        links(args[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
