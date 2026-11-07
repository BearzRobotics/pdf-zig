# Handoff: the DKDE document stack (md-zig, gtroff-zig, dkman, pdf-zig, the dkde renderer)

Written 2026-11-07 so a new Claude (or the maintainer) can continue. Read `ai/AGENTS.md` first:
the maintainer's engineering rules apply (std.Io, bounded resources, tests derived from
standards, explain significant architecture before building it, ask when a design choice is
unclear, never claim a test passed unless it ran). The maintainer uses they/them if a pronoun
is needed. **Do not push or release anything unless asked** (pushing was asked for md-zig,
gtroff-zig and dkman only).

## The projects (all under `/home/dakota/de/`, Zig 0.17.1)

| Repo | State |
|---|---|
| `md-zig` | Markdown (CommonMark 0.31.2 + GFM + footnotes + definition lists + front matter) to HTML and terminal text. Released **v0.3.0**, public. Decisions in `docs/decisions/`. |
| `gtroff-zig` | man(7) and mdoc(7) readers that build md-zig trees. Released **v0.3.0**, public. Depends on md-zig by URL+hash. |
| `dkman` | man tool: lookup, search (fzf), pager, renders man/mdoc/Markdown via the two libraries. Public, uses md-zig 0.3.0 and gtroff-zig 0.3.0 by URL+hash. Not tagged. |
| `pdf-zig` | PDF reader library (this repo, private). Milestone 1 done plus encryption and image decoding; **7+ commits not pushed, CCITT uncommitted until this handoff commit**. |
| `dkde` (user's tree) | The desktop. The user's working tree has **their own uncommitted work** (restructured `build.zig`, `-Dapp` option, `cli.handle` in pdfcheck, deleted SPEC.md ...): never edit or commit there. |
| `dkde-pdfzig` | A **git worktree** of dkde at `/home/dakota/de/dkde-pdfzig`, branch `pdf-zig-renderer`, made from dkde's committed HEAD (older than the user's tree). The renderer migration lives here. Remove with `git worktree remove ../dkde-pdfzig` from `/home/dakota/de/dkde`. |

## pdf-zig

Read `README.md`, `docs/architecture.md`, `docs/decisions/0001-architecture.md` (accepted: own
parser replacing the vendored zpdf; milestone 1 = structure + display list; encryption and
images added after). Source map is in `architecture.md`. Key rules learned the hard way:

- **Scratch arena lifetime.** `Renderer` decodes content into a scratch arena that is reset after
  every page. Anything a `DisplayList` keeps must be copied into its own arena or come from the
  document arena. (A use-after-free of inline-image data was found and fixed this way; see
  `image_tests.zig`, "inline images stay valid".)
- Text-only extraction: `Renderer.Options.graphics = false` (3.4 s and 35 MB for a 332-page book).
- Public API: `Document.open/openReader` (+`Options.password`), `pages.PageList`, `Renderer`,
  `text.extract`, `image.decode` / `fromSamples` / `withMasks`, `ccitt.decode`, `crypt` (internal).
- Example programs (`zig build`): `pdfinfo [-r]`, `pdftext [-raw] [-p PW]`, `pdfdump`, `pdfsvg`
  (page as SVG; convert with `inkscape --export-type=png` to look at it), `pdfimg`.
- Generated data: `src/std14.zig` (`scripts/gen-std14.py`, needs `gs`), `src/agl.zig`
  (`scripts/gen-agl.py` from Adobe's glyphlist.txt), `src/ccitt_tables.zig` (from zigimg, MIT).
  `src/cff_strings.zig` is copied from zpdf (CC0).
- Encrypted fixtures: `test/fixtures/*.pdf` (see its README); made with pikepdf in a venv
  (`python3 -m venv V; V/bin/pip install pikepdf`). Ghostscript only writes RC4 (R2, R3).
- Verification against poppler: `test/tools/` (edit paths first). Last results on 80 PDFs: page
  counts equal on all 79 poppler can read; words within ~1% of `pdftotext -raw`; every page of
  every file renders with no error; 1,125 mutated files, no crash or hang; encrypted variants
  (RC4 40/128, AES-128, AES-256 R5/R6) decrypt to text identical to the plain file.

### Known gaps in pdf-zig
- CCITT (`src/ccitt.zig`) is **validated** (2026-11-07): G3 1D, G3 2D and G4 pages made by Ghostscript
  decode bit-exact (test "CCITT G3 1D, G3 2D and G4 ..."; fixtures in `test/fixtures/fax_*`).
  Not covered: `/EncodedByteAlign`, damaged data, and real scanner output (no CCITT PDFs on this machine).
- JBIG2 is not decoded. JPEG/JPX are left to the caller (`image.decode` returns `.codec`).
- Mesh and function-based shadings, soft masks, vertical writing, predefined CJK CMaps: skipped.
- Text clipping modes, `d1` colour suppression, Symbol/ZapfDingbats built-in encodings.
- `Font.gidOfCid` decodes `/CIDToGIDMap` on every call into the document arena: cache it
  (the dkde renderer caches its own copy).

## The dkde renderer migration (worktree `dkde-pdfzig`)

Done (**committed on branch `pdf-zig-renderer`, never merged or pushed**):
- `src/pdfrender/render.zig` rewritten: walks pdf-zig's display list and draws with cairo
  (paths, clips, dashes, alpha and blend modes, gradients, tiling patterns, images, text with
  embedded TrueType/CFF/**Type 1** outlines, substitute system fonts otherwise). New API:
  `render.Document.open(gpa, path)` / `.openFromMemory` / `.close()` / `.pageCount()` /
  `.encrypted` / `.bytes`; `render.pageSize(doc, i)`; `render.renderPage(a, doc, i, cr, scale, &diag)`.
- `build.zig`/`build.zig.zon`: pdf-zig is a **path dependency `../pdf-zig`**; the zpdf module
  import is gone from pdfrender and pdfcheck. `src/pdfcheck/main.zig` adapted.
- `cff.zig`, `type1.zig` import `pdf` (agl, cff_strings, encoding) instead of zpdf.
- Old `src/pdfrender/image.zig` deleted (pdf-zig's `image.zig` replaces it).

Results: `dkde-pdfcheck` over 80 PDFs, 4 pages each: 205 pages drawn, 1 failure (a file that
is not a PDF), 8.3 s. Side by side with poppler the pages match closely; the old renderer
substituted fonts and broke composite-font spacing. CCITT images are drawn as pale boxes
(`image-ccitt` note, 7 files) until `pdf.image.decode` handles them (it should, once the
decoder is validated).

**Tests: `zig build test` in the worktree gives 353 pass, 5 skipped, 3 fail**, all in the
pdfrender test binary:
- `render.test.inline images are drawn, with their abbreviated keys` and
  `type1.test.a real Type 1 font draws glyphs`: dkde's own decision record
  (`docs/decisions/0001-architecture-realignment.md`) says these two **already failed before this
  work**; not investigated by anyone.
- `render.test.gradients and tiling patterns are drawn`: **a new test I wrote, failing**; it checks
  pixel colours at guessed positions, so the test or the renderer is wrong. Not investigated.

Still to do there: fix or drop that test; delete `third_party/zpdf` (now unused; also its README
mentions); update dkde's `README.md`/`docs` (they describe zpdf); the `view`/`pdf` GTK programs
still use poppler (`src/pdf/poppler.zig`), a separate decision; **merge strategy**: the user's
working tree changed `build.zig` and `pdfcheck/main.zig`, so expect conflicts in exactly those.

Build/run (worktree, ReleaseSafe, about 6 minutes cold because it builds every GTK app):
`cd /home/dakota/de/dkde-pdfzig && zig build -Doptimize=ReleaseSafe`, then
`DISPLAY= zig-out/bin/dkde-pdfcheck --pages 3 --scale 1 --out DIR PATH...` (PNGs per page).

## Environment and gotchas

- Machine: WSL2; page faults are slow (this drove the scratch-arena and `graphics=false` work).
  Installed: `gs`, `pdftotext`, `pdfinfo`, `pdftoppm`, `groff`, `inkscape`, `convert`, `strace`, `perf`.
  Not installed: `qpdf`, `mutool`, PIL (system), `pdftk`.
- Zig 0.17.1: no `**` array repetition (use `@splat` or write it out), `resume` is a keyword,
  `std.c` has no `fseek` (read in chunks), a local `var` that is never mutated is an error,
  multiline strings cannot contain tabs, `zig-pkg/` is the local package cache (**gitignore it**; it
  was committed by accident once and removed).
- Dependency hashes: a stale `zig-pkg/` can cause "hash mismatch ... N-V-__". Fix: delete
  `zig-pkg` and `.zig-cache`, empty `.dependencies`, then `zig fetch --save=NAME URL` for each.
- Never `git add -A` blindly in these repos without checking `git status` first.
- `pkill -f PATTERN` kills the shell running it if the pattern appears in its own command line;
  use a `[x]` bracket trick.

## Suggested next steps (ask the maintainer to confirm the order)
1. ~~Validate CCITT~~ (done, see Known gaps).
2. Fix or drop the new failing dkde test; investigate the two old ones if wanted.
3. Review the dkde branch with the maintainer, then decide: merge into their tree, delete zpdf.
4. Push pdf-zig; tag a release (v0.1.0) only if asked; follow the md-zig/gtroff-zig release recipe
   (`git archive` tarball attached to a GitHub release, URL+hash dependency).
5. Smaller: cache `/CIDToGIDMap`, JBIG2, a C interface for pdf-zig (AGENTS.md section 13, optional).
