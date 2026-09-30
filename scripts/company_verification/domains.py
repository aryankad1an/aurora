"""Mail-domain helpers shared by the verification pipeline.

Mirrors `MailDomain` in Aurora/Models/Job.swift (personal-mailbox list,
cleaning rules) and adds what the app doesn't need: reducing a mail host
(`ny.email.gs.com`) to the domain a company registers (`gs.com`).
"""
import re

PERSONAL = {
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "ymail.com",
    "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com",
    "mac.com", "aol.com", "proton.me", "protonmail.com", "rediffmail.com",
    "zoho.com", "gmx.com", "mail.com", "yandex.com",
    # Not in the app's list, but just as personal: regional variants, ISP
    # mailboxes, free-mail brands and alias/hosting services. None says where
    # the owner works.
    "yahoo.co.uk", "yahoo.in", "yahoo.com.hk", "yahoomail.com", "rocketmail.com",
    "hotmail.co.uk", "hotmail.co.in", "outlook.in", "live.in", "aol.in",
    "india.com", "in.com", "asia.com", "inbox.com", "email.com", "writeme.com",
    "usa.net", "web.de", "infoseek.jp", "i.softbank.jp", "simplelogin.com",
    "comcast.net", "att.net", "sbcglobal.net", "bellatlantic.net",
    "insightbb.com", "rediff.com",
    "gmaill.com",  # a typo of gmail.com, but its owner is just as unknown
}

# Two-label public suffixes seen in (or plausible for) the data. A registrable
# domain is one label plus its public suffix.
MULTI_SUFFIXES = {
    *(f"{s}.in" for s in ("co", "ac", "org", "net", "gov", "edu", "ind", "res", "nic", "gen", "firm", "ernet")),
    *(f"{s}.uk" for s in ("co", "org", "ac", "gov", "ltd", "plc", "me")),
    *(f"com.{c}" for c in ("au", "br", "mx", "qa", "sg", "hk", "ar", "cn", "my", "tr", "sa",
                           "eg", "ph", "pk", "tw", "vn", "ng", "co", "pe", "bd", "np", "lk")),
    *(f"co.{c}" for c in ("jp", "za", "nz", "id", "kr", "il", "th", "ke", "tz")),
    *(f"edu.{c}" for c in ("sg", "au", "my", "pk")),
    *(f"ac.{c}" for c in ("th", "jp", "nz", "za", "il", "kr", "ae")),
    *(f"net.{c}" for c in ("au", "in")), *(f"org.{c}" for c in ("au", "sg")),
    "uk.com", "us.com", "gov.sg",
}


def clean(raw: str):
    d = (raw or "").strip().lower()
    for scheme in ("https://", "http://"):
        if d.startswith(scheme):
            d = d[len(scheme):]
    d = re.split(r"[/?#]", d)[0]
    if "@" in d:
        d = d.rsplit("@", 1)[1]
    if d.startswith("www."):
        d = d[4:]
    d = d.rstrip(".")
    labels = d.split(".")
    ok = len(d) <= 253 and len(labels) >= 2 and all(
        l and not l.startswith("-") and not l.endswith("-") and re.fullmatch(r"[a-z0-9-]+", l)
        for l in labels)
    return d if ok else None


def is_personal(domain: str) -> bool:
    """Checks the host and its registrable domain: rana.simplelogin.com is personal."""
    return domain in PERSONAL or registrable(domain) in PERSONAL


def registrable(domain: str) -> str:
    """`ny.email.gs.com` -> `gs.com`; `mail.iitb.ac.in` -> `iitb.ac.in`."""
    labels = domain.split(".")
    n = 3 if ".".join(labels[-2:]) in MULTI_SUFFIXES else 2
    return ".".join(labels[-n:]) if len(labels) >= n else domain


def brand(domain: str) -> str:
    """The label a company picks: `zeta` for zeta.in, zeta.tech and zeta.com."""
    reg = registrable(domain)
    return reg.split(".")[0]
