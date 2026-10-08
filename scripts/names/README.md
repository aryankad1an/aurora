# Greeting classifier

Decides whether an email address names a person, and the given name to greet
them by — or that it doesn't, so the mail opens with a bare "Hi,". The app runs
it on device (`Aurora/Models/NameClassifier.swift`) for any contact whose name
field doesn't give a usable name; `RecipientName` calls it.

Where a greeting comes from, first match wins:

1. the contact's stored `greeting_name`;
2. their name field, unless it only copies the mailbox;
3. the name they signed a reply with (`From: Anjali Kumari <anjali@acme.com>`,
   from the same address; the app already reads reply headers);
4. the address, read by this classifier with names learned from the catalog;
5. nothing: "Hi,".

```bash
pip install rdata                      # build only
python3 build_model.py                 # download (cached in .cache/names/), verify, write the model
python3 build_model.py --check         # fail if the committed model is stale
python3 -m unittest -v test_name_model # cases + Swift-vs-Python parity (needs swiftc, else skipped)
python3 eval_names.py [--sweep]        # precision and coverage
```

## How it reads an address

A mailbox is read as one of the patterns a work address is built from. Each is
a tiny generative model with a prior:

| pattern | example | greets |
|---|---|---|
| G | `rahul` | Rahul |
| GS, GSS, GGS | `neha.mathur`, `nehamathur`, `sai.krishna.reddy` | Neha, Sai |
| SG | `kumar.rahul` | Rahul |
| Gi, GiS | `rahulk`, `rahul.k.sharma` | Rahul |
| IG | `r.saravanan` (South Indian order) | Saravanan |
| IS, IIS, ISI | `akushwah`, `pm.singh`, `a.kumar.s` | no one |
| S | `sharma` | no one |
| W, WW | `design` | no one |
| O | anything else, spelt by letter trigrams | no one |

A slot's likelihood is how common the word is as a given name, a surname or an
English word. A given name or surname the lists don't have still gets a share,
spelt out by letter trigrams. It can't be greeted, but it keeps a misreading
from winning by default: with Gurpreet unlisted, `singh.gurpreet` is still not
"Hi Singh,". Separators (`.`, `_`, `-`, digits) must fall between slots. Without
them every split is tried, and each boundary pays the pattern's odds of being
written with nothing in between. So `aryan` read as a + Ryan pays for an
initial glued to a given name, which is rare, while `a.ryan` doesn't.

Each reading's posterior goes to the name it greets. A name is used only when
its **support** reaches the threshold (0.9). Support counts the readings that
greet by it, plus those that greet by a known name that is it with a common
surname fused on (Kumar, Devi, Rao, Reddy, Prasad: probability at least 10⁻⁴).
So `rakeshkumar`, read as Rakesh + Kumar or as the single name Rakeshkumar,
greets Rakesh. Nothing else shortens: Nagarjuna is not "Nag", and Lakshmanan is
not "Laksh". Only a known given name is ever greeted.

## Learning from the catalog

The public lists miss names, Bengali and Malayalam ones especially (Arijit,
Debashis, Sreejith, Jithin). The catalog's own name fields fill that in.
`NameModel.learn` / `NameClassifier.learn(people:)` take every row's name field
as words, and the app relearns after each load
(`JobStore.rebuildDerived` → `RecipientName.learnNames`). `verify_names.py` does
the same over the whole catalog.

A name field teaches only when that's safe:

- **It's clear which way round it is.** Fields are written given name first
  95% of the time unless the listed words say otherwise. A word the lists
  don't have leans neither way, and one reading has to be nine times likelier
  than the other. "Singh Gurpreet" teaches Gurpreet; "Subhajit Paul" teaches
  nothing, because Paul is a given name too.
- **One half is listed in its role.** "Arijit Sen" teaches Arijit because Sen is
  a listed surname. "Infosys Recruiter" teaches nothing.
- **It isn't a role or a common word.** Rows with a role word are skipped, and an
  English word is only learned if the lists already know it as a name.
- **It has been seen twice.** A name only the catalog knows is greeted once it
  has been taught twice, so one odd record can't put a name in a greeting.

Learned counts blend with the public lists with weight n / (n + 1000), at most
0.5, for n names learned. Rows without a usable name field teach the name they
signed a reply with, if any.

Two clean-ups keep common traps out:

- A word listed as a given name less than 1% as often as it's a surname is a
  record that put the surname first ("Singh", "Das", "Williams"), so it's
  dropped from the given names. Ram and Ali, at about 2%, stay.
- An initial glued after a given name is one consonant (`rahulk`). A glued
  vowel ends a name instead: `suneeta` is Suneeta, not Suneet + A.

`RecipientName` drops role words (`careers`, `hr`), filler (`official`) and the
company's own name before asking, and treats letters wrapped around digits
(`talk2saravanan`) as leetspeak, not a name.

## Results

`python3 eval_names.py`, threshold 0.9. *Precision* is the share of greetings
that were right; *coverage* is the share of named mailboxes greeted.

| set | precision | coverage |
|---|---|---|
| 100 hand-labelled mailboxes (`LABELLED` in `test_name_model.py`) | 1.000 | 0.983 |
| 66 regional mailboxes (`COVERAGE`: Punjabi, Hindi belt, Bengali, Marathi, South Indian, Muslim, post-2000) | 1.000 | 0.833 |
| 3,000 synthetic, every name known to the model | 0.993 (0.997 clear cases) | 0.914 |
| 3,000 synthetic, 20% of name types held out | 0.966 (0.973) | 0.744 |
| the same, after learning 1,500 synthetic name fields | 0.974 (0.980) | 0.766 |

Before the lists were widened (only the top 1,000 US names a year and a
3,900-surname SECC extract), the hand-labelled set was greeted at 0.897 and the
regional set at 0.70, with one wrong greeting (`dhruv.shah` → Shah). The
regional set was written before the wider lists were built, so it couldn't be
tuned to them.

The synthetic sets draw given names and surnames by frequency from the model's
own lists and spell them in the patterns above, so their noise grows with the
lists. The held-out runs remove a fifth of the name types first, so about 19%
of the people have a given name the model has never seen. "Clear cases" leaves
out wrong greetings the synthetic labels can't rule out, such as `yo_murugan`,
where the SECC files a Tamil given name as the surname.

What's left when a name is unseen: the other half of the address gets greeted
when it's also a given name (`lewishector` → Lewis), or an unseen name is cut
back to a listed one. The regional misses are Bengali and Malayalam names no
list has (Arijit, Debashis, Moumita, Sayantan, Sreejith, Jithin), which
catalog learning covers, and a few under the threshold (Manpreet 0.83, Riya
0.83, Snehal 0.86, Amandeep 0.69). The hand-labelled miss is Mohammad (0.52):
the rolls record it as a last name three times as often as a first name.

## Data

`build_model.py` pins every source by URL and SHA-256. The model,
`Aurora/Resources/NameModel.txt` (2.2 MB, 0.8 MB compressed), holds 64,000
given names, 132,000 surnames and 10,700 English words with how common each is,
plus trigram tables. It holds no address and no full name.

| source | used for | terms |
|---|---|---|
| Indian electoral rolls, first names by state and birth year (Sood & Laohaprapanon, Harvard Dataverse [doi:10.7910/DVN/WZGJBM](https://doi.org/10.7910/DVN/WZGJBM)), as packaged in [naampy](https://pypi.org/project/naampy/) 0.1.0 | given names, births from 1955 (50%) | CC0 per naampy's data manifest; naampy is MIT |
| US Social Security baby names, every name given to 5+ babies a year, 1880–2017, as packaged in [babynames](https://github.com/hadley/babynames) | given names, births from 1955, 50+ babies (45%) | CC0 |
| [Faker](https://pypi.org/project/Faker/)'s `en_IN` person names, a curated list of current Indian names | given names (5%), surnames (5%) | MIT |
| SECC 2011 surnames by state, as packaged in [outkast](https://pypi.org/project/outkast/) 0.1.0 ([doi:10.7910/DVN/LIIBNB](https://doi.org/10.7910/DVN/LIIBNB)) | surnames (30%): name and female/male counts only, the composition columns are never read | outkast is MIT. The Dataverse terms couldn't be fetched from the build machine, so check them before redistributing beyond the app |
| Indian electoral-roll surnames by language, as packaged in [instate](https://pypi.org/project/instate/) 0.1.7 | surnames with weight 50+ (30%) | instate is MIT; the same Dataverse caveat applies |
| US Census 2000 surnames with 500+ people ([fivethirtyeight/data](https://github.com/fivethirtyeight/data/tree/master/most-common-name)) | surnames (35%) | Census data is public domain; the FiveThirtyEight compilation is CC BY 4.0 |
| [SCOWL](http://wordlist.aspell.net/) 2020.12.07, sizes 10–35 | English words; "other" trigrams | notice below |

Clean-ups at build time:

- **Tamil Nadu is left out of the surname sources** (SECC's Tamil Nadu rows and
  the rolls' Tamil share). Tamil names have no hereditary surname, so the
  "last name" those records hold is a given name (Murugan, Ramasamy). Counting
  them would stop `murugan@` being greeted.
- **Surname-first records are dropped.** A word listed as a given name less than
  1% as often as it's a surname ("Singh", "Shah") came from records that put
  the surname first.
- **Two-letter given names are limited to Om, Jo, Al and Ed.** The rest of the US
  lists' two-letter names are mostly initials (KC, AJ, JD).

SCOWL's notice, as its terms require:

> Copyright 2000-2011 by Kevin Atkinson
>
> Permission to use, copy, modify, distribute and sell these word lists, the
> associated scripts, the output created from the scripts, and its
> documentation for any purpose is hereby granted without fee, provided that
> the above copyright notice appears in all copies and that both that copyright
> notice and this permission notice appear in supporting documentation. Kevin
> Atkinson makes no representations about the suitability of this array for any
> purpose. It is provided "as is" without express or implied warranty.

## Tuning

The priors, separator odds, unseen-name shares, catalog weights and threshold
are judgement, not measurement. The build machine couldn't reach the live
catalog, so they aren't fitted to it. They live in `build_model.py` (`PRIORS`,
`GLUE`, `CONSTANTS`) and are written into the model, so the app and the
reference read the same values. After changing one, rebuild (seconds: parsed
sources are cached in `.cache/names/`), then run the tests and
`eval_names.py --sweep`. A change that makes any `LABELLED` or `COVERAGE` case
greet wrongly fails the tests.

Raising the threshold trades coverage for precision. The unseen-name shares
barely matter; coverage of the name lists does.

## The Swift port

`NameClassifier.swift` mirrors `name_model.py` step by step. `SwiftParity` in
`test_name_model.py` compiles it, runs every labelled and regional case through
both, cold and after learning a small catalog, and requires the same greeting
to four decimal places of confidence.

It keeps the model file as bytes and binary-searches its sorted sections
instead of building dictionaries. In a release build it opens the model in
about 20 ms, reads a new address in about 0.14 ms, remembers what it has read,
and learns 5,000 name fields in about 25 ms.
