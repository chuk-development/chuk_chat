import numpy as np, subprocess
raw=subprocess.run(['ffmpeg','-v','error','-i','assets/bgm/track.wav','-ac','1','-ar','22050','-f','f32le','-'],capture_output=True).stdout
y=np.frombuffer(raw,dtype=np.float32); sr=22050
def rms(a,b): s=y[int(a*sr):int(b*sr)]; return 20*np.log10(np.sqrt((s**2).mean())+1e-9)
# low vs high band energy
def band(a,b,lo,hi):
    s=y[int(a*sr):int(b*sr)]; X=np.abs(np.fft.rfft(s*np.hanning(len(s))))**2; f=np.fft.rfftfreq(len(s),1/sr)
    return 10*np.log10(X[(f>=lo)&(f<hi)].sum()+1e-9)
for t in np.arange(22.5,27.0,0.1579):
    print(f"{t:6.2f} rms {rms(t,t+0.1579):6.1f}  low {band(t,t+0.1579,30,200):6.1f} mid {band(t,t+0.1579,200,2000):6.1f} hi {band(t,t+0.1579,2000,10000):6.1f}")
