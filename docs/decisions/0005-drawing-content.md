# 0005: Drawing page content

Status: accepted by the maintainer in conversation, with all four recommendations under
"Questions for the maintainer". This is stage 2 of `docs/ROADMAP.md`, called stage B in
0003. Steps B1 to B3 are implemented; see docs/architecture.md. Settled while implementing
B1: a
canvas keeps its own copy of each image (so images need not outlive the call), equal
images are found by a digest of their content, and transparency is `setAlpha` and
`setBlend`.

Settled in B2 and B3: `write.Update.write` returns `error.UnfinishedStamp` rather than
write a file whose embedded font `finish` has not written. A font is borrowed only until
the canvas is placed: the builder and the stamp copy it. A subset keeps the glyph numbers
and empties the glyphs not used, so `CIDToGIDMap` is `Identity`. A PDF gives one text to a
code, so when a font uses one glyph for two characters the one with the lower number is
recorded; over 220 installed fonts the only case met was the increment sign reading back
as the Greek delta.

## Problem

pdf-zig can build documents from blank pages and pages of other documents, but cannot put
anything on a page except annotations. The maintainer wants to create documents. The same
ability gives watermarks and page numbers, an invisible text layer over a scan, and, with
embedded fonts, forms and text boxes in other scripts than WinAnsi.

## Proposal

A **canvas** records drawing. It knows nothing about where it will end up. Two things can
place it: the builder of new documents (0003), and an incremental update of an existing
file.

```zig
var canvas = pdf.draw.Canvas.init(gpa, 612, 792);        // the page as seen, in points
defer canvas.deinit();
try canvas.setFill(.{ .rgb = .{ 0.9, 0.9, 0.9 } });
try canvas.rect(36, 36, 540, 40);
try canvas.fill(.nonzero);
try canvas.text(.helvetica_bold, 18, 48, 64, "Quarterly report");   // x, baseline
try canvas.image(photo, 48, 100, 300, 200);

// A new document:
var out = pdf.compose.Builder.init(gpa, .{});
try out.addPage(&canvas);
try out.write(&writer.interface);

// An existing file:
var stamp = pdf.draw.Stamp.init(&upd);
try stamp.place(page, &canvas, .over);                    // or .under
try stamp.finish();                                       // writes shared fonts once
try upd.write(gpa, &writer.interface);
```

### Coordinates

The canvas uses **the page as displayed**: points, origin at the top left, y downward.
This is what `text.Layout`, `DisplayList.base` and the annotation functions use. On a
rotated page, or one with `/UserUnit`, a stamp placed this way is upright and where it
was asked for, without the caller doing anything. PDF's own space (y upward, 8.3) is not
exposed.

### What the canvas draws

| Group | Functions |
|---|---|
| State | `save`, `restore`, `transform`, `setFill`, `setStroke` (gray, RGB, CMYK), `setLineWidth`, caps, joins, dashes, `setAlpha`, `setBlend` |
| Paths | `moveTo`, `lineTo`, `curveTo`, `close`, `rect`, `fill`, `stroke`, `fillStroke`, `clip` |
| Text | `text` (one line at a baseline), `textWidth`, and options for rendering mode and horizontal fit |
| Images | `image` into a rectangle |

There is no layout engine: no wrapping, tables or paragraphs. `textWidth` lets a caller do
its own. `restore` without `save`, drawing a path that was never started, and numbers
that are not finite or are huge are errors, so a canvas always makes valid content.

**Invisible text** (rendering mode 3, 9.3.6) with a width to fit is what a text layer over
a scan needs: each word is stretched to its box.

### Images

- **JPEG** is stored as it is (`DCTDecode`, 7.4.8). Its header is read for the size and
  number of components. CMYK JPEG files differ in whether their values are inverted;
  the first version accepts gray and RGB only.
- **Raw pixels** (gray or RGB, 8 bit, with optional alpha) are compressed with the
  standard library's Flate, alpha as a soft mask (8.9.5).
- PNG and other formats are the caller's to decode.

An image is one object however often it is placed.

### Fonts

**Built in:** the twelve text fonts of the standard 14, in WinAnsi, which need nothing
embedded. Their widths are already in `std14.zig`.

**TrueType** (`.ttf` files, given as bytes): embedded as a Type 0 font with a
`CIDFontType2` descendant and `Identity-H` (9.7.4, 9.9), with a `ToUnicode` map (9.10.3)
so that the text can be selected and searched, and a font descriptor (9.8).

- **Subsetting.** Only the glyphs used are kept. Fonts are written when the document is,
  once, with the glyphs of every page that used them.
- **What pdf-zig reads:** the tables needed to map characters to glyphs, measure them,
  describe the font and cut the subset. It does not rasterise or hint.
- **A font file is untrusted input**, with bounds on every offset and count, and its own
  fuzzing.
- **Later, not now:** OpenType fonts with CFF outlines (`.otf`, which includes much CJK),
  and font collections (`.ttc`).

**Permissions.** A font says how it may be embedded, in `fsType` of its `OS/2` table
([OpenType 1.9.1](https://learn.microsoft.com/en-us/typography/opentype/spec/os2)), and
the specification says applications must not embed a font whose licence does not permit
it. Proposed:

| `fsType` | pdf-zig |
|---|---|
| Installable (0) or editable (8) | embeds |
| Preview and print (4) | embeds in page content; **not** for form fields, which invite editing |
| Restricted licence (2) | `error.FontNotEmbeddable`, unless the caller states that it has the owner's permission |
| No subsetting (bit 8) | embeds the whole font |
| Bitmap embedding only (bit 9) | `error.FontNotEmbeddable` (pdf-zig embeds outlines) |

This follows what the font declares. It does not decide what a font's licence allows,
and it is not legal advice.

**A character the font lacks** is an error (`error.MissingGlyph`), from the call that
draws the text, with nothing drawn. A caller can check first with `font.covers(text)`.
Silently drawing `?`, as filled forms do today, would lose text in a document the caller
believes complete.

**No shaping.** Each character becomes the glyph the font's character map gives, placed
left to right, without kerning or ligatures. That is right for Latin, Greek, Cyrillic and
unvertical CJK. **It is wrong for Arabic, Indic and other scripts that need shaping, and
right-to-left text would come out reversed.** `canvas.glyphs` takes glyph numbers with
positions and the text they stand for, so a caller with a shaping library can draw those
correctly. pdf-zig does not include one.

### Ownership and limits

A canvas owns its content bytes and a copy of each image. An embedded font (B3) will be
borrowed, and must live until the document or update is written. The builder
copies a canvas's content in `addPage`, so the canvas can be reused or freed.
`compose.Options.max_bytes` covers pages, fonts and images; a canvas has its own cap.

### Existing files

A stamp is an incremental update, so `write.Update`'s rules apply: encrypted and repaired
files are refused. `.over` wraps the old content as flattening does (making up for
unmatched `q` and `Q`); `.under` goes before it. The canvas becomes a form XObject with
resources of its own, so its names cannot collide with the page's.

### New documents

`Builder.addPage(canvas)` sits beside `addBlankPage`. `setInfo` writes title, author,
subject, keywords and dates (14.3.3). Carrying information, page labels and attachments
over from sources is separate work, after this.

## Alternatives

- **A font library** (FreeType, HarfBuzz) would bring shaping and every format, and C
  dependencies, which pdf-zig has none of. Zig's standard library has no TrueType
  support. **Zig font libraries have not been evaluated;** that is the first task of B3,
  and `ai/AGENTS.md` requires it before writing a parser here.
- **Taking font metrics and glyph numbers from the caller** keeps font files out of
  pdf-zig, but then every caller must also subset and describe fonts, which is the
  hard part.
- **Letting callers write content streams themselves** costs nothing, and gives no
  guarantee of a valid page, correct coordinates or usable fonts.

## Font libraries considered (B3, 2026-11-27)

pdf-zig needs to read a few tables of an untrusted TrueType file and write a subset of it.
Looked at, from their project pages and sources, without building or running them:

| Library | Finding |
|---|---|
| [andrewrk/TrueType](https://codeberg.org/andrewrk/TrueType) | A rasteriser. Its README says untrusted font files are not supported; no subsetting is mentioned |
| tatfi | A port of a Rust parser. Its project page could not be loaded; search results say it is a parser, not a subsetter, and its author no longer tracks Zig releases |
| [nat3Github/zig-lib-opentype](https://github.com/nat3Github/zig-lib-opentype) | 0BSD or MIT, Zig 0.17.1, parses, shapes and rasterises, aims to handle malicious input. Calls itself work in progress; about 3.4 MB of source; no subsetter found; one author, repository two months old |
| [sicher/platen](https://github.com/sicher/platen) | MIT, a whole PDF writing library with a subsetter. Repository a week old, one contributor; the read helpers of its subsetter return 0 past the end of the data instead of an error |

**Decision:** write the part that is needed in `truetype.zig`, with every out-of-range read
an error, under pdf-zig's own tests and fuzzing. None of these both subsets and is fit for
untrusted input. If shaping is wanted later, look at zig-lib-opentype again: a caller can
already use any shaper through `canvas.glyphs`.

## Steps

| Step | Contents | Gives |
|---|---|---|
| B1 | Canvas, paths, colours, built-in fonts, images, `addPage`, `setInfo` | new documents |
| B2 | `Stamp` over and under existing pages, invisible fitted text | watermarks, page numbers, simple scan text layers |
| B3 | TrueType embedding and subsetting | other scripts |
| B4 | Forms and text boxes using an embedded font | the end of the WinAnsi limit |

Each is usable and testable on its own.

## Testing

Output is read back by pdf-zig (same commands, same text, same positions, including on
rotated pages and with `/UserUnit`) and rendered by Poppler and MuPDF. For embedded fonts:
text extracted by both matches what was drawn; subsets are compared glyph by glyph with
the whole font's rendering over the TrueType fonts installed here; and damaged font files
are fuzzed. The canvas is tested for refusing what would make invalid content.

## Questions for the maintainer (all answered yes)

1. **Coordinates** of the page as displayed (top left, y down)? Recommended.
2. A **missing character** is an error, not a `?`? Recommended.
3. The **font permission** table above? Recommended.
4. **No shaping** in the first version, with a glyph-level call for callers that shape?
   Recommended; say if you need Arabic or Indic text soon.
