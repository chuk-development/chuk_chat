---
name: song-identify
description: Identify the song playing in a video or an audio file, the way Shazam does, and report title, artist, album and year. Use whenever the user asks "which song is this", "what song is playing", "identify the song/track/music", "name the track", "what is this music", "Shazam this", or gives a YouTube link or an audio/video file and wants the music named.
metadata:
  version: "1.0"
---

# Identify the song in a video or audio file

Goal: the user pointed at a video, a clip or an audio file and wants to know
which song it is. Recognise it yourself and answer with the track. Do not ask
the user to hum it, to describe it, or to run Shazam on their phone.

The recogniser is `shazamio`, a Python client for the real Shazam fingerprint
service. It needs no API key and no account. `ffmpeg` cuts the sample and
`yt-dlp` fetches YouTube audio. Run everything through the `python` tool as one
script.

## One script does it all

Run this with the `python` tool. Set `SOURCE` to the YouTube URL, the 11-char
video id, or the path of a local audio or video file. The script installs
`shazamio` into its own cache venv on first use, takes a short sample from the
middle of the material, fingerprints it, and prints the track.

```python
import json, os, re, shutil, subprocess, sys, tempfile
from urllib.parse import urlparse, parse_qs

SOURCE = "PASTE_THE_YOUTUBE_URL_OR_FILE_PATH_HERE"
# Optional overrides, no code edit needed:
#   SONG_AT=75      start the first sample at second 75 (a timestamp the user named)
#   SONG_LEN=20     sample length in seconds (default 15)
AT = os.environ.get("SONG_AT")
SAMPLE_LEN = int(os.environ.get("SONG_LEN") or 15)

def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)

# 1. classify the input. A local file is used as is. Anything else must be a
#    YouTube URL or an 11-char id; yt-dlp's generic extractor would otherwise
#    fetch ANY url that was pasted.
def canonical_url(value):
    value = value.strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", value):
        return f"https://www.youtube.com/watch?v={value}"
    u = urlparse(value if "://" in value else "https://" + value)
    host = (u.hostname or "").lower().removeprefix("www.")
    if host in ("youtube.com", "m.youtube.com", "music.youtube.com"):
        vid = parse_qs(u.query).get("v", [None])[0]
        if vid and re.fullmatch(r"[A-Za-z0-9_-]{11}", vid):
            return f"https://www.youtube.com/watch?v={vid}"
    if host == "youtu.be":
        vid = u.path.lstrip("/").split("/")[0]
        if re.fullmatch(r"[A-Za-z0-9_-]{11}", vid or ""):
            return f"https://www.youtube.com/watch?v={vid}"
    raise SystemExit(f"BAD_INPUT not a local file, YouTube URL or id: {value!r}")

local_path = os.path.abspath(os.path.expanduser(SOURCE)) if os.path.isfile(os.path.expanduser(SOURCE)) else None
url = None if local_path else canonical_url(SOURCE)

# 2. ffmpeg cuts the sample and ffprobe reads the duration. Both ship together.
if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
    raise SystemExit("NO_FFMPEG install it: sudo apt-get install -y ffmpeg "
                     "(macOS: brew install ffmpeg)")

# 3. shazamio is the recogniser. It carries a compiled core, so it lives in its
#    own venv under ~/.cache; a system python is usually PEP-668 locked anyway.
#    The venv is built once and reused, so a second run starts in a second.
venv = os.path.expanduser("~/.cache/song-identify/venv")
vpy = os.path.join(venv, "bin", "python")
if not os.path.exists(vpy):
    os.makedirs(os.path.dirname(venv), exist_ok=True)
    if sh([sys.executable, "-m", "venv", venv]).returncode != 0:
        raise SystemExit("NO_VENV python venv module missing: sudo apt-get install -y python3-venv")
if sh([vpy, "-c", "import shazamio"]).returncode != 0:
    r = sh([vpy, "-m", "pip", "install", "--quiet", "shazamio"])
    if sh([vpy, "-c", "import shazamio"]).returncode != 0:
        raise SystemExit("NO_SHAZAMIO pip install failed:\n" + (r.stderr or r.stdout)[-800:])

workdir = tempfile.mkdtemp(prefix="song-id-")
try:
    # 4. get the audio. For YouTube: audio only, and the smallest track that is
    #    still the ORIGINAL one. A fingerprint does not improve with bitrate.
    if local_path:
        media = local_path
    else:
        def ensure_ytdlp():
            if shutil.which("yt-dlp"):
                return ["yt-dlp"]
            for install in (["uv", "tool", "install", "yt-dlp"],
                            [sys.executable, "-m", "pip", "install", "--quiet", "--user", "yt-dlp"],
                            ["sudo", "apt-get", "install", "-y", "yt-dlp"]):
                if shutil.which(install[0]):
                    sh(install)
                    if shutil.which("yt-dlp"):
                        return ["yt-dlp"]
            if sh([sys.executable, "-m", "yt_dlp", "--version"]).returncode == 0:
                return [sys.executable, "-m", "yt_dlp"]
            raise SystemExit("NO_YTDLP try: sudo apt-get install -y yt-dlp")
        r = sh(ensure_ytdlp() + [
            "--no-playlist", "--no-embed-thumbnail", "--no-embed-metadata",
            "--no-write-thumbnail",
            "-f", "ba[format_note*=original][protocol^=https]/ba[protocol^=https]/ba/worst",
            "-S", "+size,+abr",
            "-o", os.path.join(workdir, "audio.%(ext)s"), url,
        ])
        got = [os.path.join(workdir, f) for f in os.listdir(workdir)]
        if not got:
            print("DOWNLOAD_FAILED")
            print((r.stderr or r.stdout)[-1200:])
            raise SystemExit(0)
        media = max(got, key=os.path.getsize)

    # 5. duration decides where to cut.
    p = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", media])
    try:
        dur = float(p.stdout.strip())
    except ValueError:
        dur = 0.0

    # 6. sample windows. Never start at second 0: the opening is often silence,
    #    a fade-in, a logo sting or an intro talk. 20% in is inside the song.
    #    If that window misses, 45% and 70% are tried before giving up, which
    #    costs nothing because the audio is already local.
    if AT is not None:
        starts = [float(AT)]
    elif dur <= SAMPLE_LEN + 2:
        starts = [0.0]
    else:
        starts = [round(dur * f, 1) for f in (0.20, 0.45, 0.70)]
        starts = [min(s, max(0.0, dur - SAMPLE_LEN - 1)) for s in starts]
        seen, uniq = set(), []
        for s in starts:
            if s not in seen:
                seen.add(s); uniq.append(s)
        starts = uniq

    # 7. recognise. The sample is cut to 16-bit mono 44.1 kHz PCM, which is what
    #    the fingerprinter wants and what keeps the file small.
    recog = os.path.join(workdir, "recognize.py")
    with open(recog, "w") as fh:
        fh.write(
            "import asyncio, json, sys\n"
            "from shazamio import Shazam\n"
            "async def main():\n"
            "    print(json.dumps(await Shazam().recognize(sys.argv[1])))\n"
            "asyncio.run(main())\n")

    result, used_start = None, None
    for start in starts:
        wav = os.path.join(workdir, "sample.wav")
        c = sh(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-ss", str(start), "-t", str(SAMPLE_LEN), "-i", media,
                "-vn", "-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le", wav])
        if c.returncode != 0 or not os.path.exists(wav):
            raise SystemExit("FFMPEG_FAILED " + c.stderr[-400:])
        out = sh([vpy, recog, wav])
        if out.returncode != 0:
            raise SystemExit("RECOGNIZER_FAILED " + (out.stderr or "")[-800:])
        data = json.loads(out.stdout)
        if data.get("track"):
            result, used_start = data, start
            break

    if not result:
        print("NO_MATCH")
        print(f"tried windows: {starts} of {dur:.0f}s, {SAMPLE_LEN}s each")
        raise SystemExit(0)

    t = result["track"]
    meta = {}
    for sec in t.get("sections", []):
        for m in sec.get("metadata", []) or []:
            meta[m.get("title")] = m.get("text")
    print("OK")
    print(json.dumps({
        "title": t.get("title"),
        "artist": t.get("subtitle"),
        "album": meta.get("Album"),
        "released": meta.get("Released"),
        "label": meta.get("Label"),
        "genre": (t.get("genres") or {}).get("primary"),
        "isrc": t.get("isrc"),
        "shazam_url": t.get("url"),
        "sample_window": f"{used_start:.0f}s-{used_start + SAMPLE_LEN:.0f}s of {dur:.0f}s",
    }, indent=2, ensure_ascii=False))
finally:
    shutil.rmtree(workdir, ignore_errors=True)
```

## After the script

- On `OK`: the JSON is the answer. Tell the user the title and the artist in one
  sentence, then album, year and label if the fields are filled. Add the
  `shazam_url` as the link. Fields can be `null` for a single or an obscure
  release; leave out what is empty instead of guessing it.
- On `NO_MATCH`: three windows found no music that Shazam knows. Say so plainly.
  Do **not** guess a title from the video title, the channel name or the
  description — a confident wrong answer is worse than "no match". Offer one
  retry with a window the user picks: `SONG_AT=<second> python <script>`, for
  example when the music starts late or only plays under the outro. A longer
  sample can also help on a noisy source: `SONG_LEN=25`.
  Common real causes: the clip has speech only, the music is royalty-free
  library stock that is not in the Shazam catalogue, it is a live or cover
  version, or the track is pitch-shifted to dodge copyright detection.
- On `DOWNLOAD_FAILED`: the printed `yt-dlp` stderr says why. Age-restricted,
  private and region-locked videos fail here. Pass the reason to the user.
- On `NO_FFMPEG`, `NO_VENV`, `NO_SHAZAMIO`, `NO_YTDLP`: the message carries the
  install command. Run it, then run the script again unchanged.
- On `BAD_INPUT`: the value is neither an existing file nor a YouTube URL or id.
  Ask the user for the link or the path.

## Why a short sample, and why not from the start

Shazam matches from roughly five seconds of audio. Fifteen seconds is the
default here because it survives a quiet bar or a break without costing
anything: the cut wav is about 1.3 MB and the lookup takes about a second.
A full-length upload gives no better result than those fifteen seconds.

The window starts at 20% of the duration, not at second 0. The first seconds of
a video are the worst place to sample: silence, a fade-in, a channel logo sting,
or a person talking before the music starts. At 20% a normal song is past the
intro, and a video with a music bed has it running. 45% and 70% follow if the
first window misses, which covers a clip where the music only starts halfway.
Pass `SONG_AT` when the user names a timestamp — that beats any heuristic.

## Audio only, and the smallest stream that is still the real one

The YouTube branch downloads the **audio track only** and takes the **smallest**
one on offer. This is the same selector the `youtube-transcript` skill uses, and
for the same reason: a fingerprint does not get better from a bigger file.

```
-f 'ba[format_note*=original][protocol^=https]/ba[protocol^=https]/ba/worst' -S '+size,+abr'
```

**Do not just write `-f worstaudio`.** On a video with AI dub tracks — which is
most big channels now — `worstaudio` silently selects a dubbed track. For a
transcript that returns the wrong language; here the dub can be mixed over the
music and weaken the fingerprint. The `format_note*=original` filter in the
first branch is what keeps the real track.

The rest, in order: prefer a plain https format over an m3u8 one, because HLS
variants report no size up front and arrive as fragments; fall back to any
audio-only format; and only then to `worst`, for a video that offers no
audio-only format at all. `-S '+size,+abr'` is what makes "best audio" mean the
smallest rather than the fattest — without it, `ba` still means best.

Measured on a four-minute music video: format 139, a 48 kbps m4a of 1.45 MiB.

## Notes

- The whole audio file is downloaded and then cut locally. `yt-dlp
  --download-sections` looks like the smarter route, but it hands the
  googlevideo URL to ffmpeg, and that request comes back `403 Forbidden`.
  Downloading the audio first always works and costs a few MB.
- Everything except the answer stays in a private temp dir that is removed at
  the end. Nothing is written into the workspace. The only lasting artefact is
  the `~/.cache/song-identify/venv`, which makes every later run fast.
- Recent `yt-dlp` warns "No supported JavaScript runtime could be found ... some
  formats may be missing". Recognition still works — the audio-only formats it
  can reach are enough. If a download fails outright, install `deno`
  (`sudo apt-get install -y deno`) or `nodejs` and retry; the script needs no
  change.
- A local file needs no `yt-dlp` at all, only `ffmpeg`. Any container ffmpeg can
  read works: mp4, mkv, webm, mp3, m4a, wav, ogg, opus, flac.
- Shazam recognises recordings, not compositions. A cover, a live take or a
  remix returns that specific release if it is in the catalogue, and `NO_MATCH`
  if it is not. Never present a studio original as the answer for a live version
  the user asked about.
