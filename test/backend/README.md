# Signature backend tests

What every `pdf.verify.Verifier` must answer. `conformance.zig` holds the expected
answers; a backend's tests call its `run` and `hostile` (see
`src/openssl/openssl_tests.zig`, and the `-Dopenssl` part of `build.zig`).

The `.pdf` files are made by `make_fixtures.py` (needs the `openssl` command). Each run
makes new keys, signs and throws the keys away, so every file changes: run it only to add
or change a case, and commit all of them.

A backend that lacks a format or algorithm says so in its own expectations, with the
reason it answers; it must never answer `intact` or `altered` for what it did not check.
Today the expected answers assume a backend with everything `pdf_openssl` has.
