#!/usr/bin/env bash
# Download the .deb and .rpm files that go into the repository from the
# GitHub releases of chuk-development/chuk_chat.
#
#   fetch_release_packages.sh OUTDIR
#
# OUTDIR/stable/  the newest KEEP_STABLE stable releases (default 3)
# OUTDIR/pre/     pre-releases newer than the newest stable (max KEEP_PRE, default 1)
#
# The GitHub releases are the only source of truth: the site is rebuilt
# from them on every run, so nothing is lost when a Pages deploy replaces
# the old site. Needs gh with GH_TOKEN. DRY_RUN=1 prints the selection only.
set -euo pipefail
OUT="${1:?usage: $0 OUTDIR}"
REPO="${GITHUB_REPOSITORY:-chuk-development/chuk_chat}"
KEEP_STABLE="${KEEP_STABLE:-3}"
KEEP_PRE="${KEEP_PRE:-1}"
mkdir -p "$OUT/stable" "$OUT/pre"

# Published (not draft) releases with a plain version tag.
TAGS="$(gh release list --repo "$REPO" --limit 100 --exclude-drafts \
  --json tagName --jq '.[].tagName' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-pre\.[0-9]+)?$' || true)"

STABLE="$(printf '%s\n' "$TAGS" | grep -vE -- '-pre\.' | sort -V | tail -n "$KEEP_STABLE" || true)"
NEWEST_STABLE="$(printf '%s\n' "$STABLE" | tail -n 1)"
# A pre-release counts only when its base version is above the newest stable.
PRE=""
for t in $(printf '%s\n' "$TAGS" | grep -E -- '-pre\.' | sort -V); do
  base="${t%%-pre.*}"
  if [ -z "$NEWEST_STABLE" ] || { [ "$base" != "$NEWEST_STABLE" ] &&
     [ "$(printf '%s\n%s\n' "$base" "$NEWEST_STABLE" | sort -V | tail -1)" = "$base" ]; }; then
    PRE="$PRE $t"
  fi
done
PRE="$(printf '%s\n' $PRE | sed '/^$/d' | tail -n "$KEEP_PRE" || true)"

fetch() { # tag channel
  local tag="$1" channel="$2" pattern
  for pattern in "chuk_chat-$tag-linux-amd64.deb" "chuk_chat-$tag-linux-arm64.deb" \
                 "chuk_chat-$tag-linux-x86_64.rpm" "chuk_chat-$tag-linux-aarch64.rpm"; do
    if gh release download "$tag" --repo "$REPO" --pattern "$pattern" \
         --dir "$OUT/$channel" --clobber 2>/dev/null; then
      echo "  $channel: $pattern"
    fi
  done
}

echo "stable releases: $(echo $STABLE)"
echo "pre-releases:    $(echo $PRE)"
# DRY_RUN=1: print the selection only, download nothing.
[ "${DRY_RUN:-0}" = 1 ] && exit 0
for t in $STABLE; do fetch "$t" stable; done
for t in $PRE; do fetch "$t" pre; done
