import numpy as np
W,H=640,480
a=np.fromfile(r"www\hw_in.bgr",dtype=np.uint8).reshape(H,W,3).astype(np.float32)
b=np.fromfile(r"www\hw_out.bgr",dtype=np.uint8).reshape(H,W,3).astype(np.float32)
for name,im in (("hazy in",a),("dehazed",b)):
    dx=np.abs(np.diff(im,axis=1)).mean(); dy=np.abs(np.diff(im,axis=0)).mean()
    print(f"{name:10s} mean={im.mean():6.2f}  |dx|={dx:6.2f}  |dy|={dy:6.2f}  uniq_colours/row0={len(np.unique(im[0].reshape(-1,3),axis=0))}")
# shear test: best circular shift of each row vs row 0
g=a.mean(axis=2)
def best(a,b):
    A=a-a.mean(); B=b-b.mean()
    c=np.fft.irfft(np.fft.rfft(B)*np.conj(np.fft.rfft(A)),n=W)
    i=int(np.argmax(c)); return i
print("\nrow->shift vs row0 (0 = no shear):", [best(g[0],g[r]) for r in range(1,9)])
print("row-periodicity meanabs:", [round(float(np.mean(np.abs(g[p:]-g[:-p]))),1) for p in (1,2,10,20)])
