# 0006: Digital signatures

Status: accepted by the maintainer in conversation, with all three recommendations under
"Questions for the maintainer". Nothing is implemented yet. This is stage 3 of
`docs/ROADMAP.md`.

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
