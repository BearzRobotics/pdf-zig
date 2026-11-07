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

The owner password of all of them is `o`.
