# Handoff: what the DKDE viewer needs from pdf-zig

For the Claude (or person) updating the viewer in the `dkde` repository. The maintainer
starts that work when they are ready, after other projects of theirs are done. It says
what changed in the library and **which features the viewer needs to add**.

Work on pdf-zig does not change viewer code: it only records here what the viewer needs.

**This file is kept up to date by whoever changes pdf-zig:** anything that needs work in
the viewer is added here in the same commit. Last updated 2026-11-27, for pdf-zig 0.5.0.

Read `dkde`'s own `ai/AGENTS.md` and docs first. Its rules govern that repository. Do not
push or release unless asked. The maintainer is "they" if a pronoun is needed. For this
library read `README.md`, `docs/architecture.md` and `docs/CHANGELOG.md`; where those and
this file differ, they are right about what pdf-zig does.

(`docs/HANDOFF.md` is an older, out of date handoff. Do not work from it.)

## 1. Update to the newest release

Take **whatever pdf-zig release is newest when you start**, not a version named here:

    gh release list --repo BearzRobotics/pdf-zig
    zig fetch --save=pdf <URL of that release's .tar.gz asset>

Then read every section of `docs/CHANGELOG.md` newer than the version `dkde` pins now.

**What was checked on 2026-11-27.** `dkde` master (`161b555`) pinned pdf-zig **0.2.2**.
A copy of that commit, pointed at pdf-zig 0.4.0's code by a path dependency, built with
`zig build -Dapp=pdf` without any source change, and `zig build test -Dapp=pdf` gave 178
passed, 2 skipped. **The viewer itself was not run.** Compiling says nothing about the
changes in behaviour below. `dkde` may have moved on: check again.

## 2. Behaviour that changed since 0.2.2

Go through these against the viewer's code. The change log has the full list.

### One place found that is now wrong

`src/pdf/session.zig`, `addBookmark` (line 248 at `161b555`) turns "points from the top
of the page" into user space as `p.crop_box.y1 - t`. Since 0.4.0 a page can have a
`/UserUnit`: user space units are `p.user_unit` points long, so it has to be
`p.crop_box.y1 - t / p.user_unit`. (The comment there also assumes unrotated pages. To
be right for every page, apply the inverse of `pdf.interp.baseMatrix(p)` to the point.)

### Check the rest

- **`/UserUnit` (0.4.0).** `Page.displaySize`, `DisplayList.base` and
  `interp.baseMatrix` include it. Never apply it again. `Page.crop_box` and `media_box`,
  annotation and widget rectangles and link rectangles stay in user space. Sizes passed to
  `annot.addInk` and `addFreeText` are points on the page. A search found no other
  `UserUnit` handling in `src/pdf` or `src/pdfrender`.
- **Forms (0.3.0).** A password field's value is no longer saved, so do not read it back
  after filling. Choice fields store the export value. A list box or a combo box that is
  not editable gives `error.NotAnOption` for other text: offer only its options.
  `form.Field.comb` is new (0.3.1). Widgets written directly inside another object give
  `error.DirectObject`.
- **Annotations (0.3.0).** Non-finite or huge numbers give `error.BadGeometry`.
  `annot.remove` also removes the popup. Squiggly underlines are drawn as a zigzag.
- **Limits (0.3.0).** A page over a work limit gives `error.LimitExceeded`. Show that the
  page could not be drawn; do not treat the file as unreadable.
- **Text (0.3.0).** Reading order and spacing differ in places. Check anything that
  compares extracted text or counts characters, such as the "is this a scan" threshold in
  `src/pdf/ocr.zig` (`scanned_below`).
- **New error cases (0.5.0).** `form.Error` has `NotMultiSelect`; `compose.Error` has
  `BadValue` and `PathOpen`. Extraction now includes the values of fields that had no
  saved appearance.
- **Passwords (0.3.1).** UTF-8 passwords with non-ASCII characters now work. Pass what the
  user typed.

## 3. Features to add now (in pdf-zig 0.4.0 and 0.5.0)

The viewer needs to add these. None needs new drawing code.

| Feature | pdf-zig | In the viewer |
|---|---|---|
| Say when a page is incomplete | `DisplayList.incomplete` | The viewer did not read it at `161b555`. Show a small notice |
| (0.5.0) Fields and marks without a stored appearance | Drawn by default (`interp.Options.generate_appearances`) | Nothing to add. Text extraction and search now include those fields' values; check anything that counts characters |
| (0.5.0) **Add:** multi-select lists | `form.setChoices`; `Field.multi_select` and `Field.selected` | Let a list with `multi_select` take several choices, and show all of `selected` (`value` is only the first). `form.Error` has the new `NotMultiSelect` |
| (0.5.0) **Add:** reset a form | `form.reset(&upd, field)` for one field | A "reset form" command: loop over the fields in one update; skip push buttons, signatures (`WrongKind`) and read-only fields (`ReadOnly`) |
| (0.5.0) **Add:** flatten a form | `flatten.widgets(&upd, page)` for each page, in one update | A "flatten" command: warn that fields can no longer be edited, and that **it hides nothing**, since the earlier version stays in the file. Show how many widgets were kept (hidden ones and signatures). `error.UnreadableContent` and `error.TooLarge` mean the page cannot be flattened. Handle the new error set |
| (0.5.0) Create documents | `draw.Canvas`, `compose.Builder.addPage` and `setInfo` | Only if the viewer or another program is to make PDFs, such as saving images as a PDF. Nothing needed for display. `compose.Error` has the new `BadValue` and `PathOpen` |
| (0.5.0) **Add:** stamps | `draw.Canvas` sized with `page.displaySize()`, `draw.Stamp.place(page, &canvas, .over or .under)`, then `finish` before `upd.write` | Watermarks and page numbers. For OCR results, one invisible `textWith` per word with `fit_width` (only WinAnsi text until fonts can be embedded, so OCRmyPDF stays for other languages). `.under` is hidden on scans. Handle `draw.StampError` |
| (0.5.0) Say why a page may look wrong | `DisplayList.omissions`: a flag for each thing left out or approximated | Name the ones that change what is seen (`soft_mask`, `group`, `shading`, `no_appearance`, `jbig2`, `text_clip`) in the notice. `no_unicode` only affects search and copy |
| Clickable links | `link.list(arena, &doc, list, page)`: rectangle in user space, and a page, a URI, a named action or `unsupported` | Hit-test with the inverse of `baseMatrix`, as annotations are. **A URI is untrusted:** open only schemes you choose (`http`, `https`, `mailto`), show the address, and ask first. Never run `file:` or anything else |
| Extract, delete, reorder, merge, split, rotate pages | `compose.Builder` | See below |

### Page operations

`compose.Builder` writes a **new** document; it never changes the open one. Read
`docs/architecture.md`, "New documents", and `examples/pdfpages.zig`.

- Import all pages wanted from one document in **one** `importPages` call, or links
  between them are lost and fonts are copied twice.
- Write beside the target and rename over it (`createFileAtomic`), as the example does.
- The source file's undo history does not carry into the new file.
- Tell the user what is **not carried**: title and other document information, page
  labels, attachments, accessibility tags, scripts, signatures, links to other files, and
  web-link bookmarks.
- **Never present deleting pages as redaction.** Shared images and fonts, and the values of
  fields that also sit on kept pages, can remain.
- An encrypted source gives `error.Encrypted`. Only set `allow_decrypted_output` after the
  user agrees that the new file will have **no password**.
- Form fields from merged files may be renamed (`name_2`).

### JBIG2

A survey found JBIG2 images in 13% of a sample of books. pdf-zig does not decode them
yet (`docs/ROADMAP.md`, stage 4). `src/pdfrender/render.zig` read `/JBIG2Globals` at
`161b555`, so the viewer may handle them already: check with a scanned file, and keep
whatever it does until pdf-zig can decode them.

## 4. Display list changes: drawing work

New kinds of drawing show only when the viewer draws them. `drawCommands` in
`src/pdfrender/render.zig` appeared to switch over every `display.Command` without a
catch-all at `161b555`, so a new command should stop the build. Keep it that way: no
`else` branch.

| In release | Change | Viewer work |
|---|---|---|
| 0.4.0 and earlier | The check build of section 1 needed no drawing change | none known |
| 0.5.0 | No new drawing command. Generated appearances use the existing ones | none |

**Planned, not built** (`docs/ROADMAP.md`; shapes will change):

| Planned change | Viewer work |
|---|---|
| Reasons why a page is incomplete | Say which, in the notice |
| Text rendering modes 4 to 7 | Clip to the glyph outlines (`Text.mode` is already passed) |
| Function-based and mesh shadings as coloured triangles | Draw them |
| Transparency groups and soft masks | The largest item: render groups and apply their masks |
| ICC profiles passed through | Optional: use a colour library |
| Vertical writing | Place glyphs downwards |

## 5. Features to add as pdf-zig gains them

These are the maintainer's priorities for pdf-zig, in order. pdf-zig will do the file
work; the viewer will need an interface for each. Details follow here as they are built.

1. **Forms:** several list entries, reset, flatten and blank fields are in 0.5.0 (section 3).
2. **Creating documents:** drawing on new and existing pages is in 0.5.0 (section 3).
   Embedding other fonts than the built-in ones comes next, for other scripts.
3. **Signatures:** show who signed and whether the file changed afterwards, then the
   result of verification. **Which certificates to trust is the application's decision.**
   Never show "valid" for anything less than a full check.
4. **Scans:** JBIG2 decoding is planned inside pdf-zig. JPEG and JPX stay with the
   viewer's codecs.

Later: Chinese, Japanese and Korean character data will be an **optional module** that
the viewer has to add to its build to get that text.

## 6. Check your work

- `zig build test -Dapp=pdf`, then run the viewer on real files: rotated pages, a form,
  an annotated file that you save and reopen, an encrypted file and a scan.
- Test bookmark and annotation positions on a page with `/UserUnit 2`.
- `zig-out/bin/pdfsvg` (in pdf-zig) shows what its display list holds, to tell a library
  fault from a drawing fault. Report library faults in pdf-zig, with a small file.
