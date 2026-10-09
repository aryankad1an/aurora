"""Person-name pass: a contact's name is read off its address only when the
address spells it out, and nothing is guessed.

    python3 verify_names.py                  # dry run against the live DB
    python3 verify_names.py --snapshot DIR   # dry run against a backup
    python3 verify_names.py --apply          # back up, apply, re-verify

The same rule as the app's `RecipientName`:

- An address names someone only when its mailbox separates a given name from
  the rest: `anjali.kumari`, `anjali_kumari`, `rahul.k` -> "Anjali Kumari",
  "Rahul K". The given name must be its own part, at least three letters with
  a vowel in it. A glued mailbox (`akushwah`, `nehamathur`), a lone word
  (`rahul`), initials first (`pm.singh`) and leetspeak (`talk2saravanan`)
  name no one: there is no telling where one name ends and the next begins.
- A role mailbox (`careers@`, `hr.team@`) is named "Team", as the account
  owner asked.
- A name field that is only the mailbox copied over ("Akushwah" for
  `akushwah@`) is replaced by what the address spells out, or emptied: empty
  is the "name not detected" state, and the app says so. A name written as a
  name ("Neha Mathur", "A Kushwah") is never touched; nothing here can tell a
  person's from an importer's.
- A stored greeting is a person's word (the app's Add Name, or a source such
  as a recruiter sheet naming `parag@` "Parag"): it is kept, and it confirms a
  one-word name that matches it. Since 2026-10-09 nothing derived is stored —
  the app works the greeting out from the name, a signed reply and the
  account's own mail — so only a fragment or a role word on a person is
  cleared.
"""
import argparse
import collections
import csv
import datetime
import re
import sys

import backup as backup_mod
import supabase
from verify_companies import DECISIONS, REPO, load_live, load_snapshot

# The same lists as `RecipientName.roleWords` / `fillerWords` in the app.
ROLE = {
    "hr", "info", "jobs", "job", "careers", "career", "recruiting", "recruitment", "recruiter",
    "recruiters", "talent", "hiring", "contact", "hello", "team", "admin", "support", "apply",
    "applications", "resume", "resumes", "cv", "office", "people", "staffing", "internships",
    "internship", "campus", "noreply", "ta", "talentacquisition", "corporatehr", "hrd", "hrteam",
    "placement", "placements", "operations", "dl", "mailer", "enquiry", "enquiries", "sales",
    "backend", "frontend", "engineering", "tech", "india", "global", "services", "connect",
    "reachouts", "outreach", "partnerships", "partner", "business", "marketing", "ops",
}
NOISE = {"here", "official", "work", "mail", "me", "the", "real", "its", "im", "iam", "mr", "ms", "dr"}
# Two-letter given names: a greeting this short can still be a person's.
SHORT_NAMES = {"om", "qi", "li", "yu", "bo", "jo", "al", "ed", "ai", "su", "ji", "yi", "xu", "wu", "lu", "ye", "ko"}


def tokens(local):
    local = local.split("+", 1)[0].lower()
    return [t for t in re.split(r"[^a-z]+", local) if t]


def title(t):
    return t[:1].upper() + t[1:]


def letters(s):
    return re.sub(r"[^a-z]", "", (s or "").lower())


def address_name(email):
    """(name, greeting) the address spells out, ("Team", "Team") for a role
    mailbox, or (None, None) when it names no one with certainty."""
    local, _, domain = (email or "").lower().strip().partition("@")
    local = local.split("+", 1)[0]
    if not local:
        return None, None
    words = tokens(local)
    if local in ROLE:
        return "Team", "Team"
    if re.search(r"[a-z]\d+[a-z]", local):  # leetspeak, not a separator
        return None, None
    labels = set(domain.split("."))
    people = [w for w in words if w not in ROLE and w not in NOISE and w not in labels]
    given = people[0] if people else ""
    if len(people) >= 2 and len(given) >= 3 and re.search(r"[aeiouy]", given):
        return " ".join(title(w) if len(w) > 1 else w.upper() for w in people), title(given)
    if any(w in ROLE or w in labels for w in words):  # a role, or the company's own name
        return "Team", "Team"
    return None, None


def is_mailbox_copy(name, email):
    """One word with the mailbox's letters: an importer's copy, not a name."""
    name = (name or "").strip()
    return bool(name) and not re.search(r"\s", name) and letters(name) == letters(email.split("@")[0])


def machine_greeting(greet, name):
    """A stored greeting no person would choose."""
    g = letters(greet)
    return bool(g) and ((len(g) <= 2 and g not in SHORT_NAMES) or (g in ROLE and name != "Team"))


def review(tables):
    test_ids = {c["id"] for c in tables["companies"] if c["name"] in DECISIONS["test_companies"]}
    names = {c["id"]: c["name"] for c in tables["companies"]}
    fixes = []
    for r in tables["recruiters"]:
        if r["company_id"] in test_ids:
            continue
        email = r["email"] or ""
        name, greet = (r["name"] or "").strip(), (r.get("greeting_name") or "").strip()
        new, why = {}, []
        confirmed = bool(greet) and letters(greet) == letters(name)
        if not name or (is_mailbox_copy(name, email) and not confirmed):
            d_name, _ = address_name(email)
            target = d_name or ""
            if target != name:
                new["name"] = target
                why.append(f"name {name or '(none)'!r} -> {target or '(not detected)'!r}")
        if greet and machine_greeting(greet, new.get("name", name)):
            new["greeting_name"] = None
            why.append(f"greeting {greet!r} cleared")
        if new:
            fixes.append({"id": r["id"], "email": email, "company": names.get(r["company_id"]),
                          "old_name": r["name"], "old_greeting": r.get("greeting_name"),
                          **{f"new_{k}": v for k, v in new.items()}, "why": "; ".join(why)})
    return fixes


def write(out, fixes, label):
    out.mkdir(parents=True, exist_ok=True)
    keys = sorted({k for r in fixes for k in r}, key=lambda k: (k != "email", k)) if fixes else ["email"]
    with open(out / "name_fixes.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(fixes)
    by = collections.Counter(
        ("name -> address" if f.get("new_name") else "name -> not detected") if "new_name" in f else "greeting only"
        for f in fixes)
    rep = [f"# Name pass — {label}", "", f"- fixes: {len(fixes)} ({dict(by)})", ""]
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
    fixes = review(tables)
    write(out / "before", fixes, "before")
    if not args.apply:
        return
    apply(fixes)
    after = load_live()
    left = review(after)
    write(out / "after", left, "after")
    if left:
        sys.exit(f"{len(left)} rows still need fixing after apply")
    if {r["id"] for r in tables["recruiters"]} != {r["id"] for r in after["recruiters"]}:
        sys.exit("contact set changed during the name pass")
    backup_mod.backup(label="-post-names")


if __name__ == "__main__":
    main()
