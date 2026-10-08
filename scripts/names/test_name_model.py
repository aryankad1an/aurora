"""Pins the greeting classifier to cases, and the Swift port to this one.

    python3 -m unittest -v test_name_model

The Swift parity test compiles Aurora/Models/NameClassifier.swift with a small
driver and skips itself when no `swiftc` is on PATH (or in $SWIFTC).
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import name_model as nm

REPO = Path(__file__).resolve().parents[2]

# (mailbox, the greeting a person would pick, or "-" where any greeting is
# wrong). Not greeting where a name is expected is a miss; greeting a
# different name, or greeting a "-", is an error.
LABELLED = [
    # given name alone
    ("rahul", "Rahul"), ("anjali", "Anjali"), ("priya", "Priya"), ("vijay", "Vijay"),
    ("lakshmi", "Lakshmi"), ("sunil", "Sunil"), ("pooja", "Pooja"), ("sneha", "Sneha"),
    ("mohammad", "Mohammad"), ("john", "John"), ("sarah", "Sarah"), ("michael", "Michael"),
    ("aryan", "Aryan"), ("venkateswarlu", "Venkateswarlu"), ("deepika", "Deepika"),
    ("arjun", "Arjun"), ("kavitha", "Kavitha"), ("ganesh", "Ganesh"), ("emily", "Emily"),
    # given name and surname
    ("neha.mathur", "Neha"), ("nehamathur", "Neha"), ("rohit_sharma", "Rohit"),
    ("rohitsharma", "Rohit"), ("amit.patel", "Amit"), ("amitpatel", "Amit"),
    ("priya.nair", "Priya"), ("priyanair", "Priya"), ("rakeshkumar", "Rakesh"),
    ("sanjay.gupta", "Sanjay"), ("sanjaygupta", "Sanjay"), ("john.smith", "John"),
    ("johnsmith", "John"), ("anil-thomas", "Anil"), ("deepak.yadav", "Deepak"),
    ("ravi.shankar", "Ravi"), ("suresh.reddy", "Suresh"), ("kiran.kumar", "Kiran"),
    ("abdul.rahman", "Abdul"), ("gurpreet.singh", "Gurpreet"), ("gurpreetsingh", "Gurpreet"),
    ("manoj.krishna", "Manoj"), ("sai.krishna.reddy", "Sai"), ("rahul.k.sharma", "Rahul"),
    ("david.miller", "David"), ("jennifer.lee", "Jennifer"), ("anjali.kumari87", "Anjali"),
    # surname first
    ("kumar.rahul", "Rahul"), ("sharma.amit", "Amit"), ("singh.gurpreet", "Gurpreet"),
    # given name and initial
    ("rahulk", "Rahul"), ("priyas", "Priya"), ("rahul.k", "Rahul"), ("sunil_m", "Sunil"),
    ("vijayr", "Vijay"), ("anandv", "Anand"),
    # initial and given name, separated (South Indian order)
    ("r.saravanan", "Saravanan"), ("k.lakshmi", "Lakshmi"), ("s.ramesh", "Ramesh"),
    # initials and surname: no given name to greet by
    ("akushwah", "-"), ("pm.singh", "-"), ("pmsingh", "-"), ("jsmith", "-"),
    ("a.sharma", "-"), ("asharma", "-"), ("rkgupta", "-"), ("n.mathur", "-"),
    ("skhan", "-"), ("dpatel", "-"), ("mjones", "-"), ("a.kumar.s", "-"),
    # a surname alone
    ("sharma", "-"), ("kumar", "-"), ("singh", "-"), ("patel", "-"), ("gupta", "-"),
    ("agarwal", "-"), ("iyer", "-"), ("smith", "-"),
    # words, teams, junk
    ("design", "-"), ("finance", "-"), ("marketing", "-"), ("growth", "-"),
    ("devops", "-"), ("press", "-"), ("legal", "-"), ("payroll", "-"), ("billing", "-"),
    ("accounts", "-"), ("security", "-"), ("qwzx", "-"), ("xyz", "-"), ("abc", "-"),
    ("bizdev", "-"), ("vk.mms", "-"), ("teamlead", "-"), ("helpdesk", "-"),
    ("noreply", "-"), ("webmaster", "-"), ("postmaster", "-"), ("contactus", "-"),
]


class Readings(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = nm.NameModel()

    def greet(self, local):
        return self.m.greeting(nm.parts_of(local))[0]

    def test_no_labelled_case_is_greeted_wrongly(self):
        for local, want in LABELLED:
            got = self.greet(local)
            if want == "-":
                self.assertIsNone(got, local)
            else:
                self.assertIn(got, (want, None), local)

    def test_most_named_cases_are_greeted(self):
        named = [(l, w) for l, w in LABELLED if w != "-"]
        hit = sum(self.greet(l) == w for l, w in named)
        self.assertGreaterEqual(hit / len(named), 0.85, f"{hit}/{len(named)}")

    def test_a_split_counts_toward_the_name_it_starts_with(self):
        self.assertEqual(self.greet("rakeshkumar"), "Rakesh")

    def test_an_unknown_name_is_never_guessed(self):
        self.assertIsNone(self.greet("zorvexa"))
        self.assertIsNone(self.greet("qlarbin"))

    def test_splits_respect_separators(self):
        self.assertEqual(list(nm.splits("nehamathur", 2, {4})), [["neha", "mathur"]])
        self.assertEqual(len(list(nm.splits("abcd", 2, set()))), 3)
        self.assertEqual(list(nm.splits("abcd", 2, {1, 3})), [])


@unittest.skipUnless(os.environ.get("SWIFTC") or shutil.which("swiftc"), "no swiftc")
class SwiftParity(unittest.TestCase):
    """The app's port reads every case the same way, to the same confidence."""

    def test_swift_matches_python(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        cases = [l for l, _ in LABELLED] + ["", "a", "zz", "rahul.kumar.sharma.ext", "x.y.z"]
        m = nm.NameModel()
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / "main.swift"
            driver.write_text(
                "import Foundation\n"
                "let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)\n"
                "let model = NameClassifier(modelText: text)!\n"
                "while let line = readLine() {\n"
                "    let parts = line.split(separator: \".\", omittingEmptySubsequences: false).map(String.init)\n"
                "    let r = model.greeting(parts: parts.filter { !$0.isEmpty })\n"
                "    print((r.name ?? \"-\") + \" \" + String(format: \"%.6f\", r.confidence))\n"
                "}\n")
            exe = Path(tmp) / "nc"
            subprocess.run([swiftc, "-O", str(REPO / "Aurora/Models/NameClassifier.swift"), str(driver),
                            "-o", str(exe)], check=True, capture_output=True)
            lines = "\n".join(".".join(nm.parts_of(c)) for c in cases) + "\n"
            out = subprocess.run([str(exe), str(nm.MODEL)], input=lines, capture_output=True,
                                 text=True, check=True).stdout.splitlines()
        self.assertEqual(len(out), len(cases))
        for case, line in zip(cases, out):
            name, conf = line.rsplit(" ", 1)
            want, want_conf = m.greeting(nm.parts_of(case))
            self.assertEqual(None if name == "-" else name, want, case)
            self.assertAlmostEqual(float(conf), want_conf, places=4, msg=case)


if __name__ == "__main__":
    unittest.main()
