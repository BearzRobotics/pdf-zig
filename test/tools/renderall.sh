#!/bin/bash
# Renders every page of every PDF in the list; reports crashes, timeouts, errors.
n=0; bad=0
while read -r f; do
  [ -z "$f" ] && continue
  n=$((n+1))
  out=$(timeout 120 /home/dakota/de/pdf-zig/zig-out/bin/pdfinfo "$f" -r 2>&1); rc=$?
  if [ $rc -ne 0 ] || echo "$out" | grep -q "page-errors=[1-9]"; then bad=$((bad+1)); echo "PROBLEM rc=$rc $f :: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"; fi
done < "$1"
echo "files=$n problems=$bad"
