# Fresher Hiring Ledger import

Loads the [Fresher Hiring Ledger](https://claude.ai/artifact/UE45ksFpQ3fg9EYNEMeMKk)
— companies that hire Indian B.Tech freshers, with the evidence for each — into
the shared catalog, and finds each company's logo and careers page on its own
website.

Run from this folder. Outputs go to `data_verification/fresher_ledger/` and
backups to `db_backups/` at the repo root; both are git-ignored.

```bash
# 0. Once: run migration.sql in the Supabase SQL editor (it's also in the main README).
# 1. Download companies.json from the ledger's data files.
# 2. Who to crawl: every ledger company's website, and the mail domain of every
#    catalog company the ledger doesn't cover. Then crawl them.
python3 ../company_verification/backup.py
python3 targets.py companies.json ../../db_backups/<stamp> targets.json
python3 crawl.py targets.json crawl.json --workers 48
python3 crawl.py targets_retry.json crawl_retry.json --workers 12 --desktop   # sites that refused
# 3. Dry run: writes plan.json and report.md. Read the report.
python3 import_ledger.py companies.json crawl.json
# 4. Back up, write, and re-read the catalog to check every ledger company landed.
python3 import_ledger.py companies.json crawl.json --apply
```

## Matching (`ledger.py`, `decisions.json`)

Each ledger company goes to at most one catalog company:

1. **Website** — the registrable domain of its website is one a catalog company
   lists in `domains` (the verification pass keeps one owner per domain).
2. **Contacts** — the domain is used by the contacts of exactly one company.
3. **Name** — the names agree once case, punctuation and legal suffixes are
   gone, *and* the catalog company doesn't list a different domain of its own.
   Same name, different domain is reported, never matched.
4. **By hand** — `decisions.json` `same` maps a ledger name to the catalog
   company it is when the two use different domains (Heinz is Kraft Heinz at
   hjheinz.com; Applied Materials mails from amat.com). `distinct` keeps apart
   ones that only look alike (GoTo is not GoTo Group).

Anything else is created as a new company with no contacts. Several ledger
companies can land on one catalog company when they share its mail domain
(L&T, L&T Energy and L&T PES): their routes, batches and roles are combined,
and every one's sources are kept, each with the ledger id it came from.

Catalog names made from a domain ("Sc", "Wbd", "Arcticwolf") take a proper name:
by hand in `decisions.json` `renames`, or automatically when the ledger's name is
the same letters with spaces or punctuation added. A real one-word name
("Micron", "Samsung") is never swapped for a longer one.

## What's written

| Column | From |
|---|---|
| `is_fresher`, `ledger_ids` | every matched or created ledger company |
| `website`, `website_source` | the ledger (Wikidata, a verified lookup, its careers page…); for other companies, their mail domain's homepage when it's a real site (stays on the domain or names the company, isn't parked) |
| `careers_url`, `careers_source` | the ledger; else a careers link on the homepage, on the company's own domain or a known applicant-tracking host, that answers. Student career-service pages are left out. |
| `logo_url` | the best square PNG the site offers as its icon (apple-touch-icon, PNG `<link rel=icon>`, manifest icon, /apple-touch-icon.png), downloaded and checked: a real PNG, at least 64 px, roughly square, not one flat colour |
| `company_type`, `route_category`, `hiring_routes`, `open_now`, `usually_opens`, `batches`, `fresher_roles` | the ledger |
| `company_sources` rows | each piece of ledger evidence |

Re-running is safe:

- Sources are keyed by a fingerprint and upserted, so they update in place, and
  `is_valid` is never written: a source someone marked invalid stays invalid.
- A source edited in the app (`edited_at` set) is left as edited.
- A website or careers link edited in the app (`*_source = 'edited'`) is left alone.
- Imported sources that have left the ledger are removed.
- Values already on a company the ledger doesn't cover are never overwritten.

## Merges in the verification pipeline

`company_verification/verify_companies.py` folds duplicate companies into one.
It now moves the folded company's sources and fresher details to the survivor
before deleting it, and refuses to delete a junk or emptied company that has
sources.
