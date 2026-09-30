"""Company data-verification pipeline for Aurora.

    python3 verify_companies.py                 # dry run against the live DB
    python3 verify_companies.py --snapshot DIR  # dry run against a backup
    python3 verify_companies.py --apply         # back up, apply, re-verify

What it guarantees once applied: every work mail domain maps to exactly one
company, and that company is the right one. How:

1. Resolve each contact's work domain to the domain its owner registers
   (`ny.email.gs.com` -> `gs.com`, `in.pwc.com` -> `pwc.com`).
2. Apply the verified rules in decisions.json: merges (duplicate rows, brands
   filed under a subdomain or a sibling TLD), renames, domain moves, typo
   domains, personal-mail buckets, junk rows.
3. Give every remaining registrable domain one owner (the company it is the
   main domain of) and move stray contacts to it. A company is folded into
   another only when all of its contacts move — never because one contact
   was misfiled.
4. Emit the plan, a report, and the domain -> company map; with --apply,
   execute the plan (contacts and tracked rows move before any company is
   deleted, because deleting a company cascades to its contacts and sends),
   then re-read the DB and re-check every invariant.
"""
import argparse
import collections
import csv
import datetime
import json
import re
import sys
from pathlib import Path

import backup as backup_mod
import supabase
from domains import brand, clean, is_personal, registrable

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DECISIONS = json.loads((HERE / "decisions.json").read_text())

# Old name -> the name a rule gives it, so a re-run finds already-renamed rows.
FINAL_NAME = {**{m["into"]: m["name"] for m in DECISIONS["merges"] if "name" in m},
              **DECISIONS["renames"]}

PINNED = {k: v for k, v in DECISIONS.get("_ids", {}).items() if not k.startswith("_")}
ALL_SOURCES = {s for m in DECISIONS["merges"] for s in m["from"]}

# Mailbox subdomain labels an importer turned into company names ("Ext Airbnb").
SUBDOMAIN_WORDS = {
    "ext", "external", "mail", "email", "smail", "gwmail", "partner", "partners", "jobs",
    "careers", "exchange", "exgate", "groups", "consultant", "associates", "alumni",
    "student", "students", "stu", "research", "inst", "team", "in", "us", "uk", "jp", "eu",
    "ap", "ch", "ny", "hk", "gds", "ant", "med", "e", "i", "u", "it", "cse", "mfs", "del",
    "ps", "bs", "rana", "astra", "mm", "smit", "mba", "msw", "pilani", "goa", "hyderabad",
}


# ----------------------------------------------------------------------------
# Loading

def load_live():
    return {t: supabase.get_all(t, order=o) for t, o in backup_mod.TABLES.items()}


def load_snapshot(path):
    path = Path(path)
    return {t: json.loads((path / f"{t}.json").read_text()) for t in backup_mod.TABLES}


class State:
    """The tables, indexed the ways the pipeline asks about them."""

    def __init__(self, tables):
        self.tables = tables
        self.companies = {c["id"]: c for c in tables["companies"]}
        self.recruiters = tables["recruiters"]
        self.by_company = collections.defaultdict(list)
        for r in self.recruiters:
            self.by_company[r["company_id"]].append(r)
        self.sends = collections.Counter(m["recruiter_id"] for m in tables["mail_sends"])
        self.tracked = collections.defaultdict(set)  # company_id -> {(table, user)}
        for table in ("tracked_companies", "user_companies"):
            for t in tables[table]:
                self.tracked[t["company_id"]].add((table, t["user_email"]))
        self.by_name = {c["name"]: c["id"] for c in tables["companies"]}

    def company_sends(self, cid):
        return sum(self.sends[r["id"]] for r in self.by_company[cid])

    def resolve(self, name, required=True):
        """A decisions.json name -> id, or None once the row is gone (merged
        away or deleted by an earlier run). Pinned names resolve by id only —
        after renames a name can belong to a different row ("Yahoo") — and
        unpinned ones (rules added later) by name, then by their final name."""
        if name in PINNED:
            cid = PINNED[name] if PINNED[name] in self.companies else None
            if cid is None and required and name not in ALL_SOURCES:
                raise SystemExit(f"decisions.json: pinned company {name!r} is gone from the DB")
            return cid
        cid = self.by_name.get(name) or self.by_name.get(FINAL_NAME.get(name, ""))
        if cid is None and required:
            raise SystemExit(f"decisions.json names a company that isn't in the DB: {name!r}")
        return cid


def contact_domain(r):
    return clean(r["email"] or "")


# ----------------------------------------------------------------------------
# Planning

class UnionFind:
    def __init__(self):
        self.parent = {}

    def find(self, x):
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union_into(self, target, other):
        """Make `target`'s root the root of `other`'s set."""
        rt, ro = self.find(target), self.find(other)
        if rt != ro:
            self.parent[ro] = rt


def build_plan(st, restore_rows=()):
    d = DECISIONS
    uf = UnionFind()
    final_name = {}      # root id -> name it should end with
    why = {}             # company id -> reason it was merged
    notes = []

    test_ids = {st.resolve(n, required=False) for n in d["test_companies"]} - {None}
    junk_ids = {st.resolve(n, required=False) for n in d["junk_companies"]} - {None}  # None: already deleted
    relay = set(d["relay_domains"])

    # Explicit merges and renames.
    for m in d["merges"]:
        into = st.resolve(m["into"], required=False)
        if into is None:
            # Target gone too (e.g. a personal group removed by a later rule):
            # the merge is history. A source still present would be stranded.
            live = [s for s in m["from"] if st.resolve(s, required=False)]
            if live:
                raise SystemExit(f"decisions.json: merge target {m['into']!r} is gone but {live} still exist")
            continue
        for src in m["from"]:
            sid = st.resolve(src, required=False)
            if sid is None or sid == into:  # already merged away on an earlier run
                continue
            uf.union_into(into, sid)
            why[sid] = m.get("why", f"duplicate of {m['into']!r}")
        if "name" in m:
            final_name[uf.find(into)] = m["name"]
    renames = {}
    for old, new in d["renames"].items():
        cid = st.resolve(old, required=False)
        if cid is None and new not in st.by_name and old not in PINNED:
            raise SystemExit(f"decisions.json renames a company that isn't in the DB: {old!r}")
        if cid:
            renames[cid] = new

    # New companies a domain move creates. Keyed by a placeholder id.
    creates = {}
    move_targets = {}  # host or registrable domain -> company id (or placeholder)
    for dom, rule in d["domain_moves"].items():
        if "create" in rule:
            # A row being restored keeps its original id, so it's found by id
            # once it exists again; a brand-new one is found by name.
            # A name match that's a pinned row belongs to another rule (it may
            # still carry this name until its own rename runs): never reuse it.
            by_name = st.by_name.get(rule["create"])
            if by_name in PINNED.values():
                by_name = None
            existing = rule["id"] if rule.get("id") in st.companies else by_name
            key = existing or f"new:{rule['create']}"
            if not existing:
                creates[key] = {"name": rule["create"], "id": rule.get("id")}
            move_targets[dom] = key
        else:
            move_targets[dom] = st.resolve(rule["to"])

    def root(cid):
        return cid if cid.startswith("new:") else uf.find(cid)

    # Who owns each registrable work domain: count contacts per (domain, root).
    counts = collections.defaultdict(collections.Counter)
    for r in st.recruiters:
        dom = contact_domain(r)
        if not dom or is_personal(dom) or r["company_id"] in test_ids | junk_ids:
            continue
        if registrable(dom) in relay or dom in d["typo_domains"]:
            continue
        if dom in move_targets or registrable(dom) in move_targets:
            continue
        counts[registrable(dom)][root(r["company_id"])] += 1

    # A company's primary domain: the registrable domain most of its contacts use.
    primary = {}
    per_root = collections.defaultdict(collections.Counter)
    for dom, c in counts.items():
        for rid, n in c.items():
            per_root[rid][dom] += n
    for rid, c in per_root.items():
        primary[rid] = c.most_common(1)[0][0]

    owner = {}
    contested = []
    for dom, c in counts.items():
        if len(c) == 1:
            owner[dom] = next(iter(c))
            continue
        # Prefer a company whose main domain this is; then the most contacts.
        ranked = sorted(c.items(), key=lambda kv: (primary.get(kv[0]) == dom, kv[1],
                                                   len(st.tracked[kv[0]])), reverse=True)
        owner[dom] = ranked[0][0]
        contested.append((dom, [(st.companies[k]["name"], n) for k, n in ranked]))

    # Personal-mailbox contacts: deleted when the rules say so. One with send
    # history is held instead — deleting it would cascade to its mail_sends.
    delete_personal, held_personal = [], []
    if d.get("personal_contacts", {}).get("action") == "delete":
        for r in st.recruiters:
            dom = contact_domain(r)
            if dom and is_personal(dom) and r["company_id"] not in test_ids | junk_ids:
                (held_personal if st.sends[r["id"]] else delete_personal).append(r)
    # Contacts on hosts that provably can't receive mail: same treatment.
    dead = dead_hosts()
    delete_dead, held_dead = [], []
    for r in st.recruiters:
        dom = contact_domain(r)
        if dom in dead and r["company_id"] not in test_ids | junk_ids:
            (held_dead if st.sends[r["id"]] else delete_dead).append(r)
    deleting = {r["id"] for r in delete_personal + delete_dead}

    # Each contact's destination.
    moves = collections.defaultdict(list)      # target id -> [recruiter]
    stray = []                                 # moves not implied by a company merge
    rewrite = []                               # typo addresses corrected in place
    for r in st.recruiters:
        cid = r["company_id"]
        if cid in test_ids or cid in junk_ids or r["id"] in deleting:
            continue
        dom = contact_domain(r)
        target = root(cid)
        reason = None
        if dom and dom in d["typo_domains"]:
            fixed = registrable(d["typo_domains"][dom])
            target = owner.get(fixed, target)
            rewrite.append({"id": r["id"], "from": r["email"], "to": corrected(r["email"])})
            reason = f"typo domain {dom} (meant {d['typo_domains'][dom]})"
        elif dom and not is_personal(dom) and registrable(dom) not in relay:
            reg = registrable(dom)
            if dom in move_targets:
                target, reason = move_targets[dom], f"{dom}: {d['domain_moves'][dom]['why']}"
            elif reg in move_targets:
                target, reason = move_targets[reg], f"{reg}: {d['domain_moves'][reg]['why']}"
            elif reg in owner and owner[reg] != target:
                target, reason = owner[reg], f"{reg} belongs to {st.companies[owner[reg]]['name']}"
        if target != cid:
            moves[target].append(r)
            if reason and not (target == root(cid)):
                stray.append((r, cid, target, reason))

    # Companies left with no contacts: merged away (their tracking goes to the
    # target) or deleted outright if they were junk.
    leaving = collections.Counter()
    for tgt, rs in moves.items():
        for r in rs:
            leaving[r["company_id"]] += 1
    folded = {}  # company id -> where it ends up
    for cid in st.companies:
        if cid in test_ids or cid in junk_ids:
            continue
        rt = root(cid)
        has = len(st.by_company[cid])
        if rt != cid:
            folded[cid] = rt  # explicit merge: all its contacts go to rt
            continue
        if has and leaving[cid] == has:
            # Every contact belongs elsewhere: it's a duplicate of where they went.
            dests = {t for t, rs in moves.items() for r in rs if r["company_id"] == cid}
            if len(dests) == 1:
                folded[cid] = dests.pop()
                why[cid] = f"all contacts belong to {name_of(st, folded[cid], final_name, renames, creates)}"
    # Chase chains (A folded into B folded into C).
    for cid in list(folded):
        seen = {cid}
        while folded[cid] in folded and folded[cid] not in seen:
            seen.add(folded[cid])
            folded[cid] = folded[folded[cid]]
    # Contacts of a folded company must follow it even when not moved above.
    moved_ids = {r["id"] for rs in moves.values() for r in rs}
    for cid, tgt in folded.items():
        for r in st.by_company[cid]:
            if r["id"] not in moved_ids and r["id"] not in deleting:
                moves[tgt].append(r)
    # Normalise move targets through the fold map.
    norm_moves = collections.defaultdict(list)
    for tgt, rs in moves.items():
        norm_moves[folded.get(tgt, tgt)].extend(rs)
    moves = norm_moves

    # Typo contacts deleted by an earlier run (as dead domains), restored from a
    # backup with the address corrected: same id, filed under the company that
    # owns the correct domain. Skipped if the corrected address already exists.
    restore = []
    live_ids = {r["id"] for r in st.recruiters}
    live_emails = {r["email"].strip().lower() for r in st.recruiters}
    for r in restore_rows:
        dom = contact_domain(r)
        if dom not in d["typo_domains"] or r["id"] in live_ids:
            continue
        new_email = corrected(r["email"])
        tgt = owner.get(registrable(d["typo_domains"][dom]))
        if new_email.lower() in live_emails:
            notes.append(f"not restoring {r['email']}: {new_email} is already in the catalog")
        elif not tgt:
            notes.append(f"not restoring {r['email']}: no company owns {d['typo_domains'][dom]}")
        else:
            restore.append({**r, "email": new_email, "company_id": tgt, "is_valid": True})
            live_emails.add(new_email.lower())

    # Tracking rows that must follow a folded company.
    tracking = []
    will_track = collections.defaultdict(set)
    for tgt in set(folded.values()):
        will_track[tgt] = set(st.tracked.get(tgt, set()))
    for cid, tgt in sorted(folded.items()):
        for table, user in sorted(st.tracked[cid]):
            tracking.append({"table": table, "user_email": user, "from": cid, "to": tgt,
                             "insert": (table, user) not in will_track[tgt]})
            will_track[tgt].add((table, user))

    # Names and sectors for survivors.
    rename_ops = {}
    for cid, new in renames.items():
        rename_ops[folded.get(cid, cid)] = new
    for rid, new in final_name.items():
        rename_ops[folded.get(rid, rid)] = new
    rename_ops = {k: v for k, v in rename_ops.items()
                  if k.startswith("new:") or st.companies[k]["name"] != v}
    sector_ops = {}
    for cid, tgt in folded.items():
        src = st.companies[cid].get("sector")
        if tgt.startswith("new:") or not src:
            continue
        if not st.companies[tgt].get("sector") and tgt not in sector_ops:
            sector_ops[tgt] = src

    # "(Personal Email)" groups the deletion leaves empty go too — unless
    # tracked, or still holding a contact kept for its send history.
    emptied = []
    moving_out = collections.Counter(r["company_id"] for rs in moves.values() for r in rs)
    moving_in = {folded.get(t, t) for t in moves}
    for cid, c in st.companies.items():
        if cid in folded or cid in moving_in or cid in test_ids or not st.by_company[cid]:
            continue
        gone_here = [r for r in st.by_company[cid] if r["id"] in deleting]
        left = [r for r in st.by_company[cid] if r["id"] not in deleting]
        if gone_here and len(left) == moving_out[cid] and not st.tracked[cid]:
            emptied.append(cid)

    # Junk: delete their contacts, then the company. Never if mail was sent.
    junk = []
    for cid in junk_ids:
        sends = st.company_sends(cid)
        if sends or st.tracked[cid]:
            notes.append(f"NOT deleting junk {st.companies[cid]['name']!r}: it has sends/tracking")
            continue
        junk.append(cid)

    return {
        "creates": creates,
        "moves": {t: [r["id"] for r in rs] for t, rs in moves.items()},
        "tracking": tracking,
        "delete_companies": sorted(folded),
        "fold_into": folded,
        "delete_junk": junk,
        "delete_personal": [r["id"] for r in delete_personal],
        "held_personal": [r["id"] for r in held_personal],
        "delete_dead": [r["id"] for r in delete_dead],
        "rewrite_emails": rewrite,
        "restore_contacts": restore,
        "held_dead": [r["id"] for r in held_dead],
        "delete_emptied": sorted(emptied),
        "renames": rename_ops,
        "sectors": sector_ops,
        "why": why,
        "_stray": stray,
        "_contested": contested,
        "notes": notes,
    }


def dead_hosts():
    """Hosts that provably can't receive mail. A typo host is corrected, not deleted."""
    return {h for h in DECISIONS.get("dead_domains", {}) if not h.startswith("_")} - set(DECISIONS["typo_domains"])


def corrected(email):
    """`a.b@wellfargo.com` -> `a.b@wellsfargo.com`: the typo rule's fix, local part untouched."""
    local, host = email.strip().rsplit("@", 1)
    return f"{local}@{DECISIONS['typo_domains'][host.lower()]}"


def ilike_exact(value):
    """A PostgREST filter matching `value` exactly, ignoring case. `_` and `%`
    are LIKE wildcards, so `first_last@x.com` would otherwise also match
    `firstXlast@x.com` — and a false clash aborts --apply halfway through.
    `*` is left alone: PostgREST turns it into `%` after unescaping, so an
    escaped one would match nothing and hide a real clash."""
    return "ilike." + re.sub(r"([\\%_])", r"\\\1", value)


def is_agency_itself(company_name, host):
    """Talentiser listing talentiser.com is its own domain, not a relay."""
    return brand(host).replace("-", "") in re.sub(r"[^a-z0-9]", "", company_name.lower())


def domain_ops(st):
    """companies.domains changes that keep the column true to the contacts.

    The app looks a company up by exact mail host (`domains cs.{host}`), so a
    company lists every work host its contacts use (ext.airbnb.com included).
    Removed: personal, typo and relay hosts (relay kept on the agency itself),
    and a host that now belongs only to another company's contacts. Kept: a
    host nobody's contacts use — someone typed it in the company form.
    Returns {} when the column doesn't exist yet.
    """
    if not any("domains" in c for c in st.companies.values()):
        return {}
    d = DECISIONS
    relay, typo, dead = set(d["relay_domains"]), set(d["typo_domains"]), dead_hosts()
    test_ids = {st.resolve(n, required=False) for n in d["test_companies"]} - {None}
    held = collections.defaultdict(set)  # host -> companies whose contacts use it
    for r in st.recruiters:
        h = contact_domain(r)
        if h:
            held[h].add(r["company_id"])
    ops = {}
    for cid, c in st.companies.items():
        if cid in test_ids:
            continue
        have = list(c.get("domains") or [])
        def allowed(h):
            if is_personal(h) or h in typo or h in dead:
                return False
            return registrable(h) not in relay or is_agency_itself(c["name"], h)
        mine = {contact_domain(r) for r in st.by_company[cid]} - {None}
        work = {h for h in mine if allowed(h)}
        keep = [h for h in have if allowed(h) and not (held.get(h, set()) - {cid} and h not in mine)]
        want = keep + sorted(work - set(keep))
        if want != have:
            ops[cid] = want
    return ops


def name_of(st, cid, final_name=None, renames=None, creates=None):
    if cid.startswith("new:"):
        return cid[4:]
    for table in (final_name or {}, renames or {}):
        if cid in table:
            return table[cid]
    return st.companies[cid]["name"]


# ----------------------------------------------------------------------------
# Verification — run on any state, before or after applying

def verify(st):
    """Invariant violations (must be empty after --apply) and warnings."""
    d = DECISIONS
    test_ids = {st.resolve(n, required=False) for n in d["test_companies"]} - {None}
    relay = set(d["relay_domains"])
    violations, warnings = [], []

    owners = collections.defaultdict(collections.Counter)
    for r in st.recruiters:
        dom = contact_domain(r)
        if not dom or is_personal(dom) or registrable(dom) in relay or r["company_id"] in test_ids:
            continue
        # A host with its own verified owner (med.ge.com) is its own domain.
        owners[dom if dom in d["domain_moves"] else registrable(dom)][r["company_id"]] += 1
    for dom, c in sorted(owners.items()):
        if len(c) > 1:
            violations.append(f"domain {dom} is split across companies: "
                              + ", ".join(f"{st.companies[k]['name']} ({n})" for k, n in c.items()))

    for cid, c in st.companies.items():
        name = c["name"]
        words = name.lower().replace("(", " ").split()
        hosts = {contact_domain(r) for r in st.by_company[cid]} - {None}
        for h in hosts:
            if h != registrable(h) and words and words[0] == h.split(".")[0] and words[0] in SUBDOMAIN_WORDS:
                violations.append(f"company {name!r} is named after mail host {h}")
        for h in hosts:
            suffix = registrable(h).split(".")[1:]
            if len(words) > 1 and words[-1] in suffix and words[-1] not in {"money", "exchange", "security"}:
                warnings.append(f"company {name!r} may carry its domain's suffix ({h})")
                break

    for r in st.recruiters:
        dom = contact_domain(r)
        if dom in d["typo_domains"]:
            violations.append(f"contact {r['email']} is on typo domain {dom}; should be {corrected(r['email'])}")

    # Every explicit domain rule actually landed on its target company.
    for host_rule, rule in d["domain_moves"].items():
        if "create" in rule:
            want, names = (rule["id"] if rule.get("id") in st.companies else None), {rule["create"]}
        else:
            want, names = st.resolve(rule["to"], required=False), set()
        for r in st.recruiters:
            h = contact_domain(r)
            if h == host_rule or (h and registrable(h) == host_rule):
                cid = r["company_id"]
                if cid != want and st.companies[cid]["name"] not in names:
                    violations.append(f"{r['email']} is under {st.companies[cid]['name']!r}, "
                                      f"but the rule for {host_rule} says {rule.get('create') or rule.get('to')!r}")

    if d.get("personal_contacts", {}).get("action") == "delete":
        for r in st.recruiters:
            dom = contact_domain(r)
            if dom and is_personal(dom) and r["company_id"] not in test_ids:
                if st.sends[r["id"]]:
                    warnings.append(f"personal contact {r['email']} kept: it has {st.sends[r['id']]} send(s)")
                else:
                    violations.append(f"personal contact {r['email']} should have been deleted")

    for r in st.recruiters:
        if contact_domain(r) in dead_hosts() and r["company_id"] not in test_ids:
            if st.sends[r["id"]]:
                warnings.append(f"{r['email']} is on a dead domain but kept: it has sends")
            else:
                violations.append(f"{r['email']} is on a domain that can't receive mail")

    if any("domains" in c for c in st.companies.values()):
        listed = collections.defaultdict(list)
        for cid, c in st.companies.items():
            for h in c.get("domains") or []:
                listed[h].append(c["name"])
                if is_personal(h):
                    violations.append(f"{c['name']!r} lists personal domain {h}")
                elif h in dead_hosts():
                    violations.append(f"{c['name']!r} lists dead domain {h}")
                elif h in d["typo_domains"]:
                    violations.append(f"{c['name']!r} lists typo domain {h}")
                elif registrable(h) in relay and not is_agency_itself(c["name"], h):
                    violations.append(f"{c['name']!r} lists recruiting-agency domain {h}")
        for h, names in listed.items():
            if len(names) > 1:
                violations.append(f"domain {h} is listed on several companies: {names}")
        for r in st.recruiters:
            h = contact_domain(r)
            c = st.companies.get(r["company_id"])
            if (h and c and r["company_id"] not in test_ids and not is_personal(h)
                    and h not in d["typo_domains"] and h not in dead_hosts() and registrable(h) not in relay
                    and h not in (c.get("domains") or [])):
                violations.append(f"{c['name']!r} doesn't list {h}, which its contact {r['email']} uses")

    for n in d["junk_companies"]:
        cid = st.resolve(n, required=False)
        if cid and not st.company_sends(cid):
            violations.append(f"junk company {n!r} still present")

    def key(n):
        n = re.sub(r"\(.*?\)", "", n.lower()).replace("&", " and ")
        n = re.sub(r"[^a-z0-9 ]", " ", n.replace("'", ""))
        n = re.sub(r"\b(ltd|limited|pvt|private|inc|llc|llp|plc|corp|corporation|company|co|"
                   r"technologies|technology|tech|solutions|services|group|india|global|the)\b", " ", n)
        return re.sub(r"\s+", "", n)
    keys = collections.defaultdict(list)
    for c in st.companies.values():
        keys[key(c["name"])].append(c["name"])
    distinct = {frozenset(p[:2]) for p in d.get("distinct_companies", [])}
    for k, names in keys.items():
        if len(names) > 1 and frozenset(names) not in distinct:
            warnings.append(f"similar company names: {names}")

    for cid, c in st.companies.items():
        rs = st.by_company[cid]
        if rs and cid not in test_ids and "(Personal Email)" not in c["name"] and all(
                (contact_domain(r) and is_personal(contact_domain(r))) for r in rs):
            warnings.append(f"company {c['name']!r} has only personal-mailbox contacts ({len(rs)})")
    return violations, warnings


# ----------------------------------------------------------------------------
# Outputs

def domain_map(st):
    """domain (host) -> company, with the DB details that matter."""
    d = DECISIONS
    test_ids = {st.resolve(n, required=False) for n in d["test_companies"]} - {None}
    rows = collections.OrderedDict()
    agg = collections.defaultdict(lambda: {"contacts": 0, "valid": 0, "sends": 0, "ids": set()})
    for r in st.recruiters:
        dom = contact_domain(r) or "(malformed)"
        a = agg[(dom, r["company_id"])]
        a["contacts"] += 1
        a["valid"] += 1 if r.get("is_valid", True) else 0
        a["sends"] += st.sends[r["id"]]
    for (dom, cid), a in sorted(agg.items()):
        reg = registrable(dom) if dom != "(malformed)" else ""
        if dom == "(malformed)":
            kind = "malformed"
        elif is_personal(dom):
            kind = "personal"
        elif reg in d["relay_domains"]:
            kind = "relay"
        elif dom in d["typo_domains"]:
            kind = "typo"
        elif cid in test_ids:
            kind = "test"
        elif reg in d["unresolved"]:
            kind = "unresolved"
        else:
            kind = "work"
        c = st.companies[cid]
        rows[(dom, cid)] = {
            "domain": dom, "registrable_domain": reg, "kind": kind,
            "company_id": cid, "company": c["name"], "sector": c.get("sector") or "",
            "contacts": a["contacts"], "valid_contacts": a["valid"], "sends": a["sends"],
            "tracked_by": ";".join(sorted(u for _, u in st.tracked[cid])),
            "note": d["relay_domains"].get(reg) or d["unresolved"].get(reg, ""),
        }
    return list(rows.values())


def write_outputs(out, st, plan=None, violations=(), warnings=(), label=""):
    out.mkdir(parents=True, exist_ok=True)
    dm = domain_map(st)
    with open(out / "domain_map.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(dm[0]))
        w.writeheader()
        w.writerows(dm)
    (out / "domain_map.json").write_text(json.dumps(dm, indent=1, ensure_ascii=False))

    # companies.domains holds exact mail hosts (the app looks a company up by
    # `domains cs.{host}`), so ext.airbnb.com belongs there. What must not be
    # there: an agency's domain on a client, or a typo domain.
    relay, typo = set(DECISIONS["relay_domains"]), DECISIONS["typo_domains"]
    lines = ["-- Remove recruiting-agency and typo domains from companies.domains.",
             "-- An agency's domain stays only on the agency's own company.", "begin;"]
    for cid, c in sorted(st.companies.items(), key=lambda kv: kv[1]["name"].lower()):
        for dom in c.get("domains") or []:
            agency = registrable(dom) in relay and c["name"].lower() != registrable(dom).split(".")[0]
            if agency or dom in typo:
                why = "recruiting agency" if agency else f"typo of {typo[dom]}"
                lines.append(f"update companies set domains = array_remove(domains, '{dom}') "
                             f"where id = '{cid}';  -- {c['name']}: {why}")
    lines.append("commit;")
    (out / "fix_company_domains.sql").write_text("\n".join(lines) + "\n")

    rep = [f"# Company verification — {label}", ""]
    kinds = collections.Counter(r["kind"] for r in dm)
    reg_work = {r["registrable_domain"] for r in dm if r["kind"] == "work"}
    rep += [f"- companies: {len(st.companies)}; contacts: {len(st.recruiters)}; "
            f"mail sends: {len(st.tables['mail_sends'])}",
            f"- work domains (registrable): {len(reg_work)}; host rows by kind: {dict(kinds)}",
            f"- invariant violations: {len(violations)}; warnings: {len(warnings)}", ""]
    if plan:
        rep += plan_summary(st, plan)
    rep += ["## Invariant violations", ""] + [f"- {v}" for v in violations] + ["", "## Warnings", ""]
    rep += [f"- {w}" for w in warnings] + [""]
    rep += ["## Unresolved domains (left as filed)", ""]
    rep += [f"- `{k}` — {v}" for k, v in DECISIONS["unresolved"].items()] + [""]
    (out / "report.md").write_text("\n".join(rep))


def plan_summary(st, plan):
    nm = lambda cid: plan["creates"][cid]["name"] if cid in plan["creates"] else name_of(st, cid, plan["renames"], {}, {})
    lines = ["## Plan", ""]
    lines.append(f"- create companies: {[c['name'] for c in plan['creates'].values()]}")
    lines.append(f"- personal-mailbox contacts deleted: {len(plan.get('delete_personal', []))}; "
                 f"held because mail was sent: {len(plan.get('held_personal', []))}")
    lines.append(f"- typo addresses corrected: {len(plan.get('rewrite_emails', []))}; "
                 f"typo contacts restored corrected: {len(plan.get('restore_contacts', []))}")
    lines.append(f"- contacts on dead domains deleted: {len(plan.get('delete_dead', []))}; "
                 f"held because mail was sent: {len(plan.get('held_dead', []))}")
    lines.append(f"- companies emptied by deletions (deleted): {len(plan.get('delete_emptied', []))}")
    lines.append(f"- companies whose domains change: {len(plan.get('domains', {}))}")
    lines.append(f"- contacts moved: {sum(len(v) for v in plan['moves'].values())}")
    lines.append(f"- companies folded into another: {len(plan['delete_companies'])}")
    lines.append(f"- junk companies deleted: {len(plan['delete_junk'])}")
    lines.append(f"- renames: {len(plan['renames'])}; sectors filled: {len(plan['sectors'])}")
    lines.append(f"- tracked rows moved: {len(plan['tracking'])}")
    lines += ["", "### Folded companies", ""]
    for cid in plan["delete_companies"]:
        tgt = plan["fold_into"][cid]
        lines.append(f"- {st.companies[cid]['name']} ({len(st.by_company[cid])} contacts, "
                     f"{st.company_sends(cid)} sends) → **{nm(tgt)}** — {plan['why'].get(cid, '')}")
    lines += ["", "### Renames", ""]
    for cid, new in sorted(plan["renames"].items(), key=lambda kv: kv[1].lower()):
        old = st.companies[cid]["name"] if not cid.startswith("new:") else "(new)"
        lines.append(f"- {old} → {new}")
    lines += ["", "### Contacts moved individually (not part of a company merge)", ""]
    for r, src, tgt, reason in plan["_stray"]:
        lines.append(f"- {r['email']}: {st.companies[src]['name']} → {nm(tgt)} ({reason})")
    lines += ["", "### Junk deleted", ""]
    for cid in plan["delete_junk"]:
        lines.append(f"- {st.companies[cid]['name']}: {[r['email'] for r in st.by_company[cid]]} — "
                     f"{DECISIONS['junk_companies'][st.companies[cid]['name']]}")
    lines += ["", "### Tracked rows moved", ""]
    for t in plan["tracking"]:
        lines.append(f"- {t['table']} {t['user_email']}: {st.companies[t['from']]['name']} → {nm(t['to'])}"
                     + ("" if t["insert"] else " (already tracked there)"))
    lines += ["", "### Personal contacts held (they have send history)", ""]
    rmap = {r["id"]: r for r in st.recruiters}
    for rid in plan.get("held_personal", []):
        r = rmap[rid]
        lines.append(f"- {r['email']} ({st.companies[r['company_id']]['name']}, {st.sends[rid]} send(s))")
    lines += ["", "### Typo addresses corrected / restored", ""]
    lines += [f"- {x['from']} → {x['to']}" for x in plan.get("rewrite_emails", [])]
    lines += [f"- restored: {x['email']} → {nm(x['company_id'])}" for x in plan.get("restore_contacts", [])]
    lines += ["", "### Contacts on dead domains deleted", ""]
    for rid in plan.get("delete_dead", []):
        r = rmap[rid]
        lines.append(f"- {r['email']} ({st.companies[r['company_id']]['name']}) — {DECISIONS['dead_domains'][contact_domain(r)]}")
    lines += ["", "### Companies emptied by deletions (deleted)", ""]
    lines += [f"- {st.companies[c]['name']}" for c in plan.get("delete_emptied", [])]
    lines += ["", "### Domain list changes", ""]
    for cid, doms in sorted(plan.get("domains", {}).items(), key=lambda kv: nm(kv[0]).lower()):
        old = [] if cid.startswith("new:") else (st.companies[cid].get("domains") or [])
        lines.append(f"- {nm(cid)}: -{sorted(set(old) - set(doms))} +{sorted(set(doms) - set(old))}")
    for n in plan["notes"]:
        lines.append(f"- NOTE: {n}")
    return lines + [""]


# ----------------------------------------------------------------------------
# Apply

def chunks(xs, n=100):
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def apply(st, plan):
    ids = dict()  # placeholder -> real id
    for key, spec in plan["creates"].items():
        body = {"name": spec["name"], **({"id": spec["id"]} if spec.get("id") else {})}
        row = supabase.write("POST", "companies", body=body)[0]
        ids[key] = row["id"]
        print(f"  created {spec['name']} -> {row['id']}" + (" (original id restored)" if spec.get("id") else ""))
    real = lambda cid: ids.get(cid, cid)

    for tgt, rids in plan["moves"].items():
        for part in chunks(rids):
            got = supabase.write("PATCH", "recruiters", {"id": supabase.in_filter(part)},
                                 {"company_id": real(tgt)})
            assert len(got) == len(part), f"moved {len(got)} of {len(part)} into {tgt}"
    print(f"  moved {sum(len(v) for v in plan['moves'].values())} contacts")

    for x in plan.get("rewrite_emails", []):
        clash = [c for c in supabase.get("recruiters", {"email": ilike_exact(x["to"])}, select="id") if c["id"] != x["id"]]
        if clash:
            raise SystemExit(f"refusing to rewrite {x['from']}: {x['to']} already exists")
        got = supabase.write("PATCH", "recruiters", {"id": f"eq.{x['id']}"}, {"email": x["to"], "is_valid": True})
        assert len(got) == 1, f"no row for {x['from']}"
    print(f"  corrected {len(plan.get('rewrite_emails', []))} typo addresses")
    for row in plan.get("restore_contacts", []):
        if supabase.get("recruiters", {"email": ilike_exact(row["email"])}, select="id"):
            raise SystemExit(f"refusing to restore {row['email']}: it already exists")
        supabase.write("POST", "recruiters", body=row, prefer="return=minimal")
    print(f"  restored {len(plan.get('restore_contacts', []))} typo contacts with corrected addresses")

    for t in plan["tracking"]:
        if t["insert"]:
            row = {"user_email": t["user_email"], "company_id": real(t["to"])}
            supabase.write("POST", t["table"], body=row, prefer="return=minimal")
        supabase.write("DELETE", t["table"], {"user_email": f"eq.{t['user_email']}",
                                              "company_id": f"eq.{t['from']}"}, prefer="return=minimal")
    print(f"  moved {len(plan['tracking'])} tracked rows")

    # Personal and dead-domain contacts: deleting one cascades to its sends, so
    # re-check at delete time that none has any (the plan held those that did).
    for part in chunks(plan.get("delete_personal", []) + plan.get("delete_dead", [])):
        sent = supabase.get("mail_sends", {"recruiter_id": supabase.in_filter(part)}, select="id")
        if sent:
            raise SystemExit(f"refusing to delete contacts: {len(sent)} sends appeared since planning")
        supabase.write("DELETE", "recruiters", {"id": supabase.in_filter(part)}, prefer="return=minimal")
    print(f"  deleted {len(plan.get('delete_personal', []))} personal-mailbox contacts, "
          f"{len(plan.get('delete_dead', []))} contacts on dead domains")

    # Deleting a company cascades to its contacts and their sends: refuse
    # unless the DB confirms it's empty and untracked right now.
    for cid in plan["delete_companies"] + plan.get("delete_emptied", []):
        left = supabase.get("recruiters", {"company_id": f"eq.{cid}"}, select="id")
        tracked = (supabase.get("tracked_companies", {"company_id": f"eq.{cid}"}, select="user_email")
                   + supabase.get("user_companies", {"company_id": f"eq.{cid}"}, select="user_email"))
        if left or tracked:
            raise SystemExit(f"refusing to delete {st.companies[cid]['name']}: "
                             f"{len(left)} contacts, {len(tracked)} tracked rows remain")
        supabase.write("DELETE", "companies", {"id": f"eq.{cid}"}, prefer="return=minimal")
    print(f"  deleted {len(plan['delete_companies'])} folded companies, "
          f"{len(plan.get('delete_emptied', []))} emptied companies")

    for cid in plan["delete_junk"]:
        rids = [r["id"] for r in st.by_company[cid]]
        sent = supabase.get("mail_sends", {"recruiter_id": supabase.in_filter(rids)}, select="id") if rids else []
        if sent:
            raise SystemExit(f"refusing to delete junk {st.companies[cid]['name']}: it has sends")
        if rids:
            supabase.write("DELETE", "recruiters", {"id": supabase.in_filter(rids)}, prefer="return=minimal")
        supabase.write("DELETE", "companies", {"id": f"eq.{cid}"}, prefer="return=minimal")
    print(f"  deleted {len(plan['delete_junk'])} junk companies")

    for cid, name in plan["renames"].items():
        if cid.startswith("new:"):
            continue
        supabase.write("PATCH", "companies", {"id": f"eq.{real(cid)}"}, {"name": name},
                       prefer="return=minimal")
    print(f"  renamed {len(plan['renames'])} companies")
    for cid, sector in plan["sectors"].items():
        supabase.write("PATCH", "companies", {"id": f"eq.{real(cid)}"}, {"sector": sector},
                       prefer="return=minimal")
    print(f"  filled {len(plan['sectors'])} sectors")
    for cid, doms in plan.get("domains", {}).items():
        supabase.write("PATCH", "companies", {"id": f"eq.{real(cid)}"}, {"domains": doms},
                       prefer="return=minimal")
    print(f"  updated domains on {len(plan.get('domains', {}))} companies")


def simulate(st, plan):
    """The tables as they'd be after `apply`, computed locally (dry runs)."""
    import copy
    t = copy.deepcopy(st.tables)
    for key, spec in plan["creates"].items():
        t["companies"].append({"id": key, "name": spec["name"], "sector": None, "domains": []})
    dest = {rid: tgt for tgt, rids in plan["moves"].items() for rid in rids}
    junk = set(plan["delete_junk"])
    gone_contacts = set(plan.get("delete_personal", [])) | set(plan.get("delete_dead", []))
    t["recruiters"] = [r for r in t["recruiters"] if r["company_id"] not in junk and r["id"] not in gone_contacts]
    fix = {x["id"]: x["to"] for x in plan.get("rewrite_emails", [])}
    t["recruiters"] += [dict(x) for x in plan.get("restore_contacts", [])]
    for r in t["recruiters"]:
        r["company_id"] = dest.get(r["id"], r["company_id"])
        if r["id"] in fix:
            r["email"], r["is_valid"] = fix[r["id"]], True
    for mv in plan["tracking"]:
        rows = t[mv["table"]]
        rows[:] = [x for x in rows if not (x["user_email"] == mv["user_email"] and x["company_id"] == mv["from"])]
        if mv["insert"]:
            rows.append({"user_email": mv["user_email"], "company_id": mv["to"]})
    gone = set(plan["delete_companies"]) | junk | set(plan.get("delete_emptied", []))
    t["companies"] = [c for c in t["companies"] if c["id"] not in gone]
    for c in t["companies"]:
        c["name"] = plan["renames"].get(c["id"], c["name"])
        c["sector"] = plan["sectors"].get(c["id"], c["sector"])
        if c["id"] in plan.get("domains", {}):
            c["domains"] = plan["domains"][c["id"]]
    return t


def conservation(before, after, plan):
    """What must be unchanged by the apply, row for row."""
    problems = []
    junk_contacts = {r["id"] for cid in plan["delete_junk"] for r in before.by_company[cid]}
    b_ids = ({r["id"] for r in before.recruiters} - junk_contacts
             - set(plan.get("delete_personal", [])) - set(plan.get("delete_dead", [])))
    b_ids |= {x["id"] for x in plan.get("restore_contacts", [])}
    a_ids = {r["id"] for r in after.recruiters}
    if b_ids != a_ids:
        problems.append(f"contacts changed: lost {len(b_ids - a_ids)}, gained {len(a_ids - b_ids)}")
    b_s = {m["id"] for m in before.tables["mail_sends"]}
    a_s = {m["id"] for m in after.tables["mail_sends"]}
    if b_s != a_s:
        problems.append(f"mail_sends changed: lost {len(b_s - a_s)}, gained {len(a_s - b_s)}")
    after_comp = {r["id"]: r["company_id"] for r in after.recruiters}
    for m in after.tables["mail_sends"]:
        if m["recruiter_id"] not in after_comp:
            problems.append(f"send {m['id']} lost its contact")
    # Every user still tracks the company (or its successor) they tracked before.
    fold = plan["fold_into"]
    a_track = {(t["user_email"], t["company_id"]) for t in after.tables["tracked_companies"]}
    for t in before.tables["tracked_companies"]:
        cid = fold.get(t["company_id"], t["company_id"])
        if not cid.startswith("new:") and (t["user_email"], cid) not in a_track:
            problems.append(f"{t['user_email']} lost tracking of {before.companies[t['company_id']]['name']}")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", help="verify a backup directory instead of the live DB")
    ap.add_argument("--apply", action="store_true", help="back up, apply the plan, re-verify")
    ap.add_argument("--out", default=str(REPO / "data_verification"))
    ap.add_argument("--restore-typos-from", metavar="BACKUP",
                    help="restore typo-domain contacts deleted since this backup, with corrected addresses")
    args = ap.parse_args()
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = Path(args.out) / stamp

    if args.apply and args.snapshot:
        raise SystemExit("--apply works on the live DB; drop --snapshot")
    if args.apply:
        print("backing up before any change…")
        snap = backup_mod.backup(label="-pre-verification")
        before = State(load_snapshot(snap))
    else:
        before = State(load_snapshot(args.snapshot) if args.snapshot else load_live())

    restore_rows = (json.loads((Path(args.restore_typos_from) / "recruiters.json").read_text())
                    if args.restore_typos_from else ())
    plan = build_plan(before, restore_rows)
    plan["domains"] = domain_ops(State(simulate(before, plan)))
    v, w = verify(before)
    write_outputs(out / "before", before, plan, v, w, "before")
    serial = {k: v for k, v in plan.items() if not k.startswith("_")}
    (out / "plan.json").write_text(json.dumps(serial, indent=1, ensure_ascii=False))
    print(f"before: {len(v)} violations, {len(w)} warnings; plan -> {out}")

    sim = State(simulate(before, plan))
    sv, sw = verify(sim)
    names = collections.Counter(c["name"] for c in sim.companies.values())
    sv += [f"two companies would be named {n!r}" for n, k in names.items() if k > 1]
    write_outputs(out / "simulated_after", sim, None, sv, sw, "simulated after")
    print(f"simulated after: {len(sv)} violations, {len(sw)} warnings")
    for p in sv:
        print("  !", p)
    if not args.apply:
        return
    if sv:
        raise SystemExit("the plan doesn't reach a clean state; not applying")

    print("applying…")
    apply(before, plan)
    print("re-reading and verifying…")
    after = State(load_live())
    v2, w2 = verify(after)
    cons = conservation(before, after, plan)
    write_outputs(out / "after", after, None, v2 + cons, w2, "after")
    snap_after = backup_mod.backup(label="-post-verification")
    print(f"after: {len(v2)} violations, {len(cons)} conservation problems, {len(w2)} warnings")
    for p in v2 + cons:
        print("  !", p)
    sys.exit(1 if v2 or cons else 0)


if __name__ == "__main__":
    main()
