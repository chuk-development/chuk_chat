#!/usr/bin/env bash
# Regenerate frames + audio and re-assemble the index (run from the project root).
set -euo pipefail
S=~/.claude/skills/product-launch-video/scripts
node tools/build-frames.mjs
node tools/make-audio.mjs
node $S/assemble-index.mjs --storyboard ./STORYBOARD.md --hyperframes . | tail -3
node $S/transitions.mjs inject --storyboard ./STORYBOARD.md --hyperframes . | tail -4
node $S/transitions.mjs verify --storyboard ./STORYBOARD.md --index ./index.html
python3 - <<'PY'
import re
p = "index.html"
s = open(p).read()
s = re.sub(r'(data-(?:start|duration)=")(\d+\.\d{4,})"', lambda m: m.group(1) + ("%.3f" % float(m.group(2))).rstrip("0").rstrip(".") + '"', s)
open(p, "w").write(s)
PY
# Every frame paints the same sky. Fading the outgoing frame out as well dims the sky by
# ~25% mid-transition (both layers half transparent over the ground). Keep the outgoing
# frame opaque and let the incoming one dissolve over it.
sed -i -E 's/tl\.to\("(#el-[a-z0-9-]+)", \{ opacity: 0, duration/tl.to("\1", { opacity: 1, duration/' index.html
grep -n 'opacity: 1, duration' index.html | head
