"""Person-name pass: derive who a mailbox belongs to from its address, and fix
stored names/greetings only where the derivation is confident and what's
stored is clearly worse.

    python3 verify_names.py                  # dry run against the live DB
    python3 verify_names.py --snapshot DIR   # dry run against a backup
    python3 verify_names.py --apply          # back up, apply, re-verify

Names can't be derived perfectly from addresses, so this pass is deliberately
conservative:

- The name lexicon is learned from this catalog itself: every `first.last`
  address teaches a given name and a surname. That lets a glued mailbox like
  `akushwah` split into "A Kushwah" and `manojkrishna` into "Manoj Krishna".
- A change is made only when confidence is HIGH and the stored value is
  missing, a role word on a personal mailbox, a one- or two-letter fragment,
  or the unsplit mailbox itself ("Akushwah"). A human-entered name is never
  overwritten; a stored name that contradicts a clean `first.last` address is
  reported for review instead.
- Greetings follow the app's `RecipientName` rules (initials fall through to
  the surname), and role mailboxes get "Team", as the account owner asked.
- Where the address can't be read with confidence, the greeting is left
  empty rather than guessed, and the app opens the mail with a bare "Hi,".
  A stored greeting that is only the mailbox copied over by an importer
  ("Talk2saravanan") or a one- or two-letter fragment is cleared; one a
  person typed is kept.
- Where the `first.last` lexicon isn't sure, the app's own greeting classifier
  (`scripts/names`) gets a say, taught every name field in this catalog first:
  a row with no usable name and no greeting gets the greeting it is sure of
  ("Arijit Sen" elsewhere in the catalog lets `arijit@` be greeted Arijit).
  The app would reach the same greeting itself only if it had loaded those
  other rows; storing it here makes it hold for every client.
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
from domains import brand
from verify_companies import DECISIONS, REPO, load_live, load_snapshot

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "names"))
import name_model  # noqa: E402  the app's greeting classifier, reference implementation

_MODEL = None


def classifier(recruiters):
    """The app's greeting classifier, taught every name field in the catalog."""
    global _MODEL
    if _MODEL is None:
        _MODEL = name_model.NameModel()
    _MODEL.learn([w for w in (name_model.name_words(r.get("name"), r.get("email")) for r in recruiters) if w])
    return _MODEL

ROLE = {
    "hr", "info", "jobs", "job", "careers", "career", "recruiting", "recruitment", "recruiter",
    "recruiters", "talent", "hiring", "contact", "hello", "team", "admin", "support", "apply",
    "applications", "resume", "resumes", "cv", "office", "people", "staffing", "internships",
    "internship", "campus", "noreply", "ta", "talentacquisition", "corporatehr", "hrd", "hrteam",
    "placement", "placements", "operations", "dl", "mailer", "enquiry", "enquiries", "sales",
    "backend", "frontend", "engineering", "tech", "india", "global", "services", "connect",
    "reachouts", "outreach", "partnerships", "partner", "business", "marketing", "ops",
}
# Words that carry no name when glued to one ("vijayhere", "connect.vinay2010").
# Two-letter given names, so "om_sourabh" greets Om rather than reading "om" as initials.
SHORT_NAMES = {"om", "qi", "li", "yu", "bo", "jo", "al", "ed", "ai", "su", "ji", "yi", "xu", "wu", "lu", "ye", "ko"}
NOISE = {"here", "official", "work", "mail", "me", "the", "real", "its", "im", "iam", "mr", "ms", "dr"}


def tokens(local):
    local = local.split("+", 1)[0].lower()
    return [t for t in re.split(r"[._\-0-9]+", local) if t]


class Lexicon:
    """Given names and surnames, learned from clean `first.last` addresses."""

    def __init__(self, recruiters):
        self.first, self.last = collections.Counter(), collections.Counter()
        for r in recruiters:
            local = (r["email"] or "").split("@")[0]
            ts = tokens(local)
            if len(ts) == 2 and re.fullmatch(r"[a-z]+[._\-][a-z]+\d*", local.lower()) \
                    and all(len(t) >= 3 for t in ts) and not (set(ts) & ROLE):
                self.first[ts[0]] += 1
                self.last[ts[1]] += 1

    def is_first(self, t, n=3):
        return self.first[t] >= n

    def is_last(self, t, n=3):
        return self.last[t] >= n

    def split(self, s):
        """Best split of a glued mailbox, or None: [(parts), kind]."""
        best = None
        for i in range(1, len(s) - 2):
            a, b = s[:i], s[i:]
            if not self.is_last(b) or len(b) < 3:
                continue
            if a in SHORT_NAMES:
                score, kind = self.last[b], "first_last"
            elif len(a) <= 2:
                score, kind = self.last[b] * 0.5, "initials"
            elif self.is_first(a):
                score, kind = min(self.first[a], self.last[b]) * 2, "first_last"
            else:
                continue
            if best is None or score > best[0]:
                best = (score, [a, b], kind)
        return (best[1], best[2]) if best else None


def title(t):
    return t[:1].upper() + t[1:]


def derive(email, lex):
    """(name, greeting, confidence, how) the address supports."""
    local = (email or "").split("@")[0].split("+", 1)[0].lower()
    ts = tokens(local)
    if not ts:
        return None, None, "none", "empty mailbox"
    # Letters on both sides of a digit ("talk2saravanan", "vijaym_b4u") are
    # leetspeak, not separators: whatever the split, it's a guess.
    if re.search(r"[a-z]\d+[a-z]", local):
        return None, None, "low", "digits inside the name"

    # The company's own name in the mailbox ("bi.oracle@oracle.com") is a team.
    company = brand(email.split("@")[-1].lower()) if "@" in (email or "") else ""
    ts = [t for t in ts if t != company] or ts
    if company and len(ts) < len(tokens(local)) and len(ts) <= 1 and not (ts and lex.is_first(ts[0])):
        return "Team", "Team", "high", "company-name mailbox"

    def whole(t):  # seen as a complete given name or surname somewhere
        return lex.is_first(t, 1) or lex.is_last(t, 1)

    def personal(t):
        return len(t) >= 3 and (whole(t) or lex.split(t))

    # "ta.kumar": a short role word before a surname is initials; a longer one
    # is a given name ("job.thomas").
    if len(ts) == 2 and ts[0] in ROLE and lex.is_last(ts[1]):
        if len(ts[0]) <= 2:
            return f"{ts[0].upper()} {title(ts[1])}", title(ts[1]), "high", "initials + surname"
        return f"{title(ts[0])} {title(ts[1])}", title(ts[0]), "high", "separated"
    people = [t for t in ts if t not in ROLE]
    if len(people) < len(ts) and not any(personal(t) for t in people):
        return "Team", "Team", "high", "role mailbox"
    # Filler as its own part ("im_naren", "naren.official") carries no name.
    ts = [t for t in people if t not in NOISE] if any(personal(t) for t in people) else people
    if not ts:
        return None, None, "low", "no name in mailbox"

    def glued_given(t):  # "rakeshkumar" -> ("Rakesh", "Rakesh Kumar")
        sp = None if whole(t) else lex.split(t)
        if sp and sp[1] == "first_last":
            return title(sp[0][0]), f"{title(sp[0][0])} {title(sp[0][1])}"
        return title(t), title(t)

    if len(ts) >= 2:
        # "pm.singh": a two-letter lead that isn't a known given name is initials.
        is_initial = lambda t: len(t) == 1 or (len(t) == 2 and t not in SHORT_NAMES and not lex.is_first(t, 2))
        if is_initial(ts[0]) and all(is_initial(t) for t in ts[:-1]) and len(ts[-1]) >= 3:
            if not (whole(ts[-1]) or lex.split(ts[-1])):  # "vk_mms": no name to greet
                return None, None, "low", "initials + unknown word"
            greet, last = glued_given(ts[-1])
            if greet != last:  # "rk_rakeshkumar" -> "RK Rakesh Kumar", Hi Rakesh
                return " ".join(t.upper() for t in ts[:-1]) + " " + last, greet, "high", "initials + given name + surname"
            return " ".join(t.upper() for t in ts[:-1]) + " " + title(ts[-1]), title(ts[-1]), "high", "initials + surname"
        if len(ts[0]) >= 2:
            conf = "high" if lex.is_first(ts[0], 1) or len(ts[0]) >= 3 else "medium"
            name = " ".join(title(t) if len(t) > 1 else t.upper() for t in ts)
            return name, title(ts[0]), conf, "separated"
        # "a.kumar.s": initial first, surname in the middle.
        rest = [t for t in ts if len(t) >= 3]
        if rest:
            name = " ".join(title(t) if len(t) > 1 else t.upper() for t in ts)
            return name, title(rest[0]), "medium", "initial first"
        return None, None, "low", "only initials"
    s = ts[0]
    if lex.is_first(s) or (len(s) >= 5 and whole(s)):
        # A name seen whole elsewhere ("radhakrishnan", "rishiraj") isn't split.
        return title(s), title(s), "high", "known whole name"
    sp = lex.split(s)
    if sp:
        (a, b), kind = sp
        if kind == "initials":
            return f"{a.upper()} {title(b)}", title(b), "high", "initials + known surname"
        return f"{title(a)} {title(b)}", title(a), "high", "known given name + surname"
    for i in range(len(s) - 2, 2, -1):  # "vijayhere" -> Vijay
        if lex.is_first(s[:i], 5) and s[i:] in NOISE:
            return title(s[:i]), title(s[:i]), "high", "given name + filler"
    return title(s), None, "low", "unsplit mailbox"


def letters(s):
    return re.sub(r"[^a-z]", "", (s or "").lower())


def machine_greeting(greet, local):
    """A stored greeting no person chose: the mailbox itself, or a fragment."""
    g = letters(greet)
    return g == letters(local) or (len(g) <= 2 and g not in SHORT_NAMES)


def review(tables):
    lex = Lexicon(tables["recruiters"])
    model = classifier([r for r in tables["recruiters"]])
    test_ids = {c["id"] for c in tables["companies"] if c["name"] in DECISIONS["test_companies"]}
    names = {c["id"]: c["name"] for c in tables["companies"]}
    fixes, flags = [], []
    for r in tables["recruiters"]:
        if r["company_id"] in test_ids:
            continue
        name, greet = (r["name"] or "").strip(), (r.get("greeting_name") or "").strip()
        local = (r["email"] or "").split("@")[0]
        d_name, d_greet, conf, how = derive(r["email"], lex)
        # A name that is only the mailbox re-spaced ("Akhandelwal India") was
        # made by an importer, not a person, so the address outranks it.
        blob = bool(name) and letters(name) == letters(local)
        new = {}
        reason = []
        if conf == "high":
            if not name:
                new["name"], reason = d_name, reason + ["name was empty"]
            elif blob and d_name and d_name != name and d_name != "Team" and d_name.lower() != name.lower():
                new["name"], reason = d_name, reason + [f"importer name re-derived ({how})"]
            elif d_name == "Team" and name != "Team" and letters(name) in ROLE | {letters(local)}:
                new["name"], reason = "Team", reason + ["role mailbox"]
            target_greet = d_greet
            if "name" not in new and d_name != "Team":
                # Keep a human-entered name; greet by it the way the app would.
                target_greet = greet if greet and len(greet) > 2 and letters(greet) != letters(local) else None
                if target_greet is None and blob and d_greet:
                    target_greet = d_greet
            bad_greet = (not greet or (len(letters(greet)) <= 2 and letters(greet) not in SHORT_NAMES) or
                         (letters(greet) in ROLE and d_name != "Team") or
                         (letters(greet) == letters(local) and d_greet and letters(d_greet) != letters(greet)))
            if (bad_greet or "name" in new) and target_greet and target_greet != greet:
                new["greeting_name"] = target_greet
                reason.append(f"greeting {greet or '(none)'!r} -> {target_greet!r}")
        else:
            # The lexicon isn't sure; the classifier, with the catalog learned, may be.
            guess = None
            parts = name_model.mailbox_parts(r["email"]) if not name or blob else None
            if parts:
                guess, sure = model.greeting(parts)
            if guess and guess != greet and (not greet or machine_greeting(greet, local)):
                new["greeting_name"] = guess
                reason.append(f"greeting {greet or '(none)'!r} -> {guess!r} (classifier, {sure:.0%} sure)")
            elif greet and machine_greeting(greet, local):
                # Not sure who this is: greet no one rather than the mailbox.
                new["greeting_name"] = None
                reason.append(f"greeting {greet!r} cleared ({conf} confidence: {how})")
        # Names that disagree with a clean first.last address: report only.
        ts = tokens(local)
        if name and len(ts) == 2 and all(len(t) >= 3 for t in ts) and not (set(ts) & ROLE) \
                and not ({letters(w) for w in name.split()} & set(ts)) \
                and not any(t in letters(name) or letters(name)[:4] in t for t in ts):
            flags.append({"id": r["id"], "email": r["email"], "stored_name": name,
                          "address_says": " ".join(map(title, ts)), "company": names.get(r["company_id"])})
        if new:
            fixes.append({"id": r["id"], "email": r["email"], "company": names.get(r["company_id"]),
                          "old_name": r["name"], "old_greeting": r.get("greeting_name"),
                          **{f"new_{k}": v for k, v in new.items()}, "why": "; ".join(reason)})
    return fixes, flags, lex


def write(out, fixes, flags, lex, label):
    out.mkdir(parents=True, exist_ok=True)
    for fname, rows in (("name_fixes.csv", fixes), ("name_flags.csv", flags)):
        keys = sorted({k for r in rows for k in r}, key=lambda k: (k != "email", k)) if rows else ["email"]
        with open(out / fname, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)
    by = collections.Counter(re.sub(r" '.*", "", f["why"].split(";")[0]) for f in fixes)
    rep = [f"# Name pass — {label}", "",
           f"- lexicon: {len(lex.first)} given names, {len(lex.last)} surnames",
           f"- fixes: {len(fixes)} ({dict(by)})",
           f"- names contradicting a clean first.last address (review, not changed): {len(flags)}", ""]
    (out / "names_report.md").write_text("\n".join(rep))
    print("\n".join(rep))


def apply(fixes):
    for f in fixes:
        body = {k[4:]: v for k, v in f.items() if k.startswith("new_")}
        got = supabase.write("PATCH", "recruiters", {"id": f"eq.{f['id']}"}, body)
        assert len(got) == 1, f"no row for {f['email']}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    out = REPO / "data_verification" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-names")
    if args.apply:
        snap = backup_mod.backup(label="-pre-names")
        tables = load_snapshot(snap)
    else:
        tables = load_snapshot(args.snapshot) if args.snapshot else load_live()
    fixes, flags, lex = review(tables)
    write(out / "before", fixes, flags, lex, "before")
    if not args.apply:
        return
    apply(fixes)
    after = load_live()
    fixes2, flags2, lex2 = review(after)
    write(out / "after", fixes2, flags2, lex2, "after")
    before_ids = {r["id"] for r in tables["recruiters"]}
    if before_ids != {r["id"] for r in after["recruiters"]}:
        sys.exit("contact set changed during the name pass")
    backup_mod.backup(label="-post-names")


if __name__ == "__main__":
    main()
