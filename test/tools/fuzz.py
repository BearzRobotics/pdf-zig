#!/usr/bin/env python3
# usage: fuzz.py LIST FILES MUTATIONS [SEED]
# Damages up to FILES of the PDFs in LIST (2 KB to 400 KB) MUTATIONS times each
# and runs `pdfinfo -r` on the results, then `pdfpages`, whose output must open
# without repair. Inputs that crash, hang or give a damaged copy are saved in
# the output directory ($PDFZIG_FUZZ_OUT, or a new temporary one).
# Exit status: 0 no crashes or hangs, 1 otherwise or if nothing was run.
import os, random, subprocess, sys, tempfile
from common import binary, file_list

def damage(data, rnd):
    d = bytearray(data)
    mode = rnd.randrange(4)
    if mode == 0:    # change bytes
        for _ in range(rnd.randint(1, 40)):
            d[rnd.randrange(len(d))] = rnd.randrange(256)
    elif mode == 1:  # truncate
        d = d[:rnd.randrange(len(d) // 4, len(d))]
    elif mode == 2:  # zero a range, keeping every offset
        start = rnd.randrange(len(d))
        length = min(rnd.randint(1, 2000), len(d) - start)
        d[start:start + length] = bytes(length)
    else:            # delete a chunk
        start = rnd.randrange(len(d))
        del d[start:start + rnd.randint(1, 3000)]
    return mode, bytes(d)

def main():
    exe = binary("pdfinfo")
    pages = binary("pdfpages")
    sources = [f for f in file_list(sys.argv[1]) if 2000 < os.path.getsize(f) < 400000][:int(sys.argv[2])]
    rnd = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    out = os.environ.get("PDFZIG_FUZZ_OUT") or tempfile.mkdtemp(prefix="pdfzig-fuzz-")
    os.makedirs(out, exist_ok=True)
    current = os.path.join(out, "current.pdf")
    copy = os.path.join(out, "copy.pdf")
    runs, copies, bad = 0, 0, []
    for source in sources:
        data = open(source, "rb").read()
        for k in range(int(sys.argv[3])):
            mode, damaged = damage(data, rnd)
            with open(current, "wb") as f:
                f.write(damaged)
            runs += 1
            try:
                what, detail = "", ""
                for command in ([exe, current, "-r"], [pages, copy, current]):
                    r = subprocess.run(command, capture_output=True, timeout=30)
                    if r.returncode not in (0, 1):
                        what, detail = f"status {r.returncode}", r.stderr.decode("utf8", "replace")[:300]
                        break
                else:
                    if r.returncode == 0:  # pdfpages made a copy
                        copies += 1
                        r = subprocess.run([exe, copy, "-r"], capture_output=True, timeout=30)
                        if r.returncode not in (0, 1) or b"repaired=false" not in r.stdout + r.stderr:
                            what, detail = "damaged copy", (r.stdout + r.stderr).decode("utf8", "replace")[:300]
                if not what:
                    continue
            except subprocess.TimeoutExpired:
                what, detail = "timeout", ""
            os.replace(current, os.path.join(out, f"failure-{len(bad) + 1}.pdf"))
            bad.append((source, mode, k, what, detail))
    print("runs", runs, "copies", copies, "crashes/hangs", len(bad), "kept in" if bad else "", out if bad else "")
    for b in bad[:8]:
        print(b)
    sys.exit(1 if bad or not runs else 0)

if __name__ == "__main__":
    main()
