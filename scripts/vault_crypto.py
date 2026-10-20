"""Aurora's sealing, in Python: the same values the app writes and reads.

A match for Aurora/Models/Sealing.swift and the contact half of KeyRing.swift:

- A sealed value is "v1." + base64 of AES-256-GCM's combined form
  (12-byte nonce, ciphertext, 16-byte tag). The context string is the
  additional authenticated data, so a value moved to another row or vault no
  longer opens.
- Keys made from something typed go through PBKDF2-SHA256, with the secret
  normalised the way `Sealing.normalized(_:)` does it.
- A vault's key sits in `vaults.sealed_key`, wrapped under the key made from
  its private key.

Standard library only: AES and GHASH are written out below (table-driven, a
few seconds for the whole catalog), proven against NIST's GCM vectors and
against values sealed by the Swift code itself (test_vault_crypto.py).

The private key is read from the AURORA_PRIVATE_KEY environment variable or
typed at a prompt. Never pass it on a command line or keep it in a file.
"""
import base64
import getpass
import hashlib
import hmac
import json
import os
import unicodedata

PREFIX = "v1."
DEFAULT_ROUNDS = 600_000
PRIVATE_KEY_ENV = "AURORA_PRIVATE_KEY"


class CannotOpen(Exception):
    """The key is wrong, or the value was changed or moved."""


class Malformed(Exception):
    """The stored value isn't in a form the app can read."""


# ----------------------------------------------------------------------------
# Keys

# Exactly what Foundation's `trimmingCharacters(in: .whitespacesAndNewlines)`
# drops, read off every code point by a Swift program (2026-10-20). Its docs
# say "Zs, Zl, Zp, U+0009–U+000D, U+0085", but it also drops U+200B (zero
# width space). Python's str.strip differs both ways (it drops U+001C–U+001F
# and keeps U+200B), so it isn't used.
_SPACES = frozenset(map(chr, [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
    *range(0x2000, 0x200C), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
]))


def _is_space(ch):
    return ch in _SPACES


def normalized(secret):
    """What's typed, as it's keyed: surrounding space dropped, accents in one
    canonical form (NFC). `Sealing.normalized(_:)`."""
    start, end = 0, len(secret)
    while start < end and _is_space(secret[start]):
        start += 1
    while end > start and _is_space(secret[end - 1]):
        end -= 1
    return unicodedata.normalize("NFC", secret[start:end])


def derive_key(secret, salt, rounds):
    """`Sealing.deriveKey`: PBKDF2-HMAC-SHA256, 32 bytes. Slow on purpose."""
    return hashlib.pbkdf2_hmac("sha256", normalized(secret).encode("utf-8"), bytes(salt), rounds, 32)


def new_key():
    return os.urandom(32)


def new_salt():
    return os.urandom(16)


# ----------------------------------------------------------------------------
# AES-256 (encryption direction only: GCM never decrypts a block)

def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) if a & 0x100 else a


def _make_sbox():
    sbox = [0] * 256
    p = q = 1
    while True:
        # p walks the multiplicative group by 3, q by its inverse.
        p = p ^ _xtime(p)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    return sbox


_SBOX = _make_sbox()
_T0 = []
for _s in _SBOX:
    _s2 = _xtime(_s) & 0xFF
    _T0.append((_s2 << 24) | (_s << 16) | (_s << 8) | (_s2 ^ _s))
_T1 = [((t >> 8) | (t << 24)) & 0xFFFFFFFF for t in _T0]
_T2 = [((t >> 16) | (t << 16)) & 0xFFFFFFFF for t in _T0]
_T3 = [((t >> 24) | (t << 8)) & 0xFFFFFFFF for t in _T0]
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40]


def _expand(key):
    if len(key) != 32:
        raise ValueError("an AES-256 key is 32 bytes")
    w = [int.from_bytes(key[i:i + 4], "big") for i in range(0, 32, 4)]
    for i in range(8, 60):
        t = w[i - 1]
        if i % 8 == 0:
            t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
            t = (_SBOX[t >> 24] << 24) | (_SBOX[(t >> 16) & 0xFF] << 16) | (_SBOX[(t >> 8) & 0xFF] << 8) | _SBOX[t & 0xFF]
            t ^= _RCON[i // 8 - 1] << 24
        elif i % 8 == 4:
            t = (_SBOX[t >> 24] << 24) | (_SBOX[(t >> 16) & 0xFF] << 16) | (_SBOX[(t >> 8) & 0xFF] << 8) | _SBOX[t & 0xFF]
        w.append(w[i - 8] ^ t)
    return w


def _encrypt_block(w, block):
    """One 16-byte block as an int in, one out."""
    T0, T1, T2, T3, S = _T0, _T1, _T2, _T3, _SBOX
    s0 = ((block >> 96) & 0xFFFFFFFF) ^ w[0]
    s1 = ((block >> 64) & 0xFFFFFFFF) ^ w[1]
    s2 = ((block >> 32) & 0xFFFFFFFF) ^ w[2]
    s3 = (block & 0xFFFFFFFF) ^ w[3]
    k = 4
    for _ in range(13):
        t0 = T0[s0 >> 24] ^ T1[(s1 >> 16) & 0xFF] ^ T2[(s2 >> 8) & 0xFF] ^ T3[s3 & 0xFF] ^ w[k]
        t1 = T0[s1 >> 24] ^ T1[(s2 >> 16) & 0xFF] ^ T2[(s3 >> 8) & 0xFF] ^ T3[s0 & 0xFF] ^ w[k + 1]
        t2 = T0[s2 >> 24] ^ T1[(s3 >> 16) & 0xFF] ^ T2[(s0 >> 8) & 0xFF] ^ T3[s1 & 0xFF] ^ w[k + 2]
        t3 = T0[s3 >> 24] ^ T1[(s0 >> 16) & 0xFF] ^ T2[(s1 >> 8) & 0xFF] ^ T3[s2 & 0xFF] ^ w[k + 3]
        s0, s1, s2, s3 = t0, t1, t2, t3
        k += 4
    r0 = ((S[s0 >> 24] << 24) | (S[(s1 >> 16) & 0xFF] << 16) | (S[(s2 >> 8) & 0xFF] << 8) | S[s3 & 0xFF]) ^ w[56]
    r1 = ((S[s1 >> 24] << 24) | (S[(s2 >> 16) & 0xFF] << 16) | (S[(s3 >> 8) & 0xFF] << 8) | S[s0 & 0xFF]) ^ w[57]
    r2 = ((S[s2 >> 24] << 24) | (S[(s3 >> 16) & 0xFF] << 16) | (S[(s0 >> 8) & 0xFF] << 8) | S[s1 & 0xFF]) ^ w[58]
    r3 = ((S[s3 >> 24] << 24) | (S[(s0 >> 16) & 0xFF] << 16) | (S[(s1 >> 8) & 0xFF] << 8) | S[s2 & 0xFF]) ^ w[59]
    return (r0 << 96) | (r1 << 64) | (r2 << 32) | r3


# ----------------------------------------------------------------------------
# GCM

_R = 0xE1 << 120


def _ghash_tables(h):
    """Sixteen 256-entry tables: tables[i][b] is (byte b at position i) · H."""
    powers = []           # H · x^k for k = 0..127 (GCM's reflected bit order)
    v = h
    for _ in range(128):
        powers.append(v)
        v = (v >> 1) ^ _R if v & 1 else v >> 1
    tables = []
    for i in range(16):
        basis = [powers[8 * i + j] for j in range(8)]  # bit j of the byte = 0x80 >> j
        t = [0] * 256
        for b in range(1, 256):
            low = b & -b
            t[b] = t[b ^ low] ^ basis[7 - low.bit_length() + 1]
        tables.append(t)
    return tables


class _Cipher:
    __slots__ = ("w", "tables")

    def __init__(self, key):
        self.w = _expand(bytes(key))
        self.tables = _ghash_tables(_encrypt_block(self.w, 0))

    def _mul(self, x):
        t = self.tables
        out = 0
        for i in range(16):
            out ^= t[i][(x >> (120 - 8 * i)) & 0xFF]
        return out

    def _ghash(self, aad, ct):
        y = 0
        for data in (aad, ct):
            for i in range(0, len(data), 16):
                y = self._mul(y ^ int.from_bytes(data[i:i + 16].ljust(16, b"\0"), "big"))
        return self._mul(y ^ ((len(aad) * 8) << 64) ^ (len(ct) * 8))

    def _ctr(self, j0, data):
        out = bytearray(len(data))
        prefix, counter = j0 & ~0xFFFFFFFF, j0 & 0xFFFFFFFF
        for i in range(0, len(data), 16):
            counter = (counter + 1) & 0xFFFFFFFF
            stream = _encrypt_block(self.w, prefix | counter).to_bytes(16, "big")
            chunk = data[i:i + 16]
            out[i:i + len(chunk)] = bytes(a ^ b for a, b in zip(chunk, stream))
        return bytes(out)

    def seal(self, nonce, plaintext, aad):
        j0 = (int.from_bytes(nonce, "big") << 32) | 1
        ct = self._ctr(j0, plaintext)
        tag = (_encrypt_block(self.w, j0) ^ self._ghash(aad, ct)).to_bytes(16, "big")
        return ct, tag

    def open(self, nonce, ct, tag, aad):
        j0 = (int.from_bytes(nonce, "big") << 32) | 1
        want = (_encrypt_block(self.w, j0) ^ self._ghash(aad, ct)).to_bytes(16, "big")
        if not hmac.compare_digest(want, tag):
            raise CannotOpen("This couldn't be unlocked with that key.")
        return self._ctr(j0, ct)


_CIPHERS = {}


def _cipher(key):
    key = bytes(key)
    c = _CIPHERS.get(key)
    if c is None:
        if len(_CIPHERS) > 16:
            _CIPHERS.clear()
        c = _CIPHERS[key] = _Cipher(key)
    return c


def gcm_seal(key, nonce, plaintext, aad=b""):
    """Raw AES-256-GCM with a 12-byte nonce: (ciphertext, tag). For tests."""
    return _cipher(key).seal(bytes(nonce), bytes(plaintext), bytes(aad))


def gcm_open(key, nonce, ciphertext, tag, aad=b""):
    return _cipher(key).open(bytes(nonce), bytes(ciphertext), bytes(tag), bytes(aad))


# ----------------------------------------------------------------------------
# Sealing — `Sealing.seal` / `Sealing.open`

def seal(plaintext, key, context, nonce=None):
    nonce = os.urandom(12) if nonce is None else bytes(nonce)
    if len(nonce) != 12:
        raise ValueError("a nonce is 12 bytes")
    ct, tag = gcm_seal(key, nonce, plaintext, context.encode("utf-8"))
    return PREFIX + base64.b64encode(nonce + ct + tag).decode("ascii")


def open_sealed(sealed, key, context):
    if not isinstance(sealed, str) or not sealed.startswith(PREFIX):
        raise Malformed("The stored value isn't in a form the app can read.")
    try:
        combined = base64.b64decode(sealed[len(PREFIX):], validate=True)
    except ValueError:
        raise Malformed("The stored value isn't valid base-64.") from None
    if len(combined) < 28:
        raise Malformed("The stored value is too short to be sealed.")
    return gcm_open(key, combined[:12], combined[12:-16], combined[-16:], context.encode("utf-8"))


def seal_json(value, key, context):
    return seal(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), key, context)


def open_json(sealed, key, context):
    try:
        return json.loads(open_sealed(sealed, key, context))
    except ValueError as e:  # bad UTF-8 or JSON inside a value that did open
        raise Malformed(f"The opened value isn't JSON: {e}") from None


def wrap(key, wrapping_key, context):
    """One key sealed under another (`Sealing.wrap`)."""
    return seal(bytes(key), wrapping_key, context)


def unwrap(sealed, wrapping_key, context):
    raw = open_sealed(sealed, wrapping_key, context)
    if len(raw) != 32:
        raise Malformed("A wrapped key must be 32 bytes.")
    return raw


# ----------------------------------------------------------------------------
# Contexts — part of the stored format: copied from Sealing.swift, word for word.

def contact_context(id, vault_id):
    return f"aurora.contact.v1|{id.lower()}|{vault_id.lower()}"


def send_context(id):
    return f"aurora.send.v1|{id.lower()}"


def reply_context(id):
    return f"aurora.reply.v1|{id.lower()}"


def template_context(id):
    return f"aurora.template.v1|{id.lower()}"


def profile_context(email):
    return f"aurora.profile.v1|{email.lower()}"


def vault_key_context(vault_id, key_id):
    return f"aurora.vault.v1|{vault_id.lower()}|{key_id.lower()}"


def grant_context(email, vault_id, key_id):
    return f"aurora.grant.v1|{email.lower()}|{vault_id.lower()}|{key_id.lower()}"


def account_context(email):
    return f"aurora.account.v1|{email.lower()}"


# ----------------------------------------------------------------------------
# Contacts — `KeyRing.ContactFields`

# recruiters column -> the key it's sealed under.
CONTACT_FIELDS = {"name": "n", "email": "e", "position": "p", "phone": "t", "greeting_name": "g"}


def seal_contact(fields, key, id, vault_id):
    """`fields` by column name. Empty values are left out, as the app does."""
    body = {}
    for column, short in CONTACT_FIELDS.items():
        value = fields.get(column)
        if value is not None and value != "":
            body[short] = value
    return seal_json(body, key, contact_context(id, vault_id))


def open_contact(sealed, key, id, vault_id):
    """The sealed fields by column name; a field the seal leaves out is None."""
    body = open_json(sealed, key, contact_context(id, vault_id))
    if not isinstance(body, dict):
        raise Malformed("A sealed contact must be a JSON object.")
    out = {}
    for column, short in CONTACT_FIELDS.items():
        value = body.get(short)
        out[column] = value if isinstance(value, str) else None
    return out


# ----------------------------------------------------------------------------
# Vaults

def unlock_vault(vault, private_key):
    """A vault row's current key (key_id, key), opened with its private key.
    Raises CannotOpen for a wrong private key, ValueError when the vault has
    no key yet (its owner hasn't chosen one in the app)."""
    if not (vault.get("key_id") and vault.get("sealed_key") and vault.get("kdf_salt")):
        raise ValueError(f"vault {vault.get('code')} has no private key yet")
    try:
        salt = base64.b64decode(vault["kdf_salt"], validate=True)
    except ValueError:
        raise Malformed(f"vault {vault.get('code')}: kdf_salt isn't base-64") from None
    unlocking = derive_key(private_key, salt, vault.get("kdf_rounds") or DEFAULT_ROUNDS)
    try:
        key = unwrap(vault["sealed_key"], unlocking, vault_key_context(vault["id"], vault["key_id"]))
    except CannotOpen:
        raise CannotOpen(f"That private key doesn't open {vault.get('code')}.") from None
    return vault["key_id"].lower(), key


def read_private_key(code, environ=None, prompt=getpass.getpass):
    """The private key from AURORA_PRIVATE_KEY, or typed at a hidden prompt."""
    environ = os.environ if environ is None else environ
    value = environ.get(PRIVATE_KEY_ENV)
    if value:
        return value
    return prompt(f"Private key for {code} (input hidden; or set {PRIVATE_KEY_ENV}): ")
