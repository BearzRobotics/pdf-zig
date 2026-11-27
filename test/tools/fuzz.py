#!/usr/bin/env python3
# usage: fuzz.py LIST FILES MUTATIONS [SEED]
# Damages up to FILES of the PDFs in LIST (2 KB to 400 KB) MUTATIONS times each
# and runs `pdfinfo -r` on the results, then `pdfpages` and `pdffill --flatten`,
# whose outputs must open without repair. Inputs that crash, hang or give a damaged copy are saved in
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
    fill = binary("pdffill")
    sources = [f for f in file_list(sys.argv[1]) if 2000 < os.path.getsize(f) < 400000][:int(sys.argv[2])]
    rnd = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    out = os.environ.get("PDFZIG_FUZZ_OUT") or tempfile.mkdtemp(prefix="pdfzig-fuzz-")
    os.makedirs(out, exist_ok=True)
    current = os.path.join(out, "current.pdf")
    copy = os.path.join(out, "copy.pdf")
    flat = os.path.join(out, "flat.pdf")
    runs, copies, flattened, bad = 0, 0, 0, []
    for source in sources:
        data = open(source, "rb").read()
        for k in range(int(sys.argv[3])):
            mode, damaged = damage(data, rnd)
            with open(current, "wb") as f:
                f.write(damaged)
            runs += 1
            try:
                what, detail = "", ""
                r = subprocess.run([exe, current, "-r"], capture_output=True, timeout=30)
                if r.returncode not in (0, 1):
                    what, detail = f"status {r.returncode}", r.stderr.decode("utf8", "replace")[:300]
                sound = b"repaired=false" in r.stdout + r.stderr
                # Each program that writes a file: what it writes must be sound.
                for command, made in (([pages, copy, current], copy), ([fill, current, flat, "--flatten"], flat)):
                    if what:
                        break
                    r = subprocess.run(command, capture_output=True, timeout=30)
                    if r.returncode not in (0, 1):
                        what, detail = f"{os.path.basename(command[0])} status {r.returncode}", r.stderr.decode("utf8", "replace")[:300]
                    elif r.returncode == 0:
                        if made == copy:
                            copies += 1
                        else:
                            flattened += 1
                        r = subprocess.run([exe, made, "-r"], capture_output=True, timeout=30)
                        # A new file must be sound. A flattened one is the input with
                        # more appended, so it can only be as sound as the input was.
                        damaged = b"repaired=false" not in r.stdout + r.stderr and (made == copy or sound)
                        if r.returncode not in (0, 1) or damaged:
                            what, detail = "damaged output", (r.stdout + r.stderr).decode("utf8", "replace")[:300]
                if not what:
                    continue
            except subprocess.TimeoutExpired:
                what, detail = "timeout", ""
            os.replace(current, os.path.join(out, f"failure-{len(bad) + 1}.pdf"))
            bad.append((source, mode, k, what, detail))
    print("runs", runs, "copies", copies, "flattened", flattened, "crashes/hangs", len(bad), "kept in" if bad else "", out if bad else "")
    for b in bad[:8]:
        print(b)
    sys.exit(1 if bad or not runs else 0)

if __name__ == "__main__":
    main()
