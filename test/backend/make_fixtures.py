#!/usr/bin/env python3
# usage: make_fixtures.py
# Writes the signed files every verification backend is tested with, next to
# this script, using `openssl`. The keys are made for one run and thrown away,
# so each run gives other files. The files expire with nothing: the tests never
# check a certificate's dates or chain.
import hashlib, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RANGE = b"[0 AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC]"
ROOM = 16384  # hexadecimal digits kept for the value

def openssl(*arguments):
    r = subprocess.run(("openssl",) + arguments, capture_output=True, timeout=120)
    if r.returncode != 0:
        sys.exit(f"openssl {arguments[0]}: " + r.stderr.decode("utf8", "replace")[:400])
    return r.stdout

def unsigned(sub_filter):
    bodies = [
        b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        b"<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>",
        b"<< /Type /Annot /Subtype /Widget /FT /Sig /T (signed) /Rect [0 0 0 0] /V 5 0 R >>",
        b"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /" + sub_filter.encode() +
        b" /ByteRange " + RANGE + b" /Contents <" + b"0" * ROOM + b"> >>",
    ]
    out = bytearray(b"%PDF-1.7\n")
    offsets = []
    for number, body in enumerate(bodies, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    table = len(out)
    out += b"xref\n0 6\n0000000000 65535 f \n" + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % table
    return out

def parts(der):
    """The tag, contents and rest of the DER element at the start of `der`."""
    length, at = der[1], 2
    if length & 0x80:
        at += length & 0x7f
        length = int.from_bytes(der[2:at], "big")
    return der[:1], der[at:at + length], der[at + length:]

def indefinite(element, depth):
    """`element` with the lengths of its first `depth` levels left open, as BER
    allows and streaming signers write them. Nothing signed lies that high."""
    tag, contents, _ = parts(element)
    if depth == 0 or not tag[0] & 0x20:
        return element[:len(element) - len(parts(element)[2])]
    inner = b""
    while contents:
        rest = parts(contents)[2]
        inner += indefinite(contents[:len(contents) - len(rest)], depth - 1)
        contents = rest
    return tag + b"\x80" + inner + b"\x00\x00"

def make(work, name, keys, options=(), sub_filter="adbe.pkcs7.detached", digest="sha256", content=None, encode=None):
    """Signs the file's signed bytes, or `content(signed bytes)`, with `keys`."""
    data = unsigned(sub_filter)
    at = data.index(RANGE)
    start = data.index(b"/Contents <") + len(b"/Contents ")
    stop = start + ROOM + 2
    data[at:at + len(RANGE)] = (b"[0 %d %d %d]" % (start, stop, len(data) - stop)).ljust(len(RANGE))
    signed = bytes(data[:start] + data[stop:])
    path = os.path.join(work, "in.bin")
    with open(path, "wb") as f:
        f.write(content(signed) if content else signed)
    signers = []
    for key in keys:
        signers += ["-signer", os.path.join(work, key + ".crt"), "-inkey", os.path.join(work, key + ".key")]
    value = openssl("cms", "-sign", "-binary", "-md", digest, "-in", path, "-outform", "DER", *signers, *options)
    if encode:
        value = encode(value)
    digits = value.hex().encode()
    if len(digits) > ROOM:
        sys.exit(f"{name}: the value does not fit")
    data[start + 1:stop - 1] = digits.ljust(ROOM, b"0")
    with open(os.path.join(HERE, name + ".pdf"), "wb") as f:
        f.write(data)

def main():
    with tempfile.TemporaryDirectory() as work:
        for key, algorithm in (("rsa", ["rsa:2048"]), ("rsa_other", ["rsa:2048"]), ("rsa_short", ["rsa:1024"]),
                               ("ec", ["ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"])):
            openssl("req", "-x509", "-nodes", "-days", "2", "-newkey", *algorithm, "-subj", f"/CN=pdf-zig test {key}",
                    "-keyout", os.path.join(work, key + ".key"), "-out", os.path.join(work, key + ".crt"))
        make(work, "rsa", ["rsa"])
        make(work, "ecdsa", ["ec"], digest="sha384")
        make(work, "rsa_pss", ["rsa"], ["-keyopt", "rsa_padding_mode:pss"])
        make(work, "sha1", ["rsa"], digest="sha1")
        make(work, "short_key", ["rsa_short"])
        # BER with indefinite lengths, as most real files have it.
        # ContentInfo, its [0], SignedData.
        make(work, "ber", ["rsa"], encode=lambda value: indefinite(value, 3))
        make(work, "no_attributes", ["rsa"], ["-noattr"])
        make(work, "two_signers", ["rsa", "rsa_other"])
        make(work, "no_certificate", ["rsa"], ["-nocerts"])
        # The value carries the content it signs: here other bytes than the
        # file's, which must not be what gets checked.
        make(work, "attached", ["rsa"], ["-nodetach"], content=lambda signed: b"something else")
        # The same with the file's own bytes: still not a detached signature.
        make(work, "attached_same", ["rsa"], ["-nodetach"])
        make(work, "pkcs7_sha1", ["rsa"], ["-nodetach"], "adbe.pkcs7.sha1",
             content=lambda signed: hashlib.sha1(signed).digest())
        # A sound signature over the digest of other bytes.
        make(work, "pkcs7_sha1_other", ["rsa"], ["-nodetach"], "adbe.pkcs7.sha1",
             content=lambda signed: hashlib.sha1(signed + b"x").digest())
        # The old format claimed with a detached value.
        make(work, "pkcs7_sha1_detached", ["rsa"], (), "adbe.pkcs7.sha1")
    print("written to", HERE)

if __name__ == "__main__":
    main()
