"""A second pass for logos: the icon paths sites serve without declaring them.

    python3 logo_paths.py <crawl.json> <out.json>

For every crawled site that answered but gave no logo, tries the conventional
icon files at its root (apple-touch-icon-precomposed.png, android-chrome-192x192.png,
…, and /favicon.ico when it's really a PNG) and keeps the first that passes
the same checks as crawl.py.
"""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from crawl import check_png  # noqa: E402

PATHS = [
    "/apple-touch-icon-precomposed.png", "/apple-touch-icon-180x180.png", "/apple-touch-icon-152x152.png",
    "/android-chrome-512x512.png", "/android-chrome-192x192.png", "/favicon-196x196.png",
    "/favicon-192x192.png", "/icon-192.png", "/icon-512.png", "/favicon-96x96.png", "/favicon.png",
    # Some sites serve a PNG under the .ico name; check_png only takes a real PNG.
    "/favicon.ico",
]


def find(row):
    host = urlparse(row["final_url"]).hostname
    for path in PATHS:
        url = f"https://{host}{path}"
        size = check_png(url)
        if size:
            return row["key"], {"url": url, "width": size[0], "height": size[1]}
    return row["key"], None


def main(crawl_path, out_path):
    rows = [r for r in json.loads(Path(crawl_path).read_text())
            if r.get("status") == 200 and r.get("final_url") and not r.get("logo")]
    print(f"{len(rows)} sites without a logo", flush=True)
    with ThreadPoolExecutor(48) as pool:
        found = {k: v for k, v in pool.map(find, rows) if v}
    Path(out_path).write_text(json.dumps(found, indent=1))
    print(f"found {len(found)} more logos -> {out_path}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
