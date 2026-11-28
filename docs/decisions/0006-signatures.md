# 0006: Digital signatures

Status: accepted by the maintainer in conversation, with all three recommendations under
"Questions for the maintainer". **S1 is implemented** (see "S1 as built"); S2 and S3 are
not. This is stage 3 of `docs/ROADMAP.md`.

## Problem

pdf-zig lists a signature field but says nothing about what was signed. The maintainer
wants signatures: who signed, whether the file changed, and verification. **A wrong
"valid" is worse than no answer.**

A signature raises three separate questions:

1. **Coverage:** which bytes of the file does it sign, and what changed afterwards? This
   is PDF structure.
2. **Integrity:** are those bytes as they were when the holder of a certain key signed
   them? This is CMS (RFC 3852, which ISO 32000-1 12.8.3.3 names) and cryptography.
3. **Identity:** does that key belong to who the certificate says, according to someone
   you trust? This is certificate path validation (RFC 5280), revocation and time.

A yes to 2 alone says little about who signed: anyone can make a certificate in any name.

## What Zig 0.17.1 offers (checked 2026-11-27)

**`std.crypto.Certificate` must not be given anything from a PDF.** Both points were
tested with throwaway certificates made by OpenSSL 3.5.5:

- **It does not enforce who may issue certificates.** Its parser does not use basic
  constraints or key usage. `Parsed.verify` accepted a certificate signed by an ordinary
  certificate marked `CA:FALSE`. `openssl verify` refuses that chain. Anyone holding any
  certificate could forge any name. `verify` checks one link (names, dates, signature); it
  is not path validation.
- **Its parser is not safe on damaged input.** Of 112 truncated copies of one
  certificate, built ReleaseSafe, 75 panicked with an index out of bounds and the other
  37 returned success. `der.Element.parse` reads without bounds checks, so with safety
  off I expect out-of-bounds reads (not tested).

pdf-zig uses neither it nor Zig's ASN.1 code today.

Usable pieces: the SHA hashes; `Certificate.rsa` PKCS#1 v1.5 and PSS verification, given
a modulus and exponent already taken from the certificate safely (PSS assumes a salt as
long as the digest); ECDSA on P-256, P-384 and secp256k1. I found no P-521, DSA or
RIPEMD-160, which table 257 allows (the last two). `std.crypto.codecs.asn1.der` documents
itself as bounds-checked and strict DER; I have not tested that.

A web search found no Zig package that verifies CMS signatures. It was not exhaustive.

## What files contain

In the survey of 2,000 books, under 1% (15 files) were signed, all
`adbe.pkcs7.detached`. Books are a poor sample for signatures. The system PDFs here hold
only two, both `adbe.x509.rsa_sha1`. **How real signers encode CMS has not been
measured**, including whether any use BER rather than DER.

## Proposal

### S1: list signatures and what they cover (pure Zig, no cryptography)

A new module `signature`. For each signature field, and for the permissions dictionary's
signatures (12.8.4):

- **Kind:** approval, certification (with its `DocMDP` level), usage rights or document
  timestamp. `FieldMDP` locks are listed.
- **Claims** from the dictionary: name, date, reason, location, contact. They are named
  as claims in the API, since nothing checks them.
- **Format** (`SubFilter`) and the raw signature value.
- **Coverage**, either sound or a stated defect. Sound means all of: the byte range is two
  pieces, the first starting at 0; the gap between them is exactly the hexadecimal string
  that is **this** dictionary's `/Contents`, found by its position in the file, not by
  comparing values; the values in the dictionary are direct; and opening the file cut off
  at the end of the range, without repair, gives the same signature dictionary.
- **The signed revision:** those first bytes, which a caller can open as a document to
  show what was signed.
- **Changes afterwards:** whether anything follows, and which objects later revisions
  add, replace or delete.

**S1 does not judge whether later changes are permitted.** Certification attacks
published in 2021 worked through changes that the permission level allows, such as added
annotations and signature fields, in most applications tested (as reported by
[Ruhr University Bochum](https://casa.rub.de/en/news/casa/news/two-new-attacks-break-pdf-certification);
I have not read the paper). "Changed after signing" with the signed version on offer is
an answer a user can act on. A "permitted changes only" verdict needs its own design.

### S2 and S3: verification, through a verifier module

The core gains an interface: it hands a verifier the signature value and the signed
pieces, and gets back a report. **An optional module, `pdf_openssl`, implements it with
OpenSSL's CMS functions.** The core keeps no dependencies, as with the optional CJK data
module that was agreed to. A program with another library (GnuTLS, NSS, the system's own)
can implement the interface instead.

The report never has a single "valid". It has separate answers, each able to say
**not checked**:

| Answer | Values |
|---|---|
| Coverage (from S1) | sound, or the defect |
| Integrity | intact, altered, not checked (with why) |
| Signer's chain | reaches an anchor the caller trusts, does not, not checked |
| Revocation | not revoked, revoked, not checked |
| Time | claimed by the signer, or from a verified timestamp |
| Weak algorithms | such as SHA-1 or MD5 |
| Changed after signing (from S1) | no, or what |

- **S2** gives integrity and the signer's certificate.
- **S3** adds the chain, against anchors the application supplies, and revocation from
  data the application supplies or the file carries. **pdf-zig fetches nothing.**
- Unsound coverage means integrity is never reported as intact.
- Exactly one signer per signature is accepted.

To settle while building, from OpenSSL's documentation and tests: which certificate
purposes count for a document signature (its CMS verification defaults to the e-mail
purpose, as I understand it), how `adbe.pkcs7.sha1` is checked (the signed data holds a
digest that must also be compared), and how revocation data is passed in.

**Licensing:** OpenSSL 3 is under Apache-2.0. Whether and how that combines with
LGPL-2.0-or-later has to be checked before S2; it may require using pdf-zig under a later
version of the LGPL. This is not legal advice.

### Creating signatures

Not in this design. It comes after verification and needs its own, with the private key
operation supplied by the caller.

## Alternatives for verification

| Option | For | Against |
|---|---|---|
| **A. Verifier interface and optional OpenSSL module** (proposed) | CMS parsing, signatures and path validation come from a widely used library; core stays free of dependencies | a C dependency for those who verify; the glue is still security code |
| B. Integrity in Zig, trust left to the application | S2 needs no C | we write CMS and certificate parsing; fewer algorithms; the application needs a library for trust anyway, so two parsers read each signature and may disagree |
| C. Everything in Zig | no dependencies at all | writing path validation and revocation, where a mistake accepts forgeries; not recommended |
| D. S1 only; applications verify on their own | least work here | each application writes the risky glue itself |

## Steps

| Step | Contents | Gives |
|---|---|---|
| S1 | `signature` module, example `pdfsig-info`, survey of coverage defects | who claims to have signed, what is covered, what changed |
| S2 | verifier interface, `pdf_openssl` integrity | altered or not |
| S3 | chains and revocation | whether the signer is trusted by the caller's anchors |

S1 can be released on its own.

## S2: settled and found so far (2026-11-28)

**OpenSSL 3.5 LTS** (the maintainer's decision: their distribution stays on it). Use
nothing newer, and check against 3.5's headers and manual pages.

From the 3.5.5 manual page `CMS_verify(3)`:

- Signer chains are checked for the `smimesign` purpose by default. Which purposes count
  for a document signature is still to be settled, in S3.
- `CMS_NO_SIGNER_CERT_VERIFY` leaves out the chain check, which is what S2 needs. Its
  result says nothing about trust.
- `CMS_NO_CONTENT_VERIFY` makes altered content pass, and `CMS_NO_ATTR_VERIFY` leaves the
  signed attributes unchecked. Neither may be set.
- Success means that all signers verified, so "exactly one signer" has to be checked
  separately (`CMS_get0_SignerInfos`).

**Licensing: the maintainer's decision.** `pdf_openssl` stays LGPL-2.0-or-later, like the
rest, with a note that a build including OpenSSL should be distributed under LGPL version
3 or later. Nothing is relicensed, and builds without the module are not affected.

What it rests on. Read: the FSF's license list, the ASF's page on GPL compatibility,
OpenSSL's license page, and the texts of LGPL-2.1 and LGPL-3.0 (not LGPL-2.0 or
Apache-2.0). The FSF says Apache-2.0 is compatible with GPL version 3 and not with
version 2. None of what was read says either way for the LGPL. Our inference, which is not
legal advice: "or later" lets whoever distributes such a build use LGPL-3.0, which is GPL
version 3 with added permissions.

### The interface

Built in `src/verify.zig`, marked experimental while there is only one implementation to
come; how it works is in `docs/architecture.md`. Choices beyond the proposal:

- `intact` cannot be given without the signer's certificate, the digest and the key, so
  that pdf-zig decides what is weak, the same way for every backend (SHA-1, MD5,
  RIPEMD-160; RSA and DSA under 2048 bits, elliptic curves under 224). These thresholds
  are this project's choice, not taken from a standard.
- Chain, revocation and verified time have no fields until S3.
- `adbe.x509.rsa_sha1` is reported as an unsupported format: it needs the dictionary's
  `/Cert`, which S1 does not read. Both signed system PDFs here use it.

The tests use a stand-in verifier without cryptography: they test what `check` asks and
accepts, and each of six safeguards was removed in turn to see a test fail. **Still to
come with `pdf_openssl`:** the shared files that every backend must answer correctly
(signed, altered, malformed, several signers, BER).

## S1 as built

Implemented in `src/signature.zig`; how it works is in `docs/architecture.md`,
"Signatures". Where it differs from or adds to the proposal:

- The example is `pdfsigs`, not `pdfsig-info`.
- **Limits** were added after review: a 1.2 MB file in which 1,000 fields named one
  signature made the first version use about 700 MB (about 7 MB with the limits). Only
  `max_examined` signatures are read, and values, claim text, lock names and listed
  changes are bounded. New defects `value_too_large` and `not_examined`; `Lock.complete`
  and `Changes.omitted` say when something was left out.
- Content after the signed bytes does not make coverage unsound. It is reported as
  changed, unlike the CCS 2019 algorithm, which refuses such a signature.

**Checked (2026-11-28).**

- Attack cases: the paper by Mladenov et al. (CCS 2019), its attack figures and listing 2,
  was read, as were the attack pages of pdf-insecurity.org. The figures on those pages
  were not readable. Tests cover the USF, ISA and SWA structures described in the paper,
  hide-and-replace, and a signature whose `/V` leads nowhere. They are rebuilt from the
  descriptions, not the authors' files. The other shadow and certification attacks change
  what is shown by permitted or ordinary updates, which S1 only reports as changes.
- Poppler: `test/tools/sigcheck.py` compared 21 signatures in fields (6 signed by the
  script with OpenSSL, which Poppler calls valid; 15 from the maintainer's collection) and,
  separately, the 2 in this machine's system files. No difference in the ranges. Poppler
  lists no signature that only the permissions name, and for values it cannot read
  (`adbe.x509.rsa_sha1` here) says "not total document signed", so that flag was not
  compared for them. MuPDF was not compared.
- Fuzzing: `test/tools/fuzz.py` now runs `pdfsigs` too. No crash or hang on mutated real
  files, and a seeded mutation test is among the unit tests.
- Survey of 2,000 books (the same sample size and seed as before): 17 signed, 15 with a
  certification and 2 with usage rights. Coverage: 15 sound with nothing after, 1 sound
  with later changes, 1 unsound (`gap_is_not_value`: its byte range leaves out bytes about
  2.8 MB before the value, so the ranges are wrong for that file). Poppler lists neither
  of the two files it was asked about that have only usage rights.
- System PDFs (12,952): 2 signed, both sound; no crash or timeout.

**For S2: 14 of the 16 signature values read from the books start with an indefinite
length, which is BER, not DER.** The other 2 have a definite length (not checked further
for DER). A strict DER reader would not do. This answers the open measurement under
"What files contain" only that far.

**Not done:** no one but its author (Claude) has reviewed the code. The review this record
asks for applies to S2 and S3.

## Testing

Signed files made in the tests' scripts with throwaway keys, compared with Poppler's
`pdfsig`. Attack cases built from the published classes (manipulated or missing byte
ranges and signature values, signature wrapping, later revisions that change what is
shown), after reading the research at [pdf-insecurity.org](https://pdf-insecurity.org),
which has not been done yet. Damaged and mutated files are fuzzed. **Before S2 or S3 is
called ready, someone other than its author should review it.**

## Questions for the maintainer (all answered yes)

1. **Verification** by option A, an optional OpenSSL module behind an interface?
   Recommended.
2. S1 **reports later changes without saying whether they are permitted**? Recommended.
3. **Release S1 on its own** before verification? Recommended.
