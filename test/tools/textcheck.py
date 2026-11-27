#!/usr/bin/env python3
# usage: textcheck.py LIST [WORST]. Words of `pdftext -raw` against poppler's
# `pdftotext -raw`. Prints the WORST files that differ most. Exit status: 0 if
# every file was extracted (differences in words are reported, not judged),
# 1 if pdftext failed on a file or nothing was compared.
import collections, os, re, subprocess, sys
from common import binary, file_list

def words(data):
    return collections.Counter(re.findall(r"\w+", data.decode("utf8", "replace").lower()))

exe = binary("pdftext")
rows, failures = [], 0
for f in file_list(sys.argv[1]):
    try:
        mine = subprocess.run([exe, "-raw", f], capture_output=True, timeout=120)
        ref = subprocess.run(["pdftotext", "-raw", "-enc", "UTF-8", f, "-"], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        print("ERROR", f, error)
        failures += 1
        continue
    # A crash is a failure whatever poppler made of the file. A refusal (status
    # 1) counts when poppler could read it.
    if mine.returncode not in (0, 1) or (mine.returncode == 1 and ref.returncode == 0):
        print("FAILED", f, f"status {mine.returncode}", mine.stderr.decode("utf8", "replace").strip()[:80])
        failures += 1
        continue
    if ref.returncode != 0:
        continue
    r, m = words(ref.stdout), words(mine.stdout)
    total = sum(r.values())
    if total == 0 and not m:
        continue
    note = " ".join(w for w, _ in (r - m).most_common(5)) + " | extra: " + " ".join(w for w, _ in (m - r).most_common(5))
    rows.append((f, total, sum((r - m).values()), sum((m - r).values()), note))
rows.sort(key=lambda row: -(row[2] + row[3]) / max(row[1], 1))
for f, total, missing, extra, note in rows[:int(sys.argv[2]) if len(sys.argv) > 2 else 12]:
    print(f"{os.path.basename(f)[:34]:34} words={total:7} missing={missing:6} extra={extra:6}  {note[:70]}")
print("FILES", len(rows), "WORDS", sum(r[1] for r in rows), "missing", sum(r[2] for r in rows),
      "extra", sum(r[3] for r in rows), "failures", failures)
sys.exit(1 if failures or not rows else 0)
