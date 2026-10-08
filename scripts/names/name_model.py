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
        same name, or a listed one that is `name` with a surname fused on
        (Rakesh + kumar, Lakshmi + devi). Two given names fused (Nag + arjuna)
        don't shorten: Nagarjuna isn't "Nag"."""
        if full == name:
            return True
        rest = full[len(name):]
        return full.startswith(name) and full in self.given and len(rest) >= 3 and rest in self.surname

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
        for name in sorted((g for g, _ in readings if g in self.given), key=len, reverse=True):
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
