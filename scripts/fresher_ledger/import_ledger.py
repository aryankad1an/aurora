"""Load the Fresher Hiring Ledger into the catalog.

    python3 import_ledger.py <companies.json> <vetted.json>            # dry run
    python3 import_ledger.py <companies.json> <vetted.json> --apply    # back up, write, re-verify

<vetted.json> is the crawl after logo_paths.py's logos are merged in and
vet_logos.py has dropped the ones that aren't a company's own.

Needs migration.sql to have been run. Outputs go to data_verification/fresher_ledger/
(git-ignored): plan.json and report.md.

What it writes:

* Every ledger company is matched to a catalog company (see ledger.py) or
  created. Matched and created ones are flagged `is_fresher`, and get the
  ledger's website, careers page, type, hiring routes, months, batches and roles.
  Several ledger companies can land on one catalog company (L&T, L&T Energy and
  L&T PES all mail from larsentoubro.com); their routes, batches and roles are
  combined, and the details come from the one whose name or domain is the
  company's own.
* Each piece of ledger evidence becomes a `company_sources` row. Rows are keyed
  by a fingerprint, so a re-import updates them in place and never touches
  `is_valid`: a source someone marked invalid stays invalid. Imported rows that
  have left the ledger are removed.
* Logos come from crawl.json: a PNG the company's own site offers as its icon.
* Catalog companies the ledger doesn't cover get the website and careers page
  their mail domain's homepage gives, when it's a real site (see crawl.py), and
  never over a value already there.
* A field someone edited in the app (`*_source = 'edited'`) is left alone.
* Catalog names built from a domain ("Wbd", "Sc", "Amat") take the ledger's name
  when exactly one ledger company maps there.
"""
import concurrent.futures
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "company_verification"))
sys.path.insert(0, str(HERE))
import contacts  # noqa: E402
import supabase  # noqa: E402
from backup import backup  # noqa: E402
from domains import brand, registrable  # noqa: E402
from ledger import load_ledger, match, norm, site_domain  # noqa: E402

REPO = HERE.parents[1]
OUT = REPO / "data_verification" / "fresher_ledger"
STRENGTH = {"off_campus": 3, "route_unclear": 2, "on_campus_or_intern_only": 1}
EDITED = "edited"


def fingerprint(lid, e):
    key = "|".join(str(e.get(k) or "") for k in ("route_code", "url", "role", "date", "location", "batch", "source_code"))
    return hashlib.sha1(f"{lid}|{key}".encode()).hexdigest()[:20]


def source_row(lid, e):
    return {
        "ledger_id": lid,
        "route": e["route"],
        "role": e.get("role"),
        "location": e.get("location"),
        "batch": e.get("batch"),
        "source_code": e.get("source_code"),
        "source_label": e.get("source"),
        "url": e.get("url"),
        "proof_url": e.get("proof_url") if e.get("proof_url") != e.get("url") else None,
        "posted_on": e.get("date"),
        "confidence": e.get("confidence"),
        "open_now": bool(e.get("open_now")),
        "package_lpa": e.get("package_lpa"),
        "package_text": e.get("package_text"),
        "fingerprint": fingerprint(lid, e),
    }


def https(url):
    return url.replace("http://", "https://", 1) if url else url


def origin(url):
    m = re.match(r"(https?://[^/?#]+)", url or "")
    return https(m.group(1)) if m else None


# A university's "careers" link is usually its student career service, not jobs.
NOT_JOBS = re.compile(r"career[-_ ]?(preparation|services?|cent(er|re)|development|counsel|guidance|fair)|"
                      r"placement|alumni|students?/", re.I)


def careers_from(row):
    url = (row or {}).get("careers")
    return https(url) if url and not NOT_JOBS.search(url) else None


def accepted_site(row):
    """The website a catalog company's mail-domain homepage gives, or None."""
    if not row or row.get("status") != 200 or row.get("parked") or not row.get("final_url"):
        return None
    if row.get("stays_on_domain") or row.get("title_names_company"):
        return origin(row["final_url"])
    return None


RENAMES = {k: v for k, v in json.loads((HERE / "decisions.json").read_text())["renames"].items()
           if not k.startswith("_")}


def compact(name):
    return re.sub(r"[^a-z0-9]", "", re.sub(r"\(.*?\)", "", name.lower()))


def proper_name(company, ledger_name):
    """The name a domain-made catalog name ("Arcticwolf") should have, or None.

    By hand (decisions.json `renames`) for acronyms and casing; otherwise only
    when the ledger's name is the same letters with spaces or punctuation the
    catalog's lacks ("Arctic Wolf"). A one-word name that is simply a real name
    ("Micron", "Samsung") is never swapped for a longer one.
    """
    name = company["name"]
    if name in RENAMES:
        return RENAMES[name]
    if " " in name or not any(brand(d) == name.lower() for d in company.get("domains") or []):
        return None
    if compact(ledger_name) == compact(name) and ledger_name.lower() != name.lower():
        return ledger_name
    return None


def plan(ledger, companies, recruiters, crawl):
    by_id = {c["id"]: c for c in companies}
    matches, report = match(ledger, companies, recruiters)
    led = {c["id"]: c for c in ledger}
    crawled = {r["key"]: r for r in crawl}

    groups = defaultdict(list)          # catalog id -> ledger companies
    creates = []
    for lc in ledger:
        cid, how = matches[lc["id"]]
        (groups[cid].append(lc) if cid else creates.append(lc))

    def fresher_fields(entries, company=None):
        own = {registrable(d) for d in (company or {}).get("domains") or []}
        cname = norm(company["name"]) if company else None

        def rank(lc):
            return (norm(lc["name"]) == cname, site_domain(lc["website"]) in own, len(lc["evidence"]))
        primary = max(entries, key=rank)
        logo = (crawled.get("ledger:" + primary["id"]) or {}).get("logo")
        if not logo:  # a subsidiary's site can stand in for the parent's
            logo = next((crawled["ledger:" + e["id"]]["logo"] for e in entries
                         if (crawled.get("ledger:" + e["id"]) or {}).get("logo")), None)
        careers, careers_source = primary.get("careers_url"), "ledger"
        if not careers:
            careers = careers_from(crawled.get("ledger:" + primary["id"]))
            careers_source = "website" if careers else None
        cats = [e["route_category"] for e in entries]
        return {
            "is_fresher": True,
            "ledger_ids": sorted(e["id"] for e in entries),
            "website": https(primary["website"]),
            "website_source": primary.get("website_source") or "ledger",
            "careers_url": https(careers),
            "careers_source": careers_source,
            "logo_url": logo["url"] if logo else None,
            "company_type": primary.get("type"),
            "route_category": max(cats, key=STRENGTH.get),
            "hiring_routes": sorted({r for e in entries for r in e.get("routes") or []}),
            "open_now": any(e.get("open_now") for e in entries),
            "usually_opens": primary.get("usually_opens"),
            "batches": sorted({b for e in entries for b in e.get("batches") or []}),
            "fresher_roles": list(dict.fromkeys(r for e in [primary] + entries for r in e.get("roles") or []))[:6],
        }

    updates, renames = {}, {}
    taken = {c["name"].lower() for c in companies}
    for cid, entries in groups.items():
        company = by_id[cid]
        fields = fresher_fields(entries, company)
        updates[cid] = respect_edits(company, fields)
        new = proper_name(company, entries[0]["name"]) if len(entries) == 1 or company["name"] in RENAMES else None
        if new and new != company["name"]:
            if new.lower() in taken and new.lower() != company["name"].lower():
                raise SystemExit(f"can't rename {company['name']!r} to {new!r}: the name is taken")
            renames[cid] = new
            taken.add(new.lower())

    new_rows = []
    for lc in creates:
        if lc["name"].lower() in taken:
            raise SystemExit(f"can't create {lc['name']!r}: the name is taken")
        taken.add(lc["name"].lower())
        new_rows.append({"name": lc["name"], **fresher_fields([lc])})

    # Catalog companies the ledger doesn't cover: links and logo from their own site.
    enrich = {}
    for c in companies:
        if c["id"] in groups:
            continue
        row = crawled.get("co:" + c["id"])
        site = accepted_site(row)
        if not site:
            continue
        fields = {"website": site, "website_source": "mail_domain"}
        if careers_from(row):
            fields.update(careers_url=careers_from(row), careers_source="website")
        if row.get("logo"):
            fields["logo_url"] = row["logo"]["url"]
        fields = {k: v for k, v in respect_edits(c, fields).items() if not c.get(k)}
        # A logo vet_logos.py ruled out (a platform's default icon, a
        # placeholder) comes off a company that already has it.
        if row.get("rejected_logo") and c.get("logo_url") == row["rejected_logo"] \
                and c.get("website_source") != EDITED:
            fields["logo_url"] = None
        if fields:
            enrich[c["id"]] = fields

    sources = defaultdict(dict)        # catalog id or "new:<ledger id>" -> fingerprint -> row
    for lc in ledger:
        cid = matches[lc["id"]][0] or "new:" + lc["id"]
        for e in lc["evidence"]:
            row = source_row(lc["id"], e)
            sources[cid].setdefault(row["fingerprint"], row)
    return {
        "matches": matches, "report": report, "updates": updates, "renames": renames,
        "creates": new_rows, "enrich": enrich, "sources": sources,
        "groups": {cid: [e["name"] for e in es] for cid, es in groups.items()},
    }


def respect_edits(company, fields):
    """Leave alone what someone set by hand in the app."""
    fields = dict(fields)
    for k in ("website", "careers_url"):
        src = k.replace("_url", "") + "_source"
        if company.get(src) == EDITED:
            fields.pop(k, None)
            fields.pop(src, None)
    if company.get("logo_url") and company.get("website_source") == EDITED:
        fields.pop("logo_url", None)
    return fields


def write_report(p, by_id, ledger):
    OUT.mkdir(parents=True, exist_ok=True)
    serial = {k: v for k, v in p.items() if k != "sources"}
    serial["sources"] = {k: list(v.values()) for k, v in p["sources"].items()}
    (OUT / "plan.json").write_text(json.dumps(serial, indent=1, ensure_ascii=False, default=list))
    how = Counter(h for _, h in p["matches"].values())
    n_sources = sum(len(v) for v in p["sources"].values())
    lines = [
        "# Fresher Hiring Ledger import", "",
        f"- ledger companies: {len(ledger)} — matched {sum(v for k, v in how.items() if k != 'new')} "
        f"({', '.join(f'{k} {v}' for k, v in sorted(how.items()) if k != 'new')}), new {how['new']}",
        f"- catalog companies flagged: {len(p['updates'])}; created: {len(p['creates'])}",
        f"- sources: {n_sources}",
        f"- logos: {sum(1 for f in p['updates'].values() if f.get('logo_url'))} on matched, "
        f"{sum(1 for f in p['creates'] if f.get('logo_url'))} on new, "
        f"{sum(1 for f in p['enrich'].values() if f.get('logo_url'))} on other companies",
        f"- careers pages: {sum(1 for f in list(p['updates'].values()) + p['creates'] if f.get('careers_url'))} "
        f"on fresher companies, {sum(1 for f in p['enrich'].values() if f.get('careers_url'))} on others",
        f"- websites on other companies (from their mail domain): {sum(1 for f in p['enrich'].values() if f.get('website'))}",
        f"- renames: {len(p['renames'])}", "",
        "## Renamed (domain-made names)", "",
        *[f"- {by_id[c]['name']} → {n}" for c, n in sorted(p["renames"].items(), key=lambda x: x[1])],
        "", "## Several ledger companies on one catalog company", "",
        *[f"- {by_id[c]['name']}: {', '.join(n)}" for c, n in p["groups"].items() if len(n) > 1],
        "", "## Matched (ledger → catalog, how)", "",
    ]
    led = {c["id"]: c for c in ledger}
    for lid, (cid, h) in sorted(p["matches"].items(), key=lambda x: led[x[0]]["name"].lower()):
        if cid:
            lines.append(f"- {led[lid]['name']} → {by_id[cid]['name']} ({h})")
    lines += ["", "## Created", ""] + [f"- {r['name']} ({r['website']})" for r in p["creates"]]
    (OUT / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:12]))
    print(f"report -> {OUT / 'report.md'}")


def chunks(xs, n):
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def apply(p, by_id):
    backup(label="-before-ledger-import")

    def patch(item):
        cid, body = item
        got = supabase.write("PATCH", "companies", {"id": f"eq.{cid}"}, body)
        assert len(got) == 1, f"no company {cid}"

    bodies = defaultdict(dict)
    for cid, f in p["updates"].items():
        bodies[cid].update(f)
    for cid, f in p["enrich"].items():
        bodies[cid].update(f)
    for cid, name in p["renames"].items():
        bodies[cid]["name"] = name
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        list(pool.map(patch, bodies.items()))
    print(f"  updated {len(bodies)} companies ({len(p['renames'])} renamed)")

    new_ids = {}
    for part in chunks(p["creates"], 100):
        rows = supabase.write("POST", "companies", body=part)
        assert len(rows) == len(part)
        for body, row in zip(part, rows):
            new_ids["new:" + body["ledger_ids"][0]] = row["id"]
    print(f"  created {len(new_ids)} companies")

    # A source edited in the app keeps its edit: it's left out of the upsert,
    # and kept rather than removed as stale.
    edited = {(r["company_id"], r["fingerprint"]) for r in supabase.get_all(
        "company_sources", select="company_id,fingerprint", filters={"edited_at": "not.is.null"})}
    all_rows, keep = [], defaultdict(set)
    for key, rows in p["sources"].items():
        cid = new_ids.get(key, key)
        for row in rows.values():
            keep[cid].add(row["fingerprint"])
            if (cid, row["fingerprint"]) not in edited:
                all_rows.append({**row, "company_id": cid})
    for cid, fp in edited:
        keep[cid].add(fp)
    for part in chunks(all_rows, 500):
        supabase.write("POST", "company_sources?on_conflict=company_id,fingerprint", body=part,
                       prefer="return=minimal,resolution=merge-duplicates")
    print(f"  upserted {len(all_rows)} sources")

    # Imported sources no longer in the ledger.
    existing = supabase.get_all("company_sources", select="id,company_id,fingerprint",
                                filters={"fingerprint": "not.is.null"})
    stale = [r["id"] for r in existing if r["fingerprint"] not in keep.get(r["company_id"], set())]
    for part in chunks(stale, 100):
        supabase.write("DELETE", "company_sources", {"id": supabase.in_filter(part)}, prefer="return=minimal")
    print(f"  removed {len(stale)} sources that left the ledger")
    return new_ids


def verify(ledger, p):
    """Re-read the catalog and check every ledger company landed."""
    companies = supabase.get_all("companies", select="id,name,is_fresher,ledger_ids,website,careers_url,logo_url")
    sources = supabase.get_all("company_sources", select="id,company_id,fingerprint,ledger_id")
    by_ledger = {}
    for c in companies:
        for lid in c.get("ledger_ids") or []:
            if lid in by_ledger:
                raise SystemExit(f"ledger id {lid} is on two companies")
            by_ledger[lid] = c
    problems = []
    for lc in ledger:
        c = by_ledger.get(lc["id"])
        if not c:
            problems.append(f"{lc['name']}: not in the catalog")
        elif not c["is_fresher"]:
            problems.append(f"{lc['name']}: not flagged")
    want = sum(len(v) for v in p["sources"].values())
    have = sum(1 for s in sources if s["fingerprint"])
    if have != want:
        problems.append(f"sources: {have} imported rows, expected {want}")
    by_company = Counter(s["company_id"] for s in sources if s["fingerprint"])
    for lc in ledger:
        c = by_ledger.get(lc["id"])
        if c and not by_company.get(c["id"]):
            problems.append(f"{lc['name']}: no sources")
    flagged = sum(1 for c in companies if c.get("is_fresher"))
    print(f"verify: {len(by_ledger)} ledger ids on {flagged} flagged companies, {have} sources, "
          f"{sum(1 for c in companies if c.get('logo_url'))} logos, "
          f"{sum(1 for c in companies if c.get('website'))} websites, "
          f"{sum(1 for c in companies if c.get('careers_url'))} careers pages")
    for x in problems[:50]:
        print("  PROBLEM", x)
    return not problems


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    _, ledger = load_ledger(args[0])
    crawl = json.loads(Path(args[1]).read_text())
    companies = supabase.get_all("companies")
    recruiters = contacts.read_live(select="id,company_id,email")  # addresses are sealed once the DB has vaults
    if "--apply" in sys.argv and companies and "is_fresher" not in companies[0]:
        raise SystemExit("run migration.sql first: companies has no is_fresher column")
    by_id = {c["id"]: c for c in companies}
    p = plan(ledger, companies, recruiters, crawl)
    write_report(p, by_id, ledger)
    if "--apply" in sys.argv:
        apply(p, by_id)
        if not verify(ledger, p):
            raise SystemExit("verification found problems")
        print("verified")


if __name__ == "__main__":
    main()
