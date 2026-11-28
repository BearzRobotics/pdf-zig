# Architecture

    bytes --> document.zig --> pages.zig --> interp.zig --> display.zig --> text.zig / a renderer
              object.zig        content.zig   font.zig
              filters.zig                     color.zig, function.zig
                                              cmap.zig, encoding.zig, std14.zig

| File | Role |
|---|---|
| `root.zig` | Public API |
| `object.zig` | Object model (`Object`, `Dict`, `Stream`, `Ref`) and the syntax parser (7.2, 7.3) |
| `filters.zig` | Stream filters and predictors (7.4); bounded output |
| `crypt.zig` | The standard security handler: key derivation, password check, RC4 and AES decryption |
| `document.zig` | `Document`: header, xref tables and streams, trailers, object streams, repair, indirect objects, stream decoding |
| `pages.zig` | `PageList` (the page tree with inheritance), `Page`, page contents |
| `content.zig` | Content-stream scanner, including inline images |
| `encoding.zig` | Base encodings and glyph names to Unicode |
| `cmap.zig` | CMap programs: `/ToUnicode` and code to CID maps |
| `std14.zig` | Generated widths of the standard 14 fonts (`scripts/gen-std14.py`, from Ghostscript) |
| `font.zig` | `Font` from a font dictionary: widths, encoding, composite fonts, Unicode, the embedded program |
| `function.zig` | PDF functions, types 0, 2, 3, 4 |
| `color.zig` | Colour spaces and conversion to RGB |
| `display.zig` | The display list types and `Matrix` |
| `interp.zig` | `Renderer`: graphics state, operators, forms, patterns, shadings, layers, annotations |
| `text.zig` | Text from a display list |
| `appearance.zig` | Appearances made while rendering, for annotations and fields that need one (decision 0004) |
| `draw.zig` | The canvas (paths, text in the built-in fonts, images) and stamps on existing pages (decision 0005) |
| `truetype.zig`, `font_embed.zig` | Reading and subsetting TrueType fonts, and the PDF objects of an embedded font |
| `page_edit.zig` | Adding drawing to a page being edited, shared by flattening and stamps |
| `flatten.zig` | Form widgets made part of their page's content |
| `link.zig` | The links of a page: destinations, URIs and named actions. It follows none of them |
| `write.zig`, `annot.zig`, `outline.zig`, `form.zig` | Changes to a file, appended to it |
| `compose.zig`, `compose_form.zig`, `compose_outline.zig`, `compose_pack.zig` | A new document from blank pages and pages of other documents: forms, bookmarks, and the compact output |
| `image.zig` | Image samples to RGBA; masks; hand-off to a JPEG/JPX codec |
| `ccitt.zig` | CCITT fax decoding (T.4, T.6), used for images and their masks |
| `spans.zig` | Overlapping ranges (CMaps, CID widths) made disjoint, later definitions winning |

## Ownership

`Document` owns an arena with everything parsed from the file (objects, fonts, colour
spaces, functions, CMaps, CID to glyph maps). Each is parsed on first use and cached, so
using a thing again does not grow the arena. A colour space that looks up a name in a
page's resources is not cached, and objects are cached by address only when they are part
of the document (never an inline image's copied dictionary). The file's bytes are borrowed
for `open` and owned for `openReader`. Data that is only needed for a moment (decoded
content streams, operands, filter lists) goes into a scratch arena that `Renderer` resets
after every page; it comes from the document's allocator, so the allocator given to
`render` only has to outlive the list. A `DisplayList` owns its own arena. It points into
the document (fonts, image streams), so it must not outlive the `Document`.

## Display list conventions

Coordinates are in the page's default user space (origin bottom left, y up). Every drawing
command carries the `ctm` that maps its coordinates to user space, and
`DisplayList.base` maps user space to the displayed page (points, origin top left, y down,
crop box, `/UserUnit` and `/Rotate` applied). `Page`'s boxes stay in user space units, each
`Page.user_unit` points long. Sizes given to the annotation functions (ink width, text size)
are points on the displayed page. A point `p` is drawn at `p * ctm * base`, with the
row-vector convention of the specification.

`save` and `restore` bracket the graphics state; `clip` narrows the clip until the matching
`restore`. A `text` command carries font, size, rendering mode, the text matrix at the start
of the run, and per glyph the character code, CID, offset along the run, advance and Unicode
text. A Type 3 font draws its glyphs as the paths of its procedures and also emits the run as
invisible text (mode 3) so it can be extracted.

An annotation without a stored appearance, and a text or choice field whose form sets
`NeedAppearances`, gets one made in memory (`appearance.zig`,
`docs/decisions/0004-generated-appearances.md`), drawn like a stored one. Signature fields
get no more than their background and border. Links, stamps, carets, attachments and
sounds are not made.

A button whose appearance dictionary has states, none of them a drawing, counts as having
no appearance; if any state is one, a state without a drawing shows nothing.

**Flattening** (`flatten.widgets`) is an edit: it draws each widget's appearance (stored,
or made as above) at the end of the page content, gives the page resources of its own,
removes the widgets, and takes emptied fields out of the form and XFA with them. The old
content is wrapped in enough `q` and `Q` to make up for any it leaves unmatched; content
that cannot be decoded stops it (`error.UnreadableContent`). Signatures, hidden widgets
and widgets in optional content stay. The earlier values remain in the file.

`DisplayList.omissions` says what the page uses that the list leaves out or only
approximates. `incomplete` is set when content is missing: a stream that cannot be decoded,
a function that cannot be read, a shading of type 1 or 4 to 7, or nesting past
`max_depth`. The rest (soft masks, transparency groups that matter, overprint, text
clipping, annotations without an appearance, JBIG2, text without Unicode, vertical fonts,
`/Matte`) is passed on approximately.

## New documents

`compose.Builder` writes a complete new file (`docs/decisions/0003-writing-new-documents.md`).
It creates, deletes, reorders, merges, splits and rotates pages. `write.Update` is the other
way to change a PDF: it appends to the file and keeps everything in it.

- **Copying.** `importPages` first numbers the chosen pages, then their annotations, then
  copies everything they refer to from a work list. A reference to the catalog, a page tree
  node, a structure element, the outline or a page not in the call becomes null, so nothing
  left out can come in through it. Objects are copied once per call.
- **What is rewritten.** Pages get their inherited attributes. A destination becomes an
  explicit array to the new page, or is dropped. Of actions, `GoTo` (as a destination),
  `URI` and `Named` stay; others, `/Next` chains and the `/AA` entries of pages and
  annotations are dropped. Layers that were copied go into `/OCProperties` with their
  default on or off state.
- **Forms** (`compose_form.zig`). The source's field tree is read down `/Kids` from
  `/AcroForm /Fields`. A field with a widget on an imported page is kept, with the groups
  above it, its value, and only those kids. A widget outside the tree loses `/Parent` and
  is only an annotation. `/DA` and `/Q` of the form dictionary are written on the top level
  fields, and its `/DR` fonts are merged into one dictionary. A later call's top level
  field or font whose name is taken gets `_2`, `_3` and so on, and `/DA` follows the font.
  `NeedAppearances` stays if a source had it. Signature values are dropped (they sign
  another file); so are calculation order, scripts and XFA.
- **Bookmarks** (`compose_outline.zig`). One that leads to an imported page is kept, and
  so is a heading above it, without a destination of its own if its target is gone. Titles,
  colour, style and open state stay. Each call's bookmarks follow the earlier ones.
  Bookmarks with other actions, web links included, are dropped.
- **Memory.** Pages and objects are serialized as they are copied, and the source can be
  closed after the call. `compose.Options` limits the size and the number of objects. A
  call that fails adds nothing.
- **Output** (`compose_pack.zig`). PDF 1.7 (2.0 if a source is). Objects that are not
  streams go into Flate-compressed object streams of at most 200, found through a
  compressed cross-reference stream (7.5.7, 7.5.8). Stored stream data is copied without
  being re-encoded. On the files compared, the reversed copies came to less in total than
  their originals (200 files: 45.6 MB to 41.8 MB; 7 long manuals: 40.1 MB to 36.5 MB).
  Those are totals; a single file need not come out smaller.
- **Not carried over:** document information and metadata, page labels, document
  attachments, structure and output intents. **It is not redaction:** a resource dictionary
  that pages share is copied whole, and a field with widgets on several pages keeps its
  value when only one of those pages is imported.
- **Encrypted sources** need `ImportOptions.allow_decrypted_output`, as the output is not
  encrypted. Repaired sources are fine.

## Signatures

`signature.zig` lists signatures and what they cover (ISO 32000-1 12.8; decision 0006,
step S1). It does no cryptography.

- **What is listed:** the value of each signature field that the form lists, then any
  signature that only the permissions dictionary names (`DocMDP`, `UR3`). A later change
  can take a signature out of the form, so an empty list does not mean "never signed".
- **Where the dictionary is.** The coverage rules need byte positions, so the dictionary
  is parsed again from the file text, undecrypted. One inside an object stream has no
  place in the file and is unsound (`not_in_file`).
- **Sound coverage** means all of: the file did not need repair; `/ByteRange` is four
  direct whole numbers, `[0 a b c]` with `0 < a < b` and `c > 0`, inside the file; the gap
  is exactly this dictionary's `/Contents` in hexadecimal, found by position, and not all
  zeros; the signed bytes end with `%%EOF` (and white space); and opened on their own,
  without repair, they lead to the dictionary at the same offset, through a field their
  own form lists or through their permissions dictionary.
- **Sources of the rules:** the verification algorithm of Mladenov et al. (CCS 2019,
  listing 2), except that content after the signed bytes is reported in `After` instead
  of refusing the signature, so that earlier signatures of a file stay usable. The checks
  of position and of the signed revision are pdf-zig's additions.
- **Changes** compare where the two cross-reference tables take each object from, and
  which objects the trailers name. This says which objects differ, not what that does to
  a page, and **can be empty although the file changed** (content appended without a table
  that a repairing reader would show). `After.nothing` is only reported when white space
  alone follows. Whether changes are permitted is not judged.
- **Limits.** Any number of fields can name one large dictionary, so: `max_examined`
  signatures are read (the rest are `not_examined`); values are limited by
  `max_value_bytes` and `max_all_values_bytes`; claims and lock names share
  `max_listed_bytes`; `max_changes` objects are listed and the rest counted. Each examined
  signature opens its signed revision again, so time grows with signatures times file size.
- **Ownership.** Results are allocated from the caller's arena and do not borrow from the
  document, except `signedRevision`, a slice of the document's bytes. Temporary parses and
  the reopened revision are freed before `list` returns.

### The verifier interface

`verify.zig` asks a verifier that the program supplies whether a listed signature's signed
bytes are unaltered (decision 0006, step S2). **Experimental.** The core does no cryptography.

- **`check` does what must not differ between backends.** The verifier is not asked unless
  the coverage is sound, the signature fits the document it is checked against (ranges in
  bounds, and the gap decodes to this value) and `/SubFilter` names a known format. It is
  handed slices of the document's own bytes. It refuses `intact` without a certificate or
  key size, and the two reasons only `check` can know. It decides what is weak.
- **A verifier's contract:** exactly one signer; `intact` only if both the digest of the
  signed bytes and the signature were checked; `altered` only for a check that was made
  and failed, otherwise `not_checked` with a reason; zeros may follow the structure in
  the value, and nothing else; the value may be BER.
- **What the types enforce:** `intact` carries the certificate, digest and key.
- **What nothing enforces:** that the answer is true. A backend is security code.
- `check` is not a re-check of coverage: pass it what `signature.list` returned.
- The report has no "valid", and has no field yet for the chain, revocation or a verified
  time (S3).
- **Ownership:** the verifier's answer is allocated from the caller's arena. The report
  also refers to the signature's data. The request is borrowed for the call only.

### pdf_openssl

`src/openssl/`, built only with `-Dopenssl=true`; the build translates the installed
headers (`c.h`, which refuses releases before 3.5) and links `libcrypto`.

- The value is read with `d2i_CMS_ContentInfo` (BER), and only zeros may follow it. It
  must be signed data with one signer, detached exactly when the format is
  `adbe.pkcs7.detached`.
- `CMS_verify` runs with `CMS_BINARY` and `CMS_NO_SIGNER_CERT_VERIFY`. Detached content is
  read from the two signed pieces through a source `BIO`, without joining them. For
  `adbe.pkcs7.sha1` the content in the value is verified, then compared with the SHA-1 of
  the signed bytes.
- `altered` is answered only for OpenSSL's "verification failure", or that SHA-1
  mismatch. A missing certificate and an unknown digest have their own reasons; every
  other failure is `verifier_failed`.
- CAdES and time stamps are `unsupported_format`: CAdES needs the certificate checked
  against a signed attribute, which `CMS_verify` does only together with the chain.
- The certificate in the evidence is the one whose key verified. Nothing binds its names
  to the signature.
- OpenSSL allocates for itself; its failures are `verifier_failed`, not
  `error.OutOfMemory`. Calls clear the thread's OpenSSL error queue, and use the default
  library context.
- **Limits:** the value is at most `signature.max_value_bytes`. What OpenSSL's parser
  does with it is not otherwise bounded by pdf-zig.

`test/backend/` holds the signed files and answers that every backend is tested with.

## Drawing

`draw.Canvas` records content for a page of a given size. Its coordinates are the page as
seen (points, top left origin, y down); it writes PDF's y-up numbers itself, and
`transform` is given in canvas coordinates. Every call checks first and adds nothing when
it fails, so the content is always valid: numbers are finite and bounded, path operators
come in the order of 8.2, and `restore` has its `save`. Saved states left open are closed
when the page is made.

Text is one line, in one of the twelve built-in text fonts or an embedded TrueType font. A
character the font lacks is `error.MissingGlyph`. The built-in fonts take WinAnsi and are
**not embedded**, so each reader substitutes its own, which may lack a character
(Poppler's Courier substitute on one system had no euro sign). Images are JPEG files stored as they are (gray or three
components, 8 bit) or raw gray or RGB pixels, Flate compressed, with alpha as a soft mask.
`compose.Builder.addPage` makes the page; fonts and equal images are stored once.

**Forms and text boxes** can be written in an embedded font (`form.Typeface`: a font and a
`draw.Embedder`, which a `Stamp` also has, so that one copy serves everything in an
update). The font draws the appearance; `/DA` keeps the field's own font (a box:
Helvetica), so another program editing the value later writes with that. Text is laid out
by the same code as before, over units that are WinAnsi bytes or glyph numbers with their
widths. A missing character or a preview-and-print font is refused before anything
changes. Because a form with `NeedAppearances` would have readers redraw the field in its
own font, the flag is turned off, after the other widgets that relied on it get stored
appearances: text and choice fields with values, and widgets with no drawing at all (a
button gets both its states). Those take pdf-zig's style, which differs from some
readers' (bevelled borders, the shape of a radio button).

**Embedded fonts** (`truetype.zig`, `font_embed.zig`). `truetype.Font.init` copies a
`.ttf` file and reads `head`, `hhea`, `maxp`, `hmtx`, `loca`, `glyf`, a Unicode `cmap`
(format 4 or 12), `OS/2`, `post` and `name`, checking every read; CFF fonts and
collections are `error.UnsupportedFont`. `fsType` is honoured as decision 0005 says. It is
written as a Type 0 font (`Identity-H`) over a `CIDFontType2` with a `ToUnicode` map, once
per document or update, with the glyphs of every page: the subset keeps glyph numbers,
empties the unused glyphs, ends after the last used one and keeps the hinting tables. A
font that forbids subsetting is embedded whole. When two characters share a glyph, the
lower numbered one is what reads back. There is **no shaping**: `canvas.text` places each
character's glyph left to right; `canvas.glyphs` takes glyphs and positions from a
caller's shaper. Over 220 installed fonts, Poppler and MuPDF drew each subset exactly as
they drew the whole font.

**Stamps** (`draw.Stamp`) put a canvas on a page of an existing file, in a `write.Update`.
The canvas becomes a form XObject with its own resources, placed by a matrix from the page
as seen into user space, so it is upright at any rotation, crop box and `/UserUnit`; its
top left is the page's, and drawing outside it is cut off. The same canvas on many pages is
one object. `.over` wraps the old content in enough `q` and `Q` to make up for any it
leaves unmatched, and fails with `error.UnreadableContent` if it cannot be decoded;
`.under` goes in front and needs no reading, but a page that paints all of itself hides it.
The page gets resources of its own, under names not in use. As any update, it refuses
encrypted and repaired files. Embedded fonts are written by `Stamp.finish`; until then the
update is `error.UnfinishedFonts`.

## Resource limits

All input is untrusted. The limits, and why each counts what it does, are in
`docs/decisions/0002-work-limits.md`.

- `document.Options`: file size, object numbers, decoded stream size, data retained in the
  document, `/Prev` chain length.
- `interp.Options`: per page, the operators, content bytes (every reuse counted), commands,
  glyphs and path segments; the nesting of forms, patterns and Type 3 glyphs.
- Fixed: object syntax nesting 64; objects loaded from inside one another 32; filters per
  stream 16; graphics state stack 4096; page tree depth 256 and 2^20 pages.
- Listings (`form.fields`, `annot.list`, `outline.read`) copy at most
  `write.max_listed_bytes` of strings and arrays; name-tree lookups have a node budget.

A page over an `interp.Options` limit or the graphics state limit returns
`error.LimitExceeded`. A page tree branch that is too deep is skipped and
`PageList.truncated` set.

## Errors and memory

A failed allocation must not look like a missing object. `Document.oom_events` counts
failures inside functions that answer with a value; nothing produced while it changes is
cached, and `open`, `PageList.build`, `pages.contents`, `decodeStream`, `Renderer.render`
and `Update.write` return `error.OutOfMemory`. A later call can then succeed.

## Repair

When `startxref` or a cross-reference section is unusable, the catalog is unreachable, or an
object is not where the table says, `Document.rebuild` scans the file for `N G obj`, trailers
and cross-reference streams and registers objects found inside object streams. What comes
later in the file is newer, for trailers, definitions (direct or in an object stream) and
guessed catalogs. A surviving encryption dictionary is used even if no trailer names it. A
repair that fails leaves the document as it was. Failed candidate parses share a budget, so
repair takes time in proportion to the file. A repaired file cannot be edited.

## Text extraction

Glyphs are grouped by writing direction (horizontal first) and measured along and across
their baseline. In reading order, lines form around the baselines with the most text, and
smaller raised or lowered pieces join the nearest one within half a font size.

## Not supported

- Verifying signatures: only integrity, through `pdf_openssl` or a program's own backend
  (decision 0006, step S2). CAdES, time stamps and `adbe.x509.rsa_sha1` are not checked.
  Chains, revocation and verified time stamps (S3), and creating signatures, are not
  supported. Whether changes after
  signing are permitted is not judged.
- In new documents: encryption.
- Embedding fonts with CFF outlines (`.otf`) or from collections (`.ttc`), and text
  shaping.
- Public-key security handlers: `error.UnsupportedEncryption`. (The standard handler is read: see `crypt.zig`.)
- SASLprep's normalization (NFKC) is not applied to R5 and R6 passwords. A password
  typed in composed form, as keyboards usually give it, is unaffected; one with
  decomposed accents, or compatibility characters that the writer normalized, will not
  open the file. The owner password is not used. A separate crypt filter for embedded
  files (`/EFF`) is not read.
- Shadings other than types 2 and 3 (function-based and mesh): skipped.
- Soft masks and transparency groups: alpha values and blend-mode names are passed on;
  masks are not. (Soft masks of images are applied.)
- Visibility expressions (`/VE`) of optional content are not evaluated.
- Vertical writing (`WMode 1`) is read horizontally; predefined CMaps other than
  Identity are treated as the identity (CIDs equal codes), so CJK text without
  `/ToUnicode` has no Unicode.
- Image codecs: DCT, JPX and JBIG2 data is not decoded (`image.decode` returns it with the
  codec name, for the viewer to decode and pass to `image.fromSamples`; a mask in one of
  them is reported as `Pixels.pending_mask`). JBIG2 has no decoder.
- Text clipping modes (4 to 7) and `d1` colour suppression in Type 3 glyphs.
- Symbol and ZapfDingbats built-in encodings and widths (a typical width is used);
  MacExpertEncoding; `a_b` ligature glyph names.
- References are resolved by object number; the generation is not compared.

## Encryption

`Document.load` derives the file key (`crypt.zig`) as soon as the cross-reference data is read
and before any other object is cached, from `Options.password` (empty by default). The
password is tried as given. If that fails and it is UTF-8, it is tried once more: up to
R4 in PDFDocEncoding (Adobe's ExtensionLevel 3 supplement to ISO 32000, algorithm 3.2),
and for R5 and R6 with SASLprep's character mapping (the same supplement, algorithm 3.2a;
RFC 4013). Strings are
decrypted when an object is loaded. Stream data is decrypted when it is decoded (`Stream.encrypted`
with the object number and generation), so decrypted content can live in a scratch arena.
Objects inside object streams are not decrypted separately; the object stream is. Cross-reference
streams, the encryption dictionary itself, a stream with an identity `/Crypt` filter and, with
`/EncryptMetadata false`, the metadata stream are left alone. A stream naming another filter
with `/Crypt` is decrypted with that filter's method. A method that is not recognised is an
error, never treated as unencrypted.

## Text layout, outlines, writing, annotations and forms

`text.zig` (`layout`), `outline.zig`, `link.zig`, `write.zig`, `annot.zig` and `form.zig` sit on top of
the reader. Reading stays in the document arena; everything an edit creates lives in the
`write.Update`'s own arena and is written once.

- **Coordinates.** Reading annotations and fields returns rectangles in PDF user space (y up).
  Creating annotations takes rectangles on the *displayed page* (points, top left origin, y down,
  the space `text.Layout` and `DisplayList.base` use) and converts them with the page's base matrix.
- **Incremental update.** `write.Update.write` emits the original bytes unchanged, the new and
  changed objects (keeping their generations), a cross-reference section (a table, or a
  stream when the file's last section is one) with `/Prev`, and a trailer with a new second
  `/ID` string. An empty update writes the file unchanged. Encrypted files and files whose
  cross-reference data had to be rebuilt, at open or during editing, are refused
  (`error.Encrypted`, `error.Repaired`) instead of written wrongly.
- **Undo.** An edit only appends, so cutting the bytes back to their earlier length undoes it.
- **What is touched.** Only objects the edit needs: an annotated page gets an `/Annots` array
  of its own (an array object may be shared), outline edits find items by walking the tree,
  and a reference that does not lead where it should is never written through.
- **Appearance streams.** Highlights draw with the Multiply blend mode; notes, text boxes and
  filled text fields have their own streams, so any reader shows them. List boxes are
  drawn too.
