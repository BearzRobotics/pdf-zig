#!/usr/bin/env python3
# usage: survey.py DIRECTORY_OR_LIST [--sample N] [--seed S] [--jobs J]
# Runs `pdfsurvey` on PDF files, each in its own process, and prints how many
# use each feature. Only counts are printed. The paths of files that crashed or
# timed out are written to the output directory ($PDFZIG_SURVEY_OUT, or a new
# temporary one), which is never part of the repository.
# Exit status: 0 done, 1 if nothing was run or something crashed.
import argparse, collections, os, random, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from common import binary, file_list

def pdfs(source):
    if not os.path.isdir(source):
        return file_list(source)
    # Symbolic links are not followed: a loop of them has no end.
    return sorted(os.path.join(d, n) for d, _, names in os.walk(source)
                  for n in names if n.lower().endswith(".pdf") and os.path.isfile(os.path.join(d, n)))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("--sample", type=int, default=0)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    exe = binary("pdfsurvey")
    files = pdfs(args.source)
    total = len(files)
    if args.sample and args.sample < total:
        files = random.Random(args.seed).sample(files, args.sample)
    out = os.environ.get("PDFZIG_SURVEY_OUT") or tempfile.mkdtemp(prefix="pdfzig-survey-")
    os.makedirs(out, exist_ok=True)

    def one(path):
        try:
            r = subprocess.run([exe, path], capture_output=True, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            return path, ["TIMEOUT"]
        except OSError:
            return path, ["could-not-run"]
        if r.returncode < 0 or r.returncode not in (0, 1, 2) or b"panic" in r.stderr:
            return path, ["CRASH"]
        if r.returncode != 0:
            return path, ["tool-error"]
        return path, r.stdout.decode("ascii", "replace").split()

    counts = collections.Counter()
    bad = []
    done = 0
    with ThreadPoolExecutor(args.jobs) as pool:
        for path, words in pool.map(one, files):
            done += 1
            counts.update(set(words))
            if any(w in ("CRASH", "TIMEOUT") or w.startswith(("survey-error", "page-error", "open-error")) for w in words):
                bad.append((" ".join(w for w in words if w in ("CRASH", "TIMEOUT") or "error" in w), path))
            if done % 250 == 0:
                print(f"... {done}/{len(files)}", file=sys.stderr, flush=True)
    with open(os.path.join(out, "failures.txt"), "w") as f:
        f.writelines(f"{what}\t{path}\n" for what, path in bad)

    print(f"surveyed {done} of {total} files")
    for word, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{n:7d} {100 * n / done:5.1f}%  {word}")
    print(f"failure list: {os.path.join(out, 'failures.txt')}")
    sys.exit(1 if not done or counts["CRASH"] or counts["TIMEOUT"] else 0)

if __name__ == "__main__":
    main()
