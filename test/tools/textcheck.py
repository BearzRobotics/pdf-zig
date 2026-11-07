import subprocess,re,sys,collections,os
def words(s): return collections.Counter(re.findall(r"\w+", s.lower()))
rows=[]
for line in open(sys.argv[1]):
    f=line.strip()
    if not f: continue
    try:
        ref=subprocess.run(["pdftotext","-raw","-enc","UTF-8",f,"-"],capture_output=True,timeout=60).stdout.decode("utf8","replace")
        mine=subprocess.run(["/home/dakota/de/pdf-zig/zig-out/bin/pdftext","-raw",f],capture_output=True,timeout=120).stdout.decode("utf8","replace")
    except Exception as e:
        rows.append((f,-1,-1,0,str(e))); continue
    r=words(ref); m=words(mine)
    tot=sum(r.values())
    if tot==0: continue
    missing=sum((r-m).values()); extra=sum((m-r).values())
    rows.append((f,tot,missing,extra," ".join(w for w,_ in (r-m).most_common(5))+" | extra: "+" ".join(w for w,_ in (m-r).most_common(5))))
rows.sort(key=lambda r:-(r[2]+r[3])/max(r[1],1))
for f,t,mi,ex,note in rows[:int(sys.argv[2]) if len(sys.argv)>2 else 12]:
    print(f"{os.path.basename(f)[:34]:34} words={t:7} missing={mi:6} extra={ex:6}  {note[:70]}")
T=sum(r[1] for r in rows if r[1]>0)
print("FILES",len(rows),"WORDS",T,"missing",sum(r[2] for r in rows if r[1]>0),"extra",sum(r[3] for r in rows if r[1]>0))
