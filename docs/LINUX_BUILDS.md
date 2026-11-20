# Linux Builds with Fastlane

This document explains how to build all Linux distribution formats (Flatpak, AppImage, DEB, RPM) using Fastlane for chuk_chat.

## Overview

chuk_chat supports multiple Linux distribution formats:

| Format | Use Case | Distribution Method |
|--------|----------|-------------------|
| **Flatpak** | Modern sandboxed apps | Flathub, direct install |
| **AppImage** | Universal portable apps | Direct download |
| **DEB** | Debian/Ubuntu systems | APT repositories, direct install |
| **RPM** | Fedora/RHEL systems | DNF/YUM repositories, direct install |

All formats can be built using Fastlane for a consistent development experience.

## Prerequisites

### System Requirements

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev rpm fuse libfuse2 wget file \
  flatpak flatpak-builder \
  ruby-full

# Fedora
sudo dnf install -y \
  clang cmake ninja-build pkg-config gtk3-devel xz-devel \
  libstdc++-devel rpm fuse fuse-libs wget file \
  flatpak flatpak-builder \
  ruby ruby-devel

# Arch
sudo pacman -S \
  clang cmake ninja pkg-config gtk3 xz \
  rpm fuse2 wget file \
  flatpak flatpak-builder \
  ruby
```

### Install Flutter

Follow the [Flutter Linux installation guide](https://docs.flutter.dev/get-started/install/linux).

### Setup Fastlane

```bash
cd linux
bundle install
```

This installs Fastlane and all Ruby dependencies.

## Quick Start

### Build Everything (Full Release)

```bash
# Set environment variables
export SUPABASE_URL="your-supabase-url"
export SUPABASE_ANON_KEY="your-anon-key"

# Or use .env file
cp .env.example .env
# Edit .env with your credentials
source .env

# Build all formats
cd linux
bundle exec fastlane release
```

This will build:
- Flutter Linux binary
- Flatpak package and bundle
- AppImage
- DEB package
- RPM package

**Output files:**
- `chuk_chat-{version}-linux.flatpak`
- `chuk_chat-{version}-x86_64.AppImage`
- `chuk_chat_{version}_amd64.deb`
- `chuk_chat-{version}-1.x86_64.rpm`

## Fastlane Lanes

### Flatpak Lanes

```bash
cd linux

# Build Flatpak repository
bundle exec fastlane build_flatpak

# Build single-file .flatpak bundle
bundle exec fastlane build_flatpak_bundle

# Install locally for testing
bundle exec fastlane install_flatpak
```

### Traditional Package Lanes

```bash
cd linux

# Build AppImage
bundle exec fastlane build_appimage

# Build DEB package
bundle exec fastlane build_deb

# Build RPM package
bundle exec fastlane build_rpm
```

### Utility Lanes

```bash
cd linux

# Build just the Flutter binary (required for AppImage/DEB/RPM)
bundle exec fastlane build_flutter_linux

# Clean all build artifacts
bundle exec fastlane clean
```

## Detailed Usage

### Building Flatpak

Flatpak is built from the manifest file `dev.chuk.chat.yml` which includes Flutter SDK and all dependencies.

```bash
cd linux
bundle exec fastlane build_flatpak
```

**What it does:**
1. Checks if `flatpak-builder` is installed
2. Installs Freedesktop Platform 23.08 if needed
3. Downloads Flutter SDK (3.24.5 stable)
4. Builds the Flatpak using the manifest
5. Creates a local repository in `repo/`

**Testing:**
```bash
# Install locally
bundle exec fastlane install_flatpak

# Run
flatpak run dev.chuk.chat

# Uninstall
flatpak uninstall dev.chuk.chat
```

**Create distributable bundle:**
```bash
bundle exec fastlane build_flatpak_bundle
```

This creates a single `.flatpak` file users can install directly.

### Building AppImage

AppImage creates a portable executable that runs on any Linux distribution.

```bash
cd linux
bundle exec fastlane build_appimage
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Uses `scripts/package-linux.sh` to create AppImage
3. Downloads `appimagetool` if needed
4. Creates `chuk_chat-{version}-x86_64.AppImage`

**Testing:**
```bash
chmod +x chuk_chat-*.AppImage
./chuk_chat-*.AppImage
```

### Building DEB Package

DEB packages are for Debian-based distributions (Debian, Ubuntu, Linux Mint, etc.)

```bash
cd linux
bundle exec fastlane build_deb
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Creates DEB package structure
3. Builds `chuk_chat_{version}_amd64.deb`

**Testing:**
```bash
sudo dpkg -i chuk_chat_*.deb

# Run
chuk_chat

# Uninstall
sudo apt remove chuk_chat
```

### Building RPM Package

RPM packages are for Red Hat-based distributions (Fedora, RHEL, CentOS, openSUSE, etc.)

```bash
cd linux
bundle exec fastlane build_rpm
```

**What it does:**
1. Builds Flutter Linux binary if not present
2. Creates RPM package structure
3. Builds `chuk_chat-{version}-1.x86_64.rpm`

**Testing:**
```bash
sudo rpm -i chuk_chat-*.rpm

# Or on Fedora
sudo dnf install ./chuk_chat-*.rpm

# Run
chuk_chat

# Uninstall
sudo rpm -e chuk_chat
```

## Environment Variables

### Required for Building

```bash
SUPABASE_URL          # Your Supabase project URL
SUPABASE_ANON_KEY     # Your Supabase anonymous key
```

### Optional

```bash
# If not set, credentials will need to be configured at runtime
```

## CI/CD Integration

The GitHub Actions workflow `.github/workflows/build-cross-platform.yml` builds the Linux packages on a release (see `docs/RELEASE_PIPELINE.md`).

### Manual Workflow Trigger

To build locally as CI does:

```bash
# Install all dependencies
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev rpm fuse libfuse2 wget file \
  flatpak flatpak-builder ruby-full

# Setup Flatpak runtimes
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08

# Get dependencies
flutter pub get
cd linux && bundle install

# Build everything
export SUPABASE_URL="your-url"
export SUPABASE_ANON_KEY="your-key"
bundle exec fastlane release
```

## Troubleshooting

### Flatpak: "flatpak-builder not found"

```bash
sudo apt install flatpak flatpak-builder
```

### Flatpak: "Freedesktop Platform not found"

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08
```

### AppImage: "appimagetool not found"

The build script downloads it automatically. If it fails:

```bash
wget -O appimagetool https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool
sudo mv appimagetool /usr/local/bin/
```

### DEB: "dpkg-deb not found"

```bash
sudo apt install dpkg-dev
```

### RPM: "rpmbuild not found"

```bash
# Ubuntu/Debian
sudo apt install rpm

# Fedora
sudo dnf install rpm-build
```

### Build Fails: "SUPABASE_URL not set"

Set environment variables or use `.env` file:

```bash
export SUPABASE_URL="your-url"
export SUPABASE_ANON_KEY="your-key"
```

Or:
```bash
cp .env.example .env
# Edit .env with credentials
source .env
```

### Clean Build

If you encounter issues, clean and rebuild:

```bash
cd linux
bundle exec fastlane clean
bundle exec fastlane release
```

## File Structure

```
chuk_chat/
├── linux/
│   ├── fastlane/
│   │   ├── Fastfile        # Lane definitions
│   │   └── Appfile         # App identifier
│   └── Gemfile             # Ruby dependencies
├── dev.chuk.chat.yml       # Flatpak manifest
├── build_flatpak.sh        # Standalone Flatpak script
├── flatpak/
│   ├── dev.chuk.chat.desktop      # Desktop entry
│   └── dev.chuk.chat.metainfo.xml # AppStream metadata
└── scripts/
    └── package-linux.sh    # AppImage/DEB/RPM packaging
```

## Distribution

### GitHub Releases

All formats are automatically uploaded to GitHub Releases by CI/CD:

```
https://github.com/your-org/chuk_chat/releases/latest
```

### Manual Distribution

**Flatpak:**
- Direct: Share the `.flatpak` file
- Flathub: Submit to Flathub following their [submission guide](https://docs.flathub.org/docs/for-app-authors/submission)

**AppImage:**
- Direct download from website/GitHub
- AppImageHub (community catalog)

**DEB / RPM:**
- The signed apt and dnf repository (see the next section)
- Direct download from the GitHub release. The slim package adds the
  repository when it is installed.

## apt and dnf repository

Linux users get updates through their package manager:
`sudo apt update && sudo apt install --only-upgrade chuk-chat` or
`sudo dnf upgrade chuk-chat`.

- **URL:** `https://chuk-development.github.io/chuk_chat/` (GitHub Pages of
  this repository, deployed from an Actions artifact, so no `gh-pages`
  branch). The page shows the install commands.
- **Code:** `scripts/linux_repo/`. `make_deb.sh` and `make_rpm.sh` build the
  packages (CI calls them), `build_repo.sh` builds and signs the
  repository, `fetch_release_packages.sh` gets the packages from the
  releases, `test_repo_e2e.sh` tests everything in Docker.
- **Workflow:** `.github/workflows/linux-repo.yml`. The `linux-repo` job at
  the end of `build-cross-platform.yml` calls it after each release. You
  can also start it by hand (Actions > "Linux package repository" > Run
  workflow). It does not build the app.

### Install commands for users

Debian, Ubuntu, Linux Mint:

```bash
sudo curl -fsSLo /usr/share/keyrings/chuk-chat.gpg https://chuk-development.github.io/chuk_chat/chuk-chat.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/chuk-chat.sources https://chuk-development.github.io/chuk_chat/chuk-chat.sources
sudo apt update
sudo apt install chuk-chat
```

Fedora, RHEL:

```bash
sudo rpm --import https://chuk-development.github.io/chuk_chat/chuk-chat.asc
sudo curl -fsSLo /etc/yum.repos.d/chuk-chat.repo https://chuk-development.github.io/chuk_chat/chuk-chat.repo
sudo dnf install chuk-chat
```

A user who installs the `.deb` or `.rpm` file from a release gets the
repository too. Then the update commands above work.

### What the packages do

- **`.deb` (`chuk-chat`):** ships `/usr/share/keyrings/chuk-chat.gpg`. The
  `postinst` writes `/etc/apt/sources.list.d/chuk-chat.sources` when no apt
  source names the repository yet (any file name), so there is never a
  duplicate source. `repo=no` in `/etc/default/chuk-chat` stops it.
  `apt remove` deletes the keyring and the source file (only a file with
  the line `# Managed by the chuk-chat package.`). A source without its
  keyring would make `apt update` fail.
- **`.rpm` (`chuk-chat`):** owns `/etc/yum.repos.d/chuk-chat.repo` as
  `%config(noreplace)`. `enabled=0` in that file survives updates. `dnf
  remove` deletes the file. dnf imports the key from `gpgkey=` on first use.
- **Full variant:** the package name is `chuk-chat-full`. It conflicts with
  and replaces `chuk-chat`. It is not in the repository (the files are over
  the 100 MB Pages limit) and does not add it. Thus apt never "upgrades" a
  full install to slim.
- **Versions:** `v1.0.115` gives `1.0.115`. `v1.0.115-pre.2` gives
  `1.0.115~pre.2` (output `pkg_version` of the version-bump job). The tilde
  sorts before the final release in dpkg and rpm, so the final release
  upgrades a pre-release.
- **App:** `UpdateCheckService.linuxUpdatesViaPackageManager` is true when
  `/opt/chuk-chat/chuk_chat` and the repository file exist. Then the update
  notice opens the repository page, not a package download.

### Layout and channels

```
chuk-chat.asc  chuk-chat.gpg  chuk-chat.sources  chuk-chat.repo  index.html
deb/dists/{stable,beta}/{InRelease,Release,Release.gpg,main/binary-{amd64,arm64}/Packages*}
deb/pool/main/c/chuk-chat/*.deb
rpm/{stable,beta}/{x86_64,aarch64}/*.rpm + repodata/repomd.xml(.asc)
```

`stable` has the last 3 stable releases (`KEEP_STABLE`). `beta` has the
newest stable release and the newest pre-release that is newer
(`KEEP_PRE`). Users of `beta` set `Suites: beta` (apt) or enable
`[chuk-chat-beta]` (dnf). The GitHub releases are the source of truth: each
run builds the full site again from them. A release without a `.deb` or
`.rpm` asset is not in the repository.

### Signing and the key

- RSA 4096 key, only for this repository, no expiry date. Fingerprint
  `AB7CA4E20BD8247A92758436B97C16390DC1BF79`, user ID "Chuk Chat Linux
  package repository".
- Public key: `scripts/linux_repo/chuk-chat-repo-key.asc` (committed). The
  fingerprint is also in `scripts/linux_repo/common.sh` (`REPO_KEY_FPR`).
  `build_repo.sh` refuses to sign with any other key.
- Private key: Actions secrets `LINUX_REPO_GPG_PRIVATE_KEY` (armored,
  protected with a passphrase) and `LINUX_REPO_GPG_PASSPHRASE`. Only
  `linux-repo.yml` reads them. The build jobs never see the key, because
  they run third-party build code.
- apt: `InRelease` (clear-signed) and `Release.gpg`, SHA512. Users point to
  the key with `Signed-By:`, never `apt-key`.
- rpm: every `.rpm` in the repository is signed (`rpmsign`), and
  `repomd.xml.asc` signs the metadata. The repo file sets `gpgcheck=1` and
  `repo_gpgcheck=1`. The `.rpm` on the release page is not signed; only
  the repository copy is.
- Offline copy of the private key: the owner keeps it in the password
  manager. Without it, a lost secret means a key rotation.

### Key rotation

1. Make a new key (`gpg --quick-gen-key "Chuk Chat Linux package repository" rsa4096 sign never`).
2. Put **both** public keys into `chuk-chat-repo-key.asc`
   (`gpg --armor --export OLD NEW`). The `.deb` ships that keyring, and dnf
   imports all keys from `gpgkey=`.
3. Ship one release that is still signed with the old key. Users get the
   new keyring with it.
4. Then change `REPO_KEY_FPR`, set the two secrets to the new key and run
   the workflow. Remove the old key from the file after some releases.

If the old key leaks: rotate at once and tell users to run the install
commands again (they download the new keyring).

### End-to-end test

```bash
GNUPG_SRC=<gnupg dir with the secret key> PASSPHRASE_FILE=<file> \
  scripts/linux_repo/test_repo_e2e.sh [real-release.deb]
```

It builds dummy packages with the CI scripts, serves the signed repository
on `127.0.0.1:18765` and checks in Debian, Ubuntu and Fedora containers:
install, `apt install --only-upgrade` / `dnf upgrade`, the `.deb`/`.rpm`
adds and removes the repository, the `beta` suite, the opt-out, and that
changed `InRelease`, `Packages`, `repomd.xml` and `.rpm` files are refused.
It downloads only the container images.

### Traps

- GitHub Pages: 100 MB per file, 1 GB per site. `build_repo.sh` stops above
  950 MB. The `-full` packages do not fit.
- The `github-pages` environment allows deploys from `master` and from tags
  `v*` (a tag push release runs on the tag ref).
- The CDN caches files for about 10 minutes. Right after a deploy, `apt
  update` can see a new `InRelease` with an old `Packages` and report a
  hash error. It goes away when you try again.
- dnf5 does not stop on a bad `repomd.xml` signature. It prints "repomd.xml
  GPG signature verification error" and skips the repository. So a broken
  signature shows as "No match for argument: chuk-chat".
- `rpmsign` on Ubuntu needs `__gpg` set to the gpg path, else it says
  "Could not exec gpg".
- `rpm -qi` on RPM 6 shows an empty `Signature` line. Use `rpm -Kv`.
- Debian 13 apt checks signatures with `sqv` (Sequoia), not `gpgv`. It
  refuses SHA1. We sign with SHA512.
- A pre-release tagged before this change has the version of the final
  release (no `~pre.N`). `build_repo.sh` skips such files in the `beta`
  channel.
- A shell with `CDPATH` set prints the folder on `cd`. The scripts use
  `CDPATH= cd`.

## Version Management

Version is read from `pubspec.yaml`:

```yaml
version: 1.0.14+4012
```

Format: `MAJOR.MINOR.PATCH+BUILD`

All packages use this version automatically.

## Performance Notes

### Build Times (Approximate)

| Package | Build Time | Size |
|---------|-----------|------|
| Flutter Binary | 2-5 min | ~80 MB |
| Flatpak | 5-15 min | ~100 MB |
| AppImage | 1-2 min | ~90 MB |
| DEB | 1 min | ~80 MB |
| RPM | 1 min | ~80 MB |

**Full release:** ~15-20 minutes (parallel builds not implemented)

### Caching

Fastlane caches:
- Flutter SDK download (in Flatpak)
- Flatpak build artifacts (ccache enabled)
- Ruby gems (via bundler)

First build is slower, subsequent builds are faster.

## References

- [Fastlane Documentation](https://docs.fastlane.tools/)
- [Flatpak Documentation](https://docs.flatpak.org/)
- [AppImage Documentation](https://docs.appimage.org/)
- [Debian Package Guide](https://www.debian.org/doc/manuals/maint-guide/)
- [RPM Packaging Guide](https://rpm-packaging-guide.github.io/)
- [Flutter Linux Desktop](https://docs.flutter.dev/platform-integration/linux)
