import subprocess,re,sys
mism=0;n=0;skipped=0
for line in open(sys.argv[1]):
    f=line.strip()
    if not f: continue
    try:
        ref=subprocess.run(["pdfinfo",f],capture_output=True,text=True,timeout=30)
        m=re.search(r"^Pages:\s+(\d+)",ref.stdout,re.M)
        if not m: skipped+=1; continue
        mine=subprocess.run(["/home/dakota/de/pdf-zig/zig-out/bin/pdfinfo",f],capture_output=True,text=True,timeout=60).stderr
        mm=re.search(r"pages=(\d+)",mine)
        n+=1
        if not mm or int(mm.group(1))!=int(m.group(1)):
            mism+=1; print("MISMATCH",f,"poppler",m.group(1),"mine",mm.group(1) if mm else mine.strip()[:80])
    except Exception as e:
        print("ERR",f,e)
print(f"compared={n} mismatches={mism} skipped(poppler could not read)={skipped}")
