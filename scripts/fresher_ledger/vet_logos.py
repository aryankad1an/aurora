"""Vet the logos a crawl found, and drop the ones that aren't the company's.

    python3 vet_logos.py <crawl.json> <vetted.json>

Two kinds get through crawl.py's checks without being a company's own mark:

* **A platform's default icon.** A WordPress site with no icon of its own
  serves WordPress's "W" at /favicon.ico. Any image (byte for byte, or near
  enough to look the same) that three or more unrelated domains serve is a
  default like that. Two is allowed: a group's companies share a logo
  (dxc.com and luxoft.com).
* **A placeholder shape.** One colour filling a plain circle or square.

A dropped logo stays on the row as `rejected_logo`, so the import can clear it
from a company that already has it.
"""
import hashlib
import io
import json
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "company_verification"))
from crawl import MAX_IMAGE, fetch, is_placeholder_shape  # noqa: E402
from domains import clean, registrable  # noqa: E402

SHARED_BY = 3


def average_hash(im):
    rgba = im.convert("RGBA")
    ground = Image.new("RGBA", rgba.size, "white")
    ground.alpha_composite(rgba)
    small = list(ground.convert("L").resize((12, 12)).getdata())
    mean = sum(small) / len(small)
    return "".join("1" if p > mean else "0" for p in small)


def fingerprint(row):
    response, body = fetch(row["logo"]["url"], MAX_IMAGE)
    if response is None or response.status_code != 200 or not body:
        return row["key"], None
    try:
        im = Image.open(io.BytesIO(body))
        im.load()
    except Exception:
        return row["key"], None
    return row["key"], {"sha": hashlib.sha256(body).hexdigest(), "ahash": average_hash(im),
                        "placeholder": is_placeholder_shape(im)}


def main(crawl_path, out_path):
    rows = json.loads(Path(crawl_path).read_text())
    with_logo = [r for r in rows if r.get("logo")]
    with ThreadPoolExecutor(48) as pool:
        prints = dict(pool.map(fingerprint, with_logo))

    def site(row):
        host = urlparse(row.get("final_url") or row["requested"]).hostname or ""
        return registrable(clean(host) or host)

    sites = defaultdict(set)
    for row in with_logo:
        fp = prints.get(row["key"])
        if fp:
            sites["sha:" + fp["sha"]].add(site(row))
            sites["ahash:" + fp["ahash"]].add(site(row))

    dropped = []
    for row in with_logo:
        fp = prints.get(row["key"])
        # One that didn't load just now is kept: a hiccup isn't evidence, and
        # a logo that really is gone falls back to the monogram in the app.
        if fp is None:
            continue
        if len(sites["sha:" + fp["sha"]]) >= SHARED_BY or len(sites["ahash:" + fp["ahash"]]) >= SHARED_BY:
            why = "a default icon other sites serve too"
        elif fp["placeholder"]:
            why = "a plain one-colour shape"
        else:
            continue
        row["rejected_logo"] = row.pop("logo")["url"]
        row["rejected_why"] = why
        dropped.append((row["key"], row["rejected_logo"], why))
    Path(out_path).write_text(json.dumps(rows, indent=1))
    print(f"{len(with_logo)} logos, {len(dropped)} dropped -> {out_path}")
    for key, url, why in dropped:
        print(f"  {why:38} {url}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
