import random,subprocess,sys,os,glob
exe="/home/dakota/de/pdf-zig/zig-out/bin/pdfinfo"
srcs=[l.strip() for l in open(sys.argv[1]) if l.strip()]
srcs=[s for s in srcs if 2000<os.path.getsize(s)<400000][:int(sys.argv[2])]
rnd=random.Random(int(sys.argv[4]) if len(sys.argv)>4 else 1)
n=0;bad=[]
for s in srcs:
    data=bytearray(open(s,'rb').read())
    for k in range(int(sys.argv[3])):
        d=bytearray(data)
        mode=rnd.randrange(4)
        if mode==0:   # flip bytes
            for _ in range(rnd.randint(1,40)): d[rnd.randrange(len(d))]=rnd.randrange(256)
        elif mode==1: # truncate
            d=d[:rnd.randrange(len(d)//4,len(d))]
        elif mode==2: # zero a range
            a=rnd.randrange(len(d)); d[a:a+rnd.randint(1,2000)]=b'\0'*min(rnd.randint(1,2000),len(d)-a)
        else:         # delete a chunk
            a=rnd.randrange(len(d)); del d[a:a+rnd.randint(1,3000)]
        p="/tmp/claude-1000/-home-dakota-de-md-zig/b923f66b-f2d0-49ef-9675-d84e816891c0/scratchpad/fz.pdf"
        open(p,'wb').write(d)
        n+=1
        try:
            r=subprocess.run([exe,p,"-r"],capture_output=True,timeout=30)
            if r.returncode not in (0,1):
                bad.append((s,mode,k,r.returncode,r.stderr.decode('utf8','replace')[:300]))
                open(p+f".crash{len(bad)}","wb").write(d)
        except subprocess.TimeoutExpired:
            bad.append((s,mode,k,"TIMEOUT",""))
            open(p+f".hang{len(bad)}","wb").write(d)
print("runs",n,"crashes/hangs",len(bad))
for b in bad[:8]: print(b)
