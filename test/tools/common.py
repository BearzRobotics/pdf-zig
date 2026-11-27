# Shared by the verification scripts.
import os, sys

def binary(name):
    """The path of a pdf-zig example program: in $PDFZIG_BIN, or zig-out/bin."""
    here = os.path.dirname(os.path.abspath(__file__))
    directory = os.environ.get("PDFZIG_BIN") or os.path.join(here, "..", "..", "zig-out", "bin")
    path = os.path.join(directory, name)
    if not os.access(path, os.X_OK):
        sys.exit(f"{path} is missing: run `zig build -Doptimize=ReleaseSafe`, or set PDFZIG_BIN")
    return path

def file_list(path):
    files = [line.strip() for line in open(path) if line.strip()]
    if not files:
        sys.exit(f"{path} names no files")
    return files
