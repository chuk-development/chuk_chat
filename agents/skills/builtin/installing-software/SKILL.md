---
name: installing-software
description: Install or update a program or library without root (uv tool, ~/venv, npm, apt-user-install). Never sudo or system pip. Use when a command is "not found" or before any install.
metadata:
  version: "1.0"
---

# Installing software

## Which computer is this?

```bash
command -v apt-user-install
```

- **Found: a cloud computer.** You are user `agent`. There is no `sudo` and no
  root, and there never will be. Do not try. Everything below works without it.
- **Not found: the user's own computer.** The same order applies. You may use
  the normal package manager (`apt`, `dnf`, `brew`) only when the user allows
  it for this task. Ask first.

## 1. Check that it is not already there

```bash
command -v ffmpeg pandoc soffice yt-dlp       # programs
~/venv/bin/python -c "import pandas"           # Python libraries
uv tool list                                   # Python CLIs from uv
ls ~/.local/bin ~/.local/apt/usr/bin 2>/dev/null
```

A cloud computer has a lot preinstalled:

- Media: `ffmpeg`, `ffprobe`, `mediainfo`, `sox`, ImageMagick (`magick`,
  `convert`), `exiftool`.
- Documents: `pandoc`, poppler (`pdftotext`, `pdftoppm`), `qpdf`,
  `ghostscript`, `pdftk`, `graphviz`, LibreOffice (`soffice`), `tesseract`
  (eng, deu).
- Archives and net: `7z`, `unar`, `unrar`, `zip`, `curl`, `wget`, `rsync`,
  `git`, `git-lfs`.
- Shell: `jq`, `rg`, `fd`, `sqlite3`, `parallel`, `tmux`.
- Fonts: Noto (with emoji and CJK), Liberation.
- User space: `uv`, `yt-dlp`, `gallery-dl`, `markitdown`, `playwright` with
  Chromium, Node LTS (`node`, `npm`).
- `~/venv`: pandas, numpy, matplotlib, seaborn, openpyxl, python-docx,
  python-pptx, reportlab, pypdf, pdfplumber, pillow, xlsxwriter,
  beautifulsoup4, lxml, requests, httpx, trafilatura, sympy. Run scripts with
  `~/venv/bin/python`.

## 2. Install, in this order

Take the first way that fits:

1. **Preinstalled tool.** Often a tool you have does the job (`ffmpeg`
   instead of a converter, `soffice` instead of a PDF library).
2. **Python CLI:** `uv tool install <pkg>`. It goes to `~/.local/bin`.
   Update: `uv tool upgrade <pkg>`.
3. **Python library:** `uv pip install --python ~/venv/bin/python <pkg>`.
   For a project, make its own venv: `uv venv .venv && uv pip install
   --python .venv/bin/python <pkg>`.
4. **Node CLI or library:** `npm install -g <pkg>`. The npm prefix is
   `~/.local`, so no root is needed. For a project, `npm install <pkg>` in
   the project folder.
5. **Static binary or release tarball** from the project's official release
   page, into `~/.local/bin`. When the project publishes a checksum
   (`SHA256SUMS`, `.sha256`), check it with `sha256sum -c` before you run
   the file.
6. **Debian package:** `apt-user-install <pkg>` (cloud computer only). It
   unpacks the `.deb` and its missing dependencies into `~/.local/apt`
   without install scripts. Best effort: plain programs and libraries work,
   services and anything that needs root do not.
7. **Not possible.** Tell the user that the program needs root, which this
   cloud computer does not give. Name an alternative if one exists.

## Never

- `sudo`, `su`, or any try to become root.
- `curl ... | sh` installers that write to `/usr` or call `sudo`. A script
  that installs into `$HOME` (for example deno's) is fine.
- `pip install` or `pip install --user` with the system `python3`. Ubuntu
  blocks it (PEP 668, "externally-managed-environment"). Do not pass
  `--break-system-packages`. Use uv or a venv.

## Examples

**Update yt-dlp** (YouTube changes often, an old yt-dlp fails):

```bash
uv tool upgrade yt-dlp && yt-dlp --version
```

**A Python library for a script:**

```bash
~/venv/bin/python -c "import rapidfuzz" 2>/dev/null \
  || uv pip install --python ~/venv/bin/python rapidfuzz
~/venv/bin/python script.py
```

**A Node CLI:**

```bash
command -v mmdc || npm install -g @mermaid-js/mermaid-cli
mmdc -i diagram.mmd -o diagram.png
```

**A missing Debian tool** (cloud computer):

```bash
apt-user-install cowsay
export PATH="$HOME/.local/apt/usr/bin:$HOME/.local/apt/usr/games:$HOME/.local/apt/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/apt/usr/lib/x86_64-linux-gnu:$HOME/.local/apt/usr/lib:$HOME/.local/apt/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cowsay hello
```

A new login shell finds `~/.local/apt` by itself. The `export` lines make
it work in the shell that is already open. Each `run_command` is a new
shell, so put the `export` lines in front of the command in the same call.
If the program starts but says a library is missing (`error while loading
shared libraries`), run `apt-user-install` for that library package too.
