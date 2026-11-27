# 0003: Writing new documents and page operations

Status: accepted by the maintainer in conversation, with both recommendations under
"Questions for the maintainer": encrypted sources are refused unless allowed, and forms and
bookmarks wait for A2. Stages A1 and A2 are implemented; see docs/architecture.md.

Settled while implementing A2: a clashing name gets a number (`name_2`); the form
dictionary's `/DA` and `/Q` are written on the top level fields and its fonts merged; a
bookmark heading whose own target is gone stays without one if a bookmark under it stays;
bookmarks with other actions are dropped; signature values are dropped. A field with
widgets on several pages keeps its value when only some of them are imported, because the
value belongs to the field.

## Problem

pdf-zig can only append changes to a file it has read (`write.Update`, ISO 32000-1:2008,
7.5.6). It cannot create a document, or add, delete, reorder, merge or split pages. The
maintainer wants this first (stage A), and then drawing new page content (stage B).

## Proposal

A new module, `compose.zig`, builds a new document and writes it as a complete file. It is
separate from `write.Update`, which stays as it is.

```zig
var out = pdf.compose.Builder.init(gpa, .{});
defer out.deinit();

try out.importPages(&first, &.{ 2, 0, 1 }, .{});   // any pages, in any order
try out.addBlankPage(612, 792);                    // size in points
try out.importPages(&second, &.{ 0 }, .{});
try out.write(&writer.interface);
```

One mechanism covers every operation:

| Operation | How |
|---|---|
| Create | `addBlankPage` |
| Delete | import the pages to keep |
| Reorder | import in the new order |
| Merge | import from several documents |
| Split | one builder for each output |
| Rotate | `setRotation(index, degrees)` |

To annotate a new document, write it, open the result and use the existing functions.

### How copying works

- From each page, every object it refers to is copied and given a new number. The walk
  uses a work list, not recursion.
- Inherited attributes (`Resources`, `MediaBox`, `CropBox`, `Rotate`; 7.7.3.4) are
  written onto each page, and the builder makes a new page tree.
- The walk never enters the old catalog or page tree. A reference to a page that is being
  imported in the same call is renumbered. A reference to any other page becomes null, so a
  link cannot bring a deleted page along.
- Links by name (12.3.2.3), common in LaTeX files, are
  rewritten as direct destinations, because the name table is not copied.
- Objects shared between pages are copied once **per call**. Two calls for the same
  document copy shared fonts twice, so a caller should pass all its pages in one call.
- Streams are copied in their stored, compressed form. Nothing is re-encoded.

### Ownership and limits

`importPages` writes what it copies into the builder's own buffers, as serialized objects
with their offsets. The source document can be closed when the call returns, and each
object is held once. The finished file is therefore in memory until `write`. An option
caps its size, and another the number of objects. A call that fails leaves the builder as
it was.

### What a new file contains

| From the sources | Stage A1 | Stage A2 |
|---|---|---|
| Page content, resources, annotations, `UserUnit` | yes | yes |
| Internal links between imported pages, web links | yes | yes |
| Layers: the groups and which are off by default (8.11.4) | yes | yes |
| Bookmarks that lead to imported pages | no | yes |
| Fillable form fields (12.7) | no: widgets look the same but cannot be filled | yes |
| Document information, XMP metadata, page labels, attachments, tagged structure, output intents | no | not planned |
| JavaScript and opening actions | no | no |

Layers are in A1 because without that table, content the source hides would show.

Forms are in A2 because they need their own rules: a field's other widgets may sit on
pages that were not imported (and must not be copied, with their values), and merged
files often use the same field names (12.7.3.2), which must be renamed.

The output is PDF 1.7 (2.0 if a source is) with a classic cross-reference table and no
object streams, so it can be larger than a source that uses them. Signatures cannot stay
valid in a new file.

### Deleted content

Only objects the kept pages refer to are written, so a deleted page's content is really
gone, unlike with an incremental update. **One exception:** many files give all pages one
shared resource dictionary. Its images and fonts are then copied even if only a deleted
page used them. Removing unused resources means interpreting every content stream; it is
not part of this stage. The documentation must say that this is not redaction.

### Source files

- **Repaired files** can be imported. Since the whole file is written anew, the reason
  `write.Update` refuses them does not apply.
- **Encrypted files** would come out unencrypted, because pdf-zig cannot encrypt. The
  proposal is to refuse with `error.Encrypted` unless the caller passes
  `.allow_decrypted_output = true`, so protection is never removed by accident. This needs
  a new function in `document.zig` that decrypts a stream without removing its filters.

## Alternatives considered

- **Page operations as incremental updates.** Rewriting the page tree is less work for
  delete and reorder. But deleted pages would stay in the file and could be recovered, and
  merging would still need all of the copying above.
- **Rewrite a whole document, then edit it in place.** This keeps bookmarks, forms and
  metadata without extra work for single-file edits, but deleting a page then means
  finding and cutting every reference to it, and merging is a second mechanism.

The cost of the proposal is that anything document-level is lost unless it is copied on
purpose, as the table shows.

## Testing

Each operation is checked by reopening the output: page count and order, the same display
list and text for each page as in the source, links, layer visibility, and that a deleted
page's strings are not in the file. A sample of local files is split, merged and compared
with Poppler (page count, text, rendered pages), and the builder is added to the fuzzer.

## Stage B, in outline

A design of its own will follow A. The intended first version: a page made by the builder
gets functions for paths, colours, text in the standard 14 fonts (WinAnsi characters
only), JPEG images stored as they are, and raw images. Embedding other fonts, which most
non-Latin text needs, is a later step.

## Questions for the maintainer (both answered yes)

1. Is refusing encrypted sources unless explicitly allowed right?
2. Can forms and bookmarks wait for A2?
