#!/usr/bin/env bash
# End-to-end test of the apt/dnf repository, in Docker only.
#
#   GNUPG_SRC=DIR PASSPHRASE_FILE=FILE scripts/linux_repo/test_repo_e2e.sh [REAL_DEB]
#
# GNUPG_SRC holds the repository signing key (secret part), PASSPHRASE_FILE
# its passphrase. REAL_DEB (optional) is a real release .deb; it goes into
# the stable suite next to the dummy packages, to prove that release assets
# index and download correctly.
#
# The test builds small dummy packages with make_deb.sh / make_rpm.sh (the
# same scripts CI uses), builds and signs the repository with
# build_repo.sh, serves it on 127.0.0.1:$PORT (default 18765) and then, in debian:stable-slim,
# ubuntu:24.04 and fedora:latest containers:
#   - install the package from the repository (docs flow) and upgrade it,
#   - install the .deb/.rpm file once and check that it adds the repository,
#     that "--only-upgrade" / "dnf upgrade" then finds the next version and
#     that removing the package removes the repository again,
#   - change InRelease / Packages / repomd.xml and check that apt and dnf
#     refuse the changed metadata.
# Nothing touches the host system. Work files go to _scratch/linux-repo-test.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$ROOT/_scratch/linux-repo-test"
PORT="${PORT:-18765}"
URL="http://127.0.0.1:$PORT"
REAL_DEB="${1:-}"
: "${GNUPG_SRC:?set GNUPG_SRC}" "${PASSPHRASE_FILE:?set PASSPHRASE_FILE}"
BUILDER=chuk-repo-builder:test

rm -rf "$W"; mkdir -p "$W"
cp -a "$GNUPG_SRC" "$W/gnupg"; chmod 700 "$W/gnupg"
cp "$PASSPHRASE_FILE" "$W/pass"; chmod 600 "$W/pass"

if ! docker image inspect "$BUILDER" >/dev/null 2>&1; then
  docker build -q -t "$BUILDER" - <<'EOF' >/dev/null
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dpkg-dev apt-utils rpm createrepo-c gnupg gpgv xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
EOF
fi

# Run a command in the builder as the calling user, repo at /src.
b() {
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/w -e TMPDIR=/w \
    -e GNUPGHOME=/w/gnupg -e GPG_PASSPHRASE_FILE=/w/pass -e REPO_BASE_URL="$URL" \
    -v "$ROOT:/src:ro" -v "$W:/w" -w /w "$BUILDER" bash -c "$1"
}

dummy_bundle() { # dir version
  mkdir -p "$1/lib" "$1/data"
  printf '#!/bin/sh\necho "chuk_chat dummy %s"\n' "$2" > "$1/chuk_chat"
  chmod 755 "$1/chuk_chat"
}
make_pkgs() { # version channel
  local v="$1" ch="$2"
  dummy_bundle "$W/bundle-$v" "$v"
  mkdir -p "$W/in/$ch"
  b "/src/scripts/linux_repo/make_deb.sh --bundle /w/bundle-$v --arch amd64 --version '$v' --depends '' --out /w/in/$ch/chuk-chat_${v}_amd64.deb
     /src/scripts/linux_repo/make_deb.sh --bundle /w/bundle-$v --arch arm64 --version '$v' --depends '' --out /w/in/$ch/chuk-chat_${v}_arm64.deb
     /src/scripts/linux_repo/make_rpm.sh --bundle /w/bundle-$v --arch x86_64 --version '$v' --requires '' --out /w/in/$ch/chuk-chat-${v}.x86_64.rpm"
}
build_site() { b "/src/scripts/linux_repo/build_repo.sh --in /w/in --out /w/site"; }

echo "== build packages and repository (1.0.200, 1.0.201~pre.1)"
make_pkgs 1.0.200 stable
make_pkgs '1.0.201~pre.1' pre
if [ -n "$REAL_DEB" ]; then cp "$REAL_DEB" "$W/in/stable/"; fi
build_site

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/site" >"$W/http.log" 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { cat "$W/http.log"; echo "port $PORT is busy, set PORT=" >&2; exit 1; }

# Publish 1.0.202 (stable) and 1.0.203~pre.1 into the running server.
publish_next() {
  echo "-- publish 1.0.202 and 1.0.203~pre.1"
  make_pkgs 1.0.202 stable
  rm -f "$W/in/pre/"*
  make_pkgs '1.0.203~pre.1' pre
  build_site
}
reset_site() {
  rm -rf "$W/in"
  make_pkgs 1.0.200 stable
  make_pkgs '1.0.201~pre.1' pre
  if [ -n "$REAL_DEB" ]; then cp "$REAL_DEB" "$W/in/stable/"; fi
  build_site
}

# Long-lived test containers. $W is mounted at /w (the site is /w/site;
# the parent is mounted because build_repo.sh replaces the site folder).
start() { # image -> container id
  docker run -d --label chuk-repo-e2e=1 --network host -v "$W:/w:ro" "$1" sleep infinity
}
start_apt() { local id; id="$(start "$1")"; x "$id" "$APT_INIT"; echo "$id"; }
start_dnf() { local id; id="$(start "$1")"; x "$id" "$DNF_INIT"; echo "$id"; }
x() { docker exec "$1" bash -euo pipefail -c "$2"; }
cleanup() {
  kill "$HTTP_PID" 2>/dev/null || true
  docker ps -aq --filter label=chuk-repo-e2e=1 | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Remove the distribution sources once per container: the test must not
# download anything from the internet, only from the local repository.
APT_INIT='rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/sources.list'
APT_PREP='export DEBIAN_FRONTEND=noninteractive
ver() { dpkg-query -W -f="\${Version}" chuk-chat; }
quiet() { "$@" >/tmp/o 2>&1 || { cat /tmp/o; return 1; }; }'

apt_test() { # image
  local img="$1" a b
  reset_site
  echo "== $img: docs flow (keyring + sources file, apt install, --only-upgrade)"
  a="$(start_apt "$img")"
  x "$a" "$APT_PREP
    cp /w/site/chuk-chat.gpg /usr/share/keyrings/chuk-chat.gpg
    cp /w/site/chuk-chat.sources /etc/apt/sources.list.d/chuk-chat.sources
    quiet apt-get update
    quiet apt-get install -y chuk-chat
    echo \"installed: \$(ver)\"; chuk-chat
    [ \$(ls /etc/apt/sources.list.d | wc -l) = 1 ] && echo 'one source file, no duplicate: ok'"
  if [ -n "$REAL_DEB" ]; then
    x "$a" "$APT_PREP
      cd /root && quiet apt-get download chuk-chat=1.0.114
      ls -la /root/chuk-chat_1.0.114_amd64.deb && echo 'real release .deb downloads with a verified hash: ok'"
  fi

  echo "== $img: .deb file first (postinst adds the repo)"
  b="$(start_apt "$img")"
  x "$b" "$APT_PREP
    quiet apt-get install -y /w/in/stable/chuk-chat_1.0.200_amd64.deb
    echo \"installed from file: \$(ver)\"
    test -f /etc/apt/sources.list.d/chuk-chat.sources && echo 'postinst added the source: ok'
    test -f /usr/share/keyrings/chuk-chat.gpg && echo 'package ships the keyring: ok'
    quiet apt-get install -y --reinstall /w/in/stable/chuk-chat_1.0.200_amd64.deb
    [ \$(ls /etc/apt/sources.list.d | wc -l) = 1 ] && echo 'reinstall is idempotent: ok'
    quiet apt-get update && echo 'apt update with the package keyring: ok'"

  publish_next

  for id in "$a" "$b"; do
    x "$id" "$APT_PREP
      quiet apt-get update
      quiet apt-get install -y --only-upgrade chuk-chat
      echo \"after apt install --only-upgrade: \$(ver)\"; [ \"\$(ver)\" = 1.0.202 ]"
  done
  x "$b" "$APT_PREP
    quiet apt-get remove -y chuk-chat
    test ! -e /etc/apt/sources.list.d/chuk-chat.sources && test ! -e /usr/share/keyrings/chuk-chat.gpg \
      && echo 'remove deletes the source and the keyring: ok'
    quiet apt-get update && echo 'apt update clean after remove: ok'"
  docker rm -f "$a" "$b" >/dev/null
}

opt_out_test() {
  echo "== debian: repo=no in /etc/default/chuk-chat keeps the source away"
  local a; a="$(start_apt debian:stable-slim)"
  x "$a" "$APT_PREP
    echo 'repo=no' > /etc/default/chuk-chat
    quiet apt-get install -y /w/in/stable/chuk-chat_1.0.202_amd64.deb
    test ! -e /etc/apt/sources.list.d/chuk-chat.sources && echo 'opt-out respected: ok'"
  docker rm -f "$a" >/dev/null
}

beta_test() {
  echo "== debian: beta suite offers the pre-release"
  local a; a="$(start_apt debian:stable-slim)"
  x "$a" "$APT_PREP
    cp /w/site/chuk-chat.gpg /usr/share/keyrings/chuk-chat.gpg
    sed 's/^Suites: stable/Suites: beta/' /w/site/chuk-chat.sources > /etc/apt/sources.list.d/chuk-chat.sources
    quiet apt-get update
    apt-cache policy chuk-chat > /tmp/p; sed -n '1,3p' /tmp/p
    grep -q 'Candidate: 1.0.203~pre.1' /tmp/p && echo 'beta candidate is the pre-release: ok'"
  docker rm -f "$a" >/dev/null
}

tamper_test() {
  local a ir p
  a="$(start_apt debian:stable-slim)"
  x "$a" "$APT_PREP
    cp /w/site/chuk-chat.gpg /usr/share/keyrings/chuk-chat.gpg
    cp /w/site/chuk-chat.sources /etc/apt/sources.list.d/"

  echo "== tamper: changed InRelease must be refused"
  ir="$W/site/deb/dists/stable/InRelease"
  cp "$ir" "$W/InRelease.bak"
  sed -i 's/^Origin: Chuk Chat/Origin: Evil/' "$ir"
  x "$a" "rm -rf /var/lib/apt/lists/*
    if apt-get update >/tmp/o 2>&1 && ! grep -qE '^(W|E|Err):' /tmp/o; then cat /tmp/o; exit 1; fi
    grep -E '^(W|E|Err)|signature|Signature' /tmp/o | head -3
    if apt-cache policy chuk-chat | grep -q Candidate:.*1; then echo 'package list still used'; exit 1; fi
    echo 'tampered InRelease refused: ok'"
  cp "$W/InRelease.bak" "$ir"

  echo "== tamper: changed Packages (hash mismatch) must be refused"
  p="$W/site/deb/dists/stable/main/binary-amd64"
  cp -a "$p" "$W/binary-amd64.bak"
  sed -i 's/^Description: .*/Description: evil/' "$p/Packages"
  gzip -9nkf "$p/Packages"; xz -9kf "$p/Packages"
  x "$a" "rm -rf /var/lib/apt/lists/*
    apt-get update >/tmp/o 2>&1 || true
    if apt-cache show chuk-chat 2>/dev/null | grep -q 'Description: evil'; then cat /tmp/o; exit 1; fi
    grep -iE 'hash|mismatch|^E:' /tmp/o | head -2; echo 'tampered Packages refused: ok'"
  rm -rf "$p"; mv "$W/binary-amd64.bak" "$p"
  docker rm -f "$a" >/dev/null
}

DNF_INIT='rm -f /etc/yum.repos.d/*.repo'
DNF_PREP='ver() { rpm -q --qf "%{VERSION}" chuk-chat; }
quiet() { "$@" >/tmp/o 2>&1 || { cat /tmp/o; return 1; }; }'

dnf_test() {
  local a b r
  rm -rf "$W/in"; make_pkgs 1.0.200 stable; build_site
  echo "== fedora: docs flow (rpm --import, repo file, dnf install, dnf upgrade)"
  a="$(start_dnf fedora:latest)"
  x "$a" "$DNF_PREP
    rpm --import /w/site/chuk-chat.asc
    cp /w/site/chuk-chat.repo /etc/yum.repos.d/chuk-chat.repo
    quiet dnf -y makecache --repo=chuk-chat && echo 'makecache with repo_gpgcheck=1: ok'
    quiet dnf -y install --repo=chuk-chat chuk-chat
    echo \"installed: \$(ver)\"; chuk-chat
    rpm -Kv /w/site/rpm/stable/x86_64/chuk-chat-1.0.200-1.x86_64.rpm | grep -i 'signature'"

  echo "== fedora: .rpm file first (the package adds the repo)"
  b="$(start_dnf fedora:latest)"
  x "$b" "$DNF_PREP
    quiet dnf -y install /w/in/stable/chuk-chat-1.0.200.x86_64.rpm
    echo \"installed from file: \$(ver)\"
    test -f /etc/yum.repos.d/chuk-chat.repo && echo 'package added the repo file: ok'"

  echo "-- publish 1.0.202"
  make_pkgs 1.0.202 stable; build_site

  for id in "$a" "$b"; do
    x "$id" "$DNF_PREP
      quiet dnf -y --refresh upgrade --repo=chuk-chat chuk-chat
      echo \"after dnf upgrade: \$(ver)\"; [ \"\$(ver)\" = 1.0.202 ]"
  done
  x "$b" "quiet() { \"\$@\" >/tmp/o 2>&1 || { cat /tmp/o; return 1; }; }
    quiet dnf -y remove chuk-chat
    test ! -e /etc/yum.repos.d/chuk-chat.repo && echo 'remove deletes the repo file: ok'"

  echo "== tamper: changed repomd.xml must be refused"
  r="$W/site/rpm/stable/x86_64/repodata/repomd.xml"
  cp "$r" "$W/repomd.bak"
  sed -i 's#<revision>#<revision>9#' "$r"
  # dnf5 does not stop on a bad repomd signature; it drops the repository
  # (skip_if_unavailable) and goes on. So check that the metadata is not used.
  x "$a" "rpm -e chuk-chat; cp /w/site/chuk-chat.repo /etc/yum.repos.d/; dnf clean all >/dev/null 2>&1
    dnf -y makecache --repo=chuk-chat >/tmp/o 2>&1 || true
    grep -qiE 'signature verification error|bad pgp signature' /tmp/o || { cat /tmp/o; exit 1; }
    grep -iE 'signature' /tmp/o | head -2
    if dnf -y install --repo=chuk-chat chuk-chat >>/tmp/o 2>&1; then cat /tmp/o; exit 1; fi
    echo 'tampered repomd.xml refused, no package offered: ok'"
  cp "$W/repomd.bak" "$r"

  echo "== tamper: changed .rpm must be refused"
  local f; f="$(ls "$W"/site/rpm/stable/x86_64/chuk-chat-1.0.202-*.rpm)"
  cp "$f" "$W/rpm.bak"
  printf 'X' | dd of="$f" bs=1 seek=$(( $(stat -c %s "$f") - 200 )) conv=notrunc status=none
  x "$a" "dnf clean all >/dev/null 2>&1
    if dnf -y install --repo=chuk-chat chuk-chat-1.0.202 >/tmp/o 2>&1; then cat /tmp/o; exit 1; fi
    grep -iE 'checksum|digest|signature|mismatch|fail' /tmp/o | head -2; echo 'tampered .rpm refused: ok'"
  cp "$W/rpm.bak" "$f"
  docker rm -f "$a" "$b" >/dev/null
}

apt_test debian:stable-slim
apt_test "${UBUNTU_IMAGE:-ubuntu:24.04}"
opt_out_test
beta_test
tamper_test
dnf_test
echo "== all end-to-end checks passed"
