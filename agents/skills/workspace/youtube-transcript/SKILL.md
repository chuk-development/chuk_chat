---
name: youtube-transcript
description: Pull the full transcript of a YouTube video with yt-dlp and summarize it. Use whenever the user gives a YouTube URL or video id and asks to summarize, transcribe, get the transcript, extract key points, quote, or answer questions about the video.
metadata:
  version: "1.1"
---

# YouTube transcript and summary

Goal: the user gave a YouTube link and wants the video handled end to end.
Pull the transcript yourself, then answer. Do not ask the user to paste the
transcript. Do the whole job and come back with the result.

The tool for the download is `yt-dlp`. It fetches the subtitle track without
downloading the video, so it is fast and small. Run everything through the
`python` tool as one script.

## One script does it all

Run this with the `python` tool. Set `URL` to the video the user gave. It
installs `yt-dlp` if missing, downloads the subtitle track (real captions
first, auto-captions as fallback), cleans it to plain text, and writes
`transcript.txt` in the workspace. Read that file, then write the summary.

```python
import glob, os, re, shutil, subprocess, sys, tempfile
from urllib.parse import urlparse, parse_qs

URL = "PASTE_THE_YOUTUBE_URL_HERE"   # full watch URL, youtu.be link, or 11-char id
# Preferred caption languages, in order. Overridable without editing the script:
# set YT_LANGS (comma list) to retry, e.g. YT_LANGS="all" or YT_LANGS="orig,en,de".
LANGS = [s for s in (os.environ.get("YT_LANGS") or "en,en-US,en-GB,de,de-DE").split(",") if s]

def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)

# 0. validate the input to a canonical https watch URL. yt-dlp's generic
#    extractor would otherwise fetch ANY url the user pasted — only accept
#    YouTube hosts or a bare 11-char video id.
def canonical_url(value):
    value = value.strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", value):           # bare video id
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
    raise SystemExit(f"not a YouTube video URL or id: {value!r}")

url = canonical_url(URL)

# 1. make sure yt-dlp is on PATH; install it without root if not.
def ensure_ytdlp():
    if shutil.which("yt-dlp"):
        return ["yt-dlp"]
    for install in (
        ["uv", "tool", "install", "yt-dlp"],
        [sys.executable, "-m", "pip", "install", "--quiet", "--user", "yt-dlp"],
        ["sudo", "apt-get", "install", "-y", "yt-dlp"],
    ):
        if shutil.which(install[0]):
            sh(install)
            if shutil.which("yt-dlp"):
                return ["yt-dlp"]
    if sh([sys.executable, "-m", "yt_dlp", "--version"]).returncode == 0:
        return [sys.executable, "-m", "yt_dlp"]
    raise SystemExit("could not install yt-dlp; try: sudo apt-get install -y yt-dlp")

ytdlp = ensure_ytdlp()

# 2. download the subtitle track only, into an isolated temp dir so nothing in
#    the workspace is touched. real subs first, then auto subs. --no-playlist so
#    a watch?v=...&list=... url does not pull the whole playlist.
workdir = tempfile.mkdtemp(prefix="yt-subs-")
def find_sub():
    """Pick the subtitle file for the most-preferred language, not glob order."""
    files = glob.glob(os.path.join(workdir, "sub.*.vtt"))
    by_lang = {os.path.basename(f).split(".")[1]: f for f in files if f.count(".") >= 2}
    for want in LANGS:
        for lang, path in by_lang.items():
            if lang == want or lang.startswith(want.split("-")[0]):
                return path
    return files[0] if files else None

vtt, err = None, ""
for auto in ("--write-subs", "--write-auto-subs"):
    for f in glob.glob(os.path.join(workdir, "sub.*")):
        os.remove(f)
    r = sh(ytdlp + [
        "--no-playlist", "--skip-download", auto,
        "--sub-langs", ",".join(LANGS), "--sub-format", "vtt/srv3/best",
        "--convert-subs", "vtt", "-o", os.path.join(workdir, "sub.%(ext)s"), url,
    ])
    err = r.stderr
    vtt = find_sub()
    if vtt:
        break
if not vtt:
    print("NO_SUBTITLES")
    print(err[-800:])
    raise SystemExit(0)

# 3. clean the VTT to plain text. drop timings/tags, and merge the rolling
#    overlap auto-captions produce (each cue repeats the tail of the previous
#    one, e.g. "hello" then "hello world") instead of only dropping exact dups.
def clean_vtt(path):
    out = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        if not line or line.startswith("WEBVTT") or line.startswith(("Kind:", "Language:")):
            continue
        if "-->" in line or re.fullmatch(r"\d+", line):
            continue
        line = re.sub(r"<[^>]+>", "", line)          # inline <c>/timestamp tags
        line = re.sub(r"\s+", " ", line).strip()
        if not line or (out and line == out[-1]):
            continue
        if out:
            prev = out[-1]
            # If this line extends the previous (rolling caption), keep only the new tail.
            if line.startswith(prev + " "):
                out[-1] = line
                continue
            # Or if the previous is a prefix already fully contained, skip.
            if prev.startswith(line):
                continue
        out.append(line)
    return "\n".join(out)

text = clean_vtt(vtt)
with open("transcript.txt", "w", encoding="utf-8") as fh:
    fh.write(text)
shutil.rmtree(workdir, ignore_errors=True)
words = len(text.split())
print(f"OK wrote transcript.txt  lang={os.path.basename(vtt)}  words={words}")
print("--- first 1500 chars ---")
print(text[:1500])
```

## After the script

- On `OK`: the full transcript is in `transcript.txt`. Read it with the
  `read_file` tool if you need more than the preview, then write the summary
  the user asked for. Default output: a short paragraph of what the video is
  about, then the main points as a tight list, in the user's language. If the
  user asked something specific (a quote, one section, an answer), give that
  instead of a generic summary.
- On `NO_SUBTITLES`: the video has no captions in the tried languages. Retry the
  SAME script with a wider language set via the env var — no code edit needed:
  `YT_LANGS="all" python <script>` accepts any language, or
  `YT_LANGS="orig,en,de"` to prefer the original. If still none, tell the user
  the video has no captions, and offer the audio fallback below.

## The audio fallback: audio only, and the smallest one that is still the real track

When there are no captions and the user wants the content anyway, download the
**audio track only** and take the **smallest** one on offer. Speech-to-text does
not get better from a bigger file, so paying for the big one costs time,
bandwidth and disk for nothing.

```bash
yt-dlp --no-playlist \
       -f 'ba[format_note*=original][protocol^=https]/ba[protocol^=https]/ba/worst' \
       -S '+size,+abr' \
       -x --audio-format opus --audio-quality 9 \
       -o 'audio.%(ext)s' "$URL"
```

Measured on a real video: this picks a 49 kbps m4a of 10.3 MiB where `bestaudio`
takes a 121 kbps opus of 25.6 MiB. On a long stream it was 135 MB against
399 MB. Same words either way.

**Do not just write `-f worstaudio`.** On a video with AI dub tracks — which is
most big channels now — `worstaudio` silently selects a dubbed track: on the
video this was tested against it picked `233-0`, the automatic Arabic dub. The
transcript then comes back in a language the video was never in, and nothing
warns you. That is what the `format_note*=original` filter in the first branch
is for.

The rest of the selector, in order: prefer the original-language audio over a
dub; prefer a plain https format over an m3u8 one, because the HLS variants
report no size up front and arrive as fragments; fall back to any audio-only
format; and only then to `worst`, for a video that offers no audio-only format
at all. `-S '+size,+abr'` is what makes "best audio" mean the smallest rather
than the fattest — without it, `ba` still means best.

`-x` drops the container and keeps the audio, so nothing video-sized survives
even when the last fallback had to take a muxed stream. `--audio-quality 9` is
the lowest VBR setting and applies only when yt-dlp re-encodes; with a stream it
can copy, it changes nothing.

Check the size before feeding it to anything. Tens of MB for a normal video is
right; hundreds mean the format selection did not do what it should, and the fix
is the selector, not a bigger machine.

## Notes

- Never download the full video. `--skip-download` keeps it to the subtitle
  file only, and `--no-playlist` keeps a `watch?v=...&list=...` url to the one
  video. If a download is unavoidable, it is audio only and it is the worst
  audio available — see the audio fallback above.
- The input is validated to a YouTube host or an 11-char id before it reaches
  yt-dlp, so a stray non-YouTube url is rejected rather than fetched.
- Subtitles are downloaded into a private temp dir, so nothing in the workspace
  is overwritten; only `transcript.txt` is written to the workspace.
- Age-restricted or private videos may fail the download. The `yt-dlp` stderr
  (printed on `NO_SUBTITLES`) says why; pass that reason to the user.
- Recent `yt-dlp` needs a JavaScript runtime for YouTube. Without one it warns
  ("extraction without a JS runtime has been deprecated ... some formats may be
  missing") and can silently return `NO_SUBTITLES` on videos that DO have
  captions. If that happens, install `deno` (preferred: `sudo apt-get install -y
  deno`, or `curl -fsSL https://deno.land/install.sh | sh`) or `nodejs`, then
  retry — the script needs no change.
