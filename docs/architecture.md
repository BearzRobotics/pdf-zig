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
| `image.zig` | Image samples to RGBA; masks; hand-off to a JPEG/JPX codec |

## Ownership

`Document` owns an arena with everything parsed from the file (objects, fonts, colour
spaces, CMaps). Objects are parsed on first use and cached. The file's bytes are borrowed
for `open` and owned for `openReader`. Data that is only needed for a moment (decoded
content streams, operands) goes into a scratch arena that `Renderer` resets after every
page, so rendering a long document does not keep every page's content in memory.
A `DisplayList` owns its own arena. It points into the document (fonts, image streams), so
it must not outlive the `Document`.

## Display list conventions

Coordinates are in the page's default user space (origin bottom left, y up). Every drawing
command carries the `ctm` that maps its coordinates to user space, and
`DisplayList.base` maps user space to the displayed page (points, origin top left, y down,
crop box and `/Rotate` applied). A point `p` is drawn at `p * ctm * base`, with the
row-vector convention of the specification.

`save` and `restore` bracket the graphics state; `clip` narrows the clip until the matching
`restore`. A `text` command carries font, size, rendering mode, the text matrix at the start
of the run, and per glyph the character code, CID, offset along the run, advance and Unicode
text. A Type 3 font draws its glyphs as the paths of its procedures and also emits the run as
invisible text (mode 3) so it can be extracted.

## Resource limits

`document.Options`: file size, object numbers, decoded stream size, `/Prev` chain length.
`interp.Options`: operators per page, commands per page, nesting of forms, patterns and Type
3 glyphs. Nesting of objects is limited to 64, the graphics state stack to 256, the page
tree walk to 256 levels and one million pages. A page that exceeds a limit returns
`error.LimitExceeded`.

## Repair

When `startxref` or a cross-reference section is unusable, the catalog is unreachable, or an
object is not where the table says, `Document.rebuild` scans the file for `N G obj`, trailers
and cross-reference streams, registers objects found inside object streams, and finds the
catalog by `/Type /Catalog` if no trailer names it. It runs at most once.

## Not supported

- Public-key security handlers: `error.UnsupportedEncryption`. (The standard handler is read: see `crypt.zig`.)
- Shadings other than types 2 and 3 (function-based and mesh): skipped.
- Soft masks and transparency groups: alpha values and blend-mode names are passed on;
  masks are not.
- Vertical writing (`WMode 1`) is read horizontally; predefined CMaps other than
  Identity are treated as the identity (CIDs equal codes), so CJK text without
  `/ToUnicode` has no Unicode.
- Image codecs: DCT, JPX, JBIG2 and CCITT data is not decoded here (`image.decode` returns it with the codec name). JPEG and JPX are expected to be decoded by the viewer, then passed to `image.fromSamples`; JBIG2 and CCITT have no decoder yet.
- Text clipping modes (4 to 7) and `d1` colour suppression in Type 3 glyphs.
- Symbol and ZapfDingbats built-in encodings.

## Encryption

`Document.load` derives the file key (`crypt.zig`) as soon as the cross-reference data is read
and before any other object is cached, from `Options.password` (empty by default). Strings are
decrypted when an object is loaded. Stream data is decrypted when it is decoded (`Stream.encrypted`
with the object number and generation), so decrypted content can live in a scratch arena.
Objects inside object streams are not decrypted separately; the object stream is. Cross-reference
streams, the encryption dictionary itself, a stream with an identity `/Crypt` filter and, with
`/EncryptMetadata false`, the metadata stream are left alone. The owner password is not used.
