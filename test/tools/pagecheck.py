#!/usr/bin/env python3
# usage: pagecheck.py LIST. Page counts against poppler's pdfinfo.
# Exit status: 0 all agree, 1 a mismatch or failure, or nothing was compared.
import re, subprocess, sys
from common import binary, file_list

exe = binary("pdfinfo")
bad = compared = skipped = 0
for f in file_list(sys.argv[1]):
    try:
        ref = subprocess.run(["pdfinfo", f], capture_output=True, text=True, errors="replace", timeout=30)
        wanted = re.search(r"^Pages:\s+(\d+)", ref.stdout, re.M)
        if not wanted:
            skipped += 1
            continue
        mine = subprocess.run([exe, f], capture_output=True, text=True, errors="replace", timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        print("ERROR", f, error)
        bad += 1
        continue
    compared += 1
    got = re.search(r"pages=(\d+)", mine.stderr)
    if not got or int(got.group(1)) != int(wanted.group(1)):
        bad += 1
        print("MISMATCH", f, "poppler", wanted.group(1), "pdf-zig",
              got.group(1) if got else f"status {mine.returncode}: {mine.stderr.strip()[:80]}")
print(f"compared={compared} failures={bad} skipped(poppler could not read)={skipped}")
sys.exit(1 if bad or not compared else 0)
