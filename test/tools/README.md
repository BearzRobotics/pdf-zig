# Verification scripts

Not part of `zig build test`; they compare pdf-zig with poppler (`pdftotext`, `pdfinfo`,
`pdftoppm`) and fuzz it with damaged files. They were written with absolute paths for one
machine and one session: **edit the paths at the top before use** (the pdf-zig binaries are
`zig-out/bin/pdfinfo`, `pdftext`, ... after `zig build -Doptimize=ReleaseSafe`).

| Script | What it does |
|---|---|
| `pagecheck.py LIST` | page count of each PDF in LIST (one path per line) against `pdfinfo` |
| `textcheck.py LIST N` | words of `pdftext -raw` against `pdftotext -raw`; prints the N worst files |
| `renderall.sh LIST` | `pdfinfo -r` on every file: renders every page and decodes images; reports crashes |
| `fuzz.py LIST FILES MUTATIONS SEED` | corrupts real files (flip, truncate, zero, delete) and runs `pdfinfo -r`; reports crashes and hangs |

A good LIST is every PDF under `/usr/share` and the user's documents (80 files were used).
