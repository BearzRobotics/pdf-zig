# pdf-zig

A PDF library for Zig, built on `std.Io`, for the DKDE PDF viewer. It reads the
file structure and turns pages into a **display list** (paths, text, images, shadings)
that a renderer draws; it draws nothing itself. It also finds text on the page, reads
bookmarks and form fields, and writes annotations, bookmarks and form values as an
incremental update. Zig 0.17.1, no dependencies.

Written from ISO 32000-1:2008 (see `docs/decisions/0001-architecture.md`).

```zig
const pdf = @import("pdf");

var doc = try pdf.Document.openReader(gpa, &reader.interface, .{});
defer doc.deinit();

const list = try pdf.pages.PageList.build(&doc);          // every page, in order
const page = pdf.pages.page(&doc, list, 0).?;             // sizes, rotation, resources

var rend = pdf.Renderer.init(&doc, .{});                  // caches fonts across pages
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
| `write` | serializes objects; appends an incremental update with a classic table or a cross-reference stream. Refuses encrypted files and files that had to be repaired on open |
| `annot` | reads annotations; adds highlight, underline, strike-out and note annotations with appearance streams; edits and removes them |
| `form` | finds AcroForm fields (groups, check boxes, radio groups, choices); fills text, check box, radio, combo and list fields |

Form limits: a filled text field gets a new appearance in Helvetica with WinAnsi
characters (others draw as `?`; `/V` keeps the full text); signature fields are
listed, not filled; XFA forms are not read; no scripts run. Annotation output was
checked against poppler (`zig build` makes `pdfmark` and `pdffill` for that).

## What it reads

| Area | State |
|---|---|
| Encryption | the standard security handler: RC4 40-128 bit, AES-128, AES-256 (R5, R6), user password (`Options.password`, empty by default); other handlers give `error.UnsupportedEncryption`, a wrong password `error.PasswordRequired` |
| File structure | header, cross-reference tables and streams, `/Prev` chains, hybrid files, object streams, incremental updates; **repair** by scanning when the table is damaged |
| Filters | Flate, LZW, ASCII85, ASCIIHex, RunLength, PNG and TIFF predictors. DCT, JPX, JBIG2 and CCITT are passed on undecoded (`Document.decodeStream` reports the first one in `rest`) |
| Page tree | inherited `Resources`, `MediaBox`, `CropBox`, `Rotate`; wrong `/Count` and cycles tolerated |
| Graphics | paths, strokes (width, caps, joins, dashes), fills (both rules), clipping, forms, inline images, image XObjects (referenced, not decoded), axial and radial shadings (sampled to colour stops), shading and tiling patterns, optional content (layers), annotation appearance streams, transparency values (`ca`, `CA`) and blend-mode names |
| Colour | DeviceGray/RGB/CMYK, Cal*/ICC (as the device space), Lab, Indexed, Separation, DeviceN, Pattern; PDF functions of types 0, 2, 3 and 4 |
| Text | simple fonts (Type 1, TrueType, Type 3), composite fonts (Type 0 with Identity or embedded CMaps), encodings (Standard, WinAnsi, MacRoman, Differences), `/ToUnicode`, `/Widths`, `/W`, the standard 14 metrics, text state and all text operators |
| Text extraction | reading order or content-stream order; ligatures expanded |

| Images | `image.decode` gives straight-alpha RGBA for Flate/LZW/ASCII/RunLength/raw images: 1, 2, 4, 8, 16 bit, every colour space above, `/Decode`, stencil masks, colour-key masks, soft masks. JPEG, JPX, JBIG2 and CCITT data is returned undecoded with the codec name; `image.fromSamples` then applies the colour space and masks to the codec's samples |

Not done (see `docs/architecture.md`, "Not supported"): JBIG2 and CCITT decoding (JPEG and JPX are the viewer's codec's job), public-key encryption, mesh and function-based shadings, soft masks of graphics state, vertical writing, predefined CJK CMaps other than Identity.

## Checked against poppler

On the 80 PDFs found on the development machine (CUPS, pdfTeX, Cairo, LibreOffice, Skia,
Ghostscript, fig2dev output): the page count matches `pdfinfo` on every file poppler can
read, and the words of `pdftext -raw` match `pdftotext -raw` to within about 1% (the
differences are spacing heuristics and ligature handling). A 332-page, 15 MB book is
extracted in about 3 s using 35 MB. This is a comparison on one set of files, not a
conformance claim.

## Example programs

`zig build` installs `pdfinfo` (structure, `-r` renders every page and decodes its images),
`pdftext` (`-raw` for stream order, `-p` for a password), `pdfdump` (the display list of a page),
`pdfsvg` (a page as SVG, to look at) and `pdfimg` (decode the images of a page).

## Tests

`zig build test`: syntax, filters (with the spec's LZW example), documents (incremental
updates, xref streams, repair, mutation fuzzing, encrypted files made with qpdf), pages, content streams, encodings,
CMaps, fonts, functions, colour, the interpreter on hand-built pages, text extraction, images.

License: MIT.
