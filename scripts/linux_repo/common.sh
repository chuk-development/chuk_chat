# Shared values for the Linux packages and the apt/dnf repository.
# Source this file; do not run it.
#
# REPO_BASE_URL is the public address of the repository (GitHub Pages of
# chuk-development/chuk_chat). The end-to-end test sets it to a local
# address. Every file that names the repository comes from the functions
# below, so the .deb, the .rpm and the web site always agree.

: "${REPO_BASE_URL:=https://chuk-development.github.io/chuk_chat}"
REPO_BASE_URL="${REPO_BASE_URL%/}"

# Fingerprint of the signing key. build_repo.sh refuses to sign with any
# other key. Change it only together with chuk-chat-repo-key.asc (see
# "Key rotation" in docs/LINUX_BUILDS.md).
REPO_KEY_FPR="AB7CA4E20BD8247A92758436B97C16390DC1BF79"

LINUX_REPO_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PUBLIC_KEY="$LINUX_REPO_DIR/chuk-chat-repo-key.asc"

# Marker line. The .deb removes the apt source on uninstall only when the
# file carries this line, so it never deletes a file it did not write.
APT_SOURCES_MARKER="# Managed by the chuk-chat package."

# write_apt_sources [suite] -> deb822 source on stdout.
write_apt_sources() {
  local suite="${1:-stable}"
  cat <<EOF
$APT_SOURCES_MARKER
# The package adds this file when it is installed and removes it when it
# is removed. To stop the package from adding it again, put the line
# "repo=no" into /etc/default/chuk-chat. For pre-releases, set
# "Suites: beta".
Types: deb
URIs: $REPO_BASE_URL/deb
Suites: $suite
Components: main
Signed-By: /usr/share/keyrings/chuk-chat.gpg
EOF
}

# write_dnf_repo -> /etc/yum.repos.d/chuk-chat.repo on stdout.
write_dnf_repo() {
  cat <<EOF
# Chuk Chat package repository. The chuk-chat package owns this file.
# To stop updates from this repository, set enabled=0 below.
[chuk-chat]
name=Chuk Chat
baseurl=$REPO_BASE_URL/rpm/stable/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$REPO_BASE_URL/chuk-chat.asc
metadata_expire=6h

[chuk-chat-beta]
name=Chuk Chat (pre-releases)
baseurl=$REPO_BASE_URL/rpm/beta/\$basearch
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=$REPO_BASE_URL/chuk-chat.asc
metadata_expire=6h
EOF
}

# pkg_version_from_tag v1.0.113-pre.3 -> 1.0.113~pre.3 ; v1.0.114 -> 1.0.114
# The tilde sorts before the final release in dpkg and rpm, so
# 1.0.113~pre.3 < 1.0.113 and the final release upgrades a pre-release.
pkg_version_from_tag() {
  local tag="${1#v}"
  case "$tag" in
    *-pre.*) printf '%s~pre.%s\n' "${tag%%-pre.*}" "${tag##*-pre.}" ;;
    *) printf '%s\n' "$tag" ;;
  esac
}
