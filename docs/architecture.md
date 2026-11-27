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
| `link.zig` | The links of a page: destinations, URIs and named actions. It follows none of them |
| `write.zig`, `annot.zig`, `outline.zig`, `form.zig` | Changes to a file, appended to it |
| `compose.zig` | A new document from blank pages and pages of other documents |
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

A list with content left out (a stream that cannot be decoded, a function that cannot
be read, a shading of type 1 or 4 to 7, nesting past `max_depth`) has `DisplayList.incomplete` set.

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
  annotations are dropped. A widget loses `/Parent`. Layers that were copied go into
  `/OCProperties` with their default on or off state.
- **Memory.** Pages and objects are serialized as they are copied, and the source can be
  closed after the call. `compose.Options` limits the size and the number of objects. A
  call that fails adds nothing.
- **Output.** PDF 1.7 (2.0 if a source is), a cross-reference table, no object streams.
  Stored stream data is copied without being re-encoded. A file whose source uses object
  streams grows: on the long TeX manuals tried, up to a little over twice the size.
- **Not carried over:** bookmarks and the form (planned next), document information and
  metadata, page labels, document attachments, structure and output intents. Widgets keep
  their appearance streams only. **It is not redaction:** a resource dictionary that pages
  share is copied whole.
- **Encrypted sources** need `ImportOptions.allow_decrypted_output`, as the output is not
  encrypted. Repaired sources are fine.

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

- In new documents: bookmarks, forms, object streams, encryption, and drawing new page
  content.
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
  filled text fields have their own streams, so any reader shows them. `NeedAppearances` is
  set only for list boxes, which have no generated appearance (their old one is removed).
