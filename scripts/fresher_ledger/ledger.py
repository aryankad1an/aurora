"""Load the Fresher Hiring Ledger and the catalog, and match one to the other.

The ledger (companies.json from the Fresher Hiring Ledger artifact) is the
source of truth for which companies hire freshers, how, and what they pay. Each
ledger company is matched to at most one catalog company:

1. By website: the registrable domain of the ledger's `website` is one a
   catalog company lists in `domains`. The verification pass guarantees a
   domain has exactly one owner, so this is the strongest match.
2. By contacts: the domain is one that the contacts of exactly one company use.
3. By name: the names agree once case, punctuation and legal suffixes are gone,
   and the catalog company doesn't list a different domain of its own.
4. By a verified rule in `decisions.json` (`same`), for a company the catalog
   files under another domain or name (Heinz is Kraft Heinz at hjheinz.com).

`decisions.json` can also keep two apart (`distinct`) when a name or domain
matches but the companies differ. Anything ambiguous is reported, never guessed.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "company_verification"))
from domains import clean, is_personal, registrable  # noqa: E402

DECISIONS = json.loads((HERE / "decisions.json").read_text())

# Legal and generic words that don't tell two companies apart.
_SUFFIXES = re.compile(
    r"\b(private|pvt|limited|ltd|inc|llc|llp|plc|corp|corporation|co|company|"
    r"technologies|technology|tech|software|solutions|services|systems|labs|"
    r"group|india|global|the)\b")


def norm(name: str) -> str:
    n = (name or "").lower().replace("&", " and ")
    n = re.sub(r"\(.*?\)", " ", n)
    n = re.sub(r"[^a-z0-9 ]", " ", n)
    n = _SUFFIXES.sub(" ", n)
    return re.sub(r"\s+", "", n)


def site_domain(url):
    """The registrable domain of a website URL, or None."""
    if not url:
        return None
    host = urlparse(url if "//" in url else "//" + url).hostname or ""
    d = clean(host)
    return registrable(d) if d else None


def load_ledger(path):
    data = json.loads(Path(path).read_text())
    companies = data["companies"]
    ids = [c["id"] for c in companies]
    if len(set(ids)) != len(ids):
        raise SystemExit("ledger ids aren't unique")
    return data, companies


def match(ledger, companies, recruiters):
    """Map each ledger company id to a catalog company id (or None).

    Returns (matches, report) where matches is {ledger_id: (company_id|None, how)}
    and report lists everything a person should look at.
    """
    by_id = {c["id"]: c for c in companies}
    by_name = {c["name"]: c for c in companies}
    owner = defaultdict(set)          # registrable domain -> company ids listing it
    for c in companies:
        for d in c.get("domains") or []:
            owner[registrable(d)].add(c["id"])
    users = defaultdict(set)          # registrable domain -> company ids whose contacts use it
    for r in recruiters:
        email = (r.get("email") or "").lower()
        if "@" in email and r.get("company_id") in by_id:
            d = clean(email.split("@", 1)[1])
            if d and not is_personal(d):
                users[registrable(d)].add(r["company_id"])
    names = defaultdict(set)
    for c in companies:
        names[norm(c["name"])].add(c["id"])

    same = {k: v for k, v in DECISIONS["same"].items() if not k.startswith("_")}
    distinct = {tuple(p[:2]) for p in DECISIONS["distinct"]}
    report = defaultdict(list)
    matches = {}

    for lc in ledger:
        lid, dom = lc["id"], site_domain(lc.get("website"))
        if lc["name"] in same:
            target = by_name.get(same[lc["name"]])
            if not target:
                raise SystemExit(f"decisions.same: no catalog company named {same[lc['name']]!r}")
            matches[lid] = (target["id"], "decision")
            continue

        def ok(cid):
            return (lc["name"], by_id[cid]["name"]) not in distinct

        found = None
        for how, pool in (("website", owner), ("contacts", users)):
            ids = {i for i in pool.get(dom, set()) if ok(i)} if dom else set()
            if len(ids) == 1:
                found = (next(iter(ids)), how)
                break
            if len(ids) > 1:
                report["ambiguous"].append((lc["name"], dom, how, sorted(by_id[i]["name"] for i in ids)))
                break
        if not found:
            ids = {i for i in names.get(norm(lc["name"]), set()) if ok(i)}
            if len(ids) == 1:
                cid = next(iter(ids))
                own = {registrable(d) for d in by_id[cid].get("domains") or []}
                if own and dom and dom not in own:
                    # Same name, different domain: two companies, or a rebrand.
                    # Either way a person decides.
                    report["name_but_other_domain"].append((lc["name"], dom, by_id[cid]["name"], sorted(own)))
                else:
                    found = (cid, "name")
            elif len(ids) > 1:
                report["ambiguous"].append((lc["name"], dom, "name", sorted(by_id[i]["name"] for i in ids)))
        matches[lid] = found or (None, "new")

    # Several ledger companies landing on one catalog company is expected (L&T,
    # L&T Energy and L&T PES all mail from larsentoubro.com), but listed so it
    # can be checked.
    landed = defaultdict(list)
    for lc in ledger:
        cid = matches[lc["id"]][0]
        if cid:
            landed[cid].append(lc["name"])
    for cid, names_ in landed.items():
        if len(names_) > 1:
            report["shared_target"].append((by_id[cid]["name"], names_))
    return matches, report
