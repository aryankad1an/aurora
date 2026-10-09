"""Who does a mailbox greet? The reference implementation of the classifier the
app runs (`Aurora/Models/NameClassifier.swift`); the two must agree, and
`test_name_model.py` checks the Swift port against this one.

A mailbox is read as one of a few patterns a person's work address is built
from: a given name alone (`rahul`), given name and surname (`neha.mathur`,
`nehamathur`), initials and surname (`akushwah`, `pm.singh`), given name and
initial (`rahulk`), initial and given name (`ksaravanan`, the South Indian
order), a surname alone, an English word, or none of those. Each pattern is a
small generative model with a prior; a slot's likelihood comes from how common
the word is as a given name, a surname or an English word, and letter trigrams
spell out surnames the lists don't have and anything that isn't a name at all.
Separators (`.`, `_`, `-`, digits) must fall between slots; without them every
split is tried.

The posterior of each reading is summed by the given name it would greet, and
a name is used only when its share reaches `threshold`. A given name has to be
in the lists to be greeted: a name the model has never seen is never guessed.
"""
import collections
import math
import re
from pathlib import Path

MODEL = Path(__file__).resolve().parents[2] / "Aurora" / "Resources" / "NameModel.txt"
ALPHA = "abcdefghijklmnopqrstuvwxyz"


class NameModel:
    def __init__(self, path=MODEL):
        self.priors, self.glue, self.const = {}, {}, {}
        self.given, self.surname, self.words = {}, {}, set()
        self.tri = {"trigram_other": {}, "trigram_given": {}, "trigram_surname": {}}
        section = None
        for line in Path(path).read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            if line.startswith("@"):
                section = line[1:]
                continue
            if section == "words":
                self.words.add(line)
                continue
            key, value = line.split(" ", 1)
            if section in ("priors", "glue"):
                getattr(self, section)[key] = float(value)
            elif section == "constants":
                self.const[key] = float(value)
            elif section in ("given", "surname"):
                getattr(self, section)[key] = int(value)
            else:
                self.tri[section][key] = [(ord(c) - 33) * 0.2 for c in value]
        self.scale = self.const["scale"]
        self.threshold = self.const["threshold"]
        self.learned = {"given": collections.Counter(), "surname": collections.Counter()}

    # -- learning from the catalog ---------------------------------------------

    def learn(self, people):
        """Learn given names and surnames from the catalog's own name fields,
        replacing anything learned before.

        `people` are name fields as lowercase letter words, in the order
        written, with notes, honorifics and rows naming a role already left
        out. Only the first and last word are read.

        A field teaches only when it's clear which way round it is. Fields are
        written given name first (`learn_order` of the time) unless the listed
        words say otherwise; a word the lists don't have leans neither way. One
        reading has to be nine times likelier than the other, and one half has
        to be listed in its role: "Arijit Sen" teaches Arijit (Sen is a listed
        surname), "Singh Gurpreet" teaches Gurpreet, "Subhajit Paul" teaches
        Subhajit even though Paul is a given name too. A common English word
        teaches nothing unless the lists know it as a name. A name only the
        catalog knows is greeted once it has been taught `catalog_min_count`
        times; one odd record can't put a name in a greeting."""
        self.learned = {"given": collections.Counter(), "surname": collections.Counter()}
        learned = {"given": collections.Counter(), "surname": collections.Counter()}
        for words in people:
            if len(words) < 2 or words[0] == words[-1] or min(len(words[0]), len(words[-1])) < 3:
                continue
            a, b = words[0], words[-1]
            order = self.const["learn_order"]
            forward = order * self.p_public(self.given, a) * self.p_public(self.surname, b)
            backward = (1 - order) * self.p_public(self.surname, a) * self.p_public(self.given, b)
            if forward >= 9 * backward:
                given, surname = a, b
            elif backward >= 9 * forward:
                given, surname = b, a
            else:
                continue
            if given not in self.given and surname not in self.surname:
                continue  # nothing anchors it
            if self.teaches(given, self.given):
                learned["given"][given] += 1
            if self.teaches(surname, self.surname):
                learned["surname"][surname] += 1
        self.learned = learned

    def p_public(self, table, w):
        """A word's listed probability, or a role-neutral floor if unlisted."""
        c = table.get(w)
        return math.exp(-c / self.scale) if c is not None else self.const["learn_unlisted"]

    def teaches(self, w, table):
        return w in table or w not in self.words

    def knows_given(self, w):
        return w in self.given or self.learned["given"][w] >= self.const["catalog_min_count"]

    def knows_surname(self, w):
        return w in self.surname or self.learned["surname"][w] >= self.const["catalog_min_count"]

    # -- slot likelihoods ---------------------------------------------------

    def p_given(self, w):
        """Listed given names, plus a share for names the lists don't have.
        Those can't be greeted, but they keep a misreading from winning by
        default: `singh.gurpreet` is Gurpreet Singh even if Gurpreet is unknown."""
        return self.p_listed(self.given, "given", w)

    def p_surname(self, w):
        return self.p_listed(self.surname, "surname", w)

    def p_listed(self, table, kind, w):
        if len(w) < 2:
            return 0.0
        c = table.get(w)
        listed = math.exp(-c / self.scale) if c is not None else 0.0
        # Names the catalog taught, blended in by how much it has taught: the
        # catalog is the population being greeted, but a small one.
        counts = self.learned[kind]
        n = sum(counts.values())
        if n:
            share = min(self.const["catalog_max"], n / (n + self.const["catalog_prior"]))
            listed = (1 - share) * listed + share * counts.get(w, 0) / n
        oov = self.const[kind + "_oov"]
        return (1 - oov) * listed + oov * self.p_trigram("trigram_" + kind, w)

    def p_initials(self, w):
        return {1: self.const["initial1"], 2: self.const["initial2"]}.get(len(w), 0.0)

    def p_word(self, w):
        return 1 / len(self.words) if w in self.words else 0.0

    def p_trigram(self, table, w):
        rows, nats, a, b = self.tri[table], 0.0, "^", "^"
        for c in w + "$":
            nats += rows[a + b][ALPHA.index(c) if c != "$" else 26]
            a, b = b, c
        return math.exp(-nats)

    def slot(self, kind, w):
        if kind == "G":
            return self.p_given(w)
        if kind == "S":
            return self.p_surname(w)
        if kind == "I":
            return self.p_initials(w)
        if kind == "i":
            return self.const["initial1"] if len(w) == 1 else 0.0
        if kind == "i+":  # glued on: a vowel there ends a name (Suneeta), it isn't an initial
            return self.const["initial1"] if len(w) == 1 and w not in "aeiou" else 0.0
        return self.p_word(w)

    def calls(self, full, name):
        """Whether someone whose given name reads as `full` goes by `name`: the
        same name, or a known one that is `name` with a common surname fused on
        (Rakesh + kumar, Lakshmi + devi, Srinivasa + rao). Anything else fused
        doesn't shorten: Nagarjuna isn't "Nag", Lakshmanan isn't "Laksh"."""
        if full == name:
            return True
        rest = full[len(name):]
        return (full.startswith(name) and self.knows_given(full) and len(rest) >= 3
                and rest in self.surname and math.exp(-self.surname[rest] / self.scale) >= self.const["compound_suffix"])

    # -- readings -----------------------------------------------------------

    def readings(self, parts):
        """[(greeting or None, posterior)] for a mailbox split at its separators,
        most likely first. `parts` are lowercase a-z runs."""
        text = "".join(parts)
        if not text:
            return []
        cuts, at = set(), 0
        for p in parts[:-1]:
            at += len(p)
            cuts.add(at)
        scores, seen = {}, {}

        def slot(kind, start, piece):
            if kind == "i" and start not in cuts:
                kind = "i+"
            if (kind, piece) not in seen:
                seen[kind, piece] = self.slot(kind, piece)
            return seen[kind, piece]

        def add(greet, p):
            if p > 0:
                scores[greet] = scores.get(greet, 0.0) + p

        for pattern, prior in self.priors.items():
            if pattern == "O":
                p = 1.0
                for part in parts:
                    p *= self.p_trigram("trigram_other", part)
                add(None, prior * p)
                continue
            glue = self.glue.get(pattern, 0.0)
            for pieces in splits(text, len(pattern), cuts):
                p = prior
                at = 0
                for piece in pieces[:-1]:
                    at += len(piece)
                    p *= (1 - glue) if at in cuts else glue
                start = 0
                for kind, piece in zip(pattern, pieces):
                    p *= slot(kind, start, piece)
                    start += len(piece)
                    if p == 0:
                        break
                g = pattern.find("G")
                add(pieces[g] if g >= 0 else None, p)
        total = sum(scores.values())
        if total == 0:
            return [(None, 1.0)]
        return sorted(((g, p / total) for g, p in scores.items()), key=lambda gp: -gp[1])

    def greeting(self, parts):
        """(given name or None, confidence): the name is given only when the
        confidence — its support — reaches `threshold`; otherwise confidence is
        how close the best listed name came.

        Only a listed given name is greeted. Its support is the share of
        readings that greet by it, or by a listed name that is it with a
        surname fused on: `rakeshkumar` read as Rakesh + Kumar or as the single
        name Rakeshkumar both call him Rakesh. The longest name with support at
        the threshold is used."""
        readings = self.readings(parts)
        best, support, closest = None, 0.0, 0.0
        for name in sorted((g for g, _ in readings if g and self.knows_given(g)), key=len, reverse=True):
            s = sum(p for g, p in readings if g and self.calls(g, name))
            closest = max(closest, s)
            if s >= self.threshold:
                best, support = name, s
                break
        if best is None:
            return None, closest
        return best[:1].upper() + best[1:], support


def splits(text, k, cuts):
    """Every way to cut `text` into `k` non-empty pieces that cuts at each of
    `cuts` (the separator positions) and may cut anywhere else too."""
    n = len(text)
    if k - 1 < len(cuts):
        return

    def rec(start, left):
        if left == 1:
            # The last piece may not span a separator.
            if not any(start < c < n for c in cuts):
                yield [text[start:]]
            return
        for end in range(start + 1, n - left + 2):
            if any(start < c < end for c in cuts):
                break
            for rest in rec(end, left - 1):
                yield [text[start:end]] + rest

    yield from rec(0, k)


def parts_of(local):
    """A mailbox's lowercase letter runs, split at separators and digits."""
    return [p for p in re.split(r"[^a-z]+", local.lower().split("+", 1)[0]) if p]


# The app's `RecipientName` lists, for reading rows the way the app does.
ROLE_WORDS = {
    "hr", "info", "jobs", "job", "careers", "career", "recruiting", "recruitment", "recruiter",
    "recruiters", "talent", "hiring", "contact", "hello", "team", "admin", "support", "apply",
    "applications", "resume", "resumes", "cv", "office", "people", "staffing", "internships",
    "internship", "campus", "noreply", "no-reply", "ta", "talentacquisition", "corporatehr", "hrd",
    "hrteam", "placement", "placements", "operations", "dl", "mailer", "enquiry", "enquiries",
    "sales", "backend", "frontend", "engineering", "tech", "india", "global", "services",
    "connect", "reachouts", "outreach", "partnerships", "partner", "business", "marketing", "ops",
}
FILLER_WORDS = {"here", "official", "work", "mail", "me", "the", "real", "its", "im", "iam", "mr", "ms", "dr"}
HONORIFICS = {"mr", "mrs", "ms", "miss", "mx", "dr", "prof", "professor", "sir", "madam", "madame",
              "shri", "smt", "sri", "er", "ca", "capt", "rev", "hon"}


def mailbox_parts(email):
    """What `RecipientName.nameFromEmail` asks the classifier about: the
    mailbox's a-z runs without role and filler words or the company's own
    name, or None where it asks nothing (a role mailbox, leetspeak)."""
    email = (email or "").lower().strip()
    local, _, domain = email.partition("@")
    local = local.split("+", 1)[0]
    if not local or local in ROLE_WORDS or re.search(r"[a-z][0-9]+[a-z]", local):
        return None
    labels = set(domain.split("."))
    words = [w for w in re.split(r"[^a-z]+", local) if w and w not in ROLE_WORDS
             and w not in FILLER_WORDS and w not in labels]
    return words or None


def is_mailbox_copy(name, email):
    """As `RecipientName.isMailboxCopy`: one word with the mailbox's letters
    ("Akushwah" for `akushwah@`). A spaced name that matches a `first.last`
    address ("Arijit Sen" for `arijit.sen@`) is a real name."""
    text = (name or "").strip()
    bare = lambda t: "".join(c for c in t.lower() if c.isalpha())
    return not any(c.isspace() for c in text) and bare(text) == bare((email or "").split("@")[0])


def plausible_given_name(model, word):
    """Whether `word` read alone could well be someone's given name, listed or
    not: at least 5% of the readings take the whole word as one. `arijit` and
    `subhajit` are; `akushwah` (A + Kushwah) and `talksaravanan` aren't."""
    w = word.lower()
    if len(w) < 3 or not w.isalpha():
        return False
    return sum(p for g, p in model.readings([w]) if g == w) >= 0.05


def name_words(name, email):
    """What `RecipientName.nameWords` teaches from a row: its name field as
    lowercase a-z words, given name first where a comma says the surname
    leads, or None (a mailbox copied over, an address, a role)."""
    import unicodedata
    text = (name or "").strip()
    if not text or "@" in text or is_mailbox_copy(text, email):
        return None
    text = re.sub(r"\([^)]*\)|\[[^]]*\]", " ", text)
    head, comma, tail = (x.strip() for x in text.partition(","))
    text = f"{tail} {head}" if comma and tail and len(head.split(" ")) == 1 else head
    folded = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c)).lower()
    words = []
    for word in re.split(r"[ \t.\-]+", folded):
        word = word.replace("'", "")
        if not word:
            continue
        if not re.fullmatch(r"[a-z]+", word):
            return None
        if word in HONORIFICS:
            continue
        if word in ROLE_WORDS:
            return None
        words.append(word)
    return words if len(words) >= 2 else None
