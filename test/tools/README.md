# Verification scripts

Not part of `zig build test`; they compare pdf-zig with poppler (`pdftotext`, `pdfinfo`,
`pdftoppm`) and fuzz it with damaged files. Build the programs first with
`zig build -Doptimize=ReleaseSafe`; the scripts use `zig-out/bin`, or the directory
in `PDFZIG_BIN`. Each exits non-zero if something failed or nothing was run.

| Script | What it does |
|---|---|
| `pagecheck.py LIST` | page count of each PDF in LIST (one path per line) against `pdfinfo` |
| `textcheck.py LIST N` | words of `pdftext -raw` against `pdftotext -raw`; prints the N worst files |
| `renderall.sh LIST` | `pdfinfo -r` on every file: renders every page and decodes images; reports crashes |
| `fuzz.py LIST FILES MUTATIONS SEED` | corrupts real files (flip, truncate, zero, delete) and runs `pdfinfo -r`, `pdfpages`, `pdffill --flatten` and `pdfstamp`; reports crashes, hangs and damaged output |
| `survey.py DIR_OR_LIST --sample N` | runs `pdfsurvey` over many files and counts which features they use; prints counts only, and writes the paths of failures outside the repository |

A good LIST is a large, varied set of PDFs, such as those under `/usr/share`.
