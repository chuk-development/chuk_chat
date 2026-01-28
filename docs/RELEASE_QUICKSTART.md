# Release Quick Start Guide

TL;DR guide for creating releases with the automated pipeline.

## First Time Setup (Once)

### 1. Add GitHub Secrets

**Repository Settings → Secrets and variables → Actions**

**Minimum required:**
```
SUPABASE_URL
SUPABASE_ANON_KEY
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_PASSWORD
ANDROID_KEY_ALIAS
```

See [RELEASE_PIPELINE.md](./RELEASE_PIPELINE.md) for complete list.

### 2. Create Android Keystore

```bash
keytool -genkey -v -keystore chuk_chat.keystore \
  -alias chuk_chat -keyalg RSA -keysize 2048 -validity 10000

# Convert to base64 for GitHub Secret
base64 -w 0 chuk_chat.keystore
```

Copy the base64 output and add as `ANDROID_KEYSTORE_BASE64` secret.

## Creating a Release (Every Time)

### 1. Update Version

Edit `pubspec.yaml`:
```yaml
version: 1.0.15+4013  # Increment version number
```

### 2. Commit Version Bump

```bash
git add pubspec.yaml
git commit -m "chore: bump version to 1.0.15"
git push
```

### 3. Create and Push Tag

```bash
git tag v1.0.15
git push origin v1.0.15
```

### 4. Wait for Builds

Go to **Actions** tab in GitHub and monitor the 5 workflows:
- ✅ Release - Android (~15 min)
- ✅ Release - macOS (~30 min)
- ✅ Release - Windows (~20 min)
- ✅ Release - Linux (~25 min)
- ✅ Release - Web (~10 min)

### 5. Download Release Assets

Go to **Releases** tab → Your new release → Download binaries:
- `app-release.apk` (Android)
- `chuk_chat-macos.zip` (macOS)
- `chuk_chat-windows-portable.zip` + `*.msix` (Windows)
- `chuk_chat-*-x86_64.AppImage` + `*.deb` + `*.rpm` + `*.tar.gz` (Linux)
- `chuk_chat-*-web.zip` (Web)

## Testing a Build Locally

Before creating a tag, test builds locally:

```bash
# Android
cd android && bundle install && bundle exec fastlane build_apk

# macOS
cd macos && bundle install && bundle exec fastlane build

# Windows
.\scripts\package-windows.ps1 -Version "1.0.15"

# Linux
./scripts/package-linux.sh all 1.0.15

# Web
flutter build web --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

## Store Deployment (Optional)

All store deployments are **disabled by default**. To enable:

1. Add required secrets (see [RELEASE_PIPELINE.md](./RELEASE_PIPELINE.md))
2. Uncomment the deploy job in the respective workflow file
3. Push a new tag

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Build fails with "SUPABASE_URL not set" | Add secret in GitHub Settings |
| Android signing fails | Check `ANDROID_KEYSTORE_BASE64` is correctly encoded |
| Workflow not triggered | Ensure tag starts with `v` (e.g., `v1.0.15`) |
| Build timeout | Increase timeout in workflow YAML file |

## One-Command Release Script

Create this as `scripts/release.sh` for convenience:

```bash
#!/bin/bash
VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh 1.0.15"
    exit 1
fi

# Update version in pubspec.yaml
sed -i "s/^version: .*/version: $VERSION+$(date +%s)/" pubspec.yaml

# Commit and push
git add pubspec.yaml
git commit -m "chore: bump version to $VERSION"
git push

# Create and push tag
git tag "v$VERSION"
git push origin "v$VERSION"

echo "✅ Release v$VERSION triggered!"
echo "Monitor at: https://github.com/YOUR_ORG/chuk_chat/actions"
```

Usage:
```bash
chmod +x scripts/release.sh
./scripts/release.sh 1.0.15
```

## Version Naming Convention

- **Stable release**: `v1.0.15`
- **Beta release**: `v1.0.15-beta.1`
- **Alpha release**: `v1.0.15-alpha.1`
- **RC release**: `v1.0.15-rc.1`

## Next Steps

- Read full documentation: [RELEASE_PIPELINE.md](./RELEASE_PIPELINE.md)
- Enable store deployments when ready
- Set up automated testing before releases
- Configure release notes generation

## Support

Issues? Check [RELEASE_PIPELINE.md](./RELEASE_PIPELINE.md) for detailed troubleshooting.
