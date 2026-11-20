#!/usr/bin/env bash
# Build the signed apt + dnf repository (the GitHub Pages site).
#
#   build_repo.sh --in PKGDIR --out SITEDIR
#
# PKGDIR/stable/  .deb and .rpm files of stable releases
# PKGDIR/pre/     .deb and .rpm files of pre-releases (may be empty)
#
# Result (SITEDIR):
#   chuk-chat.asc  chuk-chat.gpg  chuk-chat.sources  chuk-chat.repo  index.html
#   deb/dists/{stable,beta}/{InRelease,Release,Release.gpg,main/binary-*/Packages*}
#   deb/pool/main/c/chuk-chat/*.deb
#   rpm/{stable,beta}/{x86_64,aarch64}/{*.rpm,repodata/repomd.xml(.asc)}
#
# Suites: "stable" holds every stable package from PKGDIR/stable. "beta"
# holds the newest stable package per architecture plus the pre-releases.
#
# Signing: the key with fingerprint REPO_KEY_FPR (common.sh) must be in
# GNUPGHOME. GPG_PASSPHRASE_FILE names a file with its passphrase. The
# script refuses any other key, so a wrong secret cannot sign the repo.
#
# Needs: gpg, gpgv, dpkg-deb, apt-ftparchive, rpm, rpmsign, createrepo_c.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IN="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --in) IN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$IN" ] && [ -n "$OUT" ] || { echo "usage: $0 --in PKGDIR --out SITEDIR" >&2; exit 2; }
mkdir -p "$IN/stable" "$IN/pre"

# GitHub Pages limits: 100 MB per file, 1 GB per site.
MAX_FILE_BYTES=$((100 * 1000 * 1000))
MAX_SITE_BYTES=$((950 * 1000 * 1000))
DEB_ARCHES="amd64 arm64"
RPM_ARCHES="x86_64 aarch64"

for tool in gpg gpgv dpkg-deb apt-ftparchive rpm rpmsign createrepo_c sha256sum; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

GPG_ARGS=(--batch --yes --no-tty --pinentry-mode loopback --local-user "$REPO_KEY_FPR" --digest-algo SHA512)
[ -n "${GPG_PASSPHRASE_FILE:-}" ] && GPG_ARGS+=(--passphrase-file "$GPG_PASSPHRASE_FILE")

# The signing key must be the committed public key, and the secret part
# must be present.
committed_fpr="$(gpg --batch --with-colons --show-keys "$REPO_PUBLIC_KEY" | awk -F: '$1=="fpr"{print $10; exit}')"
[ "$committed_fpr" = "$REPO_KEY_FPR" ] || {
  echo "chuk-chat-repo-key.asc ($committed_fpr) does not match REPO_KEY_FPR ($REPO_KEY_FPR)" >&2; exit 1; }
gpg --batch --with-colons --list-secret-keys "$REPO_KEY_FPR" >/dev/null 2>&1 || {
  echo "secret key $REPO_KEY_FPR is not in GNUPGHOME" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(CDPATH= cd "$OUT" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-$PWD}/repowork.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Keyring for apt's signed-by (binary) and for gpgv checks below.
cp "$REPO_PUBLIC_KEY" "$OUT/chuk-chat.asc"
gpg --batch --yes --dearmor -o "$OUT/chuk-chat.gpg" < "$REPO_PUBLIC_KEY"
write_apt_sources stable > "$OUT/chuk-chat.sources"
write_dnf_repo > "$OUT/chuk-chat.repo"

# ── apt ─────────────────────────────────────────────────────────────────
POOL_REL="pool/main/c/chuk-chat"
mkdir -p "$OUT/deb/$POOL_REL"
declare -A DEB_SEEN=()          # name_version_arch -> sha256
declare -A DEB_STANZAS=()       # suite/arch -> file with stanzas
declare -A NEWEST_STABLE_DEB=() # arch -> "version<TAB>stanza file"

add_deb() { # file channel
  local f="$1" channel="$2" pkg ver arch base dest sha stanza
  pkg="$(dpkg-deb -f "$f" Package)"
  ver="$(dpkg-deb -f "$f" Version)"
  arch="$(dpkg-deb -f "$f" Architecture)"
  [ "$pkg" = chuk-chat ] || { echo "skip $f: package $pkg is not chuk-chat" >&2; return 0; }
  case " $DEB_ARCHES " in *" $arch "*) ;; *) echo "skip $f: arch $arch" >&2; return 0 ;; esac
  if [ "$channel" = pre ] && [ "${ver#*~pre.}" = "$ver" ]; then
    echo "skip $f: pre-release with version $ver (no ~pre.N, would clash with the final release)" >&2
    return 0
  fi
  if [ "$channel" = stable ] && [ "${ver#*~}" != "$ver" ]; then
    echo "skip $f: stable channel with version $ver" >&2; return 0
  fi
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  base="${pkg}_${ver}_${arch}.deb"
  if [ -n "${DEB_SEEN[$base]:-}" ]; then
    [ "${DEB_SEEN[$base]}" = "$sha" ] && return 0
    echo "two different files claim $base" >&2; exit 1
  fi
  DEB_SEEN[$base]="$sha"
  dest="$OUT/deb/$POOL_REL/$base"
  cp "$f" "$dest"
  stanza="$WORK/stanza.$base"
  {
    dpkg-deb -f "$dest"
    echo "Filename: $POOL_REL/$base"
    echo "Size: $(stat -c %s "$dest")"
    echo "MD5sum: $(md5sum "$dest" | cut -d' ' -f1)"
    echo "SHA1: $(sha1sum "$dest" | cut -d' ' -f1)"
    echo "SHA256: $sha"
    echo
  } > "$stanza"
  if [ "$channel" = stable ]; then
    cat "$stanza" >> "$WORK/deb.stable.$arch"
    local cur="${NEWEST_STABLE_DEB[$arch]:-}"
    if [ -z "$cur" ] || dpkg --compare-versions "$ver" gt "${cur%%	*}"; then
      NEWEST_STABLE_DEB[$arch]="$ver	$stanza"
    fi
  else
    cat "$stanza" >> "$WORK/deb.beta.$arch"
  fi
}

shopt -s nullglob
for f in "$IN"/stable/*.deb; do add_deb "$f" stable; done
for f in "$IN"/pre/*.deb; do add_deb "$f" pre; done
for arch in $DEB_ARCHES; do
  touch "$WORK/deb.stable.$arch" "$WORK/deb.beta.$arch"
  cur="${NEWEST_STABLE_DEB[$arch]:-}"
  [ -n "$cur" ] && cat "${cur#*	}" >> "$WORK/deb.beta.$arch"
done

for suite in stable beta; do
  dist="$OUT/deb/dists/$suite"
  for arch in $DEB_ARCHES; do
    d="$dist/main/binary-$arch"
    mkdir -p "$d"
    cp "$WORK/deb.$suite.$arch" "$d/Packages"
    gzip -9nkf "$d/Packages"
    xz -9kf "$d/Packages"
    printf 'Archive: %s\nComponent: main\nOrigin: Chuk Chat\nLabel: Chuk Chat\nArchitecture: %s\n' \
      "$suite" "$arch" > "$d/Release"
  done
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Chuk Chat" \
    -o APT::FTPArchive::Release::Label="Chuk Chat" \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="$DEB_ARCHES" \
    -o APT::FTPArchive::Release::Components="main" \
    -o APT::FTPArchive::Release::Description="Chuk Chat packages ($suite)" \
    release "$dist" > "$WORK/Release"
  mv "$WORK/Release" "$dist/Release"
  gpg "${GPG_ARGS[@]}" --clearsign -o "$dist/InRelease" "$dist/Release"
  gpg "${GPG_ARGS[@]}" --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"
  gpgv --keyring "$OUT/chuk-chat.gpg" "$dist/InRelease" 2>/dev/null
  gpgv --keyring "$OUT/chuk-chat.gpg" "$dist/Release.gpg" "$dist/Release" 2>/dev/null
done

# ── rpm ─────────────────────────────────────────────────────────────────
# rpmsign reads the passphrase through gpg; loopback mode lets gpg take it
# from the file instead of a pinentry prompt.
SIGN_EXTRA="--batch --no-tty --pinentry-mode loopback --digest-algo SHA512"
[ -n "${GPG_PASSPHRASE_FILE:-}" ] && SIGN_EXTRA="$SIGN_EXTRA --passphrase-file $GPG_PASSPHRASE_FILE"
RPMDB="$WORK/rpmdb"
mkdir -p "$RPMDB"
rpm --dbpath "$RPMDB" --initdb
rpm --dbpath "$RPMDB" --import "$REPO_PUBLIC_KEY"

declare -A RPM_SEEN=()
declare -A NEWEST_STABLE_RPM=() # arch -> "version<TAB>file"
mkdir -p "$WORK/signed"

sign_rpm() { # file -> signed copy path on stdout
  local f="$1" out
  out="$WORK/signed/$(basename "$f")"
  cp "$f" "$out"
  rpmsign --define "__gpg $(command -v gpg)" \
    --define "_gpg_name $REPO_KEY_FPR" \
    --define "_gpg_sign_cmd_extra_args $SIGN_EXTRA" \
    --addsign "$out" >/dev/null
  # Verify with only our key in the rpm database.
  rpm --dbpath "$RPMDB" -K "$out" | grep -qE 'signatures OK|pgp.*OK' || {
    echo "signature check failed for $out" >&2; rpm --dbpath "$RPMDB" -Kv "$out" >&2; exit 1; }
  printf '%s\n' "$out"
}

add_rpm() { # file channel
  local f="$1" channel="$2" name ver arch base signed sha
  name="$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)"
  ver="$(rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null)"
  arch="$(rpm -qp --qf '%{ARCH}' "$f" 2>/dev/null)"
  [ "$name" = chuk-chat ] || { echo "skip $f: package $name is not chuk-chat" >&2; return 0; }
  case " $RPM_ARCHES " in *" $arch "*) ;; *) echo "skip $f: arch $arch" >&2; return 0 ;; esac
  if [ "$channel" = pre ] && [ "${ver#*~pre.}" = "$ver" ]; then
    echo "skip $f: pre-release with version $ver" >&2; return 0
  fi
  if [ "$channel" = stable ] && [ "${ver#*~}" != "$ver" ]; then
    echo "skip $f: stable channel with version $ver" >&2; return 0
  fi
  base="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm' "$f" 2>/dev/null)"
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ -n "${RPM_SEEN[$base]:-}" ]; then
    [ "${RPM_SEEN[$base]}" = "$sha" ] && return 0
    echo "two different files claim $base" >&2; exit 1
  fi
  RPM_SEEN[$base]="$sha"
  signed="$(sign_rpm "$f")"
  if [ "$channel" = stable ]; then
    mkdir -p "$OUT/rpm/stable/$arch"
    cp "$signed" "$OUT/rpm/stable/$arch/$base"
    local cur="${NEWEST_STABLE_RPM[$arch]:-}"
    if [ -z "$cur" ] || [ "$(printf '%s\n%s\n' "${cur%%	*}" "$ver" | sort -V | tail -1)" = "$ver" ]; then
      NEWEST_STABLE_RPM[$arch]="$ver	$signed"
    fi
  else
    mkdir -p "$OUT/rpm/beta/$arch"
    cp "$signed" "$OUT/rpm/beta/$arch/$base"
  fi
}

for f in "$IN"/stable/*.rpm; do add_rpm "$f" stable; done
for f in "$IN"/pre/*.rpm; do add_rpm "$f" pre; done
for arch in $RPM_ARCHES; do
  cur="${NEWEST_STABLE_RPM[$arch]:-}"
  if [ -n "$cur" ]; then
    mkdir -p "$OUT/rpm/beta/$arch"
    f="${cur#*	}"
    cp "$f" "$OUT/rpm/beta/$arch/$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm' "$f" 2>/dev/null)"
  fi
done

for channel in stable beta; do
  for arch in $RPM_ARCHES; do
    d="$OUT/rpm/$channel/$arch"
    mkdir -p "$d"
    # gz metadata: zstd is not readable by older dnf/yum (RHEL 8).
    createrepo_c --quiet --general-compress-type gz "$d"
    gpg "${GPG_ARGS[@]}" --armor --detach-sign -o "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml"
    gpgv --keyring "$OUT/chuk-chat.gpg" "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml" 2>/dev/null
  done
done

# ── landing page ────────────────────────────────────────────────────────
cat > "$OUT/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chuk Chat Linux packages</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}
pre{background:#f2f2f2;padding:.8rem;overflow-x:auto}@media(prefers-color-scheme:dark){body{background:#111;color:#ddd}pre{background:#222}}</style>
</head><body>
<h1>Chuk Chat Linux packages</h1>
<p>Signed apt and dnf repository for <a href="https://chuk.chat">Chuk Chat</a>.
Key fingerprint: <code>$REPO_KEY_FPR</code></p>
<h2>Update an installed copy</h2>
<pre>sudo apt update &amp;&amp; sudo apt install --only-upgrade chuk-chat   # Debian, Ubuntu
sudo dnf upgrade chuk-chat                                       # Fedora, RHEL</pre>
<p>The .deb and .rpm from the GitHub releases add this repository when you
install them, so these commands work after the first install.</p>
<h2>Debian, Ubuntu, Linux Mint</h2>
<pre>sudo curl -fsSLo /usr/share/keyrings/chuk-chat.gpg $REPO_BASE_URL/chuk-chat.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/chuk-chat.sources $REPO_BASE_URL/chuk-chat.sources
sudo apt update
sudo apt install chuk-chat</pre>
<p>Update: <code>sudo apt update &amp;&amp; sudo apt install --only-upgrade chuk-chat</code></p>
<h2>Fedora, RHEL, openSUSE (dnf)</h2>
<pre>sudo rpm --import $REPO_BASE_URL/chuk-chat.asc
sudo curl -fsSLo /etc/yum.repos.d/chuk-chat.repo $REPO_BASE_URL/chuk-chat.repo
sudo dnf install chuk-chat</pre>
<p>Update: <code>sudo dnf upgrade chuk-chat</code></p>
</body></html>
EOF

# ── limits ──────────────────────────────────────────────────────────────
big="$(find "$OUT" -type f -size +"$((MAX_FILE_BYTES / 1000))"k -printf '%s %p\n' | awk -v m="$MAX_FILE_BYTES" '$1>m')"
[ -z "$big" ] || { echo "files over the GitHub Pages limit of 100 MB:" >&2; echo "$big" >&2; exit 1; }
total="$(du -sb "$OUT" | cut -f1)"
[ "$total" -le "$MAX_SITE_BYTES" ] || { echo "site is $total bytes, over $MAX_SITE_BYTES" >&2; exit 1; }
echo "repository built in $OUT ($((total / 1000000)) MB)"
find "$OUT" \( -name '*.deb' -o -name '*.rpm' \) -printf '  %P\n' | sort
