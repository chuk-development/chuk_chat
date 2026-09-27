"""Find kick onsets (low band) and the downbeat phase of the grid."""
import numpy as np
import librosa

y, sr = librosa.load(__import__("sys").argv[1] if len(__import__("sys").argv)>1 else "assets/bgm/track.wav", sr=22050, mono=True)
yl = librosa.effects.preemphasis(y, coef=-0.97)  # tilt toward lows
hop = 128
S = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
f = librosa.fft_frequencies(sr=sr, n_fft=2048)
low = S[f < 120].sum(0)
t = librosa.frames_to_time(np.arange(S.shape[1]), sr=sr, hop_length=hop)
dl = np.maximum(0, np.diff(low, prepend=low[0]))
thr = np.percentile(dl, 99.3)
peaks = librosa.util.peak_pick(dl, pre_max=20, post_max=20, pre_avg=40, post_avg=40, delta=thr * 0.3, wait=40)
kt = t[peaks]
print("kick-ish onsets:", len(kt))
print(np.round(kt, 3).tolist())
# full-band onsets
on = librosa.onset.onset_detect(y=y, sr=sr, hop_length=hop, units="time", backtrack=False, delta=0.25)
print("onsets n", len(on))
for w in [(7.0, 9.0), (15.0, 17.0), (21.0, 25.0), (37.0, 41.0), (47.0, 49.0), (55.0, 57.0), (59.0, 66.0)]:
    print(w, np.round(on[(on >= w[0]) & (on < w[1])], 3).tolist())
