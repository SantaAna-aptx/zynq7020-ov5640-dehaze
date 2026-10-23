import numpy as np, sys
W,H=640,480
d=np.fromfile(r"www\hw_out_cam.bin.in.bgr",dtype=np.uint8).reshape(H,W,3).astype(np.float32)
g=d.mean(axis=2)
# best circular shift of row r relative to row 0
def best_shift(a,b):
    # b shifted by s equals a  (b = np.roll(a,-s)?) use fft corr
    A=np.fft.rfft(a-a.mean()); B=np.fft.rfft(b-b.mean())
    c=np.fft.irfft(B*np.conj(A),n=W)
    s=int(np.argmax(c))
    return s, c.max()/(np.linalg.norm(a-a.mean())*np.linalg.norm(b-b.mean())+1e-9)
print("row  shift vs row0   corr")
for r in list(range(0,24))+[100,200,300]:
    s,c=best_shift(g[0],g[r])
    print(f"{r:4d} {s:6d} {c:8.3f}")
print()
# row repetition: find period p minimizing mean abs diff between row r and r+p
for p in range(1,40):
    e=np.mean(np.abs(g[p:]-g[:-p]))
    print(f"period {p:3d}  meanabs {e:7.3f}")
