# pdf-zig

A PDF library for Zig, built on `std.Io`, for the DKDE PDF viewer. It reads the
file structure and turns pages into a **display list** (paths, text, images, shadings)
that a renderer draws; it draws nothing itself. It also finds text on the page, reads
bookmarks, links and form fields, and writes annotations, bookmarks and form values as an
incremental update. It can also make new documents from blank pages and from pages of
others. Zig 0.17.1, no dependencies.

Written from ISO 32000-1:2008 (see `docs/decisions/0001-architecture.md`).

```zig
const pdf = @import("pdf");

var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
defer doc.deinit();

const list = try pdf.pages.PageList.build(&doc);          // every page, in order
const page = pdf.pages.page(&doc, list, 0).?;             // sizes, rotation, resources

var rend = pdf.Renderer.init(&doc, .{});                  // reusable across pages
defer rend.deinit();
var dl = try rend.render(gpa, page);                      // the display list
defer dl.deinit();
for (dl.commands) |cmd| switch (cmd) { ... };             // draw it

const text = try pdf.text.extract(gpa, &dl, .reading);    // or just the text
```

`Renderer.Options.graphics = false` returns only the text runs: several times faster and
a fraction of the memory, for search and extraction.

## Text positions, bookmarks, annotations and forms

```zig
// Where every glyph is: select, copy and search on the displayed page.
var lay = try pdf.text.layout(gpa, &dl);                  // text + a box per glyph
defer lay.deinit(gpa);
const at = lay.offsetAt(x, y);                            // byte offset nearest a point
var found: std.ArrayList([2]u32) = .empty;
try lay.find(gpa, "needle", &found);                      // byte ranges of matches
try lay.rectsFor(gpa, from, to, &rects);                  // one rectangle per line

// The document outline ("bookmarks"), as a tree.
const items = try pdf.outline.read(arena, &doc, list);

// The links of a page: a rectangle and a target (a page, a URI, a named action).
const links = try pdf.link.list(arena, &doc, list, page);

// Edits are an incremental update appended to the file; the original bytes stay.
var upd = try pdf.write.Update.init(gpa, &doc);
defer upd.deinit();
_ = try pdf.annot.addMarkup(&upd, page, .highlight, rects.items, .{ .contents = "why" });
_ = try pdf.annot.addNote(&upd, page, x, y, .{ .contents = "a note" });
_ = try pdf.outline.add(&upd, page.num, "A bookmark", null);
const fields = try pdf.form.fields(arena, &doc, list);
try pdf.form.setText(&upd, fields[0], "Dakota");
try upd.write(gpa, &writer.interface);                    // original file + the update
```

| Module | What it does |
|---|---|
| `text.layout` | reading-order text with a box for every glyph; hit testing, search ranges and per-line rectangles |
| `outline` | reads the bookmark tree (named destinations too); adds and removes bookmarks |
| `link` | reads a page's links. It follows none: a URI is untrusted text, so check its scheme before opening it |
| `write` | serializes objects; appends an incremental update with a classic table or a cross-reference stream. Refuses encrypted files and files that had to be repaired on open |
| `annot` | reads annotations; adds highlights, underlines (straight or squiggly), strike-outs, notes, ink and text boxes with appearance streams; edits and removes them |
| `form` | finds AcroForm fields (groups, check boxes, radio groups, choices); fills text, check box, radio, combo and list fields |

Form limits: a filled text field gets a new appearance with the widget's background,
border and rotation. It uses the font `/DA` names if that font can write the text,
else Helvetica; characters outside WinAnsi draw as `?` (`/V` keeps the full text). A comb
field gets one character per cell (without dividing lines). A widget's pressed appearance
is dropped. The value
of a password field is not stored in the file. A choice field stores the option's export
value, and only an editable combo box takes other text. Signature fields are listed, not
filled; XFA forms are not read; no scripts run.

## New documents: extract, reorder, merge

```zig
var out = pdf.compose.Builder.init(gpa, .{});
defer out.deinit();
try out.importPages(&first, &.{ 2, 0, 1 }, .{});          // any pages, in any order
try out.addBlankPage(612, 792);                           // points
try out.importPages(&second, &.{0}, .{});
try out.setRotation(0, 90);
try out.write(&writer.interface);                         // a complete new file
```

Import all the pages you want from a document in one call: shared fonts and images are
then copied once, and links between those pages keep working. Pages keep their content,
annotations, links, hidden layers, fillable form fields and the bookmarks that lead to them.
Fields or form fonts that would share a name with an earlier import are renamed (`name_2`).
Document information, page labels, accessibility tags, scripts and signatures are not carried. An encrypted source is refused unless `allow_decrypted_output` is set, because the
new file is not encrypted. Leaving a page out is **not redaction**: pages often share
resources, which are copied whole. Details in `docs/architecture.md`, "New documents".
Drawing content on new pages is not supported yet.

## What it reads

| Area | State |
|---|---|
| Encryption | the standard security handler: RC4 40-128 bit, AES-128, AES-256 (R5, R6), user password (`Options.password`, empty by default); other handlers give `error.UnsupportedEncryption`, a wrong password `error.PasswordRequired` |
| File structure | header, cross-reference tables and streams, `/Prev` chains, hybrid files, object streams, incremental updates; **repair** by scanning when the table is damaged |
| Filters | Flate, LZW, ASCII85, ASCIIHex, RunLength, PNG and TIFF predictors. DCT, JPX, JBIG2 and CCITT are passed on by `Document.decodeStream`, which reports the first one in `rest` (`image.decode` decodes CCITT) |
| Page tree | inherited `Resources`, `MediaBox`, `CropBox`, `Rotate`; `UserUnit`; wrong `/Count` and cycles tolerated |
| Graphics | paths, strokes (width, caps, joins, dashes), fills (both rules), clipping, forms, inline images, image XObjects (referenced, not decoded), axial and radial shadings (sampled to colour stops), shading and tiling patterns, optional content (layers), annotation appearance streams (made when a field or mark has none), transparency values (`ca`, `CA`) and blend-mode names |
| Colour | DeviceGray/RGB/CMYK, Cal*/ICC (as the device space), Lab, Indexed, Separation, DeviceN, Pattern; PDF functions of types 0, 2, 3 and 4 |
| Text | simple fonts (Type 1, TrueType, Type 3), composite fonts (Type 0 with Identity or embedded CMaps), encodings (Standard, WinAnsi, MacRoman, Differences), `/ToUnicode`, `/Widths`, `/W`, the standard 14 metrics, text state and all text operators |
| Text extraction | reading order or content-stream order, rotated text along its own baseline; ligatures expanded |
| Images | `image.decode` gives straight-alpha RGBA for Flate/LZW/ASCII/RunLength/CCITT/raw images: 1, 2, 4, 8, 16 bit, every colour space above, `/Decode`, stencil masks, colour-key masks, soft masks. JPEG, JPX and JBIG2 data is returned undecoded with the codec name; `image.fromSamples` then applies the colour space and masks to the codec's samples, and `image.withMaskSamples` a mask that needed the codec |

Not done (see `docs/architecture.md`, "Not supported"): JBIG2, DCT and JPX decoding (the viewer's codec's job), public-key encryption, mesh and function-based shadings, soft masks of graphics state, vertical writing, predefined CJK CMaps other than Identity.

Damaged and hostile files are expected: limits on memory and work are described in
`docs/decisions/0002-work-limits.md`. No claim of being proof against every input is made.

## Checked against poppler

On an even sample of 831 of the PDFs under `/usr/share` on the development machine
(mostly TeX documentation), version 0.3.0 reports the same page count, draws the same
number of commands and reports the same page errors as 0.2.2 did, with no crash or
timeout. The text of some files differs. Measured by words against `pdftotext`, in
reading order 125 of those files moved closer to it, 60 further away and 15 stayed as
far (the total difference over them fell by about 4%). In stream order 135 moved closer,
9 further and 4 stayed as far, but the total rose by about 2%, mostly from two files with
heavily overlapping text. 0.3.1 extracts the same text as 0.3.0 from all of them, and
0.4.0 the same as 0.3.1. In a separate sample, 273 copies with annotations added by the
library showed no new errors when Poppler and MuPDF drew their first page. These are
comparisons on one set of files, not a conformance claim. The scripts in `test/tools/`
compare with `pdftotext` and `pdfinfo`.

## Example programs

`zig build` installs `pdfinfo` (structure, `-r` renders every page and decodes its images),
`pdftext` (`-raw` for stream order, `-p` for a password), `pdfdump` (the display list of a page),
`pdfsvg` (a page as SVG, to look at), `pdfimg` (decode the images of a page), `pdfmark`
(highlight a word and add a note), `pdffill` (list or fill form fields) and `pdfpages` (a new
PDF from chosen pages of others, as in `pdfpages out.pdf a.pdf:3,1,5-9 b.pdf`). `pdfsurvey` names the features a
file uses.

## Tests

`zig build test` runs the unit tests and compiles the example programs: syntax, filters
(with LZW data from libtiff and fax data from Ghostscript), documents (xref forms, repair,
hostile input, token-level mutation), encrypted files made with qpdf, content streams,
fonts, CMaps, functions, colour, the interpreter, text extraction, images, writing,
links and new documents.
It also passes for `x86-linux` and in the release modes. Changes between releases are in
`docs/CHANGELOG.md`.

## License

Copyright (c) 2026 Dakota James Owen Keeler.

pdf-zig is free software under the GNU Library General Public License, version 2
or (at your option) any later version (`LGPL-2.0-or-later`). It comes with no
warranty. See `LICENSE`. Releases made before this change were published
under the MIT License.

Material from others keeps its own terms: the Adobe Glyph List in `src/agl.zig`
(its notice is in the file) and the fax code tables in `src/ccitt_tables.zig`
(from zigimg, MIT License). The font widths in `src/std14.zig` were measured
from Ghostscript's fonts (`scripts/gen-std14.py`).
