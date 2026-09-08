#!/usr/bin/env bash
# Assemble a loadable add-on for one browser. No bundler, no npm: the files that
# ship are the files in src/, which is also what keeps a Mozilla source review
# short.
set -euo pipefail

target="${1:-chrome}"
root="$(cd "$(dirname "$0")" && pwd)"
out="$root/dist/$target"

case "$target" in
  chrome|firefox) ;;
  *) echo "usage: $0 [chrome|firefox]" >&2; exit 2 ;;
esac

rm -rf "$out"
mkdir -p "$out"
cp -rf "$root/src" "$out/src"
cp -rf "$root/icons" "$out/icons"
cp -f "$root/manifest.$target.json" "$out/manifest.json"

echo "$out"
echo
case "$target" in
  chrome)
    echo "Load it: chrome://extensions -> Developer mode -> Load unpacked -> $out"
    echo "Then register the bridge with the id Chrome shows:"
    echo "  ../tools/cowork-browser-bridge/install_host_manifest.py --chrome-id <id>"
    ;;
  firefox)
    echo "Load it: about:debugging#/runtime/this-firefox -> Load Temporary Add-on -> $out/manifest.json"
    echo "Then: ../tools/cowork-browser-bridge/install_host_manifest.py"
    ;;
esac
