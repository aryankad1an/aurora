"""Visit company websites and find each one's logo and careers page.

    python3 crawl.py targets.json out.json [--workers 32]

`targets.json` is a list of {"key", "url", "name"}: a ledger company's website,
or https://<domain> for a catalog company the ledger doesn't cover. For each,
the homepage is fetched and three things are worked out:

* **website**: the page it settled on. A catalog company's domain only counts as
  its website when the homepage stays on that domain, or its title names the
  company: a parked domain or a redirect to someone else is not a website.
* **logo**: the best square PNG the site offers as its icon: its
  apple-touch-icon, a PNG `<link rel=icon>`, a web-app manifest icon, or
  /apple-touch-icon.png. Each candidate is downloaded and checked: a real PNG,
  at least 64 px, roughly square, and not one flat colour. SVG and ICO are left
  out (iOS can't draw the first; the second is rarely more than 32 px).
* **careers**: a link on the homepage whose text or path says careers or jobs,
  on the company's own domain or a known applicant-tracking host, that answers.

Nothing is guessed: a site that can't be reached, or offers no icon that passes,
gets nothing, and the app keeps its monogram.
"""
import io
import json
import re
import sys
import threading
import warnings
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup, XMLParsedAsHTMLWarning
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "company_verification"))
from domains import clean, registrable  # noqa: E402

warnings.filterwarnings("ignore", category=XMLParsedAsHTMLWarning)
Image.MAX_IMAGE_PIXELS = 20_000_000

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
DESKTOP_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")
HEADERS = {"User-Agent": DESKTOP_UA if "--desktop" in sys.argv else UA, "Accept-Language": "en-US,en;q=0.9"}
TIMEOUT = (6, 12)
MAX_PAGE = 3_000_000
MAX_IMAGE = 2_000_000

# Hosts that serve job boards for many companies. A careers link there is the
# company's own board.
ATS_HOSTS = (
    "greenhouse.io", "lever.co", "myworkdayjobs.com", "myworkdaysite.com", "ashbyhq.com",
    "smartrecruiters.com", "workable.com", "keka.com", "zohorecruit.com", "zohorecruit.in",
    "darwinbox.in", "darwinbox.com", "freshteam.com", "bamboohr.com", "jobvite.com",
    "icims.com", "successfactors.com", "successfactors.eu", "taleo.net", "oraclecloud.com",
    "eightfold.ai", "recruitee.com", "teamtailor.com", "breezy.hr", "applytojob.com",
    "jazzhr.com", "pinpointhq.com", "rippling-ats.com", "rippling.com", "dover.com",
    "wellfound.com", "personio.de", "personio.com", "phenompeople.com", "avature.net",
    "turbohire.co", "superset.com", "hirist.tech", "instahyre.com",
)
CAREERS_TEXT = re.compile(r"\b(careers?|jobs|join (us|our team|the team)|work with us|"
                          r"we'?re hiring|open (roles|positions))\b", re.I)
CAREERS_PATH = re.compile(r"/(careers?|jobs|join-us|joinus|work-with-us|opportunities)(/|$|\.|\?)", re.I)

# What a domain for sale or a host's placeholder page says about itself.
PARKED = re.compile(r"(domain (is )?for sale|buy this domain|this domain (may be|is) for sale|"
                    r"parked (free|domain)|hugedomains|sedoparking|dan\.com|afternic|"
                    r"domain has expired|account (has been )?suspended|coming soon|under construction|"
                    r"default web site page|welcome to nginx|it works!|index of /)", re.I)

_local = threading.local()


def session():
    if not hasattr(_local, "s"):
        s = requests.Session()
        s.headers.update(HEADERS)
        s.max_redirects = 8
        _local.s = s
    return _local.s


def fetch(url, limit, accept=None):
    """GET `url`, reading at most `limit` bytes. (response, body) or (None, None)."""
    try:
        h = {"Accept": accept} if accept else {}
        r = session().get(url, timeout=TIMEOUT, stream=True, allow_redirects=True, headers=h)
        body = b""
        for chunk in r.iter_content(65536):
            body += chunk
            if len(body) > limit:
                r.close()
                return None, None
        return r, body
    except Exception:
        return None, None


def host_of(url):
    return (urlparse(url).hostname or "").lower()


def reg_of(url):
    d = clean(host_of(url))
    return registrable(d) if d else None


def words(name):
    stop = {"the", "and", "of", "private", "pvt", "limited", "ltd", "inc", "llc", "group",
            "technologies", "technology", "solutions", "services", "india", "software", "labs", "co"}
    n = re.sub(r"\(.*?\)", " ", (name or "").lower())
    return [w for w in re.findall(r"[a-z0-9]+", n) if len(w) > 2 and w not in stop]


def check_png(url):
    """The image at `url` if it's a usable logo: (width, height) or None."""
    if not url.startswith("https://"):
        return None
    r, body = fetch(url, MAX_IMAGE, accept="image/png,image/*;q=0.8")
    if r is None or r.status_code != 200 or not body:
        return None
    try:
        im = Image.open(io.BytesIO(body))
        if im.format != "PNG":
            return None
        im.load()
    except Exception:
        return None
    w, h = im.size
    if min(w, h) < 64 or not (0.8 <= w / h <= 1.25):
        return None
    # A flat square (all one colour, or fully transparent) is a placeholder.
    rgba = im.convert("RGBA")
    alpha = rgba.getchannel("A").getextrema()
    if alpha[1] == 0:
        return None
    colors = rgba.convert("RGB").getcolors(maxcolors=4)
    if colors is not None and len(colors) <= 1:
        return None
    if is_placeholder_shape(im):
        return None
    return w, h


def is_placeholder_shape(im):
    """One colour filling a plain circle or square: a placeholder, not a mark.

    A single-colour logo is common (a spade, an eagle); what gives a
    placeholder away is that its one colour fills the most basic shape there is.
    """
    n = 48
    rgba = im.convert("RGBA").resize((n, n))
    pixels = list(rgba.getdata())
    opaque = [(x, y) for i, (r, g, b, a) in enumerate(pixels) if a >= 128 for x, y in [(i % n, i // n)]]
    # Fine marks (a dotted wordmark) shrink to nothing solid: no shape to judge.
    if not opaque:
        return False
    buckets = defaultdict(int)
    for r, g, b, a in pixels:
        if a >= 128:
            buckets[(r // 32, g // 32, b // 32)] += 1
    # Truly one colour: a wordmark on a solid tile blurs into many faint
    # shades when shrunk, each too small to count on its own, but together
    # they're more than a sliver.
    if max(buckets.values()) < len(opaque) * 0.985:
        return False
    xs, ys = [p[0] for p in opaque], [p[1] for p in opaque]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    # A placeholder is a round or square blob filling the icon; a wordmark is
    # a wide band, however solid it looks once shrunk.
    if not (0.85 <= w / h <= 1.18) or w < n * 0.6:
        return False
    mask = set(opaque)
    square = {(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    disc = {(x, y) for x, y in square if ((x - cx) / (w / 2)) ** 2 + ((y - cy) / (h / 2)) ** 2 <= 1.0}

    def iou(a, b):
        return len(a & b) / len(a | b) if a | b else 0
    return iou(mask, square) > 0.97 or iou(mask, disc) > 0.93


def icon_candidates(soup, base):
    """(priority, size, url) for every icon the page declares, best first."""
    out = []
    for link in soup.find_all("link", href=True):
        rel = " ".join(link.get("rel") or []).lower()
        href = urljoin(base, link["href"].strip())
        typ = (link.get("type") or "").lower()
        if href.lower().split("?")[0].endswith((".svg", ".ico")) or "svg" in typ or "icon" not in rel:
            continue
        if "mask-icon" in rel:
            continue
        sizes = re.findall(r"(\d+)x(\d+)", link.get("sizes") or "")
        size = max((int(a) for a, _ in sizes), default=0)
        prio = 0 if "apple-touch-icon" in rel else 1
        out.append((prio, -size, href))
    return sorted(out)


def manifest_icons(soup, base):
    link = soup.find("link", rel=lambda v: v and "manifest" in v, href=True)
    if not link:
        return []
    url = urljoin(base, link["href"])
    r, body = fetch(url, 500_000)
    if r is None or r.status_code != 200:
        return []
    try:
        icons = json.loads(body).get("icons") or []
    except Exception:
        return []
    out = []
    for icon in icons:
        src = icon.get("src")
        if not src or src.lower().split("?")[0].endswith((".svg", ".ico")):
            continue
        sizes = re.findall(r"(\d+)x(\d+)", icon.get("sizes") or "")
        size = max((int(a) for a, _ in sizes), default=0)
        out.append((2, -size, urljoin(r.url, src)))
    return sorted(out)


def find_logo(soup, base):
    seen = set()
    candidates = icon_candidates(soup, base) + manifest_icons(soup, base)
    root = f"https://{host_of(base)}/apple-touch-icon.png"
    candidates.append((3, 0, root))
    tried = 0
    for _, _, url in candidates:
        url = url.replace("http://", "https://", 1)
        if url in seen:
            continue
        seen.add(url)
        tried += 1
        if tried > 6:
            break
        size = check_png(url)
        if size:
            return {"url": url, "width": size[0], "height": size[1]}
    return None


def find_careers(soup, base, own):
    best = None
    for a in soup.find_all("a", href=True):
        href = a["href"].strip()
        if href.startswith(("mailto:", "tel:", "javascript:", "#")):
            continue
        url = urljoin(base, href)
        if not url.startswith(("http://", "https://")):
            continue
        host = host_of(url)
        reg = reg_of(url)
        # A "Careers" link back to the homepage is no careers page.
        if urlparse(url).path in ("", "/") and not urlparse(url).query \
                and not host.startswith(("careers.", "jobs.")):
            continue
        on_ats = any(host == h or host.endswith("." + h) for h in ATS_HOSTS)
        if reg != own and not on_ats:
            continue
        text = " ".join(a.get_text(" ", strip=True).split())[:60]
        path = urlparse(url).path
        score = 0
        if CAREERS_PATH.search(path + ("?" + urlparse(url).query if urlparse(url).query else "")):
            score += 2
        if CAREERS_TEXT.search(text):
            score += 2
        if on_ats:
            score += 1
        if host.startswith(("careers.", "jobs.")) and reg == own:
            score += 2
        if score >= 2 and (best is None or score > best[0]):
            best = (score, url.replace("http://", "https://", 1))
    if not best:
        return None
    r, _ = fetch(best[1], MAX_PAGE)
    if r is None or r.status_code >= 400:
        return None
    return best[1]


def crawl(target):
    url, name = target["url"], target["name"]
    want = reg_of(url)
    out = {"key": target["key"], "requested": url}
    r, body = fetch(url, MAX_PAGE, accept="text/html,application/xhtml+xml")
    if r is None and url.startswith("https://"):
        r, body = fetch("https://www." + host_of(url).removeprefix("www.") + urlparse(url).path, MAX_PAGE)
    if r is None or r.status_code >= 400 or not body:
        out["status"] = getattr(r, "status_code", None) or "unreachable"
        return out
    final = r.url
    out["status"] = r.status_code
    out["final_url"] = final
    try:
        soup = BeautifulSoup(body, "html.parser")
    except Exception:
        out["status"] = "unparseable"
        return out
    title = " ".join((soup.title.get_text(" ", strip=True) if soup.title else "").split())[:200]
    site_name = soup.find("meta", property="og:site_name")
    out["title"] = title
    out["site_name"] = (site_name.get("content") or "")[:120] if site_name else ""
    stays = reg_of(final) == want
    named = any(w in (title + " " + out["site_name"]).lower() for w in words(name))
    out["stays_on_domain"] = stays
    out["parked"] = bool(PARKED.search(title + " " + body[:20000].decode("utf-8", "ignore")[:20000]))
    out["title_names_company"] = named
    own = reg_of(final)
    out["logo"] = find_logo(soup, final)
    out["careers"] = find_careers(soup, final, own)
    return out


def main(targets_path, out_path, workers=32):
    targets = json.loads(Path(targets_path).read_text())
    done = {}
    out = Path(out_path)
    if out.exists():
        done = {row["key"]: row for row in json.loads(out.read_text())}
    todo = [t for t in targets if t["key"] not in done]
    print(f"{len(targets)} targets, {len(todo)} to crawl", flush=True)
    lock = threading.Lock()
    with ThreadPoolExecutor(workers) as pool:
        futures = {pool.submit(crawl, t): t for t in todo}
        for i, f in enumerate(as_completed(futures), 1):
            t = futures[f]
            try:
                row = f.result()
            except Exception as e:
                row = {"key": t["key"], "requested": t["url"], "status": f"error: {e}"[:200]}
            with lock:
                done[row["key"]] = row
                if i % 100 == 0 or i == len(todo):
                    out.write_text(json.dumps(list(done.values()), indent=1))
                    logos = sum(1 for v in done.values() if v.get("logo"))
                    print(f"  {i}/{len(todo)}  logos so far {logos}", flush=True)
    out.write_text(json.dumps(list(done.values()), indent=1))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    workers = int(sys.argv[sys.argv.index("--workers") + 1]) if "--workers" in sys.argv else 32
    main(args[0], args[1], workers)
