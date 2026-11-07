# pdf-zig

A PDF reader library for Zig, built on `std.Io`, for the DKDE PDF viewer. It reads the
file structure and turns pages into a **display list** (paths, text, images, shadings)
that a renderer draws; it draws nothing itself. Zig 0.17.1, no dependencies.

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

## What it reads

| Area | State |
|---|---|
| File structure | header, cross-reference tables and streams, `/Prev` chains, hybrid files, object streams, incremental updates; **repair** by scanning when the table is damaged |
| Filters | Flate, LZW, ASCII85, ASCIIHex, RunLength, PNG and TIFF predictors. DCT, JPX, JBIG2 and CCITT are passed on undecoded (`Document.decodeStream` reports the first one in `rest`) |
| Page tree | inherited `Resources`, `MediaBox`, `CropBox`, `Rotate`; wrong `/Count` and cycles tolerated |
| Graphics | paths, strokes (width, caps, joins, dashes), fills (both rules), clipping, forms, inline images, image XObjects (referenced, not decoded), axial and radial shadings (sampled to colour stops), shading and tiling patterns, optional content (layers), annotation appearance streams, transparency values (`ca`, `CA`) and blend-mode names |
| Colour | DeviceGray/RGB/CMYK, Cal*/ICC (as the device space), Lab, Indexed, Separation, DeviceN, Pattern; PDF functions of types 0, 2, 3 and 4 |
| Text | simple fonts (Type 1, TrueType, Type 3), composite fonts (Type 0 with Identity or embedded CMaps), encodings (Standard, WinAnsi, MacRoman, Differences), `/ToUnicode`, `/Widths`, `/W`, the standard 14 metrics, text state and all text operators |
| Text extraction | reading order or content-stream order; ligatures expanded |

Not done (see `docs/architecture.md`, "Not supported"): encryption (an encrypted file gives
`error.Encrypted`), mesh and function-based shadings, soft masks, vertical writing, predefined
CJK CMaps other than Identity, image pixel decoding.

## Checked against poppler

On the 80 PDFs found on the development machine (CUPS, pdfTeX, Cairo, LibreOffice, Skia,
Ghostscript, fig2dev output): the page count matches `pdfinfo` on every file poppler can
read, and the words of `pdftext -raw` match `pdftotext -raw` to within about 1% (the
differences are spacing heuristics and ligature handling). A 332-page, 15 MB book is
extracted in about 3 s using 35 MB. This is a comparison on one set of files, not a
conformance claim.

## Example programs

`zig build` installs `pdfinfo` (structure, `-r` renders every page), `pdftext` (`-raw`
for stream order) and `pdfdump` (the display list of a page).

## Tests

`zig build test`: syntax, filters (with the spec's LZW example), documents (incremental
updates, xref streams, repair, mutation fuzzing), pages, content streams, encodings,
CMaps, fonts, functions, colour, the interpreter on hand-built pages, text extraction.

License: MIT.
