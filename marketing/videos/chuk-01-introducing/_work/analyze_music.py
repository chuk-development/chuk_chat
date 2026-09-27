import librosa, numpy as np, json
y, sr = librosa.load('assets/bgm/track.wav', sr=22050, mono=True)
dur = len(y)/sr
hop=512
rms = librosa.feature.rms(y=y, hop_length=hop)[0]
t = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=hop)
print("duration", round(dur,3))
# per-second dB
line=[]
for s in range(int(np.ceil(dur))):
    m=(t>=s)&(t<s+1)
    v=20*np.log10(np.mean(rms[m])+1e-9)
    line.append(f"{s}:{v:.1f}")
print(" ".join(line))
tempo, beats = librosa.beat.beat_track(y=y, sr=sr, hop_length=hop, start_bpm=100)
bt = librosa.frames_to_time(beats, sr=sr, hop_length=hop)
print("tempo", tempo)
print("beats", " ".join(f"{b:.2f}" for b in bt))
onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
# strong onsets
on = librosa.onset.onset_detect(onset_envelope=onset_env, sr=sr, hop_length=hop, units='time')
strength = onset_env[librosa.time_to_frames(on, sr=sr, hop_length=hop)]
top = sorted(zip(strength, on), reverse=True)[:40]
print("strong onsets", " ".join(f"{o:.2f}({s:.1f})" for s,o in sorted(top, key=lambda x:x[1])))
# low-frequency (kick) energy onsets
S = np.abs(librosa.stft(y, hop_length=hop))
freqs = librosa.fft_frequencies(sr=sr)
low = S[freqs<150].sum(axis=0)
lowdiff = np.maximum(0, np.diff(low, prepend=low[0]))
pk = librosa.util.peak_pick(lowdiff, pre_max=5, post_max=5, pre_avg=10, post_avg=10, delta=np.percentile(lowdiff,90)*0.5, wait=8)
pt = librosa.frames_to_time(pk, sr=sr, hop_length=hop)
print("kick-ish", " ".join(f"{p:.2f}" for p in pt))
json.dump({"duration":dur,"tempo":float(np.atleast_1d(tempo)[0]),"beats":[float(b) for b in bt]}, open('_work/beats_librosa.json','w'), indent=1)
