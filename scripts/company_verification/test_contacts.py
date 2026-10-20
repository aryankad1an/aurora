"""Tests for contacts.py and the scripts' sealed path, against a fake PostgREST.

    python3 -m unittest -v test_contacts          # from this folder

Nothing here touches the live DB: every read and write goes to FakePostgREST,
an in-memory stand-in for the handful of PostgREST features the scripts use,
holding made-up people only.
"""
import base64
import copy
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import company_links
import contacts
import supabase
import vault_crypto
import verify_companies as vc
import verify_names as vn

VAULT_ID = "0e984725-c51c-4bf4-9960-e1c80e27aba0"
KEY_ID = "8c2d1a7e-5b3f-4e21-9a0b-7d6c5e4f3a21"
PRIVATE_KEY = "correct horse battery staple"
VAULT_KEY = bytes(range(32))


class FakePostgREST:
    """Tables as lists of dicts; filters eq., in.(), is.null; select lists."""

    def __init__(self, tables, migrated=True):
        self.tables = copy.deepcopy(tables)
        if migrated:
            self.tables.setdefault("vaults", [])
        self.writes = []

    def has_table(self, table):
        return table in self.tables

    def _table(self, table):
        if table not in self.tables:
            raise supabase.APIError(f"GET {table} -> HTTP 404: PGRST205 Could not find the table")
        return self.tables[table]

    @staticmethod
    def _match(row, filters):
        for col, f in (filters or {}).items():
            if col in ("limit", "order", "select"):
                continue
            value = row.get(col)
            if f.startswith("eq."):
                if value is None or str(value) != f[3:]:
                    return False
            elif f.startswith("in.("):
                if str(value) not in f[4:-1].split(","):
                    return False
            elif f == "is.null":
                if value is not None:
                    return False
            else:
                raise AssertionError(f"filter the fake doesn't know: {col}={f}")
        return True

    @staticmethod
    def _project(row, select):
        if select == "*":
            return dict(row)
        return {c.strip(): row.get(c.strip()) for c in select.split(",")}

    def get(self, table, filters, select="*"):
        rows = [self._project(r, select) for r in self._table(table) if self._match(r, filters)]
        return rows[:int(filters["limit"])] if "limit" in filters else rows

    def get_all(self, table, order="id.asc", select="*", filters=None):
        return self.get(table, filters or {}, select)

    def write(self, method, table, filters=None, body=None, prefer="return=representation"):
        rows = self._table(table)
        self.writes.append((method, table, copy.deepcopy(filters), copy.deepcopy(body)))
        if method == "POST":
            got = []
            conflict = (filters or {}).get("on_conflict", "").split(",") if "merge-duplicates" in prefer else []
            for b in body if isinstance(body, list) else [body]:
                same = [r for r in rows if conflict and all(r.get(c) == b.get(c) for c in conflict)]
                if same:   # an upsert: the row takes every column sent, its id too
                    same[0].update(b)
                    got.append(dict(same[0]))
                    continue
                row = {"id": f"gen-{len(rows)}", **b}
                if any(r["id"] == row["id"] for r in rows):
                    raise supabase.APIError("HTTP 409: duplicate key")
                rows.append(row)
                got.append(dict(row))
            return got
        hit = [r for r in rows if self._match(r, filters)]
        if method == "PATCH":
            for r in hit:
                r.update(body)
        elif method == "DELETE":
            self.tables[table] = [r for r in rows if r not in hit]
        return [dict(r) for r in hit]


def sealed_vault(key_id=KEY_ID, **extra):
    salt = bytes(16)
    unlocking = vault_crypto.derive_key(PRIVATE_KEY, salt, 1000)
    return {"id": VAULT_ID, "code": "AURORA", "owner_email": "owner@example.com", "key_id": key_id,
            "kdf_salt": base64.b64encode(salt).decode(), "kdf_rounds": 1000,
            "sealed_key": vault_crypto.wrap(VAULT_KEY, unlocking, vault_crypto.vault_key_context(VAULT_ID, key_id)),
            "pending_key_id": None, **extra}


def stored(rid, cid, email, name="", vault=VAULT_ID, key=VAULT_KEY, **more):
    """A contact the way the app stores it: sealed, plain columns null."""
    fields = {"name": name, "email": email, **more}
    return {"id": rid, "company_id": cid, "is_valid": True, "vault_id": vault, "key_id": KEY_ID,
            "sealed": vault_crypto.seal_contact(fields, key, rid, vault),
            "name": None, "email": None, "position": None, "phone": None, "greeting_name": None}


def plain(rid, cid, email, name="", **more):
    return {"id": rid, "company_id": cid, "is_valid": True, "email": email, "name": name,
            "position": None, "phone": None, "greeting_name": None, **more}


class SealedPath(unittest.TestCase):
    def setUp(self):
        self.asked = []
        self.db = FakePostgREST({"vaults": [sealed_vault()], "recruiters": [
            stored("r1", "c1", "maya.rao@example.com", "Maya Rao", greeting_name="Maya"),
            stored("r2", "c1", "zoe@example.com"),
            # Someone else's vault: unreadable here.
            stored("r3", "c2", "secret@example.com", vault="11111111-2222-3333-4444-555555555555", key=bytes(32)),
            # Ours, not sealed yet by the app.
            {**plain("r4", "c2", "asha@example.com", "Asha Rao"), "vault_id": VAULT_ID, "key_id": None, "sealed": None},
        ]})
        self.session = contacts.Session(api=self.db, environ={"AURORA_PRIVATE_KEY": PRIVATE_KEY},
                                        prompt=self.fail_prompt, log=lambda m: None)
        patcher = mock.patch.object(contacts, "_session", self.session)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fail_prompt(self, text):
        raise AssertionError("prompted although AURORA_PRIVATE_KEY is set")

    def stored_fields(self, rid):
        row = next(r for r in self.db.tables["recruiters"] if r["id"] == rid)
        return row, vault_crypto.open_contact(row["sealed"], VAULT_KEY, rid, row["vault_id"])

    def test_rows_open_into_the_shape_the_scripts_always_read(self):
        rows = {r["id"]: r for r in contacts.read_live()}
        self.assertEqual(rows["r1"], {"id": "r1", "company_id": "c1", "is_valid": True, "name": "Maya Rao",
                                      "linkedin": None, "location": None,
                                      "email": "maya.rao@example.com", "position": None, "phone": None,
                                      "greeting_name": "Maya"})
        self.assertEqual(rows["r2"]["name"], "")
        self.assertEqual(rows["r4"]["email"], "asha@example.com")
        self.assertEqual(rows["r3"]["email"], "")          # another vault's contact reads blank
        self.assertEqual(self.session.locked, {"r3"})
        for r in rows.values():
            self.assertFalse(set(contacts.STORAGE) & set(r))

    def test_a_sealed_row_and_the_plain_row_it_came_from_compare_equal(self):
        before = contacts.open_rows([{**plain("r9", "c", "a@x.com", "A", position=""), "vault_id": VAULT_ID}])
        after = contacts.open_rows([stored("r9", "c", "a@x.com", "A")])
        self.assertEqual(before, after)

    def test_select_adds_what_opening_needs(self):
        rows = contacts.read_live(select="id,company_id,email")
        self.assertEqual({r["id"]: r["email"] for r in rows}["r1"], "maya.rao@example.com")

    def test_insert_seals_and_leaves_plain_columns_empty(self):
        got = contacts.insert([{"company_id": "c9", "name": "Neha Mathur", "email": "neha.mathur@example.com",
                                "greeting_name": None, "position": None, "phone": None, "is_valid": True}])
        row, fields = self.stored_fields(got[0]["id"])
        self.assertEqual((row["vault_id"], row["key_id"]), (VAULT_ID, KEY_ID))
        self.assertTrue(all(row[f] is None for f in contacts.COLUMNS))
        self.assertEqual(fields["email"], "neha.mathur@example.com")
        self.assertEqual(fields["name"], "Neha Mathur")
        self.assertEqual(got[0]["id"], got[0]["id"].lower())   # made here: it's part of the seal

    def test_update_reseals_the_whole_row_and_keeps_other_fields(self):
        contacts.update("r1", {"name": "Maya R", "greeting_name": None})
        row, fields = self.stored_fields("r1")
        self.assertEqual(fields, {"name": "Maya R", "email": "maya.rao@example.com", "position": None,
                                  "phone": None, "greeting_name": None, "linkedin": None, "location": None})
        self.assertIsNone(row["name"])

    def test_linkedin_and_location_go_in_the_seal_only(self):
        got = contacts.insert([{"company_id": "c9", "name": "Ravi Menon", "email": "", "position": "Recruiter",
                                "linkedin": "https://www.linkedin.com/in/ravi-menon-example",
                                "location": "Pune, Maharashtra, India", "is_valid": True}])
        row, fields = self.stored_fields(got[0]["id"])
        self.assertEqual(fields["linkedin"], "https://www.linkedin.com/in/ravi-menon-example")
        self.assertEqual(fields["location"], "Pune, Maharashtra, India")
        self.assertIsNone(fields["email"])                       # no address: left out of the seal
        self.assertFalse({"linkedin", "location"} & set(row))    # no such columns
        contacts.update(got[0]["id"], {"location": "Mumbai, Maharashtra, India"})
        _, fields = self.stored_fields(got[0]["id"])
        self.assertEqual((fields["location"], fields["linkedin"], fields["position"]),
                         ("Mumbai, Maharashtra, India", "https://www.linkedin.com/in/ravi-menon-example", "Recruiter"))

    def test_linkedin_has_nowhere_to_go_unsealed(self):
        plain = contacts.Session(api=FakePostgREST({"recruiters": []}, migrated=False), environ={}, log=lambda m: None)
        with self.assertRaises(SystemExit):
            plain.insert([{"company_id": "c9", "name": "Ravi Menon", "linkedin": "linkedin.com/in/x"}])
        plain.insert([{"company_id": "c9", "name": "Ravi Menon", "linkedin": None}])

    def test_update_of_a_row_the_app_has_not_sealed_seals_it(self):
        contacts.update("r4", {"greeting_name": "Asha"})
        row, fields = self.stored_fields("r4")
        self.assertEqual(fields["email"], "asha@example.com")
        self.assertEqual(fields["greeting_name"], "Asha")
        self.assertIsNone(row["email"])

    def test_update_outside_the_seal_is_a_plain_patch(self):
        contacts.update("r1", {"company_id": "c7"})
        self.assertEqual(self.db.writes[-1], ("PATCH", "recruiters", {"id": "eq.r1"}, {"company_id": "c7"}))

    def test_update_refuses_another_vaults_contact(self):
        with self.assertRaises(SystemExit):
            contacts.update("r3", {"name": "X"})

    def test_update_refuses_when_the_row_changed_since_it_was_read(self):
        real_get = self.db.get

        def racing_get(table, filters, select="*"):
            rows = real_get(table, filters, select)
            if table == "recruiters":  # the app re-seals the row between our read and write
                self.db.tables["recruiters"][0]["sealed"] = stored("r1", "c1", "new@example.com")["sealed"]
            return rows
        self.db.get = racing_get
        with self.assertRaises(SystemExit):
            contacts.update("r1", {"name": "Late"})

    def test_a_wrong_private_key_stops_the_run(self):
        s = contacts.Session(api=self.db, environ={"AURORA_PRIVATE_KEY": "wrong"}, log=lambda m: None)
        with self.assertRaises(SystemExit):
            s.read_live()

    def test_the_key_is_asked_for_once_when_not_in_the_environment(self):
        asked = []
        s = contacts.Session(api=self.db, environ={}, prompt=lambda p: asked.append(p) or PRIVATE_KEY,
                             log=lambda m: None)
        s.read_live()
        s.insert([{"company_id": "c", "email": "x@example.com", "name": ""}])
        self.assertEqual(len(asked), 1)

    def test_writes_wait_for_a_private_key_change_to_finish(self):
        self.db.tables["vaults"][0]["pending_key_id"] = "99999999-0000-0000-0000-000000000000"
        with self.assertRaises(SystemExit):
            contacts.insert([{"company_id": "c", "email": "x@example.com", "name": ""}])

    def test_a_vault_without_a_key_yet_gets_plain_rows_the_app_will_seal(self):
        self.db.tables["vaults"][0].update(key_id=None, sealed_key=None, kdf_salt=None)
        self.db.tables["recruiters"] = [r for r in self.db.tables["recruiters"] if not r["sealed"]]
        got = contacts.insert([{"company_id": "c", "email": "x@example.com", "name": "X Y"}])
        row = next(r for r in self.db.tables["recruiters"] if r["id"] == got[0]["id"])
        self.assertEqual((row["vault_id"], row["email"], row.get("sealed")), (VAULT_ID, "x@example.com", None))

    def test_emails_in_use_reads_sealed_addresses(self):
        self.assertEqual(contacts.emails_in_use()["maya.rao@example.com"], {"r1"})
        self.assertNotIn("secret@example.com", contacts.emails_in_use())

    def test_a_backup_opens_with_the_vault_rows_saved_beside_it(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "recruiters.json").write_text(json.dumps(self.db.tables["recruiters"]))
            Path(d, "vaults.json").write_text(json.dumps(self.db.tables["vaults"]))
            offline = contacts.Session(api=FakePostgREST({}, migrated=False),
                                       environ={"AURORA_PRIVATE_KEY": PRIVATE_KEY}, log=lambda m: None)
            rows = {r["id"]: r for r in offline.open_backup(d)}
        self.assertEqual(rows["r1"]["email"], "maya.rao@example.com")

    # -- the scripts on the sealed path ---------------------------------------

    def test_pipeline_typo_rewrite_and_restore_are_sealed(self):
        self.db.tables["recruiters"].append(stored("r5", "c1", "a.b@wellfargo.com", "A B"))
        plan = {"creates": {}, "moves": {}, "tracking": [], "delete_companies": [], "fold_into": {},
                "delete_junk": [], "delete_personal": [], "delete_emptied": [], "renames": {}, "sectors": {},
                "domains": {}, "rewrite_emails": [{"id": "r5", "from": "a.b@wellfargo.com", "to": "a.b@wellsfargo.com"}],
                "restore_contacts": [{**plain("r6", "c1", "c.d@wellsfargo.com", "C D")}]}
        st = vc.State({"companies": [], "recruiters": [], "mail_sends": [], "tracked_companies": [],
                       "user_companies": []})
        with mock.patch.object(vc.supabase, "write", self.db.write), mock.patch.object(vc.supabase, "get", self.db.get):
            vc.apply(st, plan)
        self.assertEqual(self.stored_fields("r5")[1]["email"], "a.b@wellsfargo.com")
        row, fields = self.stored_fields("r6")
        self.assertEqual((fields["email"], row["email"], row["vault_id"]), ("c.d@wellsfargo.com", None, VAULT_ID))

    def test_pipeline_refuses_a_rewrite_onto_an_address_already_sealed_elsewhere(self):
        self.db.tables["recruiters"].append(stored("r5", "c1", "maya.rao@exampel.com"))
        plan = {"creates": {}, "moves": {}, "tracking": [], "delete_companies": [], "fold_into": {},
                "delete_junk": [], "renames": {}, "sectors": {},
                "rewrite_emails": [{"id": "r5", "from": "maya.rao@exampel.com", "to": "Maya.Rao@example.com"}]}
        st = vc.State({"companies": [], "recruiters": [], "mail_sends": [], "tracked_companies": [],
                       "user_companies": []})
        with self.assertRaises(SystemExit):
            vc.apply(st, plan)

    def test_snapshot_loads_open_for_the_pipeline(self):
        with tempfile.TemporaryDirectory() as d:
            tables = {"companies": [{"id": "c1", "name": "C1"}, {"id": "c2", "name": "C2"}],
                      "recruiters": self.db.tables["recruiters"], "mail_sends": [], "profiles": [],
                      "templates": [], "tracked_companies": [], "user_companies": [], "company_sources": [],
                      "vaults": self.db.tables["vaults"]}
            for t, rows in tables.items():
                Path(d, f"{t}.json").write_text(json.dumps(rows))
            st = vc.State(vc.load_snapshot(d))
        self.assertEqual({r["email"] for r in st.recruiters},
                         {"maya.rao@example.com", "zoe@example.com", "asha@example.com", ""})
        self.assertNotIn("vaults", st.tables)

    def test_name_pass_reseals_and_skips_other_vaults(self):
        self.db.tables["recruiters"].append(stored("r7", "c1", "neha.mathur@example.com", "Neha.mathur"))
        tables = {"companies": [{"id": "c1", "name": "C1"}, {"id": "c2", "name": "C2"}],
                  "recruiters": contacts.read_live()}
        fixes = vn.review(tables)
        self.assertNotIn("r3", {f["id"] for f in fixes})
        vn.apply(fixes)
        self.assertEqual(self.stored_fields("r7")[1]["name"], "Neha Mathur")

    def test_sheet_import_apply_writes_sealed_rows_and_logs_their_ids(self):
        if "cdc_review" not in sys.modules:  # the git-ignored review isn't needed to apply a plan
            sys.modules["cdc_review"] = types.ModuleType("cdc_review")
        import import_sheet
        reviewed = {"simulated": {"violations_after": []}, "creates": [], "domain_adds": {},
                    "contacts": [{"company": "c1", "name": "Priya Nair", "email": "priya.nair@example.com",
                                  "greeting_name": "Priya"}]}
        with tempfile.TemporaryDirectory() as d:
            Path(d, "plan.json").write_text(json.dumps(reviewed))
            with mock.patch.object(import_sheet, "OUT", Path(d)), \
                    mock.patch.object(import_sheet.backup_mod, "backup", lambda label="": d), \
                    mock.patch.object(import_sheet, "plan", lambda snap: reviewed):
                import_sheet.apply()
            log = json.loads(Path(d, "applied.json").read_text())
        row, fields = self.stored_fields(log["recruiters"][0])
        self.assertEqual((fields["email"], fields["greeting_name"]), ("priya.nair@example.com", "Priya"))
        self.assertEqual((row["email"], row["name"], row["vault_id"]), (None, None, VAULT_ID))


class CompanyLinks(unittest.TestCase):
    """company_links.py: links only ever stored sealed, and kept through merges."""
    OTHER = "11111111-2222-3333-4444-555555555555"

    def setUp(self):
        self.db = FakePostgREST({"vaults": [sealed_vault()], "company_links": []})
        self.session = contacts.Session(api=self.db, environ={"AURORA_PRIVATE_KEY": PRIVATE_KEY},
                                        prompt=lambda t: self.fail("prompted"), log=lambda m: None)
        patcher = mock.patch.object(contacts, "_session", self.session)
        patcher.start()
        self.addCleanup(patcher.stop)

    def rows(self, cid=None):
        return [r for r in self.db.tables["company_links"] if cid is None or r["company_id"] == cid]

    def test_save_seals_and_a_second_save_updates_the_same_row(self):
        company_links.save("c1", {"linkedin": "https://www.linkedin.com/company/acme"})
        [row] = self.rows()
        self.assertNotIn("acme", json.dumps(row))
        self.assertEqual(vault_crypto.open_company_links(row["sealed"], VAULT_KEY, row["id"], VAULT_ID)["linkedin"],
                         "https://www.linkedin.com/company/acme")
        company_links.save("c1", {"linkedin": "https://www.linkedin.com/company/acme", "x": "https://x.com/acme"},
                           row_id=row["id"])
        self.assertEqual(len(self.rows()), 1)
        self.assertEqual(company_links.read_live()["c1"]["x"], "https://x.com/acme")

    def test_nothing_is_written_unsealed(self):
        bare = contacts.Session(api=FakePostgREST({"vaults": [{**sealed_vault(), "key_id": None, "sealed_key": None}],
                                                   "company_links": []}),
                                environ={}, log=lambda m: None)
        with self.assertRaises(SystemExit):
            company_links.save("c1", {"x": "https://x.com/acme"}, s=bare)

    def test_move_takes_the_row_across(self):
        company_links.save("c1", {"x": "https://x.com/acme"})
        self.assertEqual(company_links.move("c1", "c2"), 1)
        self.assertEqual((self.rows("c1"), company_links.read_live()["c2"]["x"]), ([], "https://x.com/acme"))

    def test_move_onto_our_own_links_merges_them_and_the_target_wins(self):
        company_links.save("c1", {"x": "https://x.com/old", "facebook": "https://www.facebook.com/acme"})
        company_links.save("c2", {"x": "https://x.com/acme"})
        company_links.move("c1", "c2")
        self.assertEqual(self.rows("c1"), [])
        got = company_links.read_live()["c2"]
        self.assertEqual((got["x"], got["facebook"]), ("https://x.com/acme", "https://www.facebook.com/acme"))

    def test_move_refuses_where_both_hold_another_vaults_links(self):
        self.db.tables["company_links"] += [
            {"id": "l1", "company_id": "c1", "vault_id": self.OTHER, "key_id": KEY_ID, "sealed": "x"},
            {"id": "l2", "company_id": "c2", "vault_id": self.OTHER, "key_id": KEY_ID, "sealed": "y"}]
        with self.assertRaises(SystemExit):
            company_links.move("c1", "c2")
        self.assertEqual(len(self.rows("c1")), 1)

    def test_other_vaults_links_are_counted_but_never_opened(self):
        self.db.tables["company_links"].append(
            {"id": "l1", "company_id": "c1", "vault_id": self.OTHER, "key_id": KEY_ID, "sealed": "x"})
        self.assertEqual((company_links.count_at("c1"), company_links.read_live()), (1, {}))

    def test_before_the_migration_there_are_none(self):
        self.db.tables.pop("company_links")
        self.assertEqual((company_links.read_live(), company_links.move("c1", "c2"), company_links.count_at("c1")),
                         ({}, 0, 0))


class PlainPath(unittest.TestCase):
    """A DB without vault_migration.sql: the scripts write exactly what they always did."""

    def setUp(self):
        self.db = FakePostgREST({"recruiters": [plain("r1", "c1", "maya.rao@example.com", "Maya Rao")]},
                                migrated=False)
        self.session = contacts.Session(api=self.db, environ={}, prompt=self.never, log=lambda m: None)
        patcher = mock.patch.object(contacts, "_session", self.session)
        patcher.start()
        self.addCleanup(patcher.stop)

    def never(self, text):
        raise AssertionError("asked for a private key on a DB without vaults")

    def test_reads_need_no_key(self):
        self.assertEqual(contacts.read_live(select="id,company_id,email")[0]["email"], "maya.rao@example.com")

    def test_insert_and_update_are_plain(self):
        row = {"company_id": "c1", "name": "Zoe", "email": "zoe@example.com"}
        contacts.insert([row])
        contacts.update("r1", {"name": "Maya R"})
        self.assertEqual(self.db.writes, [("POST", "recruiters", None, [row]),
                                          ("PATCH", "recruiters", {"id": "eq.r1"}, {"name": "Maya R"})])
        self.assertNotIn("vault_id", self.db.tables["recruiters"][1])

    def test_pipeline_rewrite_is_a_plain_patch(self):
        self.db.tables["recruiters"].append(plain("r5", "c1", "a.b@wellfargo.com"))
        plan = {"creates": {}, "moves": {}, "tracking": [], "delete_companies": [], "fold_into": {},
                "delete_junk": [], "renames": {}, "sectors": {},
                "rewrite_emails": [{"id": "r5", "from": "a.b@wellfargo.com", "to": "a.b@wellsfargo.com"}]}
        st = vc.State({"companies": [], "recruiters": [], "mail_sends": [], "tracked_companies": [],
                       "user_companies": []})
        vc.apply(st, plan)
        self.assertIn(("PATCH", "recruiters", {"id": "eq.r5"}, {"email": "a.b@wellsfargo.com", "is_valid": True}),
                      self.db.writes)


if __name__ == "__main__":
    unittest.main()
