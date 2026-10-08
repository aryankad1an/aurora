"""How well does the classifier greet, and how often does it greet wrongly?

    python3 eval_names.py              # report at the model's threshold
    python3 eval_names.py --sweep      # precision/coverage across thresholds

Two test sets:

- LABELLED (in test_name_model.py): hand-written mailboxes with the greeting
  a person would choose, or "-" where any greeting is wrong.
- Synthetic: mailboxes built from given names and surnames drawn by how
  common they are, in the patterns work addresses use: once with the model
  knowing every name, once with a fifth of the name types held out of it, so
  the classifier meets names it has never seen.

"Clear cases" leaves out wrong greetings the synthetic case can't rule out:
a "surname" drawn for a no-name case that is mostly a given name elsewhere
(Tamil records file the given name as the surname), or a greeted word that
is mostly a given name and isn't part of the true one.

A wrong greeting ("Hi Ryan," to Aryan, "Hi Kumar," to a surname) is the error
that matters; no greeting ("Hi,") is only a miss.
"""
import argparse
import collections
import random

import name_model as nm
from test_name_model import LABELLED

# Pattern -> (how to spell it, whether it greets the given name). Weights
# follow the model's priors so the mix is what the model expects; the
# held-out names are what it doesn't.
SEPS = ["", ".", "_", "-"]


def sample(model, rng, given, surnames):
    g = rng.choices(given[0], given[1])[0]
    s = rng.choices(surnames[0], surnames[1])[0]
    s2 = rng.choices(surnames[0], surnames[1])[0]
    i = rng.choice("abcdefghijklmnoprstvy")
    i2 = i + rng.choice("abcdefghijklmnoprstvy")
    pat = rng.choices(list(model.priors), list(model.priors.values()))[0]
    glue = model.glue.get(pat, 0)
    sep = lambda: "" if rng.random() < glue else rng.choice(SEPS[1:])
    build = {
        "G": [g], "S": [s], "GS": [g, s], "SG": [s, g], "Gi": [g, i], "IG": [i, g],
        "IS": [rng.choice([i, i2]), s], "GG": None, "GSS": [g, s, s2], "GGS": None,
        "GiS": [g, i, s], "ISI": [i, s, i], "IIS": [i, i2[1], s], "W": None, "WW": None, "O": None,
    }[pat]
    if build is None:
        return None
    local = build[0]
    for piece in build[1:]:
        local += sep() + piece
    return local, (g if "G" in pat else None)


def held_out(model, rng, share=0.2):
    given = sorted(model.given)
    surnames = sorted(model.surname)
    weights_g = [model.p_given(w) for w in given]
    weights_s = [(model.p_surname(w)) for w in surnames]
    for w in rng.sample(given, int(len(given) * share)):
        del model.given[w]
    for w in rng.sample(surnames, int(len(surnames) * share)):
        del model.surname[w]
    return (given, weights_g), (surnames, weights_s)


def ambiguous(model, local, truth, got):
    """A "wrong" greeting the case's own construction can't rule out: the
    surname drawn for a no-name case is mostly a given name elsewhere
    (`yo_murugan`: Tamil records file the given name as the surname), or the
    greeted word is the truth's other half and is mostly a given name too."""
    def given_share(w):
        g, s = model.p_given(w), model.p_surname(w)
        return g / (g + s) if g + s else 0
    return got is not None and given_share(got) >= 0.5 and (truth is None or got not in truth)


def score(model, cases, threshold, reference=None):
    model.threshold = threshold
    reference = reference or model
    c = collections.Counter()
    wrong = []
    for local, truth in cases:
        got, _ = model.greeting(nm.parts_of(local))
        got = got.lower() if got else None
        if truth is None:
            c["no-name cases"] += 1
        else:
            c["named cases"] += 1
        if got and got == truth:
            c["right"] += 1
        elif got:
            c["wrong"] += 1
            if ambiguous(reference, local, truth, got):
                c["ambiguous"] += 1
            wrong.append((local, got, truth))
    greeted = c["right"] + c["wrong"]
    c["precision"] = c["right"] / greeted if greeted else 1.0
    c["precision, clear cases"] = c["right"] / (greeted - c["ambiguous"]) if greeted > c["ambiguous"] else 1.0
    c["coverage"] = c["right"] / c["named cases"] if c["named cases"] else 0.0
    return c, wrong


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("-n", type=int, default=4000)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    labelled = [(local, None if want == "-" else want.lower()) for local, want in LABELLED]
    model = nm.NameModel()
    sets = [("labelled", model, labelled)]
    for share in (0.0, 0.2):
        rng = random.Random(args.seed)
        held = nm.NameModel()
        given, surnames = held_out(held, rng, share)
        cases = []
        while len(cases) < args.n:
            case = sample(held, rng, given, surnames)
            if case:
                cases.append(case)
        sets.append((f"synthetic, {share:.0%} held out", held, cases))

    thresholds = [0.5, 0.7, 0.8, 0.85, 0.9, 0.95, 0.98] if args.sweep else [model.threshold]
    for t in thresholds:
        for label, m, cases in sets:
            c, wrong = score(m, cases, t, reference=model)
            print(f"threshold {t:.2f}  {label:24} precision {c['precision']:.3f} "
                  f"(clear cases {c['precision, clear cases']:.3f})  "
                  f"coverage {c['coverage']:.3f}  wrong {c['wrong']}/{len(cases)}")
            if not args.sweep:
                for local, got, truth in wrong[:15]:
                    print(f"    {local:24} greeted {got!r}, should be {truth!r}")


if __name__ == "__main__":
    main()
