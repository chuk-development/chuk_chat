import numpy as np, subprocess
raw=subprocess.run(['ffmpeg','-v','error','-i','assets/bgm/track.wav','-ac','1','-ar','22050','-f','f32le','-'],capture_output=True).stdout
y=np.frombuffer(raw,dtype=np.float32); sr=22050
n=8192; hop=2048
win=np.hanning(n)
frames=[]; times=[]
for s in range(0,len(y)-n,hop):
    X=np.abs(np.fft.rfft(y[s:s+n]*win))**2
    frames.append(X); times.append((s+n/2)/sr)
S=np.array(frames).T; times=np.array(times)
freqs=np.fft.rfftfreq(n,1/sr)
ok=(freqs>55)&(freqs<2000)
pc=np.round(12*np.log2(freqs[ok]/261.63))%12
chroma=np.zeros((12,S.shape[1]))
for i in range(12):
    chroma[i]=S[ok][pc==i].sum(axis=0)
chroma=chroma/ (chroma.sum(axis=0,keepdims=True)+1e-12)
maj=np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88])
mnr=np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17])
names=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
def key(seg):
    c=seg.mean(axis=1); best=[]
    for i in range(12):
        best.append((float(np.corrcoef(c,np.roll(maj,i))[0,1]),names[i]+' maj'))
        best.append((float(np.corrcoef(c,np.roll(mnr,i))[0,1]),names[i]+' min'))
    best.sort(reverse=True); return best[:3]
def w(a,b):
    m=(times>=a)&(times<b); return chroma[:,m]
for a,b in [(5.14,10.19),(10.19,15.25),(15.25,20.3),(20.3,25.35),(25.35,30.4),(30.4,35.46),(35.46,40.5),(40.5,45.56),(45.56,51.8),(5.14,25.35),(25.35,45.56)]:
    print(f"{a:6.2f}-{b:6.2f}", [(round(r,2),k) for r,k in key(w(a,b))])
for lab,(a,b) in [('A 5-25',(5.14,25.35)),('B 25-45',(25.35,45.56))]:
    p=w(a,b).mean(axis=1); order=np.argsort(-p)
    print(lab, [(names[i],round(float(p[i]),3)) for i in order[:7]])
for t0 in np.arange(19.03,31,1.263):
    r,k=key(w(t0,t0+1.263))[0]
    print(round(float(t0),2), k, round(r,2))
