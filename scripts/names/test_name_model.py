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


# Coverage: realistic work addresses across India's regions and naming
# customs, each with the name a person would greet by. Written before the
# model was extended, to measure how many it greets (`eval_names.py`). Not
# greeting one is a miss, not an error; greeting a different name is an error.
COVERAGE = [
    # Punjabi / Sikh
    ("gurpreet.singh", "Gurpreet"), ("harpreetkaur", "Harpreet"), ("manpreet", "Manpreet"),
    ("jaspreet.kaur", "Jaspreet"), ("navneet.sandhu", "Navneet"), ("simran.gill", "Simran"),
    ("amandeep", "Amandeep"), ("ravinder.singh", "Ravinder"),
    # Hindi belt
    ("ankit.verma", "Ankit"), ("priyanka.mishra", "Priyanka"), ("shubham", "Shubham"),
    ("saurabh.tiwari", "Saurabh"), ("shivani", "Shivani"), ("abhishek.pandey", "Abhishek"),
    ("nidhi.srivastava", "Nidhi"), ("aakash.agarwal", "Aakash"), ("deepti", "Deepti"),
    ("rajat.saxena", "Rajat"), ("vikas.chauhan", "Vikas"), ("pallavi", "Pallavi"),
    # Bengali / Odia
    ("sourav.ganguly", "Sourav"), ("subhajit", "Subhajit"), ("arijit.das", "Arijit"),
    ("debashis.roy", "Debashis"), ("moumita", "Moumita"), ("sayantan", "Sayantan"),
    ("tanmay.mohanty", "Tanmay"), ("sudipta.ghosh", "Sudipta"),
    # Marathi / Gujarati
    ("sachin.patil", "Sachin"), ("swapnil", "Swapnil"), ("tejas.kulkarni", "Tejas"),
    ("prachi", "Prachi"), ("hardik.patel", "Hardik"), ("dhruv.shah", "Dhruv"),
    ("nikhil.joshi", "Nikhil"), ("snehal", "Snehal"),
    # Tamil / Malayalam / Kannada / Telugu
    ("karthik", "Karthik"), ("senthil.kumar", "Senthil"), ("murugan", "Murugan"),
    ("anoop", "Anoop"), ("sreejith.nair", "Sreejith"), ("jithin", "Jithin"),
    ("manjunath", "Manjunath"), ("raghavendra.rao", "Raghavendra"), ("divya.menon", "Divya"),
    ("lakshmi.priya", "Lakshmi"), ("vignesh", "Vignesh"), ("aishwarya", "Aishwarya"),
    ("harsha.vardhan", "Harsha"), ("srinivas", "Srinivas"),
    # Muslim
    ("faizan.khan", "Faizan"), ("ayesha", "Ayesha"), ("sameer.shaikh", "Sameer"),
    ("imran", "Imran"), ("zainab", "Zainab"), ("arshad.ali", "Arshad"),
    # born after 2000, and common everywhere
    ("aarav", "Aarav"), ("ishaan", "Ishaan"), ("ananya.sharma", "Ananya"), ("kavya", "Kavya"),
    ("aryan", "Aryan"), ("riya", "Riya"), ("vivek", "Vivek"), ("tanvi", "Tanvi"),
    # North-East
    ("bhaskar.bora", "Bhaskar"), ("lalremruata", "Lalremruata"),
]


# Name fields as a catalog might hold them, for the learning tests.
CATALOG = [p.split() for p in [
    "arijit sen", "arijit das", "sreejith nair", "sreejith menon", "singh gurpreet", "gurpreet kaur",
    "jithin kumar", "jithin nair", "jithin joseph", "moumita dey", "debashis roy", "subhajit paul", "rahul sharma",
    "infosys recruiter", "talent acquisition", "kumar rahul", "neha", "priya r",
]]


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

    def test_regional_names_are_greeted_and_never_misgreeted(self):
        hit = 0
        for local, want in COVERAGE:
            got = self.greet(local)
            self.assertIn(got, (want, None), local)
            hit += got == want
        self.assertGreaterEqual(hit / len(COVERAGE), 0.8, f"{hit}/{len(COVERAGE)}")

    def test_a_split_counts_toward_the_name_it_starts_with(self):
        self.assertEqual(self.greet("rakeshkumar"), "Rakesh")

    def test_an_unknown_name_is_never_guessed(self):
        self.assertIsNone(self.greet("zorvexa"))
        self.assertIsNone(self.greet("qlarbin"))

    def test_the_catalog_teaches_names_the_lists_lack(self):
        m = nm.NameModel()
        self.assertIsNone(m.greeting(["arijit"])[0])
        m.learn(CATALOG)
        self.assertEqual(m.greeting(["arijit"])[0], "Arijit")
        self.assertEqual(m.greeting(["sreejith", "nair"])[0], "Sreejith")
        self.assertEqual(m.greeting(["jithin"])[0], "Jithin")

    def test_learning_reads_which_way_round_a_name_is(self):
        m = nm.NameModel()
        m.learn([["singh", "gurpreet"], ["sreejith", "nair"]])
        self.assertEqual(m.learned["given"].keys() & {"gurpreet", "sreejith"}, {"gurpreet", "sreejith"})
        self.assertNotIn("singh", m.learned["given"])
        self.assertNotIn("nair", m.learned["given"])

    def test_one_odd_record_greets_no_one(self):
        m = nm.NameModel()
        m.learn([["moumita", "dey"]])
        self.assertIsNone(m.greeting(["moumita"])[0])
        m.learn([["moumita", "dey"], ["moumita", "das"]])
        self.assertEqual(m.greeting(["moumita"])[0], "Moumita")

    def test_unanchored_and_word_names_teach_nothing(self):
        m = nm.NameModel()
        m.learn([["zorvexa", "qlarbin"], ["design", "lead"]] * 3)
        self.assertEqual(sum(m.learned["given"].values()), 0)

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
                "    if line.hasPrefix(\"!\") {\n"
                "        model.learn(people: line.dropFirst().split(separator: \";\").map { $0.split(separator: \" \").map(String.init) })\n"
                "        continue\n"
                "    }\n"
                "    let parts = line.split(separator: \".\", omittingEmptySubsequences: false).map(String.init)\n"
                "    let r = model.greeting(parts: parts.filter { !$0.isEmpty })\n"
                "    print((r.name ?? \"-\") + \" \" + String(format: \"%.6f\", r.confidence))\n"
                "}\n")
            exe = Path(tmp) / "nc"
            subprocess.run([swiftc, "-O", str(REPO / "Aurora/Models/NameClassifier.swift"), str(driver),
                            "-o", str(exe)], check=True, capture_output=True)
            # Every case read cold, then again after learning a small catalog.
            learned_cases = [c for c, _ in COVERAGE] + ["arijit", "sreejith.nair", "jithin", "subhajit"]
            lines = ("\n".join(".".join(nm.parts_of(c)) for c in cases) + "\n!"
                     + ";".join(" ".join(p) for p in CATALOG) + "\n"
                     + "\n".join(".".join(nm.parts_of(c)) for c in learned_cases) + "\n")
            out = subprocess.run([str(exe), str(nm.MODEL)], input=lines, capture_output=True,
                                 text=True, check=True).stdout.splitlines()
        self.assertEqual(len(out), len(cases) + len(learned_cases))
        expected = [m.greeting(nm.parts_of(c)) for c in cases]
        m.learn(CATALOG)
        expected += [m.greeting(nm.parts_of(c)) for c in learned_cases]
        for case, line, (want, want_conf) in zip(cases + learned_cases, out, expected):
            name, conf = line.rsplit(" ", 1)
            self.assertEqual(None if name == "-" else name, want, case)
            self.assertAlmostEqual(float(conf), want_conf, places=4, msg=case)


if __name__ == "__main__":
    unittest.main()
