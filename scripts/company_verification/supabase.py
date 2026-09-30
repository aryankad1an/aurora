"""Minimal PostgREST client for the Aurora Supabase project.

Uses the app's anon key from Aurora/AppConfig.swift (it ships in the app, so
it is not a secret). Every write goes through `write`, which logs and raises on
anything but 2xx so a half-applied plan stops instead of carrying on.
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

_CONFIG = (Path(__file__).resolve().parents[2] / "Aurora" / "AppConfig.swift").read_text()
BASE = re.search(r'supabaseURL = "([^"]+)"', _CONFIG).group(1).rstrip("/") + "/rest/v1/"
KEY = re.search(r'supabaseAnonKey = "([^"]+)"', _CONFIG).group(1)
PAGE = 1000


class APIError(RuntimeError):
    pass


def _request(method, path, query=None, body=None, headers=None, timeout=30):
    url = BASE + path + ("?" + urllib.parse.urlencode(query, safe=",.()*") if query else "")
    h = {"apikey": KEY, "Authorization": "Bearer " + KEY, "Content-Type": "application/json"}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(5):
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return (json.loads(raw) if raw else None), r.headers
        except urllib.error.HTTPError as e:
            raise APIError(f"{method} {path} {query} -> HTTP {e.code}: {e.read().decode()[:400]}")
        except Exception as e:  # network blip: retry with backoff
            last = e
            time.sleep(1 + attempt * 2)
    raise APIError(f"{method} {path} failed after retries: {last}")


def get_all(table, order="id.asc", select="*", filters=None):
    """Every row of `table`, paged with a stable order."""
    rows, offset = [], 0
    while True:
        q = {"select": select, **(filters or {})}
        if order:
            q["order"] = order
        batch, headers = _request("GET", table, q, headers={
            "Range-Unit": "items", "Range": f"{offset}-{offset + PAGE - 1}", "Prefer": "count=exact"})
        rows += batch
        offset += len(batch)
        total = (headers.get("Content-Range") or "*/*").split("/")[1]
        if not batch or (total != "*" and offset >= int(total)) or len(batch) < PAGE:
            if total != "*" and len(rows) != int(total):
                raise APIError(f"{table}: read {len(rows)} rows, server reports {total}")
            return rows


def get(table, filters, select="*"):
    rows, _ = _request("GET", table, {"select": select, **filters})
    return rows


def write(method, table, filters=None, body=None, prefer="return=representation"):
    rows, _ = _request(method, table, filters, body, headers={"Prefer": prefer})
    return rows


def in_filter(ids):
    return "in.(" + ",".join(ids) + ")"
