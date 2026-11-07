# 0001: Architecture of pdf-zig

Status: accepted by the maintainer in conversation (role and first milestone). Milestone 1 is implemented, including encryption (decision 5) and image pixels (decision 4); see docs/architecture.md.

## Problem

The DKDE PDF viewer needs to read PDF files and draw pages. Today it uses the
vendored `third_party/zpdf` (about 14,500 lines, CC0, by another author) for
file structure and text, and `src/pdfrender` (about 3,300 lines) to draw with
cairo. The maintainer wants a PDF library that follows `ai/AGENTS.md` (`std.Io`,
bounded resources, tests derived from the standard, code readable without the
author) and that replaces zpdf.

## Decisions

1. **pdf-zig is written from the specification, not extracted from zpdf.**
   References: ISO 32000-1:2008 (PDF 1.7, Adobe's free copy), and ISO
   32000-2:2020 where it differs. Clause numbers are cited in the code where a
   rule is not obvious. zpdf may be read to compare behaviour but its code is not
   copied.
2. **Milestone 1 delivers file structure and a display list.**
   - File structure: header, cross-reference tables and streams (including
     `/Prev` chains and hybrid files), trailers, object streams, repair of broken
     files by scanning for `N G obj`, the object model, stream filters, the page
     tree with inherited attributes.
   - Display list: a content-stream interpreter that turns a page into a flat,
     device-independent list of commands (fill/stroke/clip paths, text runs,
     images, shadings) with the graphics state resolved. The viewer draws it
     (cairo in DKDE); the library does no drawing.
   - Text: positioned Unicode text per page, from font encodings, `/ToUnicode`
     and CMaps.
3. **Fonts: the library describes, the renderer draws.** pdf-zig resolves font
   dictionaries (encoding, widths, composite fonts and CIDs, `ToUnicode`) and
   hands the embedded font program (TrueType, CFF, Type 1 bytes and kind) to the
   renderer with each text run. Outline parsing and rasterising stay in the
   viewer, which already has TrueType, CFF and Type 1 code.
4. **Image data is decoded as far as the filters of ISO 32000 that need no codec
   library**: Flate, LZW, ASCII85, ASCIIHex, RunLength, with PNG/TIFF
   predictors. DCT (JPEG), JPX, JBIG2 and CCITT streams are passed to the
   renderer undecoded with their filter name and parameters.
5. **Encryption (standard security handler, RC4 and AES, empty user password) is
   in scope but not milestone 1.** An encrypted file is reported as
   `error.Encrypted` until then.
6. **API shape.** Input is a byte slice or a `*std.Io.Reader` read completely
   (bounded by `Options.max_bytes`), because a PDF is read from the end and by
   offset. A `Document` owns an arena for parsed objects; objects are parsed on
   demand and cached. Everything returned by the library is borrowed from the
   document and valid until `deinit`. No file system, OS or libc calls.
7. **Untrusted input.** Every loop and recursion has a limit (`Options`: object
   count, stream size after decoding, nesting depth, form XObject depth, content
   stream operations). Malformed input yields an error or a documented repair,
   never undefined behaviour.

## Alternatives considered

- Extract and harden zpdf: fastest, but starts as someone else's design and
  inherits its decisions; rejected by the maintainer.
- Keep zpdf and fill gaps: two PDF code bases to keep in step.
- Draw pages inside the library: ties the library to one graphics API and to
  font rasterising; the viewer already has both.
- Memory-map the file: not available through `std.Io` portably, and a read-all
  buffer is simple and bounded.

## Consequences

- The library is testable without any renderer: tests compare parsed structure,
  decoded streams, extracted text and display lists against hand-built PDFs and
  against real files.
- dkde's `pdfrender` must be changed to consume the display list (not part of
  this repository).
- Unsupported features are reported, not silently ignored (see
  `docs/architecture.md`, "Not supported").
