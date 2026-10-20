"""Tests for import_people.py. Run from this folder:

    python3 -m unittest -v test_import_people

Made-up people and companies only. `plan` runs against a backup written to a
temporary folder, with plain (unsealed) contacts, so no key is needed.
"""
import csv
import io
import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import contacts
import import_people as ip

HEADER = ["Name", "Job Title", "Linkedin URL", "Company Name", "Status", "Applied for Internship/Job",
          "Company Website", "Company Linkedin", "Company Social", "Company Twitter", "Location", "Company Niche"]

COMPANIES = [
    {"id": "c-acme", "name": "Acme", "domains": ["acme.com"], "website": "https://acme.com", "sector": None,
     "also_known_as": [], "website_source": "mail_domain"},
    {"id": "c-getzap", "name": "Getzap", "domains": ["getzap.com"], "website": None, "sector": None,
     "also_known_as": [], "website_source": None},
    {"id": "c-peak", "name": "Peak", "domains": ["peak.ai"], "website": "https://peak.ai", "sector": None,
     "also_known_as": [], "website_source": "mail_domain"},
    {"id": "c-orbit", "name": "Orbit Labs", "domains": [], "website": None, "sector": "Enterprise software",
     "also_known_as": ["Orbit"], "website_source": "edited"},
]
RECRUITERS = [
    {"id": "r-1", "company_id": "c-acme", "name": "Neha Rao", "email": "neha.rao@acme.com", "position": None,
     "phone": None, "greeting_name": None, "is_valid": True},
]


def row(name, title, slug, company, site, location="Pune, India", niche="Information Technology & Services"):
    return [name, title, f"http://www.linkedin.com/in/{slug}", company, "", "FALSE", site, "", "", "", location, niche]


def review(**kw):
    base = dict(COMPANY={}, RENAME={}, ALIASES={}, SECTOR_FIX={}, NAME={}, SECTOR={}, DUPLICATES={}, SAME_NAME={},
                PERSON_COMPANY={}, LINKS={})
    base.update(kw)
    return types.SimpleNamespace(**base)


class Parsing(unittest.TestCase):
    def test_person_names(self):
        self.assertEqual(ip.person_name("Asha Verma She/Her"), "Asha Verma")
        self.assertEqual(ip.person_name("  Dr.  Ravi   Menon "), "Ravi Menon")
        self.assertEqual(ip.person_name("Kiran (he/him)"), "Kiran")
        self.assertEqual(ip.name_key("Ravi  K."), ip.name_key("ravi k"))

    def test_linkedin_links(self):
        self.assertEqual(ip.linkedin("http://www.linkedin.com/in/asha-verma-1a2b3c4d/"),
                         "https://www.linkedin.com/in/asha-verma-1a2b3c4d")
        self.assertEqual(ip.linkedin("in.linkedin.com/in/asha?trk=x"), "https://www.linkedin.com/in/asha")
        self.assertIsNone(ip.linkedin("https://www.linkedin.com/company/acme"))
        self.assertIsNone(ip.linkedin("https://example.com/in/asha"))

    def test_a_renamed_profile_keeps_its_key(self):
        a = ip.linkedin_key("https://www.linkedin.com/in/sai-k-5a15434a")
        b = ip.linkedin_key("https://www.linkedin.com/in/saicharan-kumar-5a15434a")
        self.assertEqual(a, b)
        self.assertNotEqual(ip.linkedin_key("https://www.linkedin.com/in/asha"),
                            ip.linkedin_key("https://www.linkedin.com/in/asha-verma"))

    def test_websites(self):
        self.assertEqual(ip.website("http://www.acme.com/"), ("https://www.acme.com", "acme.com"))
        self.assertEqual(ip.website("https://www.mpokket.in:443"), ("https://www.mpokket.in", "mpokket.in"))
        self.assertEqual(ip.website("http://www.linkedin.com/company/acme"), (None, None))
        self.assertEqual(ip.website("http://www.page.link/"), (None, None))
        self.assertEqual(ip.website(""), (None, None))

    def test_company_names(self):
        with mock.patch.object(ip, "R", review()):
            self.assertEqual(ip.company_name("Zap Finance Private Limited"), "Zap Finance")
            self.assertEqual(ip.company_name("Bolt Pvt. Ltd."), "Bolt")
            self.assertEqual(ip.company_name("Serosoft: A leading educational software company"), "Serosoft")
            self.assertEqual(ip.company_name("Knowlarity - Cloud Communications"), "Knowlarity")
            self.assertEqual(ip.company_name("Quantive (formerly Gtmhub)"), "Quantive")
            self.assertEqual(ip.company_name("ATCS Inc."), "ATCS")
            self.assertEqual(ip.company_name("Brick&Bolt"), "Brick&Bolt")

    def test_the_header_can_follow_a_banner(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "list.csv"
            with open(path, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["Get the full database at our site!"])
                w.writerow(HEADER)
                w.writerow(row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Acme", "http://www.acme.com/"))
            rows = ip.read_sheet(path)
            self.assertEqual(len(rows), 1)
            self.assertEqual((rows[0]["Name"], rows[0]["_row"]), ("Asha Verma", 3))


class Planning(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.snap = Path(self.dir.name) / "snap"
        self.snap.mkdir()
        tables = {t: [] for t in ("mail_sends", "profiles", "templates", "tracked_companies", "user_companies",
                                  "company_sources")}
        tables.update(companies=COMPANIES, recruiters=RECRUITERS)
        for t, rows in tables.items():
            (self.snap / f"{t}.json").write_text(json.dumps(rows))
        self.csv = Path(self.dir.name) / "list.csv"
        # Plain contacts: the backup has no vaults, so nothing needs a key.
        session = contacts.Session(api=mock.Mock(has_table=lambda t: False), environ={}, log=lambda m: None)
        self.patches = [mock.patch.object(contacts, "_session", session)]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.dir.cleanup()

    def plan(self, rows, **kw):
        with open(self.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(HEADER)
            w.writerows(rows)
        with mock.patch.object(ip, "R", review(**kw)):
            return ip.plan(self.csv, self.snap)

    def test_matches_by_domain_then_by_name_and_fills_only_what_is_missing(self):
        p = self.plan([
            row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Acme Corp", "http://www.acme.com/"),
            row("Kiran Das", "TA Lead", "kiran-das-2b3c4d5e", "Orbit", "http://www.orbit.io/"),
        ])
        self.assertEqual(p["decisions"]["Acme Corp"]["id"], "c-acme")
        self.assertEqual(p["decisions"]["Orbit"]["id"], "c-orbit")   # its also-known-as
        self.assertEqual(p["patches"]["c-acme"]["after"], {"sector": "Enterprise software"})
        # Orbit has a sector, and its website was edited by someone: left alone.
        self.assertNotIn("c-orbit", p["patches"])
        self.assertEqual([x["name"] for x in p["people"]], ["Asha Verma", "Kiran Das"])
        self.assertEqual(p["people"][0]["linkedin"], "https://www.linkedin.com/in/asha-verma-1a2b3c4d")
        self.assertEqual(p["simulated"]["new_violations"], [])

    def test_a_name_that_contradicts_the_domain_needs_a_decision(self):
        rows = [row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Peak", "http://www.peak.com/",
                    niche="Computer Games")]
        with self.assertRaises(SystemExit):
            self.plan(rows)
        p = self.plan(rows, COMPANY={"Peak": ("new", "Peak Games", "a different company")})
        self.assertEqual(p["creates"][0]["name"], "Peak Games")
        self.assertEqual(p["creates"][0]["sector"], "Gaming")
        self.assertEqual(p["creates"][0]["website"], "https://www.peak.com")

    def test_a_new_company_needs_a_sector(self):
        rows = [row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Bloom Learning", "http://bloom.example/",
                    niche="Government Administration")]
        with self.assertRaises(SystemExit):
            self.plan(rows)
        p = self.plan(rows, SECTOR={"Bloom Learning": "Education"})
        self.assertEqual((p["creates"][0]["name"], p["creates"][0]["sector"]), ("Bloom Learning", "Education"))

    def test_rename_keeps_the_old_name_as_also_known_as(self):
        p = self.plan([row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Zap", "http://www.getzap.com/")],
                      RENAME={"c-getzap": ("Getzap", "Zap", "named from getzap.com")})
        after = p["patches"]["c-getzap"]["after"]
        self.assertEqual((after["name"], after["also_known_as"]), ("Zap", ["Getzap"]))
        self.assertEqual(after["website"], "https://www.getzap.com")

    def test_one_person_per_profile_keeping_the_fullest_name(self):
        p = self.plan([
            row("Sai K", "Recruiter", "sai-k-5a15434a", "Acme", "http://www.acme.com/"),
            row("Saicharan Kumar", "Recruiter", "saicharan-kumar-5a15434a", "Acme", "http://www.acme.com/"),
        ])
        self.assertEqual([x["name"] for x in p["people"]], ["Saicharan Kumar"])
        self.assertEqual(len(p["excluded"]), 1)

    def test_same_name_two_profiles_needs_a_decision(self):
        rows = [row("Devesh", "Recruiter", "devesh-1a2b3c4d", "Acme", "http://www.acme.com/"),
                row("Devesh", "Recruiter", "devesh-9f8e7d6c", "Acme", "http://www.acme.com/")]
        with self.assertRaises(SystemExit):
            self.plan(rows)
        self.assertEqual(len(self.plan(rows, DUPLICATES={"Devesh|Acme": "different"})["people"]), 2)

    def test_someone_already_on_file_is_filled_in_not_added(self):
        p = self.plan([row("Neha  Rao", "Talent Partner", "neha-rao-3c4d5e6f", "Acme", "http://www.acme.com/",
                           location="Mumbai, India")])
        self.assertEqual(p["people"], [])
        self.assertEqual(p["merges"][0]["contact"], "r-1")
        self.assertEqual(p["merges"][0]["changes"], {"linkedin": "https://www.linkedin.com/in/neha-rao-3c4d5e6f",
                                                     "location": "Mumbai, India", "position": "Talent Partner"})

    def test_namesakes_on_file_go_to_the_working_address_or_need_a_decision(self):
        twin = dict(RECRUITERS[0], id="r-2", email="neha@acme.com")
        sheet = [row("Neha Rao", "Talent Partner", "neha-rao-3c4d5e6f", "Acme", "http://www.acme.com/")]
        RECRUITERS.append(twin)
        try:
            (self.snap / "recruiters.json").write_text(json.dumps(RECRUITERS))
            with self.assertRaises(SystemExit):
                self.plan(sheet)
            self.assertEqual(self.plan(sheet, SAME_NAME={"Neha Rao|Acme": "r-2"})["merges"][0]["contact"], "r-2")
            self.assertEqual(len(self.plan(sheet, SAME_NAME={"Neha Rao|Acme": "new"})["people"]), 1)
            twin["is_valid"] = False
            (self.snap / "recruiters.json").write_text(json.dumps(RECRUITERS))
            merge = self.plan(sheet)["merges"][0]
            self.assertEqual((merge["contact"], merge["why"]),
                             ("r-1", "the only one of the namesakes whose address still works"))
        finally:
            RECRUITERS.remove(twin)

    def test_a_skipped_company_leaves_its_people_out(self):
        p = self.plan([row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "N/A", "")],
                      COMPANY={"N/A": ("skip", "no company")})
        self.assertEqual((p["people"], len(p["excluded"])), ([], 1))

    def test_a_person_can_be_filed_apart_from_their_sheet_company(self):
        sheet = [row("Asha Verma", "Recruiter", "asha-verma-1a2b3c4d", "Acme", "http://www.acme.com/"),
                 row("Kiran Das", "TA Lead", "kiran-das-2b3c4d5e", "Acme", "http://www.peak.ai/")]
        p = self.plan(sheet, COMPANY={"Acme": ("id", "c-acme", "test")},
                      PERSON_COMPANY={"id:2b3c4d5e": ("c-peak", "its own website is peak.ai")})
        self.assertEqual(sorted((x["name"], x["company"]) for x in p["people"]),
                         [("Asha Verma", "c-acme"), ("Kiran Das", "c-peak")])


def linked(name, slug, company, linkedin="", social="", twitter=""):
    r = row(name, "Recruiter", slug, company, "")
    r[7:10] = [linkedin, social, twitter]
    return r


class CompanyLinks(unittest.TestCase):
    def test_links_are_told_apart_by_host_and_tidied(self):
        cases = {
            "http://www.linkedin.com/company/Acme-Labs/about/": ("linkedin", "https://www.linkedin.com/company/acme-labs"),
            "in.linkedin.com/school/acme-u?trk=x": ("linkedin", "https://www.linkedin.com/school/acme-u"),
            "https://twitter.com/AcmeHQ": ("x", "https://x.com/AcmeHQ"),
            "https://mobile.twitter.com/acme/status/1": ("x", "https://x.com/acme"),
            "http://twitter.com/#!/acme": ("x", "https://x.com/acme"),
            "https://x.com/acme": ("x", "https://x.com/acme"),
            "https://m.facebook.com/acmeindia/": ("facebook", "https://www.facebook.com/acmeindia"),
            "https://www.facebook.com/profile.php?id=123&ref=x": ("facebook", "https://www.facebook.com/profile.php?id=123"),
            "https://www.facebook.com/pages/Acme/123/": ("facebook", "https://www.facebook.com/pages/Acme/123"),
        }
        for raw, want in cases.items():
            self.assertEqual(ip.company_link(raw), want, raw)
            self.assertEqual(ip.company_link(want[1]), want, want[1])   # stored links stay as they are
        for raw in ("", "https://www.linkedin.com/in/asha", "https://twitter.com/intent/tweet",
                    "https://www.facebook.com/sharer.php?u=x", "http://acme.com", "https://example.com/acme"):
            self.assertIsNone(ip.company_link(raw), raw)

    def links(self, sheet, on_file=None, **kw):
        names = {"c-acme": "Acme", "c-peak": "Peak"}
        with mock.patch.object(ip, "R", review(**kw)), \
                mock.patch.object(ip, "read_sheet", return_value=[{**dict(zip(HEADER, r)), "_row": i + 2}
                                                                  for i, r in enumerate(sheet)]), \
                mock.patch.object(ip, "sheet_companies", return_value={"Acme": "c-acme", "Peak": "c-peak"}):
            return ip.links_plan("sheet.csv", on_file=on_file or {}, live_companies=names)

    def test_most_rows_win_whatever_the_column(self):
        p = self.links([
            linked("A", "a-1", "Acme", "linkedin.com/company/acme", "facebook.com/acme", "twitter.com/acme"),
            linked("B", "b-1", "Acme", "linkedin.com/company/acme", "twitter.com/acme", ""),
            linked("C", "c-1", "Acme", "facebook.com/acme", "twitter.com/acme_old", ""),
        ])
        self.assertEqual(p["problems"], [])
        self.assertEqual(p["fills"]["c-acme"]["after"], {"linkedin": "https://www.linkedin.com/company/acme",
                                                         "x": "https://x.com/acme",
                                                         "facebook": "https://www.facebook.com/acme"})
        self.assertEqual(p["fills"]["c-acme"]["why"]["x"], "2 of 3 rows")

    def test_a_tie_needs_a_decision(self):
        sheet = [linked("A", "a-1", "Acme", twitter="twitter.com/acme"),
                 linked("B", "b-1", "Acme", twitter="twitter.com/acme_hq")]
        self.assertEqual(len(self.links(sheet)["problems"]), 1)
        p = self.links(sheet, LINKS={"Acme": {"x": "https://x.com/acme_hq"}})
        self.assertEqual((p["problems"], p["fills"]["c-acme"]["after"]["x"]), ([], "https://x.com/acme_hq"))
        p = self.links(sheet, LINKS={"Acme": {"x": None}})
        self.assertEqual((p["problems"], p["fills"]), ([], {}))

    def test_a_person_filed_elsewhere_takes_their_rows_links_along(self):
        sheet = [linked("A", "a-1", "Acme", twitter="twitter.com/acme"),
                 linked("B", "b-1", "Acme", twitter="twitter.com/peak_hq")]
        p = self.links(sheet, PERSON_COMPANY={"b-1": ("c-peak", "test")})
        self.assertEqual((p["fills"]["c-acme"]["after"]["x"], p["fills"]["c-peak"]["after"]["x"]),
                         ("https://x.com/acme", "https://x.com/peak_hq"))

    def test_only_missing_links_are_filled(self):
        sheet = [linked("A", "a-1", "Acme", "linkedin.com/company/acme", "facebook.com/acme", "twitter.com/acme")]
        on_file = {"c-acme": {"id": "l-1", "linkedin": "https://www.linkedin.com/company/acme-inc",
                              "x": None, "facebook": "https://www.facebook.com/acme"}}
        p = self.links(sheet, on_file=on_file)
        fill = p["fills"]["c-acme"]
        self.assertEqual((fill["row"], fill["after"]["linkedin"], fill["after"]["x"], list(fill["why"])),
                         ("l-1", "https://www.linkedin.com/company/acme-inc", "https://x.com/acme", ["x"]))
        self.assertEqual(len(p["kept"]), 1)
        on_file["c-acme"]["x"] = "https://x.com/acme"
        self.assertEqual(self.links(sheet, on_file=on_file)["fills"], {})


    def test_verify_follows_a_company_merged_since(self):
        """Acme's links went into Peak (whose own X stays) after the apply: still sound."""
        sheet = [linked("A", "a-1", "Acme", "linkedin.com/company/acme", twitter="twitter.com/acme")]
        acme = {"linkedin": "https://www.linkedin.com/company/acme", "x": "https://x.com/acme", "facebook": None}
        peak = {"linkedin": None, "x": "https://x.com/peak", "facebook": None}
        merged = {"linkedin": acme["linkedin"], "x": peak["x"], "facebook": None}
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / ip.LINKS_LOG).write_text(json.dumps({"pre_backup": "/b/20261020-213000-pre-hr-links"}))
            with mock.patch.object(ip, "OUT", out), mock.patch.object(ip, "R", review()), \
                    mock.patch.object(ip, "later_changes", return_value=({"c-acme": "c-peak"}, {})), \
                    mock.patch.object(ip, "read_sheet", return_value=[{**dict(zip(HEADER, r)), "_row": i + 2}
                                                                      for i, r in enumerate(sheet)]), \
                    mock.patch.object(ip, "sheet_companies", return_value={"Acme": "c-acme"}), \
                    mock.patch.object(ip.company_links, "open_backup", return_value={"c-acme": acme, "c-peak": peak}), \
                    mock.patch.object(ip.company_links, "read_live", return_value={"c-peak": merged}), \
                    mock.patch.object(ip.supabase, "get_all", return_value=[{"id": "c-peak", "name": "Peak"}]), \
                    mock.patch("sys.stdout", new_callable=io.StringIO):
                ip.links_check("sheet.csv")   # exits on a problem
                with mock.patch.object(ip.company_links, "read_live", return_value={"c-peak": {**merged, "x": None}}):
                    with self.assertRaises(SystemExit):
                        ip.links_check("sheet.csv")

class LaterChanges(unittest.TestCase):
    def test_only_applied_merges_and_refiles_after_the_backup_count(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            for stamp, folds, applied in (("20261020-200000", {"c-old": "c-x"}, True),
                                          ("20261020-230000", {"c-a": "c-b", "c-b": "c-c"}, True),
                                          ("20261020-232000", {"c-dry": "c-run"}, False)):
                (repo / "data_verification" / stamp).mkdir(parents=True)
                (repo / "data_verification" / stamp / "plan.json").write_text(json.dumps({"fold_into": folds}))
                if applied:
                    (repo / "data_verification" / stamp / "after").mkdir()
            out = repo / "data_verification" / "hr_import"
            out.mkdir()
            (out / "refiled.json").write_text(json.dumps([
                {"backup": "/b/20261020-190000-pre-refile", "moves": [{"contact": "r-old", "from": "c-1", "to": "c-2"}]},
                {"backup": "/b/20261020-231000-pre-refile", "moves": [{"contact": "r-1", "from": "c-1", "to": "c-2"}]}]))
            with mock.patch.object(ip, "REPO", repo), mock.patch.object(ip, "OUT", out):
                folds, refiled = ip.later_changes("/b/20261020-213000-pre-hr-import")
        self.assertEqual((folds, refiled), ({"c-a": "c-b", "c-b": "c-c"}, {"r-1": ("c-1", "c-2")}))
        self.assertEqual(ip.folded_into("c-a", folds), "c-c")
        self.assertEqual(ip.folded_into("c-z", folds), "c-z")


if __name__ == "__main__":
    unittest.main()
