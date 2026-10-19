"""Fill in missing company websites and careers pages, 50 companies at a time.

    python3 fill_links.py queue                 # who's missing what, in work order
    python3 fill_links.py probe <batch>         # check 1: fetch and test candidates
    python3 fill_links.py apply <batch>         # write the reviewed answers, re-read them

Work lives in data_verification/links/ (git-ignored):

* queue.json — every company missing a website or careers page, the user's
  tracked companies first, then by number of contacts. Batch k is
  queue[50k : 50k+50]. Companies whose links were edited in the app are left out.
* batch_<k>.json — what `probe` found for each company: the candidates and the
  evidence for them (status, final URL, page title, careers words on the page).
* review_<k>.json — the second check, written by hand after reading the probe and
  opening every doubtful page in a browser: {company id: {"website", "careers",
  "note"}}. A null means "leave empty"; a missing key means "no change".
* applied_<k>.json — the rows before and after the write, for rollback.

`apply` only fills fields that are still empty in the live catalog, never one
edited in the app, and re-reads every row afterwards to prove it landed.
Sources are written as `verified_lookup`.
"""
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

from bs4 import BeautifulSoup

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "company_verification"))
import supabase  # noqa: E402
import crawl  # noqa: E402
from crawl import ATS_HOSTS, PARKED, fetch, host_of, reg_of, words  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / "data_verification" / "links"
BATCH = 50
USER = "realaryankadian@gmail.com"
SOURCE = "verified_lookup"

crawl.HEADERS["User-Agent"] = crawl.DESKTOP_UA
BLOCKED = re.compile(r"just a moment|attention required|access denied|request rejected|"
                     r"are you a robot|captcha|forbidden|cloudflare", re.I)
JOB_WORDS = re.compile(r"\b(careers?|jobs?|openings?|vacanc(y|ies)|positions?|join (us|our)|"
                       r"apply|hiring|life at|work with us)\b", re.I)
CAREER_PATHS = ("/careers", "/careers/", "/career", "/jobs", "/join-us", "/company/careers",
                "/about/careers", "/about-us/careers", "/en/careers", "/work-with-us")


def queue():
    rows = supabase.get_all("companies", select="id,name,domains,website,website_source,"
                                                "careers_url,careers_source,is_fresher")
    recs = supabase.get_all("recruiters", select="company_id")
    tracked = {r["company_id"] for r in supabase.get("tracked_companies",
                                                     {"user_email": "eq." + USER}, "company_id")}
    contacts = {}
    for r in recs:
        contacts[r["company_id"]] = contacts.get(r["company_id"], 0) + 1
    todo = []
    for c in rows:
        need_w = not c["website"] and c["website_source"] != "edited"
        need_c = not c["careers_url"] and c["careers_source"] != "edited"
        if need_w or need_c:
            todo.append({**c, "need_website": need_w, "need_careers": need_c,
                         "contacts": contacts.get(c["id"], 0), "tracked": c["id"] in tracked})
    todo.sort(key=lambda c: (not c["tracked"], -c["contacts"], c["name"].lower()))
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "queue.json").write_text(json.dumps(todo, indent=1))
    print(f"{len(todo)} companies to fill: {sum(c['need_website'] for c in todo)} websites, "
          f"{sum(c['need_careers'] for c in todo)} careers pages, "
          f"{-(-len(todo) // BATCH)} batches of {BATCH}")


def page(url):
    """What a URL serves: status, final URL, title, and the parsed page."""
    r, body = fetch(url, crawl.MAX_PAGE, accept="text/html,application/xhtml+xml")
    if r is None:
        return {"url": url, "status": "unreachable"}, None
    try:
        soup = BeautifulSoup(body or b"", "html.parser")
    except Exception:
        soup = None
    title = " ".join((soup.title.get_text(" ", strip=True) if soup and soup.title else "").split())[:160]
    text = soup.get_text(" ", strip=True)[:40000] if soup else ""
    info = {"url": url, "status": r.status_code, "final": r.url, "title": title,
            "blocked": r.status_code in (401, 403, 429, 503) or bool(BLOCKED.search(title)),
            "parked": bool(PARKED.search(title + " " + text[:5000]))}
    return info, (soup, text)


def probe_website(c):
    if c["website"]:
        info, parsed = page(c["website"])
        return {**info, "candidate": c["website"], "kind": "existing"}, parsed
    tried = []
    for d in c["domains"] or []:
        d = crawl.clean(d)
        reg = crawl.registrable(d) if d else None
        if not reg:
            continue
        for url in (f"https://{reg}", f"https://www.{reg}"):
            info, parsed = page(url)
            info["stays"] = reg_of(info.get("final", "")) == reg
            info["named"] = any(w in (info.get("title") or "").lower() for w in words(c["name"]))
            tried.append(info)
            if info["status"] == 200 and not info["parked"] and (info["stays"] or info["named"]):
                return {**info, "candidate": f"https://{host_of(info['final'])}/", "kind": "domain",
                        "tried": tried}, parsed
    return {"candidate": None, "tried": tried}, None


def careers_check(url, own):
    info, parsed = page(url)
    final = info.get("final") or ""
    host = host_of(final)
    on_ats = any(host == h or host.endswith("." + h) for h in ATS_HOSTS)
    hits = sorted({m.group(0).lower() for m in JOB_WORDS.finditer(parsed[1][:20000])}) if parsed else []
    info.update(on_own=reg_of(final) == own, on_ats=on_ats, job_words=hits[:8],
                homepage=urlparse(final).path in ("", "/") and not host.startswith(("careers.", "jobs.")))
    info["ok"] = (info["status"] == 200 and (info["on_own"] or on_ats) and not info["homepage"]
                  and not info["parked"] and len(hits) >= 2)
    return info


def greenhouse(c, own):
    slugs = {re.sub(r"[^a-z0-9]", "", (own or "").split(".")[0])}
    slugs.add("".join(words(c["name"])))
    for slug in filter(None, slugs):
        r, body = fetch(f"https://boards-api.greenhouse.io/v1/boards/{slug}", 200_000)
        if r is not None and r.status_code == 200:
            try:
                name = json.loads(body).get("name") or ""
            except Exception:
                continue
            if any(w in name.lower() for w in words(c["name"])):
                return {"url": f"https://job-boards.greenhouse.io/{slug}", "board_name": name}
    return None


def probe_one(c):
    out = {"id": c["id"], "name": c["name"], "domains": c["domains"],
           "need_website": c["need_website"], "need_careers": c["need_careers"]}
    site, parsed = probe_website(c)
    out["website"] = site
    if not c["need_careers"] or not site.get("candidate") or site.get("status") != 200:
        return out
    final = site.get("final") or site["candidate"]
    own = reg_of(final)
    cands = []
    if parsed and parsed[0]:
        link = crawl.find_careers(parsed[0], final, own)
        if link:
            cands.append(("homepage link", link))
    root = f"https://{host_of(final)}"
    cands += [("path", root + p) for p in CAREER_PATHS]
    cands += [("subdomain", f"https://{s}.{own}/") for s in ("careers", "jobs")]
    checks = []
    for how, url in cands:
        info = careers_check(url, own)
        info["how"] = how
        checks.append(info)
        if info["ok"]:
            break
    out["careers_checks"] = checks
    found = next((x for x in checks if x["ok"]), None)
    if not found:
        gh = greenhouse(c, own)
        if gh:
            found = {**careers_check(gh["url"], own), "how": "greenhouse", **gh}
    out["careers"] = found["final"] if found else None
    return out


def probe(k):
    todo = json.loads((WORK / "queue.json").read_text())[k * BATCH:(k + 1) * BATCH]
    with ThreadPoolExecutor(12) as pool:
        rows = list(pool.map(probe_one, todo))
    (WORK / f"batch_{k}.json").write_text(json.dumps(rows, indent=1))
    for i, r in enumerate(rows):
        w = r["website"]
        print(f"{k * BATCH + i:4} {r['name'][:28]:28} "
              f"W{'*' if r['need_website'] else ' '} {(w.get('candidate') or '-')[:40]:40} "
              f"[{w.get('status', '-')}{' blocked' if w.get('blocked') else ''}] "
              f"{(w.get('title') or '')[:30]:30} "
              f"C{'*' if r['need_careers'] else ' '} {r.get('careers') or '-'}")


def check(k):
    """Live-test every URL in review_<k>.json: the page answers, isn't parked or a
    homepage, and (for careers) talks about jobs. Prints one line per URL."""
    review = json.loads((WORK / f"review_{k}.json").read_text())
    names = {r["id"]: r["name"] for r in json.loads((WORK / f"batch_{k}.json").read_text())}
    jobs = [(cid, f, u) for cid, a in review.items() for f in ("website", "careers") if (u := a.get(f))]

    def run(job):
        cid, f, u = job
        if f == "website":
            info, _ = page(u)
            info["ok"] = info["status"] == 200 and not info["parked"]
        else:
            own = reg_of(review[cid].get("website") or u)
            info = careers_check(u, own)
        return cid, f, u, info
    with ThreadPoolExecutor(12) as pool:
        for cid, f, u, i in pool.map(run, jobs):
            flag = "OK " if i.get("ok") else ("BLK" if i.get("blocked") else "?? ")
            print(f"{flag} {names.get(cid, cid)[:24]:24} {f[:4]} {u[:60]:60} [{i.get('status')}] "
                  f"-> {(i.get('final') or '')[:50]} | {(i.get('title') or '')[:40]} {i.get('job_words', '')}")


def apply(k):
    review = json.loads((WORK / f"review_{k}.json").read_text())
    ids = list(review)
    before = {r["id"]: r for r in supabase.get(
        "companies", {"id": supabase.in_filter(ids)},
        "id,name,website,website_source,careers_url,careers_source")}
    log, skipped = [], []
    for cid, ans in review.items():
        row = before[cid]
        body = {}
        if ans.get("website") and not row["website"] and row["website_source"] != "edited":
            body.update(website=ans["website"], website_source=SOURCE)
        if ans.get("careers") and not row["careers_url"] and row["careers_source"] != "edited":
            body.update(careers_url=ans["careers"], careers_source=SOURCE)
        if not body:
            skipped.append(row["name"])
            continue
        after = supabase.write("PATCH", "companies", {"id": "eq." + cid}, body)
        log.append({"id": cid, "before": row, "set": body, "after": after})
    (WORK / f"applied_{k}.json").write_text(json.dumps(log, indent=1))
    # Re-read every row we wrote and compare.
    now = {r["id"]: r for r in supabase.get(
        "companies", {"id": supabase.in_filter([e["id"] for e in log])},
        "id,website,website_source,careers_url,careers_source")} if log else {}
    bad = [e["id"] for e in log if any(now[e["id"]].get(f) != v for f, v in e["set"].items())]
    print(f"wrote {len(log)} companies "
          f"({sum('website' in e['set'] for e in log)} websites, "
          f"{sum('careers_url' in e['set'] for e in log)} careers pages); "
          f"nothing to write for {len(skipped)}; re-read mismatches: {len(bad)} {bad}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "queue":
        queue()
    elif cmd == "probe":
        probe(int(sys.argv[2]))
    elif cmd == "check":
        check(int(sys.argv[2]))
    elif cmd == "apply":
        apply(int(sys.argv[2]))
