"""vault_crypto.py against NIST's GCM vectors and the app's own Swift code.

    python3 -m unittest -v test_vault_crypto        # from scripts/

Swift -> Python: vault_vectors.json was sealed by vault_vectors.swift, compiled
against Aurora/Models/Sealing.swift and KeyRing.swift; every value must open
here. Python -> Swift: when swiftc and those files are on hand, the same
program is compiled and opens what Python seals (skipped otherwise; set
AURORA_SWIFT_SOURCES to a folder holding Sealing.swift and KeyRing.swift to
point it elsewhere).
"""
import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import vault_crypto as vc

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
VECTORS = json.loads((HERE / "vault_vectors.json").read_text())


class NIST(unittest.TestCase):
    """AES-256 and GCM as specified, before any comparison with Swift."""

    def test_aes256_block(self):  # FIPS-197 appendix C.3
        w = vc._expand(bytes(range(32)))
        out = vc._encrypt_block(w, int("00112233445566778899aabbccddeeff", 16))
        self.assertEqual(f"{out:032x}", "8ea2b7ca516745bfeafc49904b496089")

    def test_gcm_zero_key(self):  # GCM spec test cases 13 and 14
        self.assertEqual(vc.gcm_seal(bytes(32), bytes(12), b"")[1].hex(), "530f8afbc74536b9a963b4f1c4cb738b")
        ct, tag = vc.gcm_seal(bytes(32), bytes(12), bytes(16))
        self.assertEqual(ct.hex(), "cea7403d4d606b6e074ec5d3baf39d18")
        self.assertEqual(tag.hex(), "d0d1c8a799996bf0265b98b5d48ab919")

    def test_gcm_with_aad_and_partial_block(self):  # GCM spec test case 16
        k = bytes.fromhex("feffe9928665731c6d6a8f9467308308" * 2)
        iv = bytes.fromhex("cafebabefacedbaddecaf888")
        p = bytes.fromhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
                          "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
        a = bytes.fromhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        ct, tag = vc.gcm_seal(k, iv, p, a)
        self.assertEqual(ct.hex(), "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
                                   "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662")
        self.assertEqual(tag.hex(), "76fc6ece0f4e1768cddf8853bb2d551b")
        self.assertEqual(vc.gcm_open(k, iv, ct, tag, a), p)

    def test_pbkdf2(self):  # RFC 7914 §11
        self.assertEqual(vc.derive_key("passwd", b"salt", 1)[:16].hex(), "55ac046e56e3089fec1691c22544b605")


class SwiftSealedOpensHere(unittest.TestCase):
    key = bytes.fromhex(VECTORS["key_hex"])

    def test_contexts_match_word_for_word(self):
        c = VECTORS["contexts"]
        id_, vault, key_id, email = ("6F9619FF-8B86-D011-B42D-00C04FC964FF", "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
                                     "8C2D1A7E-5B3F-4E21-9A0B-7D6C5E4F3A21", "Maya.Rao@Example.com")
        self.assertEqual(vc.contact_context(id_, vault), c["contact"])
        self.assertEqual(vc.send_context(id_), c["send"])
        self.assertEqual(vc.reply_context(id_), c["reply"])
        self.assertEqual(vc.template_context(id_), c["template"])
        self.assertEqual(vc.profile_context(email), c["profile"])
        self.assertEqual(vc.vault_key_context(vault, key_id), c["vault_key"])
        self.assertEqual(vc.grant_context(email, vault, key_id), c["grant"])
        self.assertEqual(vc.account_context(email), c["account"])

    def test_values_open(self):
        for s in VECTORS["seals"]:
            self.assertEqual(vc.open_sealed(s["sealed"], self.key, s["context"]).hex(), s["plaintext_hex"])

    def test_contacts_open(self):
        for c in VECTORS["contacts"]:
            self.assertEqual(vc.open_contact(c["sealed"], self.key, c["id"], c["vault_id"]), c["fields"])

    def test_derived_keys_match(self):
        for d in VECTORS["derived"]:
            got = vc.derive_key(d["secret"], bytes.fromhex(d["salt_hex"]), d["rounds"])
            self.assertEqual(got.hex(), d["key_hex"], repr(d["secret"]))

    def test_vault_unlocks(self):
        v = VECTORS["vault"]
        key_id, key = vc.unlock_vault(v["row"], v["private_key"])
        self.assertEqual(key.hex(), v["vault_key_hex"])
        self.assertEqual(key_id, v["row"]["key_id"])
        with self.assertRaises(vc.CannotOpen):
            vc.unlock_vault(v["row"], "not the key")

    def test_moved_changed_or_garbage_values_do_not_open(self):
        c = VECTORS["contacts"][0]
        with self.assertRaises(vc.CannotOpen):  # another row
            vc.open_contact(c["sealed"], self.key, "00000000-0000-0000-0000-000000000000", c["vault_id"])
        with self.assertRaises(vc.CannotOpen):  # another vault
            vc.open_contact(c["sealed"], self.key, c["id"], "00000000-0000-0000-0000-000000000000")
        with self.assertRaises(vc.CannotOpen):  # a wrong key
            vc.open_contact(c["sealed"], bytes(32), c["id"], c["vault_id"])
        raw = bytearray(base64.b64decode(c["sealed"][3:]))
        raw[-1] ^= 1
        with self.assertRaises(vc.CannotOpen):  # one changed bit
            vc.open_contact("v1." + base64.b64encode(bytes(raw)).decode(), self.key, c["id"], c["vault_id"])
        for junk in ("garbage", "v1.***", "v1." + base64.b64encode(b"short").decode(), None):
            with self.assertRaises(vc.Malformed):
                vc.open_sealed(junk, self.key, "x")


class Roundtrip(unittest.TestCase):
    def test_contact_leaves_out_empty_fields_and_reads_them_as_none(self):
        key, rid, vid = vc.new_key(), "r1", "v1"
        sealed = vc.seal_contact({"name": "A B", "email": "a@x.com", "position": "", "phone": None}, key, rid, vid)
        inner = json.loads(vc.open_sealed(sealed, key, vc.contact_context(rid, vid)))
        self.assertEqual(inner, {"n": "A B", "e": "a@x.com"})
        self.assertEqual(vc.open_contact(sealed, key, rid, vid),
                         {"name": "A B", "email": "a@x.com", "position": None, "phone": None, "greeting_name": None})

    def test_each_seal_uses_a_fresh_nonce(self):
        key = vc.new_key()
        self.assertNotEqual(vc.seal(b"x", key, "c"), vc.seal(b"x", key, "c"))

    def test_normalized_trims_like_foundation(self):
        self.assertEqual(vc.normalized("   x 　\u0085"), "x")
        self.assertEqual(vc.normalized("\x1cx\x1f"), "\x1cx\x1f")   # Python's strip() would drop these
        self.assertEqual(vc.normalized("​x﻿"), "x﻿")     # Foundation drops U+200B, keeps U+FEFF
        self.assertEqual(vc.normalized("café"), "café")

    def test_private_key_comes_from_the_environment_or_a_prompt(self):
        self.assertEqual(vc.read_private_key("AURORA", {"AURORA_PRIVATE_KEY": "k"}, prompt=None), "k")
        asked = []
        self.assertEqual(vc.read_private_key("AURORA", {}, prompt=lambda p: asked.append(p) or "typed"), "typed")
        self.assertIn("AURORA", asked[0])

    def test_vault_without_a_key_is_refused(self):
        with self.assertRaises(ValueError):
            vc.unlock_vault({"id": "v", "code": "AURORA", "key_id": None, "sealed_key": None, "kdf_salt": None}, "k")


def swift_sources():
    root = Path(os.environ.get("AURORA_SWIFT_SOURCES") or REPO / "Aurora" / "Models")
    files = [root / "Sealing.swift", root / "KeyRing.swift"]
    return files if all(f.exists() for f in files) else None


@unittest.skipUnless(shutil.which("swiftc") and swift_sources(), "needs swiftc and Aurora/Models/Sealing.swift")
class PythonSealedOpensInSwift(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.tmp.name) / "vault_vectors"
        subprocess.run(["swiftc", "-parse-as-library", *map(str, swift_sources()), str(HERE / "vault_vectors.swift"),
                        "-o", str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def swift(self, *args, stdin=None):
        return subprocess.run([str(self.binary), *args], input=stdin, check=True, capture_output=True, text=True).stdout

    def test_python_seals_open_in_swift(self):
        key = vc.new_key()
        rid, vid, kid = "6F9619FF-8B86-D011-B42D-00C04FC964FF", "0e984725-c51c-4bf4-9960-e1c80e27aba0", "8c2d1a7e-5b3f-4e21-9a0b-7d6c5e4f3a21"
        texts = ["", "hello", "sixteen bytes!!!" * 3, "Zoë — café ☕️ 名前"]
        seals = [{"plaintext_hex": t.encode().hex(), "context": vc.send_context(rid),
                  "sealed": vc.seal(t.encode(), key, vc.send_context(rid))} for t in texts]
        fields = [{"name": "Maya Rao", "email": "maya.rao@example.com", "position": "Talent Partner",
                   "phone": "+91 98765 43210", "greeting_name": "Maya"},
                  {"name": "Zoë Ünal", "email": "zoe/unal@example.com", "position": None, "phone": None,
                   "greeting_name": None}]
        contacts = [{"id": rid, "vault_id": vid, "fields": f, "sealed": vc.seal_contact(f, key, rid, vid)} for f in fields]
        salt, private = os.urandom(16), "  correct horse battery staple "
        vault_key = vc.new_key()
        row = {"id": vid, "key_id": kid, "kdf_salt": base64.b64encode(salt).decode(), "kdf_rounds": 1000,
               "sealed_key": vc.wrap(vault_key, vc.derive_key(private, salt, 1000), vc.vault_key_context(vid, kid))}
        rejects = [{"sealed": contacts[0]["sealed"], "context": vc.contact_context("other", vid), "why": "moved row"},
                   {"sealed": seals[1]["sealed"], "context": vc.reply_context(rid), "why": "other context"}]
        out = json.loads(self.swift("open", stdin=json.dumps({
            "key_hex": key.hex(), "seals": seals, "contacts": contacts, "rejects": rejects,
            "vault": {"row": row, "private_key": private, "vault_key_hex": vault_key.hex()}})))
        self.assertEqual(out, {"ok": True, "failures": []})

    def test_committed_vectors_are_what_swift_makes_today(self):
        """Fresh Swift seals (new nonces) still open here, and the derived keys still agree."""
        fresh = json.loads(self.swift("make"))
        self.assertEqual(fresh["contexts"], VECTORS["contexts"])
        self.assertEqual(fresh["derived"], VECTORS["derived"])
        key = bytes.fromhex(fresh["key_hex"])
        for c in fresh["contacts"]:
            self.assertEqual(vc.open_contact(c["sealed"], key, c["id"], c["vault_id"]), c["fields"])


if __name__ == "__main__":
    unittest.main()
