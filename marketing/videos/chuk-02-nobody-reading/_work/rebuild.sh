#!/usr/bin/env bash
# Regenerate frames, re-assemble index.html, re-inject transitions, lint.
set -e
cd "$(dirname "$0")/.."
S=~/.claude/skills/product-launch-video/scripts
python3 _work/build_frames.py >/dev/null
node $S/assemble-index.mjs --storyboard ./STORYBOARD.md --hyperframes . --audio-meta ./audio_meta.json 2>&1 | grep -E "total|✗|warn" || true
node $S/transitions.mjs inject --storyboard ./STORYBOARD.md --hyperframes . 2>&1 | grep -E "✓|✗" || true
node $S/transitions.mjs verify --storyboard ./STORYBOARD.md --index ./index.html 2>&1 | grep -E "✓|✗" || true
npx hyperframes lint 2>&1 | grep -E "error|warning|✗|⚠" | tail -20
