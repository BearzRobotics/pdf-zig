# Changelog

## Unreleased

- UTF-8 passwords with non-ASCII characters now open files encrypted at R2 to R4
  (they are converted to PDFDocEncoding). R5 and R6 passwords also get SASLprep's
  character mapping; its NFKC normalization is still not applied.
- Squiggly underlines are drawn as a zigzag, not a straight line.
- Filled comb text fields lay one character in each cell. `form.Field` has `comb`.

## 0.3.0 (2026-11-27)

A review of the whole library for bugs, and the fixes: crashes and hangs on small
malformed files, unbounded memory use, edits that could damage a saved file, and many
places where content was silently lost or wrong. The test suite grew from 114 to 306
tests. Treat every PDF as hostile: if you used 0.2.x on untrusted files, upgrade.

### License

0.3.0 is licensed under the GNU Library General Public License, version 2 or later
(`LGPL-2.0-or-later`). Releases up to 0.2.2 were published under the MIT License.

### Changes that need attention when upgrading

API:

- `write.Update.set` returns `error.InvalidObject` for object 0 or a number that is
  neither in the file nor from `add`; `add` returns `error.TooManyObjects` when numbers
  run out. Both are in `write.Error`.
- `form.Error` has `NotAnOption`; `outline.EditError` has `BadDestination`.
- `Renderer.fonts` is gone: fonts are cached in the `Document`.
- `crypt.Method` has `unsupported`; `encoding.Base` has `expert`.
- Switches over these error sets and enums need the new cases.

Behaviour:

- A password field's value is no longer written to `/V`; only the masked appearance is.
- Choice fields store the export value. A list box or non-editable combo box rejects
  text that is not one of its options.
- Annotation functions return `error.BadGeometry` for non-finite or huge numbers;
  colour components are clamped. `setContents` accepts only annotations and redraws
  text boxes. `annot.remove` also removes the popup.
- An annotated page gets its own `/Annots` array.
- Setting widgets that are written directly inside another object is `error.DirectObject`
  instead of a silent no-op.
- An unknown crypt filter or method is `error.UnsupportedEncryption` (it used to open
  with ciphertext as content).
- Pages that exceed the new limits return `error.LimitExceeded`; so does `q` nested more
  than 4096 deep (it used to be ignored past 256, corrupting the state).
- `filters.Result.rest` has full codec names (`DCTDecode`, not `DCT`).
- Text extraction orders rotated text along its baseline and forms lines differently,
  and spacing differs in places.
- Example programs exit with status 1 when a page fails and reject bad arguments.

Added:

- Limits: `interp.Options.max_content_bytes`, `max_glyphs`, `max_path_segments`
  (`max_commands` now counts pattern cells); `document.Options.max_retained_bytes`.
- `DisplayList.incomplete`, `PageList.truncated`, blend modes on text and shadings.
- `image.Pixels.pending_mask` and `image.withMaskSamples` for masks that need a codec;
  fax-coded masks are applied. **A viewer should check `pending_mask`.**
- `form.Field.exports` and `editable`; `write.Update.refTo`; 32-bit targets.

### Fixed, in short

- **Saved files:** object generations are kept; a bad `/Annots`, `/Size` or outline link
  can no longer overwrite or damage other objects; a repair during editing stops the
  write; bookmarks are no longer dropped; real numbers keep their value.
- **Crashes and hangs:** integer overflows and out-of-range conversions on file values,
  stack overflow on reference chains, exponential page, field, name and function trees,
  and quadratic repair, scanning, CMap and fax decoding.
- **Memory:** budgets for work done, not only per buffer; parsed objects cached instead
  of re-parsed per use; out of memory is reported instead of cached as missing objects.
- **Reading:** truncated Flate data, hybrid files, repair choosing stale data, crypt
  filters, inline images, CMap ranges and widths, Lab colour and images, `/None`
  separations, fax data with end-of-line codes, Type 3 fonts, optional content, text
  strings, and more.

## 0.2.2 and earlier

See the releases on GitHub.
