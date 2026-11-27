#!/bin/bash
# usage: renderall.sh LIST. Renders every page of every PDF in LIST and reports
# crashes, timeouts and errors. Exit status: 0 no problems, 1 otherwise or if
# nothing was run. The programs are in $PDFZIG_BIN, or zig-out/bin.
bin="${PDFZIG_BIN:-$(dirname "$0")/../../zig-out/bin}"
if [ ! -x "$bin/pdfinfo" ]; then
  echo "$bin/pdfinfo is missing: run 'zig build -Doptimize=ReleaseSafe', or set PDFZIG_BIN" >&2
  exit 1
fi
n=0; bad=0
while read -r f; do
  [ -z "$f" ] && continue
  n=$((n+1))
  out=$(timeout 120 "$bin/pdfinfo" "$f" -r 2>&1); rc=$?
  if [ $rc -ne 0 ] || echo "$out" | grep -q "page-errors=[1-9]"; then bad=$((bad+1)); echo "PROBLEM rc=$rc $f :: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"; fi
done < "$1"
echo "files=$n problems=$bad"
[ $n -gt 0 ] && [ $bad -eq 0 ]
