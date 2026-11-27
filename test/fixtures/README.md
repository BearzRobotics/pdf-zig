# Test fixtures

`plain.pdf` is a one-page PDF whose page shows "Hello encrypted world" in Helvetica
and whose Info dictionary has the title "Secret Title". The `enc_*.pdf` files are the
same file encrypted with qpdf (through pikepdf 10, `static_id=True`):

| File | Handler | Password |
|---|---|---|
| `enc_rc4_40` | RC4 40 bit, R2 | empty |
| `enc_rc4_128` | RC4 128 bit, R3 | empty |
| `enc_aes_128` | AES-128, R4 | empty |
| `enc_aes_256` | AES-256, R6 | empty |
| `enc_aes_256_pw` | AES-256, R6 | `pw` |
| `enc_rc4_128_pw` | RC4 128 bit, R3 | `pw` |

Five more cover paths those do not, made with pikepdf 10.3 (`static_id=True`):
`enc_rc4_40_pw` (R2, password `pw`), `enc_rc4_v4_clearmeta` and
`enc_aes_128_clearmeta` (V4 with `/EncryptMetadata false` and a metadata
stream), `enc_aes_256_r5` (R5, deprecated) and `enc_aes_128_objstm` (object
streams). Poppler reads all of them.

The owner password of all of them is `o`.

## LZW

`lzw_libtiff.bin` is the single strip of a 60,000-byte image that libtiff
(through Pillow, `compression="tiff_lzw"`) wrote. Byte `i` of the input is
`(x >> 16) % 17` in even blocks of 3000 bytes and `i % 251` in odd ones, with
`x = (x * 1103515245 + 12345) & 0x7fffffff` stepped once per byte from 1.

## CCITT fax

`fax_g3_1d.pdf`, `fax_g3_2d.pdf` and `fax_g4.pdf` (1728x300, K = 0, 4, -1) are the strips of
Ghostscript `-sDEVICE=tiffg3 / tiffg32d / tiffg4` output wrapped by `scripts/tiff2pdf-ccitt.py`.
`fax_ref.pbm` is Ghostscript's `pbmraw` render of the same PostScript page; the decoder must
reproduce it exactly (all three, verified 0 of 518,400 pixels differ).

`fax_runs.bin` is Ghostscript's `CCITTFaxEncode` (`/K 0`, 5300 columns) of 144
rows, row *i* being `r` white pixels, `r` black ones and white to the end, for
`r` in 0..63, every multiple of 64 up to 2560 and each of those plus 5. It
checks the run-length code tables against an independent encoder.
