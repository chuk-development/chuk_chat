"""Map the supplied track: tempo, beat grid, band energy, centroid.

Run from the project root: python3 tools/analyze_music.py
"""
import json
import numpy as np
import librosa

y, sr = librosa.load("assets/bgm/track.wav", sr=22050, mono=True)
tempo, beats = librosa.beat.beat_track(y=y, sr=sr, start_bpm=118, tightness=200)
bt = librosa.frames_to_time(beats, sr=sr)
print("tempo", tempo, "n beats", len(bt))
print("first beats", np.round(bt[:12], 3))
d = np.diff(bt)
print("median ibi", np.median(d))

hop = 512
S = np.abs(librosa.stft(y, n_fft=2048, hop_length=hop))
freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
t = librosa.frames_to_time(np.arange(S.shape[1]), sr=sr, hop_length=hop)
low = S[freqs < 150].sum(0)
mid = S[(freqs >= 150) & (freqs < 4000)].sum(0)
high = S[freqs >= 5000].sum(0)
cent = librosa.feature.spectral_centroid(S=S, sr=sr)[0]
onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)

def db(x):
    return 20 * np.log10(x + 1e-9)

step = 0.5
rows = []
for s in np.arange(0, t[-1], step):
    m = (t >= s) & (t < s + step)
    rows.append((s, db(low[m].mean()), db(mid[m].mean()), db(high[m].mean()), cent[m].mean(), onset[m].mean()))
print(" t     low    mid    high   cent   onset")
for r in rows:
    print("%5.1f %6.1f %6.1f %6.1f %6.0f %5.2f" % r)
json.dump({"tempo": float(np.atleast_1d(tempo)[0]), "beats": [round(float(b), 3) for b in bt]}, open("tools/librosa_beats.json", "w"))
