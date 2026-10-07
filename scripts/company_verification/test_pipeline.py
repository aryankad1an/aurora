"""Tests for the verification pipeline. Run from this folder:

    python3 -m unittest -v test_pipeline

Each test pins one rule to a concrete case, including the failure modes that
matter for data safety: a stray contact must not merge two companies, a
renamed row must not be hit by a rule meant for another, a company is never
deleted while it still has contacts or sends, and a personal contact with
send history is never deleted.
"""
import copy
import json
import unittest
from unittest import mock

import verify_companies as vc
import verify_names as vn
from domains import clean, is_personal, registrable


class Domains(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(clean("Priya.S@Stripe.COM "), "stripe.com")
        self.assertEqual(clean("https://www.stripe.com/jobs"), "stripe.com")
        self.assertIsNone(clean("not-an-address"))
        self.assertIsNone(clean("a@b..com"))

    def test_registrable(self):
        cases = {
            "ext.airbnb.com": "airbnb.com", "ny.email.gs.com": "gs.com",
            "in.pwc.com": "pwc.com", "mail.iitb.ac.in": "iitb.ac.in",
            "iimahd.ernet.in": "iimahd.ernet.in", "cms.co.in": "cms.co.in",
            "globalconcept.uk.com": "globalconcept.uk.com", "sapientag2.com.br": "sapientag2.com.br",
            "stripe.com": "stripe.com", "mm.smu.edu.sg": "smu.edu.sg",
        }
        for host, want in cases.items():
            self.assertEqual(registrable(host), want, host)

    def test_personal(self):
        for h in ["gmail.com", "yahoo.co.in", "rana.simplelogin.com", "i.softbank.jp", "comcast.net"]:
            self.assertTrue(is_personal(h), h)
        # Work hosts that merely contain a provider-ish word, and Titan's own domain.
        for h in ["mail.intuit.com", "in.pwc.com", "email.iimcal.ac.in", "yahooinc.com",
                  "titan.email", "verizon.com", "zohocorp.com", "sify.com"]:
            self.assertFalse(is_personal(h), h)


# ---------------------------------------------------------------------------
# A tiny catalog to plan against.

def company(cid, name, domains=None, sector=None):
    return {"id": cid, "name": name, "sector": sector, "domains": domains or []}


def contact(rid, cid, email, name=None, valid=True):
    return {"id": rid, "company_id": cid, "email": email, "name": name, "position": None,
            "phone": None, "is_valid": valid, "greeting_name": None}


BASE_DECISIONS = {
    "test_companies": {}, "junk_companies": {}, "typo_domains": {}, "domain_moves": {},
    "merges": [], "renames": {}, "unresolved": {}, "distinct_companies": [],
    "relay_domains": {"tophire.co": "agency"}, "_ids": {},
}


class Pipeline(unittest.TestCase):
    def plan(self, tables, **decisions):
        d = copy.deepcopy(BASE_DECISIONS)
        d.update(decisions)
        ids = {k: v for k, v in d["_ids"].items()}
        patches = [
            mock.patch.object(vc, "DECISIONS", d),
            mock.patch.object(vc, "PINNED", ids),
            mock.patch.object(vc, "ALL_SOURCES", {s for m in d["merges"] for s in m["from"]}),
            mock.patch.object(vc, "FINAL_NAME", {**{m["into"]: m["name"] for m in d["merges"] if "name" in m},
                                                 **d["renames"]}),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        st = vc.State(tables)
        plan = vc.build_plan(st)
        plan["domains"] = vc.domain_ops(vc.State(vc.simulate(st, plan)))
        after = vc.State(vc.simulate(st, plan))
        return st, plan, after

    def tables(self, companies, recruiters, sends=(), tracked=()):
        return {"companies": companies, "recruiters": recruiters,
                "mail_sends": [{"id": f"s{i}", "recruiter_id": r} for i, r in enumerate(sends)],
                "tracked_companies": [{"user_email": u, "company_id": c} for u, c in tracked],
                "user_companies": [], "profiles": [], "templates": []}

    def test_stray_contact_moves_alone_and_never_merges_companies(self):
        t = self.tables(
            [company("apple", "Apple"), company("ocwen", "Ocwen")],
            [contact(f"a{i}", "apple", f"p{i}@apple.com") for i in range(5)]
            + [contact("x", "apple", "k.karkare@ocwen.com")]
            + [contact(f"o{i}", "ocwen", f"q{i}@ocwen.com") for i in range(3)])
        st, plan, after = self.plan(t)
        self.assertEqual(plan["moves"], {"ocwen": ["x"]})
        self.assertEqual(plan["delete_companies"], [])
        self.assertEqual(vc.verify(after)[0], [])

    def test_subdomain_duplicate_is_folded_with_its_tracking(self):
        t = self.tables(
            [company("air", "Airbnb"), company("ext", "Ext Airbnb")],
            [contact("a", "air", "a@airbnb.com"), contact("b", "air", "b@airbnb.com"),
             contact("e", "ext", "e@ext.airbnb.com")],
            sends=["e"], tracked=[("me@x.com", "ext")])
        st, plan, after = self.plan(t)
        self.assertEqual(plan["fold_into"], {"ext": "air"})
        self.assertEqual(plan["tracking"][0]["to"], "air")
        self.assertTrue(plan["tracking"][0]["insert"])
        self.assertEqual({r["company_id"] for r in after.recruiters}, {"air"})
        self.assertEqual(len(after.tables["mail_sends"]), 1)          # the send survives
        self.assertIn("ext.airbnb.com", after.companies["air"]["domains"])  # app looks up by host
        self.assertEqual(vc.verify(after)[0], [])

    def test_relay_domain_stays_with_client_and_is_never_owned(self):
        t = self.tables(
            [company("cur", "Cursor", ["tophire.co"]), company("zep", "Zepto"),
             company("th", "Tophire")],
            [contact("c", "cur", "s@tophire.co"), contact("z", "zep", "t@tophire.co"),
             contact("h", "th", "boss@tophire.co")])
        st, plan, after = self.plan(t)
        self.assertEqual(plan["moves"], {})
        self.assertEqual(plan["domains"]["cur"], [])          # agency domain removed from client
        self.assertEqual(after.companies["th"]["domains"], ["tophire.co"])  # kept on the agency itself
        self.assertEqual(vc.verify(after)[0], [])

    def test_typo_domain_is_corrected_not_deleted(self):
        t = self.tables(
            [company("wf", "Wells Fargo"), company("typo", "Wellfargo")],
            [contact("w", "wf", "a.b@wellsfargo.com"), contact("t", "typo", "c.d@wellfargo.com", valid=False)])
        st, plan, after = self.plan(t, typo_domains={"wellfargo.com": "wellsfargo.com"},
                                    dead_domains={"wellfargo.com": "no host"})   # typo wins over dead
        self.assertEqual(plan["rewrite_emails"], [{"id": "t", "from": "c.d@wellfargo.com", "to": "c.d@wellsfargo.com"}])
        self.assertEqual(plan["delete_dead"], [])
        self.assertEqual(plan["fold_into"], {"typo": "wf"})
        fixed = next(r for r in after.recruiters if r["id"] == "t")
        self.assertEqual((fixed["email"], fixed["company_id"], fixed["is_valid"]), ("c.d@wellsfargo.com", "wf", True))
        self.assertEqual(after.companies["wf"]["domains"], ["wellsfargo.com"])
        self.assertEqual(vc.verify(after)[0], [])

    def test_deleted_typo_contact_is_restored_corrected(self):
        t = self.tables([company("mi", "Micron")], [contact("m", "mi", "a@micron.com")])
        backup_rows = [contact("gone", "old-co", "spradhan@micron.con", name="S Pradhan"),
                       contact("m", "mi", "a@micron.com")]                  # still live: ignored
        st = vc.State(t)
        with mock.patch.dict(vc.DECISIONS, {**copy.deepcopy(BASE_DECISIONS), "typo_domains": {"micron.con": "micron.com"}}):
            plan = vc.build_plan(st, backup_rows)
            plan["domains"] = vc.domain_ops(vc.State(vc.simulate(st, plan)))   # as main() does
            after = vc.State(vc.simulate(st, plan))
            self.assertEqual(vc.verify(after)[0], [])
        self.assertEqual([(x["id"], x["email"], x["company_id"], x["is_valid"]) for x in plan["restore_contacts"]],
                         [("gone", "spradhan@micron.com", "mi", True)])

    def test_restore_skipped_when_corrected_address_already_exists(self):
        t = self.tables([company("mi", "Micron")], [contact("m", "mi", "spradhan@micron.com")])
        with mock.patch.dict(vc.DECISIONS, {**copy.deepcopy(BASE_DECISIONS), "typo_domains": {"micron.con": "micron.com"}}):
            plan = vc.build_plan(vc.State(t), [contact("gone", "x", "spradhan@micron.con")])
        self.assertEqual(plan["restore_contacts"], [])
        self.assertTrue(any("already in the catalog" in n for n in plan["notes"]))

    def test_personal_contacts_deleted_but_never_one_with_sends(self):
        t = self.tables(
            [company("y", "Yahoo (Personal Email)", ["yahoo.in"]), company("sf", "Salesforce"),
             company("tp", "Tracked (Personal Email)")],
            [contact("p1", "y", "a@yahoo.com"), contact("p2", "y", "b@yahoo.in"),
             contact("g", "sf", "c@gmail.com"), contact("w", "sf", "d@salesforce.com"),
             contact("p3", "tp", "e@hotmail.com")],
            sends=["g"], tracked=[("me@x.com", "tp")])
        st, plan, after = self.plan(t, personal_contacts={"action": "delete"})
        self.assertEqual(sorted(plan["delete_personal"]), ["p1", "p2", "p3"])
        self.assertEqual(plan["held_personal"], ["g"])
        self.assertEqual(plan["delete_emptied"], ["y"])         # tracked group is kept
        self.assertIn("g", {r["id"] for r in after.recruiters})
        self.assertEqual(vc.verify(after)[0], [])

    def test_pinned_id_stops_a_renamed_row_being_hit_by_another_rule(self):
        # First run merged the pseudo-company "Yahoo" away and renamed the
        # employer "Yahoo Inc" to "Yahoo". A re-run must not merge the employer
        # into the personal group just because it now carries the name.
        t = self.tables(
            [company("emp", "Yahoo", ["yahooinc.com"]), company("grp", "Yahoo (Personal Email)")],
            [contact("e", "emp", "a@yahooinc.com")])
        st, plan, after = self.plan(
            t, merges=[{"into": "Yahoo (Personal Email)", "from": ["Yahoo"]},
                       {"into": "Yahoo Inc", "name": "Yahoo", "from": []}],
            _ids={"Yahoo": "old-pseudo-id", "Yahoo (Personal Email)": "grp", "Yahoo Inc": "emp"})
        self.assertEqual(plan["delete_companies"], [])
        self.assertEqual(plan["moves"], {})

    def test_restoring_a_wrongly_merged_domain_recreates_the_original_row(self):
        t = self.tables(
            [company("ust", "UST", ["ust.com", "uste3.com"])],
            [contact("a", "ust", "a@ust.com"), contact("b", "ust", "b@uste3.com")])
        st, plan, after = self.plan(t, domain_moves={"uste3.com": {"create": "UST (e3)", "id": "orig-id", "why": "x"}})
        self.assertEqual(plan["creates"], {"new:UST (e3)": {"name": "UST (e3)", "id": "orig-id"}})
        self.assertEqual(plan["moves"], {"new:UST (e3)": ["b"]})
        self.assertEqual(after.companies["ust"]["domains"], ["ust.com"])
        self.assertEqual(after.companies["new:UST (e3)"]["domains"], ["uste3.com"])
        # Once it exists (a re-run), it's found by its id and nothing is planned.
        t2 = self.tables([company("ust", "UST", ["ust.com"]), company("orig-id", "UST (e3)", ["uste3.com"])],
                         [contact("a", "ust", "a@ust.com"), contact("b", "orig-id", "b@uste3.com")])
        _, plan2, _ = self.plan(t2, domain_moves={"uste3.com": {"create": "UST (e3)", "id": "orig-id", "why": "x"}})
        self.assertEqual((plan2["creates"], plan2["moves"], plan2["domains"]), ({}, {}, {}))

    def test_merge_whose_target_was_removed_later_is_skipped_not_fatal(self):
        t = self.tables([company("s", "Stripe")], [contact("a", "s", "a@stripe.com")])
        _, plan, _ = self.plan(t, merges=[{"into": "Gone Group", "from": ["Gone Source"]}],
                               _ids={"Gone Group": "g1", "Gone Source": "g2"})
        self.assertEqual((plan["moves"], plan["delete_companies"]), ({}, []))

    def test_merge_target_gone_but_source_alive_stops(self):
        t = self.tables([company("s", "Stripe"), company("src", "Src")], [contact("a", "s", "a@stripe.com")])
        with self.assertRaises(SystemExit):
            self.plan(t, merges=[{"into": "Gone", "from": ["Src"]}], _ids={"Gone": "g1", "Src": "src"})

    def test_new_company_is_not_matched_to_a_pinned_row_still_carrying_its_name(self):
        # First run wrongly renamed "Ivpindia" to "Indus Valley Partners"; the fix
        # renames it "IVP Limited" and creates the real one. The create must not
        # latch onto the wrong row just because it still has the name.
        t = self.tables(
            [company("ivpl", "Indus Valley Partners", ["ivp.in", "ivpindia.com"])],
            [contact("a", "ivpl", "a@ivpindia.com"), contact("b", "ivpl", "b@ivp.in")])
        _, plan, after = self.plan(
            t, renames={"Ivpindia": "IVP Limited"}, _ids={"Ivpindia": "ivpl"},
            domain_moves={"ivp.in": {"create": "Indus Valley Partners", "why": "x"}})
        self.assertEqual(plan["moves"], {"new:Indus Valley Partners": ["b"]})
        self.assertEqual(after.companies["ivpl"]["name"], "IVP Limited")
        self.assertEqual(after.companies["ivpl"]["domains"], ["ivpindia.com"])
        self.assertEqual(vc.verify(after)[0], [])

    def test_verify_catches_a_domain_rule_that_did_not_land(self):
        t = self.tables([company("ivpl", "IVP Limited", ["ivp.in"])], [contact("b", "ivpl", "b@ivp.in")])
        st, _, _ = self.plan(t, domain_moves={"ivp.in": {"create": "Indus Valley Partners", "why": "x"}})
        self.assertTrue(any("ivp.in" in v for v in vc.verify(st)[0]))

    def test_dead_domain_contacts_deleted_emptied_company_removed_sent_ones_held(self):
        t = self.tables(
            [company("w", "Wolves India", ["wolves-india.com"]), company("am", "Amazon", ["amazon.com", "ant.amazon.com"]),
             company("tr", "Tracked Dead", ["gone.io"]), company("s", "Sent Dead")],
            [contact("w1", "w", "a@wolves-india.com"), contact("w2", "w", "b@wolves-india.com"),
             contact("a1", "am", "x@amazon.com"), contact("a2", "am", "y@ant.amazon.com"),
             contact("t1", "tr", "z@gone.io"), contact("s1", "s", "q@dead.biz")],
            sends=["s1"], tracked=[("me@x.com", "tr")])
        dead = {"_about": "x", "wolves-india.com": "nx", "ant.amazon.com": "nx", "gone.io": "nx", "dead.biz": "nx"}
        _, plan, after = self.plan(t, dead_domains=dead)
        self.assertEqual(sorted(plan["delete_dead"]), ["a2", "t1", "w1", "w2"])
        self.assertEqual(plan["held_dead"], ["s1"])                 # a send is never cascaded away
        self.assertEqual(plan["delete_emptied"], ["w"])             # tracked company kept, Amazon kept
        self.assertEqual(after.companies["am"]["domains"], ["amazon.com"])
        self.assertEqual(after.companies["tr"]["domains"], [])       # dead host dropped from the list
        self.assertEqual(vc.verify(after)[0], [])

    def test_ilike_exact_escapes_like_wildcards_but_not_star(self):
        self.assertEqual(vc.ilike_exact("first_last@x.com"), r"ilike.first\_last@x.com")
        self.assertEqual(vc.ilike_exact("a%b@x.com"), r"ilike.a\%b@x.com")
        self.assertEqual(vc.ilike_exact("a*b@x.com"), "ilike.a*b@x.com")

    def test_verify_flags_a_contact_on_a_dead_domain(self):
        t = self.tables([company("w", "W")], [contact("w1", "w", "a@wolves-india.com")])
        st, _, _ = self.plan(t, dead_domains={"wolves-india.com": "nx"})
        self.assertTrue(any("can't receive mail" in v for v in vc.verify(st)[0]))

    def test_typed_in_domain_with_no_contacts_is_kept(self):
        t = self.tables([company("s", "Stripe", ["stripe.dev"])], [contact("a", "s", "a@stripe.com")])
        _, plan, after = self.plan(t)
        self.assertEqual(after.companies["s"]["domains"], ["stripe.dev", "stripe.com"])


class ApplySafety(unittest.TestCase):
    """apply() against a fake API: order of writes and the cascade guards."""

    def run_apply(self, plan, db_recruiters_left=None, sends_found=None):
        calls = []

        def write(method, table, filters=None, body=None, prefer=None):
            calls.append((method, table, json.dumps(filters, sort_keys=True), json.dumps(body, sort_keys=True)))
            ids = (filters or {}).get("id", "")
            n = ids.count(",") + 1 if ids.startswith("in.(") else 1
            return [{"id": body.get("id", "new-id") if body else "x"}] * n

        def get(table, filters, select="*"):
            if table == "recruiters":
                return db_recruiters_left or []
            if table == "mail_sends":
                return sends_found or []
            return []

        st = vc.State({"companies": [company("a", "A"), company("b", "B")], "recruiters": [],
                       "mail_sends": [], "tracked_companies": [], "user_companies": []})
        with mock.patch.object(vc.supabase, "write", write), mock.patch.object(vc.supabase, "get", get):
            vc.apply(st, plan)
        return calls

    def base_plan(self, **kw):
        p = {"creates": {}, "moves": {}, "tracking": [], "delete_companies": [],
             "fold_into": {}, "delete_junk": [], "delete_personal": [], "delete_emptied": [],
             "renames": {}, "sectors": {}, "domains": {}}
        p.update(kw)
        return p

    def test_contacts_move_before_any_company_is_deleted(self):
        calls = self.run_apply(self.base_plan(moves={"a": ["r1", "r2"]}, delete_companies=["b"],
                                              fold_into={"b": "a"}, renames={"a": "A2"}))
        order = [(m, t) for m, t, _, _ in calls]
        self.assertLess(order.index(("PATCH", "recruiters")), order.index(("DELETE", "companies")))
        self.assertLess(order.index(("DELETE", "companies")), order.index(("PATCH", "companies")))

    def test_refuses_to_delete_a_company_that_still_has_contacts(self):
        with self.assertRaises(SystemExit):
            self.run_apply(self.base_plan(delete_companies=["b"], fold_into={"b": "a"}),
                           db_recruiters_left=[{"id": "still-here"}])

    def test_refuses_to_delete_personal_contacts_that_gained_sends(self):
        with self.assertRaises(SystemExit):
            self.run_apply(self.base_plan(delete_personal=["p1"]), sends_found=[{"id": "s"}])

    def test_restored_company_is_created_with_its_original_id(self):
        calls = self.run_apply(self.base_plan(creates={"new:X": {"name": "X", "id": "orig"}}))
        self.assertEqual(json.loads(calls[0][3]), {"name": "X", "id": "orig"})


class Names(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rows = [{"email": f"{f}.{l}@x.com"} for f, l in [
            ("neha", "mathur"), ("ravi", "mathur"), ("amit", "mathur"), ("neha", "gupta"), ("neha", "singh"), ("anjali", "kushwah"),
            ("rohit", "kushwah"), ("amit", "kushwah"), ("rahul", "sharma"), ("ravi", "sharma"),
            ("ajay", "sharma"), ("vijay", "kumar"), ("vijay", "rao"), ("vijay", "singh"),
            ("vijay", "nair"), ("vijay", "das"), ("rakesh", "kumar"), ("rakesh", "rao"),
            ("rakesh", "das"), ("radhakrishnan", "iyer"), ("om", "prakash"), ("amit", "singh"),
            ("sunil", "singh"), ("rohit", "thomas"), ("anil", "thomas"), ("ravi", "thomas")]]
        cls.lex = vn.Lexicon(rows)

    def check(self, email, name, greeting):
        n, g, conf, how = vn.derive(email, self.lex)
        self.assertEqual((n, g), (name, greeting), f"{email}: {how}")

    def test_readings(self):
        self.check("neha.mathur@x.com", "Neha Mathur", "Neha")
        self.check("nehamathur@x.com", "Neha Mathur", "Neha")
        self.check("akushwah@x.com", "A Kushwah", "Kushwah")
        self.check("pm.singh@x.com", "PM Singh", "Singh")
        self.check("careers@x.com", "Team", "Team")
        self.check("hr-neha@x.com", "Neha", "Neha")
        self.check("radhakrishnan@x.com", "Radhakrishnan", "Radhakrishnan")   # whole name, not split
        self.check("om_sourabh@x.com", "Om Sourabh", "Om")
        self.check("bi.oracle@oracle.com", "Team", "Team")

    def test_ambiguous_mailboxes_are_left_alone(self):
        for email in ["talk2saravanan@x.com", "vijaym_b4u@x.com", "vk_mms@x.com"]:
            self.assertNotEqual(vn.derive(email, self.lex)[2], "high", email)

    def test_human_entered_names_are_never_overwritten(self):
        tables = {"companies": [{"id": "c", "name": "C"}], "recruiters": [
            {"id": "1", "company_id": "c", "email": "akushwah@x.com", "name": "Anjali Kushwah", "greeting_name": "Anjali"},
            {"id": "2", "company_id": "c", "email": "akushwah2@x.com", "name": "Akushwah", "greeting_name": "Akushwah"},
            {"id": "3", "company_id": "c", "email": "careers@x.com", "name": "Priya Nair", "greeting_name": "Priya"},
            # Same letters as the mailbox, but split, cased or punctuated by a person.
            {"id": "4", "company_id": "c", "email": "vijaykumar@x.com", "name": "Vijay Kumar", "greeting_name": "Vijay"},
            {"id": "5", "company_id": "c", "email": "neha.ca@x.com", "name": "Neha C A", "greeting_name": "Neha"},
            {"id": "6", "company_id": "c", "email": "neha.dsouza@x.com", "name": "Neha D'souza", "greeting_name": "Neha"},
        ] + [{"id": f"l{i}", "company_id": "c", "email": f"{f}.{l}@x.com", "name": f"{f} {l}".title(),
              "greeting_name": f.title()} for i, (f, l) in enumerate([("anjali", "kushwah"), ("rohit", "kushwah"), ("amit", "kushwah")])]}
        fixes, _, _ = vn.review(tables)
        changed = {f["id"]: f for f in fixes}
        self.assertNotIn("1", changed)     # human name kept
        self.assertNotIn("3", changed)     # a person behind a role mailbox kept
        for rid in ("4", "5", "6"):
            self.assertNotIn(rid, changed)  # not the mailbox merely re-spaced
        self.assertEqual(changed["2"]["new_name"], "A Kushwah")


if __name__ == "__main__":
    unittest.main()
