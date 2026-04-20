#!/usr/bin/env bash
#
# Builds a self-contained JS bundle of @excalidraw/excalidraw + react +
# react-dom and copies it, together with its CSS, into
# assets/excalidraw/. The WebView shell at assets/excalidraw/index.html
# then loads ./bundle.js and renders the Excalidraw React component
# fully offline.
#
# Re-run this script whenever you want to pick up a newer Excalidraw /
# React release — it pins via the npm install step, then commits the
# built bundle into the repo so end users never need Node to run the app.
#
# Usage:
#   scripts/build_excalidraw_bundle.sh             # reproducible install
#   EXCALIDRAW_VERSION=0.19.0 REACT_VERSION=19.3.0 \
#     scripts/build_excalidraw_bundle.sh           # upgrade pins
#
# Requires: node >= 18, npm.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT_DIR/assets/excalidraw"
WORK_DIR="$(mktemp -d -t chuk-excalidraw-build-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

EXCALIDRAW_VERSION="${EXCALIDRAW_VERSION:-0.18.0}"
REACT_VERSION="${REACT_VERSION:-19.2.5}"
REACT_DOM_VERSION="${REACT_DOM_VERSION:-19.2.5}"

mkdir -p "$ASSET_DIR"

echo "==> Work dir: $WORK_DIR"
echo "==> Versions: @excalidraw/excalidraw@$EXCALIDRAW_VERSION, react@$REACT_VERSION, react-dom@$REACT_DOM_VERSION"

cd "$WORK_DIR"

cat > package.json <<JSON
{
  "name": "chuk-excalidraw-bundle",
  "private": true,
  "version": "0.0.0",
  "type": "module"
}
JSON

npm install --silent --no-audit --no-fund --prefer-offline=false \
  "@excalidraw/excalidraw@$EXCALIDRAW_VERSION" \
  "react@$REACT_VERSION" \
  "react-dom@$REACT_DOM_VERSION" \
  "esbuild@^0.24.0"

cat > entry.jsx <<'JS'
import React from 'react';
import { createRoot } from 'react-dom/client';
import {
  Excalidraw,
  getNonDeletedElements,
  MIME_TYPES,
  restore,
} from '@excalidraw/excalidraw';

const root = createRoot(document.getElementById('root'));

/** Mount the scene on a stable key so React fully remounts on updates. */
function Mount({ scene, nonce, viewMode }) {
  const key = `scene-${nonce}`;
  const initialData = scene
    ? {
        elements: scene.elements ?? [],
        appState: {
          ...(scene.appState ?? {}),
          viewModeEnabled: viewMode === 'readOnly',
          zenModeEnabled: false,
          gridSize: scene.appState?.gridSize ?? null,
          theme: scene.appState?.theme ?? 'light',
        },
        files: scene.files ?? {},
        scrollToContent: true,
      }
    : null;
  return React.createElement(
    Excalidraw,
    {
      key,
      initialData,
      viewModeEnabled: viewMode === 'readOnly',
      zenModeEnabled: false,
      UIOptions: {
        canvasActions: {
          saveToActiveFile: false,
          loadScene: false,
          export: false,
        },
      },
    },
  );
}

let current = { scene: null, nonce: 0, viewMode: 'readOnly' };

function render() {
  root.render(React.createElement(Mount, current));
}

function post(message) {
  const encoded = JSON.stringify(message);
  try {
    if (window.chukBridge && typeof window.chukBridge.post === 'function') {
      window.chukBridge.post(encoded);
    } else if (window.parent && window.parent !== window) {
      window.parent.postMessage(encoded, '*');
    }
  } catch (_) {
    // bridge not ready yet; renderer state still updates below.
  }
}

/**
 * Public API the native host calls.
 *
 * - setScene(rawJson): replace the scene. Accepts the `.excalidraw` file
 *   shape (object with `elements` + `appState`) or a pre-parsed object.
 * - setViewMode('readOnly' | 'edit'): toggle interactive editing.
 */
window.chukExcalidraw = {
  setScene(raw) {
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      const restored = restore(parsed, null, null);
      current = {
        scene: {
          elements: getNonDeletedElements(restored.elements ?? []),
          appState: restored.appState ?? {},
          files: restored.files ?? {},
        },
        nonce: current.nonce + 1,
        viewMode: current.viewMode,
      };
      render();
      post({ type: 'scene-loaded', elementCount: current.scene.elements.length });
    } catch (err) {
      post({ type: 'error', message: String(err && err.message ? err.message : err) });
    }
  },
  setViewMode(mode) {
    current = { ...current, viewMode: mode === 'edit' ? 'edit' : 'readOnly', nonce: current.nonce + 1 };
    render();
  },
  MIME_TYPES,
};

// Handle postMessage from web iframe parent.
window.addEventListener('message', (evt) => {
  let data = evt.data;
  if (typeof data === 'string') {
    try { data = JSON.parse(data); } catch (_) { return; }
  }
  if (!data || typeof data !== 'object') return;
  if (data.type === 'scene' && data.payload) {
    window.chukExcalidraw.setScene(data.payload);
  } else if (data.type === 'viewMode') {
    window.chukExcalidraw.setViewMode(data.mode);
  }
});

// Initial render so the canvas is visible before any scene arrives.
render();
post({ type: 'ready' });
JS

cat > shim.js <<'JS'
// The Excalidraw npm package expects `process.env.NODE_ENV` and a few
// other Node-isms at runtime. Provide minimal shims for the browser.
globalThis.process = globalThis.process || {};
globalThis.process.env = globalThis.process.env || { NODE_ENV: 'production' };
JS

echo "==> Running esbuild"
# Stub @excalidraw/mermaid-to-excalidraw: ~1.8 MB of mermaid parsing that
# Excalidraw only needs for the "Paste Mermaid" dialog, which we don't
# expose in read-only rendering. Returning empty arrays keeps the feature
# paths in Excalidraw happy without pulling in the mermaid parser.
mkdir -p stubs
cat > stubs/mermaid-to-excalidraw.js <<'JS'
export function graphToExcalidraw() { return { elements: [], files: {} }; }
export async function parseMermaidToExcalidraw() { return { elements: [], files: {} }; }
export default { graphToExcalidraw, parseMermaidToExcalidraw };
JS

node <<'NODE'
import('esbuild').then(async ({ build }) => {
  await build({
    entryPoints: ['entry.jsx'],
    bundle: true,
    format: 'iife',
    target: 'es2020',
    minify: true,
    treeShaking: true,
    sourcemap: false,
    outfile: 'bundle.js',
    loader: { '.js': 'jsx', '.jsx': 'jsx' },
    jsx: 'automatic',
    define: { 'process.env.NODE_ENV': JSON.stringify('production') },
    inject: ['shim.js'],
    alias: {
      '@excalidraw/mermaid-to-excalidraw': './stubs/mermaid-to-excalidraw.js',
    },
    legalComments: 'none',
    logLevel: 'info',
  });
  process.exit(0);
}).catch((err) => { console.error(err); process.exit(1); });
NODE

# Excalidraw ships a standalone CSS file — copy it beside the JS bundle.
EXCALIDRAW_CSS="node_modules/@excalidraw/excalidraw/dist/prod/index.css"
if [[ ! -f "$EXCALIDRAW_CSS" ]]; then
  echo "!! Excalidraw CSS not found at $EXCALIDRAW_CSS" >&2
  exit 1
fi

BUNDLE_SIZE_BYTES="$(wc -c < bundle.js)"
CSS_SIZE_BYTES="$(wc -c < "$EXCALIDRAW_CSS")"
TOTAL_MB="$(awk -v b="$BUNDLE_SIZE_BYTES" -v c="$CSS_SIZE_BYTES" 'BEGIN { printf "%.2f", (b+c)/1048576 }')"
echo "==> bundle.js: $BUNDLE_SIZE_BYTES bytes"
echo "==> bundle.css: $CSS_SIZE_BYTES bytes"
echo "==> total (js+css): ${TOTAL_MB} MB"

install -m 0644 bundle.js "$ASSET_DIR/bundle.js"
install -m 0644 "$EXCALIDRAW_CSS" "$ASSET_DIR/bundle.css"

# Fonts. bundle.css uses @font-face url("./fonts/Assistant/...") for the
# UI font, and Excalidraw scenes with `fontFamily:1` (hand-drawn, the
# default) need Excalifont at render time. We deliberately skip the
# other font families (Cascadia, Nunito, Virgil, Xiaolai, …) to stay
# under the 5 MB asset budget; the browser falls back to the system
# sans-serif for those, which is acceptable for read-only preview.
FONT_SRC_ROOT="node_modules/@excalidraw/excalidraw/dist/prod/fonts"
for family in Assistant Excalifont; do
  src="$FONT_SRC_ROOT/$family"
  if [[ ! -d "$src" ]]; then
    echo "!! Missing font family: $src" >&2
    exit 1
  fi
  dest="$ASSET_DIR/fonts/$family"
  mkdir -p "$dest"
  # Clear stale files from previous builds so removed subsets don't linger.
  rm -f "$dest"/*.woff2
  install -m 0644 "$src"/*.woff2 "$dest/"
done
FONT_BYTES="$(du -sb "$ASSET_DIR/fonts" | awk '{print $1}')"
echo "==> fonts/: $FONT_BYTES bytes"

TOTAL_BYTES=$((BUNDLE_SIZE_BYTES + CSS_SIZE_BYTES + FONT_BYTES))
TOTAL_MB_FINAL="$(awk -v b="$TOTAL_BYTES" 'BEGIN { printf "%.2f", b/1048576 }')"
echo "==> grand total (js+css+fonts): ${TOTAL_MB_FINAL} MB"

cat > "$ASSET_DIR/VERSIONS.txt" <<META
Built on: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Excalidraw: $EXCALIDRAW_VERSION
React: $REACT_VERSION
React-DOM: $REACT_DOM_VERSION
bundle.js size: $BUNDLE_SIZE_BYTES bytes
bundle.css size: $CSS_SIZE_BYTES bytes
fonts size:     $FONT_BYTES bytes
grand total:    $TOTAL_BYTES bytes (${TOTAL_MB_FINAL} MB)
META

echo "==> Wrote $ASSET_DIR/bundle.js, bundle.css, VERSIONS.txt"
echo "==> Done."
