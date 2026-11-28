#!/usr/bin/env python3
# usage: sigcheck.py [LIST]
# Compares `pdfsigs` with poppler's `pdfsig`: how many signatures each file has,
# the bytes each one covers, and whether that is the whole file. Signatures that
# only the permissions dictionary names are left out: poppler does not list them.
#
# It first signs files of its own with a throwaway key (`openssl`; `qpdf` adds
# the object-stream and encrypted forms), so that `pdfsig` also says whether the
# bytes pdf-zig reports as signed are the ones that were signed. LIST adds real
# signed files, one path per line; their paths are not printed.
# Exit status: 0 all agree, 1 otherwise or if nothing was compared.
import os, re, shutil, subprocess, sys, tempfile
from common import binary, file_list

RANGE = b"[0 AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC]"
ROOM = 8192  # hexadecimal digits kept for the value

def run(*command, **options):
    return subprocess.run(command, capture_output=True, timeout=120, **options)

def build(objects):
    out = bytearray(b"%PDF-1.7\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    table = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, table)
    return bytes(out)

def unsigned(permissions):
    signature = (b"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /Name (Test) "
                 b"/ByteRange " + RANGE + b" /Contents <" + b"0" * ROOM + b">")
    if permissions:
        signature += b" /Reference [<< /TransformMethod /DocMDP /TransformParams << /P 2 /V /1.2 >> >>]"
    catalog = b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >>"
    if permissions:
        catalog += b" /Perms << /DocMDP 5 0 R >>"
    return build([
        catalog + b" >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>",
        b"<< /Type /Page /Parent 2 0 R /Annots [4 0 R] >>",
        b"<< /Type /Annot /Subtype /Widget /FT /Sig /T (signed) /Rect [0 0 0 0] /P 3 0 R /V 5 0 R >>",
        signature + b" >>",
    ])

def sign(data, key, certificate, work):
    """Fills in the byte range and the value of the one unsigned signature."""
    data = bytearray(data)
    at = data.index(b"/ByteRange [") + len(b"/ByteRange ")
    end = data.index(b"]", at) + 1
    start = data.index(b"<" + b"0" * ROOM + b">")
    stop = start + ROOM + 2
    numbers = b"[0 %d %d %d]" % (start, stop, len(data) - stop)
    if len(numbers) > end - at:
        sys.exit("no room for the byte range")
    data[at:end] = numbers.ljust(end - at)
    signed = os.path.join(work, "signed.bin")
    with open(signed, "wb") as f:
        f.write(data[:start] + data[stop:])
    r = run("openssl", "cms", "-sign", "-binary", "-md", "sha256", "-signer", certificate,
            "-inkey", key, "-in", signed, "-outform", "DER")
    if r.returncode != 0:
        sys.exit("openssl could not sign: " + r.stderr.decode("utf8", "replace")[:300])
    digits = r.stdout.hex().encode()
    if len(digits) > ROOM:
        sys.exit("the value does not fit")
    data[start + 1:stop - 1] = digits.ljust(ROOM, b"0")
    return bytes(data)

def appended(data):
    """`data` with a further revision that replaces the page."""
    previous = int(re.findall(rb"startxref\s+(\d+)", data)[-1])
    out = bytearray(data)
    offset = len(out)
    out += b"3 0 obj\n<< /Type /Page /Parent 2 0 R /Annots [4 0 R] /MediaBox [0 0 9 9] >>\nendobj\n"
    table = len(out)
    out += b"xref\n3 1\n%010d 00000 n \ntrailer\n<< /Size 6 /Root 1 0 R /Prev %d >>\nstartxref\n%d\n%%%%EOF\n" % (offset, previous, table)
    return bytes(out)

def own_files(work):
    """(name, path, password) of files signed here."""
    key, certificate = os.path.join(work, "key.pem"), os.path.join(work, "cert.pem")
    r = run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-subj", "/CN=pdf-zig test", "-keyout", key, "-out", certificate)
    if r.returncode != 0:
        sys.exit("openssl could not make a key")
    made = []

    def keep(name, data, password=""):
        path = os.path.join(work, name + ".pdf")
        with open(path, "wb") as f:
            f.write(data)
        made.append((name, path, password))
        return path

    for name, permissions in (("plain", False), ("certified", True)):
        data = sign(unsigned(permissions), key, certificate, work)
        keep(name, data)
        keep(name + "-changed", appended(data))
    if shutil.which("qpdf"):
        source = os.path.join(work, "source.pdf")
        with open(source, "wb") as f:
            f.write(unsigned(False))
        for name, password, options in (
                ("object-streams", "", ["--object-streams=generate"]),
                ("encrypted", "pw", ["--encrypt", "pw", "owner", "256", "--"])):
            target = os.path.join(work, "rewritten.pdf")
            r = run("qpdf", "--newline-before-endstream", *options, source, target)
            # Status 3 is success with warnings.
            if r.returncode not in (0, 3):
                sys.exit(f"qpdf could not write the {name} form: " + r.stderr.decode("utf8", "replace")[:300])
            data = open(target, "rb").read()
            # qpdf writes the value in its own way: it must still be the zeros.
            if b"<" + b"0" * ROOM + b">" not in data or b"/ByteRange [" not in data:
                print(f"skipped {name}: qpdf rewrote the placeholders")
                continue
            keep(name, sign(data, key, certificate, work), password)
    return made

def poppler(path, password):
    """For each signature: (covered ranges, whole file, "valid" or not)."""
    options = ["-nocert"] + (["-upw", password] if password else [])
    text = run("pdfsig", *options, path).stdout.decode("utf8", "replace")
    found = []
    for block in re.split(r"^Signature #\d+:\s*$", text, flags=re.M)[1:]:
        ranges = re.search(r"Signed Ranges: \[(\d+) - (\d+)\], \[(\d+) - (\d+)\]", block)
        if not ranges:
            continue  # a field without a signature
        whole = re.search(r"^\s*- Total document signed", block, flags=re.M) is not None
        valid = "Signature is Valid" in block
        # For a value it cannot read, poppler reports no file as wholly signed.
        if "Signature Type: unknown" in block:
            whole = None
        found.append((tuple(int(n) for n in ranges.groups()), whole, valid))
    return found

def pdfsigs(exe, path, password):
    """For each signature: (covered ranges or the defect, whole file)."""
    options = ["-p", password] if password else []
    r = run(exe, *options, path)
    if r.returncode != 0:
        return None
    found = []
    for block in re.split(r"^\d+\. ", r.stdout.decode("utf8", "replace"), flags=re.M)[1:]:
        # poppler lists only signatures in fields, not those that only the
        # permissions name.
        if " in field " not in block.split("\n")[0] and "named by the document's permissions" in block.split("\n")[0]:
            continue
        sound = re.search(r"covers the first (\d+) of \d+ bytes", block)
        if sound:
            ranges = re.search(r"byte range: (\d+) (\d+) (\d+) (\d+)", block)
            a, b, c, d = (int(n) for n in ranges.groups())
            found.append(((a, a + b, c, c + d), "nothing follows the signed bytes" in block))
        else:
            found.append((re.search(r"COVERAGE NOT SOUND: (\w+)", block).group(1), False))
    return found

def main():
    exe = binary("pdfsigs")
    for tool in ("pdfsig", "openssl"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is needed")
    compared, bad, unsound = 0, [], {}
    with tempfile.TemporaryDirectory(prefix="pdfzig-sig-") as work:
        files = own_files(work)
        own = len(files)
        if len(sys.argv) > 1:
            files += [(f"listed file {i}", path, "") for i, path in enumerate(file_list(sys.argv[1]), 1)]
        for index, (name, path, password) in enumerate(files):
            theirs, ours = poppler(path, password), pdfsigs(exe, path, password)
            if ours is None:
                bad.append((name, "pdfsigs failed"))
                continue
            if index < own:
                print(f"{name}: poppler {theirs}")
                print(f"{' ' * len(name)}  pdf-zig {ours}")
                if len(theirs) != 1 or not theirs[0][2]:
                    bad.append((name, "poppler does not call our test signature valid"))
            if len(theirs) != len(ours):
                bad.append((name, f"poppler lists {len(theirs)} signatures, pdf-zig {len(ours)}"))
                continue
            for (their_range, their_whole, _), (our_range, our_whole) in zip(theirs, ours):
                compared += 1
                if isinstance(our_range, str):
                    unsound[our_range] = unsound.get(our_range, 0) + 1
                    if index < own and not (name == "object-streams" and our_range == "not_in_file"):
                        bad.append((name, "unsound: " + our_range))
                elif our_range != their_range:
                    bad.append((name, f"ranges differ: {their_range} {our_range}"))
                elif their_whole is not None and our_whole != their_whole:
                    bad.append((name, f"whole file: poppler {their_whole}, pdf-zig {our_whole}"))
    print("files", len(files), "signatures compared", compared, "unsound", unsound, "disagreements", len(bad))
    for name, what in bad[:20]:
        print(f"  {name}: {what}")
    sys.exit(1 if bad or not compared else 0)

if __name__ == "__main__":
    main()
