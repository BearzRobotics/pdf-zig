# Changelog

## 0.7.0 (2026-11-28)

- New module `signature`: lists a document's signatures with what each claims (kind,
  certification level, field locks, name, date, reason), whether its byte range covers a
  whole revision but its own value, and which objects changed afterwards. **Nothing is
  verified.** New example `pdfsigs`, which can also save the signed revision.
- No existing public function or type changed.

## 0.6.0 (2026-11-27)

- Drawn text can use an embedded TrueType font: new `truetype.Font` and
  `draw.Font.embedded`, with `canvas.glyphs` for shaped text. Fonts are subset, honour
  their `fsType` embedding permissions, and keep their text searchable. `.otf` fonts with
  CFF outlines and `.ttc` collections are not read yet; there is no shaping.
- Forms and text boxes can be written in an embedded font: `form.setTextWith`,
  `setChoicesWith` and `resetWith`, `annot.addFreeTextWith` and `setContentsWith`, with a
  `form.Typeface`; new `draw.Embedder` stores a font once for all of an update. A form
  that asked for appearances (`NeedAppearances`) has the flag turned off, after its other
  widgets that relied on it are given appearances. Preview-and-print fonts are refused
  (`error.FontNotForForms`).
- **Fixed: of a dictionary key that a file repeats, the last now counts**, as in Poppler
  and MuPDF; the first did. A file with four `/AcroForm` entries had changes to its form
  written where those readers never looked. `write.dictWith` leaves one entry.
- New error cases, which switches need: `write.Error` has `UnfinishedFonts`;
  `form.Error` and `annot.Error` have `MissingGlyph`, `FontNotForForms` and `BadFont`;
  `compose.Error` and `draw.StampError` have `BadFont`. `draw.Font` has the new case
  `embedded`. `form.textForm`, `form.listForm`, `form.wrapLine` and `annot.freeTextForm`,
  the appearance builders, take the text as UTF-8 or units and a `form.Face`.

## 0.5.0 (2026-11-27)

Fields and marks that used to be blank are now drawn, forms can do more, and pdf-zig can
draw: new pages, and onto existing ones. No public function or type of 0.4.0 was removed
or had its signature changed.

### Check this when upgrading

- **Annotations and form fields without a stored appearance are now drawn**, and in a form
  with `NeedAppearances`, text and choice fields with a value are made again. So pages draw
  more, and **text extraction and search include those fields' values.**
  `interp.Options.generate_appearances` turns it off.
- `form.Error` has `NotMultiSelect` and `compose.Error` has `BadValue` and `PathOpen`:
  switches over them need the cases. `form.Field` has `multi_select` and `selected`.
- Filling a list box now writes its appearance; it no longer removes it and sets
  `NeedAppearances`.

### Forms

- New `form.setChoices` (several entries of a multi-select list) and `form.reset`.
- New `flatten.widgets`: makes a page's form widgets part of its content and takes those
  fields out of the form. Hidden widgets and signatures stay. **It is not redaction:** the
  earlier version stays in the file. `pdffill` has `--flatten`.
- Appearances are made for text, combo and list fields, check boxes, radio and push
  buttons, and for highlights and other text markup, squares, circles, lines, polygons,
  ink, free text and notes. New module `appearance`. They do not follow bevelled or inset
  border styles, and may place text taller than its box differently from other readers.
- A filled comb field with a border colour has lines between its cells.

### Creating and changing pages

- New `draw.Canvas` and `compose.Builder.addPage`: paths, colours, transparency, clipping,
  text in the twelve built-in text fonts, and JPEG or raw images, measured from the top
  left of the page. New example `pdfdraw`.
- New `draw.Stamp`: puts a canvas over or under pages of an existing file, upright at any
  rotation, crop box and `/UserUnit`. New example `pdfstamp`.
- New `compose.Builder.setInfo` (title, author and other document information).
- The built-in fonts cover WinAnsi (Western European) and are **not embedded**: a reader
  draws them with its own substitute, which may lack a character. There is no line
  wrapping, text shaping or embedding of other fonts yet.

### Also

- `DisplayList.omissions` says what a page uses that is left out or only approximated.
  `incomplete` means what it did. New example `pdfsurvey` and `test/tools/survey.py`.

### Fixed

- A button whose appearance states include no drawing at all was shown as nothing.
- `write.Update.write` reported `error.WriteFailed` when it ran out of memory; it now
  reports `error.OutOfMemory`.
- The `pdfsvg` example put the letters of a run too far apart.

## 0.4.0 (2026-11-27)

pdf-zig can now make new documents, to take PDFs apart and put them together. No public
function or type of 0.3.1 was removed or had its signature changed.

### Check this when upgrading

- Pages with `/UserUnit` now have their true size: `Page.displaySize` and
  `DisplayList.base` give points. **A viewer that applied `/UserUnit` itself must stop,
  or such pages are scaled twice.** `Page`'s boxes stay in user space units, and `Page`
  has the new `user_unit`. Sizes given to the annotation functions are points on the page.
- A page with a function-based or mesh shading (types 1 and 4 to 7), which is skipped,
  now has `DisplayList.incomplete` set.

### New

- `compose.Builder` makes a new document from blank pages and pages of other documents:
  create, delete, reorder, merge, split and rotate pages. Page content, annotations, links
  between imported pages, layers, fillable form fields and the bookmarks that lead to
  imported pages are carried over. Clashing form field and form font names get a number.
  The output uses compressed object streams. New example `pdfpages`.
  - Not carried: document information and metadata, page labels, document attachments,
    accessibility structure, scripts, signature values, links to other files and
    bookmarks with other actions. Encrypted sources are refused unless you allow an
    unencrypted copy. **Leaving a page out is not redaction.** See
    `docs/architecture.md`, "New documents". Drawing on new pages is not supported yet.
- `link.list`: the links of a page, with the page they go to, their URI or their named
  action. It follows none of them; check a URI's scheme before opening it.
- `Document.storedStreamData` and `Renderer.loadOcgs`, which `compose` uses. Parts of
  `outline`'s destination lookup are public too, for `link` and `compose`.

### Fixed

- Reading bookmarks could take time in proportion to bookmarks times named destinations
  on files built to make it so. After enough lookups the names are now indexed.

## 0.3.1 (2026-11-27)

Upgrade from 0.3.0 for the CMap fix. The only interface change is the new `form.Field.comb`.

- UTF-8 passwords with non-ASCII characters now open files encrypted at R2 to R4
  (they are converted to PDFDocEncoding). R5 and R6 passwords also get SASLprep's
  character mapping; its NFKC normalization is still not applied.
- In a composite font, a code outside the CMap's code space ranges now takes as many
  bytes as ISO 32000-1, 9.7.6.3 says. It could take too few, which shifted the rest of
  the string.
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
