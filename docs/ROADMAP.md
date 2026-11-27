# Plan for the missing features

Status: **accepted** by the maintainer, 2026-11-27, after 0.4.0. What is missing today is
in `docs/architecture.md`, "Not supported". What the viewer must do is in
`docs/HANDOFF-viewer.md`.

## The maintainer's answers

1. The DKDE viewer's side is done later by another Claude, from `docs/HANDOFF-viewer.md`,
   which updates it to whatever release is newest then. Display list changes are fine as
   long as that file records them. **Work on this plan does not change viewer code:** it
   is about making the library as good as it can be.
2. Priority: **forms, creating documents, signatures, scans**, in that order. Text in
   other languages comes as it comes.
3. CJK data as an optional module: yes.
4. The maintainer offered their PDF collection for the survey. Only counts are reported:
   no file names, paths or contents go into the repository.

## How the plan works

- **Order:** the maintainer's priorities. The survey may change the order within them.
- **Each stage ends in something usable**, and can be released on its own.
- **Each large item gets a short design in `docs/decisions/` before code**, as 0003 did.
- **Done** means: tests taken from the standard, the existing tests in every build mode and
  on x86-linux, comparison with Poppler and MuPDF on real files, fuzzing, and updated docs.
  Real files matter: they found a crash in 0.4.0's form copying that no test had.
- **Viewer work** marks items that pdf-zig cannot finish alone. It draws nothing, so a
  new kind of drawing command shows only once the DKDE viewer draws it.

Sizes are relative, and are guesses until the design is written:
**S** like link targets, **M** like forms and bookmarks in new documents, **L** like all of
page operations, **XL** several times that.

## Stage 0: measure

| Item | Size | Notes |
|---|---|---|
| Say what was left out: `DisplayList.incomplete` gains a set of reasons | S | Also lets the viewer tell its user why a page looks wrong |
| Report the rest: soft masks, groups, overprint, clipping text modes, annotations without appearance, JBIG2, unmapped text, vertical fonts, XFA | S | Detection only |
| A survey program in `test/tools/`: for a list of files, how many use each | S | Prints counts, no file contents |

`/usr/share` is mostly TeX manuals and understates scans, office files and forms, so the
survey also runs on a sample of the maintainer's collection.

### What the survey found (2026-11-27)

A random sample of 2,000 files from the maintainer's collection of books, at most 30 pages
of each, so rare things are undercounted. Books say little about forms and signatures.
No file crashed, timed out or had a page that failed to render; 1,994 opened. Of the rest,
four need a password or an unread security handler and two are damaged files that Poppler
does not open either.

| Found | Files |
|---|---|
| Pages that are scans | 43% (31% have a text layer; the two can overlap) |
| JPEG, JPX, CCITT images | 32%, 28%, 19% |
| **JBIG2 images** | **13%**: pdf-zig cannot decode them |
| Overprint set | 13% (it rarely changes what a screen shows) |
| Text without known Unicode | 9% |
| A form | 5% |
| An annotation or field without an appearance | 3% |
| Transparency groups that matter, soft masks, `/Matte` | 4%, 3%, 1% |
| Signed | under 1% (15 files, all `adbe.pkcs7.detached`) |
| Text clipping, vertical text, mesh shadings, XFA | under 0.5% each |

**What it means for the order:** JBIG2 is the most common thing pdf-zig cannot show in
this sample, ahead of forms. The viewer may already decode it itself: its code read
`/JBIG2Globals` when last looked at (whether it decodes JBIG2 was not checked).

## Stage 1: forms

**Progress:** done are appearances made while rendering (decision 0004), list box
appearances when filled, comb dividers, multiple selection, reset and flatten. Open: the
font items, and two matters of style that real files showed: made appearances ignore the
bevelled and inset border styles, and place text taller than its box a little higher than
Poppler and MuPDF do. The pressed appearance stays dropped from filled fields on purpose: kept,
it would show the old value while the field is pressed.

| Item | Size | Viewer work |
|---|---|---|
| **Make missing appearances while rendering** (12.5.5, 12.7.3.3), without changing the file: text and choice fields, check boxes and radio buttons, then markup, shape and note annotations; honour `NeedAppearances` | M | none |
| List box appearances (also fixes `setChoice` leaving none), comb dividers, keep the pressed appearance | S | none |
| Multiple selection, reset, flatten | M | to offer them |
| Symbol and ZapfDingbats encodings and widths (check marks use them), MacExpertEncoding, `a_b` ligature names | S | none |
| Type 3 `d1`: ignore colour inside such glyphs | S | none |

The first item is mostly a restructuring: the code that makes appearances in `form.zig`
and `annot.zig` writes into an edit today, and must also be able to feed the interpreter.
Forms in other scripts than WinAnsi need font embedding (stage 2).

## Stage 2: creating documents (stage B of 0003)

Design: `docs/decisions/0005-drawing-content.md`. **Progress:** B1 (new pages, built-in
fonts, images, document information), B2 (stamps on existing pages) and B3 (embedded
TrueType fonts) are done. Next B4, forms and text boxes in an embedded font.

| Item | Size |
|---|---|
| On new pages: paths, colours, transparency, text in the standard 14 fonts, JPEG and raw images | L |
| The same on top of existing pages (watermarks, page numbers, the invisible text layer of a scan) | M |
| Embed TrueType fonts, with a Unicode map and subsetting; then forms and text boxes in any script | L |
| Document information in new documents, and carrying it, page labels and attachments over | M |

## Stage 3: signatures

| Item | Size | Notes |
|---|---|---|
| List signatures: who is named, when, which bytes each covers, whether the file was changed after (12.8) | M | no cryptography |
| Verify: digest, CMS signature, certificate chain | XL | what to trust is the caller's decision |
| Create signatures | XL | after verification; appends to the file as `write.Update` does |

Zig's standard library has certificate and RSA verification code. Whether it covers what
CMS needs has **not** been checked; that is the first task of this stage's design. This is
security code: a wrong "valid" is worse than no answer. Prefer letting the caller supply
the private key operations, and get it reviewed.

## Stage 4: scans

| Item | Size | Notes |
|---|---|---|
| JBIG2 decoding | L | see below |
| What else the survey finds in scanned files | | |

JPEG, JPX and CCITT scans work today (the viewer's codec decodes the first two).

### JBIG2

- **Use `jbig2dec`:** not recommended. It is packaged as AGPL
  ([AlmaLinux](https://git.almalinux.org/rpms/jbig2dec/raw/branch/c10s/jbig2dec.spec)),
  which would put stricter terms on what ships with it. Its own license file has to be
  read before any decision, and this is not legal advice.
- **Write a decoder** from ITU-T T.88: fits the project. Search results show free
  downloads for the superseded
  [2000 edition](https://www.itu.int/rec/T-REC-T.88-200002-S). Access to the current text
  and a source of test files are unchecked.
- **Leave it to the viewer**, as with JPEG and JPX today.

## Later, as it comes

### Pages look right

| Item | Size | Viewer work |
|---|---|---|
| Function-based and mesh shadings (8.7.4.5, types 1 and 4 to 7). Proposal: turn all five into one list of coloured triangles | L | **yes**: draw triangles |
| Transparency groups and soft masks (11.4, 11.6.5): new commands that begin and end a group and name its mask | L | **yes, the larger part** |
| `Matte` of image soft masks | S | none |
| Colour: hand ICC profiles to the viewer; read default colour spaces and output intents | M | **yes** to use a profile |
| Overprint and transfer settings: pass them on | S | optional |
| Text clipping modes 4 to 7 | S | **yes**: clip to glyph shapes |

**Design first**, covering both libraries' sides: these change the display list, and a
viewer that switches over `Command` must handle the new cases. A colour management
engine inside pdf-zig is not proposed.

### Text

| Item | Size | Notes |
|---|---|---|
| Vertical writing (`WMode 1`, `W2`, `DW2`; 9.7.4.3), in layout, extraction and the display list | M | viewer work to place glyphs |
| Predefined CJK CMaps (9.7.5.2), `usecmap`, and Unicode through the collections' UCS2 maps (9.10.2) | M to L | needs Adobe's data, see below |
| `ActualText` (14.9.4) | S to M | |
| Right-to-left text: first test real files, then decide | S, then unknown | |
| Reading order from the tagged structure (14.8) | L | later, only if wanted |

**Data.** Adobe publishes [the CMaps](https://github.com/adobe-type-tools/cmap-resources)
and [the PDF mapping resources](https://github.com/adobe-type-tools/mapping-resources-pdf)
under BSD-3-Clause, which can ship with an LGPL library. The CMaps that `poppler-data`
installs here are about 12 MB as text; packed they would be much smaller (not measured).
Choices: a separate module that a program opts into (proposed), always built in, or
loaded by the caller from files.

### Around the page

| Item | Size |
|---|---|
| Title, author and the other document information, XMP metadata (14.3) | S |
| Page labels (12.4.2) | S |
| List and extract attachments | S |
| Viewer preferences and the opening destination (no actions are run) | S |
| Layers: list and toggle them; visibility expressions and automatic usage rules (8.11.4) | M |

These are independent and cheap. Any of them can move ahead if the viewer needs it.

### Editing and security

| Item | Size | Notes |
|---|---|---|
| Bookmarks: rename, move, add under a parent | S | |
| Annotations: shapes, lines, stamps, links; change colour, place and size; remove replies with their parent | M | |
| Compare generation numbers in references | S | check against damaged files first |
| Write encrypted files (AES-256), then edit them | M each | |
| Owner password; embedded-file crypt filter (`/EFF`) | S | |
| Password normalization (NFKC) | S to M | about 77 KB of tables unpacked; the viewer could do it instead |
| Certificate (public-key) encryption (7.6.4) | L | needs CMS parsing and private key decryption |

A damaged file can already be rewritten by importing its pages into a new document, which
keeps what 0003 lists.

## Not planned

| Item | Why |
|---|---|
| Running JavaScript | A large attack surface in files that are treated as hostile |
| XFA forms | A separate form technology, large; to my knowledge deprecated in PDF 2.0 (not checked) |
| Decoding JPEG and JPX | The viewer's codec does it |
| A colour management engine | The viewer can use a library for the profiles it is handed |
| Redaction | Removing content safely means rewriting content streams and pruning resources. A half-done version is worse than none. It needs its own proposal |

## Proposed releases

| Release | Contents |
|---|---|
| 0.5.0 | Stage 0 and stage 1: survey and forms |
| 0.6.0 | Stage 2: creating documents |
| 0.7.0 | Stage 3: signatures (listing and verification) |
| 0.8.0 | Stage 4: scans |
| later | The rest, as it comes |

Version numbers are a guess; a stage may need more than one release.
