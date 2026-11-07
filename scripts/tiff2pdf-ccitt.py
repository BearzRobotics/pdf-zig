import struct,sys
t=open(sys.argv[1],'rb').read(); bo='<' if t[:2]==b'II' else '>'
off=struct.unpack(bo+'I',t[4:8])[0]; n=struct.unpack(bo+'H',t[off:off+2])[0]; tags={}
for i in range(n):
    e=t[off+2+12*i:off+14+12*i]; tag,typ,cnt=struct.unpack(bo+'HHI',e[:8])
    v=struct.unpack(bo+('H' if typ==3 else 'I'),e[8:10] if typ==3 else e[8:12])[0]; tags[tag]=(typ,cnt,v)
def val(tag): return tags[tag][2]
def arr(tag):
    typ,cnt,v=tags[tag]
    if cnt==1: return [v]
    sz=2 if typ==3 else 4; return list(struct.unpack(bo+('H' if typ==3 else 'I')*cnt,t[v:v+sz*cnt]))
w,h=val(256),val(257); comp=val(259); fill=tags.get(266,(0,0,1))[2]; opt=tags.get(292,(0,0,0))[2]
offs,cnts=arr(273),arr(279); data=b''.join(t[o:o+c] for o,c in zip(offs,cnts))
if fill==2: data=bytes(int('{:08b}'.format(b)[::-1],2) for b in data)
K=-1 if comp==4 else (0 if not opt&1 else 4)
parms=f"<< /K {K} /Columns {w} /Rows {h} /BlackIs1 false"+(" /EndOfLine true" if K>=0 else "")+" >>"
print(sys.argv[1],'comp',comp,'opt',opt,'fill',fill,parms,file=sys.stderr)
objs=[b"<< /Type /Catalog /Pages 2 0 R >>",b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Contents 4 0 R /Resources << /XObject << /I 5 0 R >> >> >>".encode(),
None,None]
cs=f"{w} 0 0 {h} 0 0 cm /I Do".encode()
objs[3]=b"<< /Length %d >>\nstream\n"%len(cs)+cs+b"\nendstream"
objs[4]=f"<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms {parms} /Length {len(data)} >>\nstream\n".encode()+data+b"\nendstream"
out=b"%PDF-1.4\n";xr=[]
for i,o in enumerate(objs):
    xr.append(len(out)); out+=f"{i+1} 0 obj\n".encode()+o+b"\nendobj\n"
x=len(out); out+=f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n".encode()+b"".join(f"{p:010d} 00000 n \n".encode() for p in xr)
out+=f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
open(sys.argv[2],'wb').write(out)
