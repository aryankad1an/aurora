"""Build Aurora/Resources/NameModel.txt, the data behind the greeting classifier.

    python3 build_model.py            # download (cached), verify, build
    python3 build_model.py --check    # rebuild and fail if the file would change

Needs `rdata` to read one source (`pip install rdata`). Every source is pinned
by URL and SHA-256 and cached in `.cache/names/` at the repo root; a source
that has changed upstream stops the build instead of silently shifting the
model. What each source is and its terms are in README.md.

The model holds no one's address or full name: only how common a given name,
a surname or an English word is, and letter-trigram tables.
"""
import argparse
import collections
import csv
import gzip
import hashlib
import io
import math
import re
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CACHE = REPO / ".cache" / "names"
OUT = REPO / "Aurora" / "Resources" / "NameModel.txt"

SOURCES = {
    # Indian electoral rolls, first names by state and birth year (CC0, via naampy).
    "in_given": ("https://files.pythonhosted.org/packages/e5/d7/16b2f770a6061d3987d9a10f7278008b30be449569c3d83b03584b444776/"
                 "naampy-0.1.0-py2.py3-none-any.whl",
                 "e6ff410071cfaf678bdb0791c8d597de706f09b1943e7c5035e60b2f232cefcc"),
    # US Social Security baby names, every name given to 5+ babies a year, 1880-2017
    # (CC0, via the babynames R package).
    "us_given": ("https://raw.githubusercontent.com/hadley/babynames/master/data/babynames.rda",
                 "1d5c601fa3c5177f4d9edb4c8c2f08fddc8d9bf04372b8a40dc6aecf92bfa324"),
    # SECC 2011 surnames by state and birth year (via outkast). Only the surname and
    # its female/male counts are read; the composition columns are never touched.
    "in_surname": ("https://files.pythonhosted.org/packages/3d/a7/9980bbb70a2fb5c343655065394e42f0a77e0f4851432c935184d4fdbb62/"
                   "outkast-0.1.0-py2.py3-none-any.whl",
                   "c2aa4e2d51e0b64875cbae0546efd18eb09dcc922a6da4dd015ba1a63d55bbca"),
    # Indian electoral-roll surnames across the states, by language (via instate).
    "in_surname_rolls": ("https://files.pythonhosted.org/packages/22/89/689a9b915579d101ab5305de7824e9effea8afa68f91ddba1aed4fa8517c/"
                         "instate-0.1.7-py2.py3-none-any.whl",
                         "3f875317682db298fcd7fe44684be296e4d1560e85a9ea93bc2d63e7afc60d2f"),
    # US Census 2000 surnames with 100+ people (public domain).
    "us_surname": ("https://raw.githubusercontent.com/fivethirtyeight/data/master/most-common-name/surnames.csv",
                   "1498e6a40db61e5edcbd93d9dded9e5249e1a2e9db7571ecc8468c6d6e6acdf7"),
    # Faker's en_IN person names: a curated list of current Indian names (MIT).
    "faker": ("https://files.pythonhosted.org/packages/07/52/9ae853e8c70d6b77fe81b1563378d8ee49aa316cf19502a2e0bf1e4a873e/"
              "faker-40.41.0-py3-none-any.whl",
              "35a7f66282990698c20c3e6dd57180900206b760c2f777112c085cc217e7de92"),
    # SCOWL English word lists by frequency class (permissive; notice in README).
    "words": ("http://archive.ubuntu.com/ubuntu/pool/main/s/scowl/scowl_2020.12.07.orig.tar.gz",
              "5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc"),
}

# People of working age: born 1955 or later.
BORN_FROM = 1955
# Each list's share of its mixture. The catalog is mostly Indian recruiters.
# The rolls cover Andhra, the North-East, Goa, J&K and Puducherry; US births
# fill in much of the rest (Gurpreet, Aarav, Simran) and every other origin.
GIVEN_MIX = {"in_rolls": 0.5, "us_ssa": 0.45, "faker_in": 0.05}
SURNAME_MIX = {"in_secc": 0.3, "in_rolls": 0.3, "us_census": 0.35, "faker_in": 0.05}
# Smaller counts than these are mostly misspellings and one-offs.
US_GIVEN_MIN = 50
IN_ROLLS_SURNAME_MIN = 50
US_SURNAME_MIN = 500
# Tamil names have no hereditary surname: the "last name" a record holds is
# the person's own or their father's given name (Murugan, Ramasamy). Counting
# those as surnames would stop `murugan@` being greeted.
NO_SURNAME_STATES = {"tamilnadu"}
NO_SURNAME_LANGUAGES = {"tamil"}
# Two-letter given names worth greeting by. The rest the US lists carry are
# mostly initials (KC, AJ, JD) or fragments a mailbox is full of (an, de).
TWO_LETTER_GIVEN = {"om", "jo", "al", "ed"}
# Tokens the rolls record as a first name that are titles, not names.
NOT_GIVEN = {"smt", "late", "shri", "mr", "mrs", "ms", "dr", "md", "kumari", "devi", "bibi", "bai", "bewa"}
# Costs are -ln(p) in quarter-nats: plenty of resolution for a ratio test.
SCALE = 4

# A word listed as a given name less than this often relative to how often
# it's a surname is a record that put the surname first ("Singh", "Das",
# "Williams"), not a name to greet anyone by. Ram (2%) and Ali (2%) stay.
SURNAME_FIRST_NOISE = 0.01
# Pattern priors: how often a work mailbox is built each way. Judgement, not
# measurement — see README "Tuning". G given name, S surname, I one or two
# initials, i exactly one (after a given name: `rahulk`, never `breann`+`ev`,
# and never a vowel glued on: `suneeta` is not Suneet + A), W English word;
# O is anything else, scored by letter trigrams.
PRIORS = {
    "G": 0.10, "S": 0.03, "GS": 0.28, "SG": 0.04, "Gi": 0.07, "IG": 0.05, "IS": 0.17,
    "GG": 0.03, "GSS": 0.02, "GGS": 0.02, "GiS": 0.02, "ISI": 0.01, "IIS": 0.03,
    "W": 0.03, "WW": 0.01, "O": 0.09,
}
# How often each pattern is written with nothing between its parts:
# `nehamathur` for neha.mathur. Applied once per boundary, so `aryan` read as
# a + Ryan pays for an initial glued to a given name, which is rare, while
# `a.ryan` doesn't.
GLUE = {
    "GS": 0.45, "SG": 0.35, "Gi": 0.55, "IG": 0.1, "IS": 0.6, "GG": 0.4, "GSS": 0.3,
    "GGS": 0.3, "GiS": 0.15, "ISI": 0.2, "IIS": 0.3, "WW": 0.5,
}
CONSTANTS = {
    "threshold": 0.9,        # greet only when this sure of the name
    "given_oov": 0.2,        # share of given names not in the lists (spelt by trigrams)
    "surname_oov": 0.3,      # share of surnames not in the lists
    "initial1": 0.7 / 26,    # one-letter initial
    "initial2": 0.3 / 676,   # two-letter initials ("pm")
    # Names learned from the catalog get weight n / (n + catalog_prior) for n
    # learned, up to catalog_max: a big catalog counts for a lot, never all.
    "catalog_prior": 1000,
    "catalog_max": 0.5,
    "catalog_min_count": 2,  # times a name only the catalog knows is seen before it's greeted
    "learn_order": 0.95,     # name fields written given name first
    "learn_unlisted": 1e-7,  # what an unlisted word weighs either way when orienting a field
    # A name shortens to the part before a fused surname only when that surname
    # is this common: Kumar, Devi, Rao, Reddy, Raju, Babu, Prasad pass; Manan doesn't.
    "compound_suffix": 1e-4,
}
ALPHA = "abcdefghijklmnopqrstuvwxyz"


def fetch(key):
    url, digest = SOURCES[key]
    path = CACHE / url.rsplit("/", 1)[1]
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print(f"downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as r:
            path.write_bytes(r.read())
    got = hashlib.sha256(path.read_bytes()).hexdigest()
    if got != digest:
        sys.exit(f"{key}: {path.name} has sha256 {got}, expected {digest}")
    return path


def derived(fn):
    """Cache a source's parsed distribution next to the download, keyed by the
    pinned digests and the settings it was read with, so a rebuild after
    changing a prior doesn't re-read hundreds of megabytes."""
    import functools
    import json

    @functools.wraps(fn)
    def wrapper():
        settings = json.dumps([sorted(d for _, d in SOURCES.values()), BORN_FROM, US_GIVEN_MIN,
                               IN_ROLLS_SURNAME_MIN, US_SURNAME_MIN, sorted(NO_SURNAME_STATES),
                               sorted(NO_SURNAME_LANGUAGES), sorted(NOT_GIVEN)])
        key = hashlib.sha256((fn.__name__ + settings).encode()).hexdigest()[:16]
        path = CACHE / f"{fn.__name__}-{key}.json"
        if path.exists():
            return json.loads(path.read_text())
        value = fn()
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return value
    return wrapper


def clean(word):
    w = (word or "").strip().lower()
    return w if re.fullmatch(r"[a-z]{2,}", w) else None


def normalise(counts):
    total = sum(counts.values())
    return {k: v / total for k, v in counts.items()}


@derived
def indian_given():
    with zipfile.ZipFile(fetch("in_given")) as z:
        raw = z.read("naampy/data/in_rolls/in_rolls_state_year_fn_naampy.csv.gz")
    counts = collections.Counter()
    for row in csv.DictReader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(raw)), "utf-8")):
        name = clean(row["first_name"])
        if name and name not in NOT_GIVEN and int(row["birth_year"]) >= BORN_FROM:
            counts[name] += int(row["n_female"]) + int(row["n_male"]) + int(row["n_third_gender"])
    return normalise(counts)


@derived
def us_given():
    import rdata
    frame = rdata.conversion.convert(rdata.parser.parse_file(fetch("us_given")))["babynames"]
    counts = collections.Counter()
    for year, name, n in zip(frame["year"], frame["name"], frame["n"]):
        name = clean(name)
        if name and year >= BORN_FROM:
            counts[name] += int(n)
    return normalise({k: v for k, v in counts.items() if v >= US_GIVEN_MIN})


@derived
def indian_surnames():
    with zipfile.ZipFile(fetch("in_surname")) as z:
        raw = z.read("outkast/data/secc/secc_all_state_year_ln_outkast.csv.gz")
    counts = collections.Counter()
    for row in csv.DictReader(io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(raw)), "utf-8")):
        name = clean(row["last_name"])
        if name and row["state"] not in NO_SURNAME_STATES:
            counts[name] += int(row["n_female"]) + int(row["n_male"])
    return normalise(counts)


@derived
def indian_roll_surnames():
    with zipfile.ZipFile(fetch("in_surname_rolls")) as z:
        packed = z.read("instate/data/lastname_langs_india.csv.tar.gz")
    with tarfile.open(fileobj=io.BytesIO(packed)) as t:
        member = next(m for m in t.getmembers() if m.name.endswith("lastname_langs_india.csv")
                      and not m.name.rsplit("/", 1)[-1].startswith("._"))
        reader = csv.reader(io.TextIOWrapper(t.extractfile(member), "utf-8"))
        header = next(reader)
        keep = [i for i, col in enumerate(header) if i > 0 and col not in NO_SURNAME_LANGUAGES]
        counts = {}
        for row in reader:
            name = clean(row[0])
            weight = sum(float(row[i]) for i in keep)
            if name and weight >= IN_ROLLS_SURNAME_MIN:
                counts[name] = counts.get(name, 0) + weight
    return normalise(counts)


@derived
def us_surnames():
    counts = {}
    with open(fetch("us_surname"), newline="") as f:
        for row in csv.DictReader(f):
            name = clean(row["name"])
            if name and int(row["count"]) >= US_SURNAME_MIN:
                counts[name] = int(row["count"])
    return normalise(counts)


@derived
def faker_indian():
    """(given names, surnames) from Faker's en_IN person provider, read as data."""
    import ast
    with zipfile.ZipFile(fetch("faker")) as z:
        tree = ast.parse(z.read("faker/providers/person/en_IN/__init__.py").decode())
    lists = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", None) in (
                "first_names_male", "first_names_female", "last_names"):
            lists[node.targets[0].id] = ast.literal_eval(node.value)
    uniform = lambda names: normalise({n: 1 for n in map(clean, names) if n})
    return (uniform(lists["first_names_male"] + lists["first_names_female"]),
            uniform(lists["last_names"]))


def words():
    """(common words, all words for trigram training) from SCOWL."""
    lists = {}
    with tarfile.open(fetch("words")) as t:
        for level in ("10", "20", "35"):
            data = t.extractfile(f"scowl-2020.12.07/final/english-words.{level}").read().decode("latin-1")
            lists[level] = {w for w in data.split() if re.fullmatch(r"[a-z]{3,}", w)}
    return lists["10"] | lists["20"], lists["10"] | lists["20"] | lists["35"]


def mix(parts):
    """Weighted mixture of distributions: {name: p}."""
    out = collections.Counter()
    for dist, weight in parts:
        for k, p in dist.items():
            out[k] += weight * p
    return dict(out)


def cost(p):
    return round(-math.log(p) * SCALE)


def trigram_table(types):
    """-ln P(next | two before) over ^a-z contexts and a-z$ outcomes, as one
    printable character per cell (0.2-nat steps). Interpolated with the bigram
    and an add-one unigram so every string gets some probability."""
    tri, bi, uni = collections.Counter(), collections.Counter(), collections.Counter()
    for w in types:
        s = "^^" + w + "$"
        for i in range(2, len(s)):
            tri[s[i - 2:i + 1]] += 1
            bi[s[i - 1:i + 1]] += 1
            uni[s[i]] += 1
    ctx2 = collections.Counter()
    ctx1 = collections.Counter()
    for k, v in tri.items():
        ctx2[k[:2]] += v
    for k, v in bi.items():
        ctx1[k[0]] += v
    outcomes = ALPHA + "$"
    total = sum(uni.values())
    rows = []
    for a in "^" + ALPHA:
        for b in "^" + ALPHA:
            if a != "^" and b == "^":
                continue
            cells = []
            for c in outcomes:
                p1 = (uni[c] + 1) / (total + len(outcomes))
                p2 = bi[b + c] / ctx1[b] if ctx1[b] else p1
                p3 = tri[a + b + c] / ctx2[a + b] if ctx2[a + b] else p2
                n2, n3 = ctx1[b], ctx2[a + b]
                l3 = n3 / (n3 + 5)
                l2 = n2 / (n2 + 5)
                p = l3 * p3 + (1 - l3) * (l2 * p2 + (1 - l2) * p1)
                cells.append(chr(33 + min(93, round(-math.log(p) / 0.2))))
            rows.append(a + b + " " + "".join(cells))
    return rows


def build():
    faker_given, faker_surnames = faker_indian()
    given = mix([(indian_given(), GIVEN_MIX["in_rolls"]), (us_given(), GIVEN_MIX["us_ssa"]),
                 (faker_given, GIVEN_MIX["faker_in"])])
    surnames = mix([(indian_surnames(), SURNAME_MIX["in_secc"]), (indian_roll_surnames(), SURNAME_MIX["in_rolls"]),
                    (us_surnames(), SURNAME_MIX["us_census"]), (faker_surnames, SURNAME_MIX["faker_in"])])
    given = {k: p for k, p in given.items()
             if p / (p + surnames.get(k, 0)) >= SURNAME_FIRST_NOISE
             and (len(k) >= 3 or k in TWO_LETTER_GIVEN)}
    common, all_words = words()
    lines = ["# NameModel v1 - built by scripts/names/build_model.py; do not edit by hand.",
             "# Sources and their terms: scripts/names/README.md",
             "# English words from SCOWL, Copyright 2000-2011 by Kevin Atkinson, used under its",
             "# permission notice (reproduced in scripts/names/README.md)."]
    lines.append("@priors")
    lines += [f"{k} {v}" for k, v in PRIORS.items()]
    lines.append("@glue")
    lines += [f"{k} {v}" for k, v in GLUE.items()]
    lines.append("@constants")
    lines += [f"{k} {v:.6g}" for k, v in CONSTANTS.items()]
    lines.append(f"scale {SCALE}")
    lines.append("@given")
    lines += [f"{k} {cost(p)}" for k, p in sorted(given.items()) if p > 0]
    lines.append("@surname")
    lines += [f"{k} {cost(p)}" for k, p in sorted(surnames.items()) if p > 0]
    lines.append("@words")
    lines += sorted(common)
    lines.append("@trigram_other")      # anything that isn't a name: English words
    lines += trigram_table(all_words)
    lines.append("@trigram_given")      # given names the lists don't have
    lines += trigram_table(given.keys())
    lines.append("@trigram_surname")    # surnames the lists don't have
    lines += trigram_table(surnames.keys())
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = build()
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f"{OUT.relative_to(REPO)} is out of date: run build_model.py")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(REPO)}: {len(text) // 1024} KB")


if __name__ == "__main__":
    main()
