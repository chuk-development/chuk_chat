# Release Pipeline Documentation

Complete guide for the GitHub Actions + Fastlane release pipeline for chuk_chat.

## Overview

The release pipeline automatically builds and deploys chuk_chat for all platforms when you push a git tag matching `v*` (e.g., `v1.0.14`).

### Supported Platforms

| Platform | Outputs | Store Deployment |
|----------|---------|------------------|
| Android | APK, AAB | Google Play Store (optional) |
| macOS | DMG, PKG, ZIP | Mac App Store (optional) |
| Windows | MSIX, Portable ZIP | Microsoft Store (optional) |
| Linux | AppImage, DEB, RPM, tar.gz | Snap Store (optional) |
| Web | ZIP archive | GitHub Pages (auto), Firebase/Netlify/Vercel (optional) |

## Quick Start

### 1. Configure GitHub Secrets

Go to your GitHub repository → Settings → Secrets and variables → Actions → New repository secret.

Add the required secrets (see [Required GitHub Secrets](#required-github-secrets) below).

### 2. Create a Release

```bash
# Example: Release version 1.0.15
git tag v1.0.15
git push origin v1.0.15
```

### 3. Monitor the Build

Go to Actions tab in your GitHub repository and watch the workflows execute:
- `Release - Android`
- `Release - macOS`
- `Release - Windows`
- `Release - Linux`
- `Release - Web`

### 4. Download Release Assets

Once complete, go to the Releases page to find all platform binaries attached to the release.

## Required GitHub Secrets

### Essential (All Platforms)

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `SUPABASE_URL` | Supabase project URL | From Supabase dashboard |
| `SUPABASE_ANON_KEY` | Supabase anonymous key | From Supabase dashboard |

### Android Signing

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded keystore file | `base64 -w 0 keystore.keystore` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password | From your keystore setup |
| `ANDROID_KEY_PASSWORD` | Key password | From your keystore setup |
| `ANDROID_KEY_ALIAS` | Key alias (e.g., `chuk_chat`) | From your keystore setup |

#### Creating Android Keystore

```bash
# Generate keystore
keytool -genkey -v -keystore chuk_chat.keystore \
  -alias chuk_chat -keyalg RSA -keysize 2048 -validity 10000

# Convert to base64 for GitHub Secret
base64 -w 0 chuk_chat.keystore
```

### Android Play Store (Optional)

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Service account JSON | [Google Play Console](https://developers.google.com/android-publisher/getting_started) |

### macOS Signing (Optional)

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `MACOS_CERTIFICATE_BASE64` | Developer ID certificate (p12) | Export from Keychain Access |
| `MACOS_CERTIFICATE_PASSWORD` | Certificate password | Password set during export |
| `MACOS_KEYCHAIN_PASSWORD` | Temporary keychain password | Any secure password |
| `APPLE_ID` | Apple ID email | Your Apple developer account |
| `APPLE_TEAM_ID` | Apple Developer Team ID | From Apple Developer portal |
| `APPLE_APP_PASSWORD` | App-specific password | Generate at appleid.apple.com |

### macOS App Store (Optional)

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `MACOS_APPSTORE_CERTIFICATE_BASE64` | App Store certificate (p12) | Export from Keychain Access |
| `MACOS_APPSTORE_CERTIFICATE_PASSWORD` | Certificate password | Password set during export |

### Windows Microsoft Store (Optional)

| Secret Name | Description | How to Get |
|-------------|-------------|------------|
| `MS_STORE_TENANT_ID` | Azure AD Tenant ID | Azure Portal |
| `MS_STORE_CLIENT_ID` | Azure AD Client ID | Azure Portal |
| `MS_STORE_CLIENT_SECRET` | Azure AD Client Secret | Azure Portal |
| `MS_STORE_APP_ID` | Microsoft Store App ID | Partner Center |

### Web Hosting (Optional)

For Firebase:
- `FIREBASE_SERVICE_ACCOUNT` - Service account JSON

For Netlify:
- `NETLIFY_AUTH_TOKEN` - Auth token
- `NETLIFY_SITE_ID` - Site ID

For Vercel:
- `VERCEL_TOKEN` - Auth token
- `VERCEL_ORG_ID` - Organization ID
- `VERCEL_PROJECT_ID` - Project ID

## Workflow Files

| File | Purpose |
|------|---------|
| `.github/workflows/release-android.yml` | Android APK/AAB build + Play Store upload |
| `.github/workflows/release-macos.yml` | macOS DMG/PKG build + App Store upload |
| `.github/workflows/release-windows.yml` | Windows MSIX/ZIP build + Store upload |
| `.github/workflows/release-linux.yml` | Linux AppImage/DEB/RPM build + Snap Store upload |
| `.github/workflows/release-web.yml` | Web build + GitHub Pages/Firebase/Netlify/Vercel |

## Fastlane Configuration

### Android

Location: `android/fastlane/`

**Available lanes:**
```bash
# Build APK only
bundle exec fastlane build_apk

# Build AAB only
bundle exec fastlane build_aab

# Deploy to Play Store internal track
bundle exec fastlane deploy_internal

# Deploy to Play Store beta track
bundle exec fastlane deploy_beta

# Deploy to Play Store production
bundle exec fastlane deploy_production

# Full release (APK + AAB + Play Store upload)
bundle exec fastlane release track:internal
```

**Configuration:**
- Edit `android/fastlane/Appfile` to set your `package_name`
- Set `json_key_file` path for Play Store uploads

### macOS

Location: `macos/fastlane/`

**Available lanes:**
```bash
# Build app only
bundle exec fastlane build

# Build and sign app
bundle exec fastlane build_signed

# Build DMG installer
bundle exec fastlane build_dmg

# Build PKG installer
bundle exec fastlane build_pkg

# Notarize with Apple
bundle exec fastlane notarize

# Upload to Mac App Store
bundle exec fastlane deploy

# Full release (DMG + PKG + notarization)
bundle exec fastlane release
```

**Configuration:**
- Edit `macos/fastlane/Appfile` to set your `app_identifier` and `apple_id`
- Update `YOUR_TEAM_NAME` placeholders in `macos/fastlane/Fastfile`

## Manual Building

### Android

```bash
# APK
cd android
bundle install
bundle exec fastlane build_apk

# AAB
bundle exec fastlane build_aab
```

### macOS

```bash
# DMG
cd macos
bundle install
bundle exec fastlane build_dmg

# PKG
bundle exec fastlane build_pkg
```

### Windows

```powershell
# PowerShell
.\scripts\package-windows.ps1 -Version "1.0.14"

# Skip build (if already built)
.\scripts\package-windows.ps1 -Version "1.0.14" -SkipBuild
```

### Linux

```bash
# All formats
./scripts/package-linux.sh all 1.0.14

# Specific format
./scripts/package-linux.sh appimage 1.0.14
./scripts/package-linux.sh deb 1.0.14
./scripts/package-linux.sh rpm 1.0.14
```

### Web

```bash
flutter build web --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=FEATURE_PROJECTS=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_VOICE_MODE=true \
  --tree-shake-icons \
  --web-renderer canvaskit
```

## Store Deployment

All store deployments are **commented out by default** in the workflows. Uncomment the relevant job in the workflow file when ready to publish.

### Android - Google Play Store

1. Create a service account in Google Play Console
2. Download JSON key file
3. Add `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` secret to GitHub
4. Uncomment `deploy-playstore` job in `.github/workflows/release-android.yml`

### macOS - Mac App Store

1. Generate App Store distribution certificate
2. Export as p12 and convert to base64
3. Add required secrets to GitHub
4. Uncomment `deploy-appstore` job in `.github/workflows/release-macos.yml`

### Windows - Microsoft Store

1. Register app in Microsoft Partner Center
2. Create Azure AD app registration
3. Add required secrets to GitHub
4. Uncomment `deploy-msstore` job in `.github/workflows/release-windows.yml`

### Linux - Snap Store

1. Create Snap Store account
2. Register app
3. Get snapcraft credentials
4. Add `SNAPCRAFT_TOKEN` secret to GitHub
5. Uncomment `deploy-snapstore` job in `.github/workflows/release-linux.yml`

### Web - Hosting Platforms

**GitHub Pages** (enabled by default):
- Automatically deploys to `https://<username>.github.io/<repo>`
- Set custom domain in workflow: `cname: chat.chuk.dev`

**Firebase/Netlify/Vercel** (commented out):
- Uncomment relevant job in `.github/workflows/release-web.yml`
- Add required secrets
- Configure project IDs

## Versioning

Version is managed in `pubspec.yaml`:

```yaml
version: 1.0.14+4012
```

Format: `MAJOR.MINOR.PATCH+BUILD`

**Update version before creating tag:**
```bash
# Edit pubspec.yaml
vim pubspec.yaml

# Commit version bump
git add pubspec.yaml
git commit -m "chore: bump version to 1.0.15"
git push

# Create release tag
git tag v1.0.15
git push origin v1.0.15
```

## Troubleshooting

### Build Fails - Missing Secrets

**Error:** `SUPABASE_URL not set`

**Solution:** Add the secret in GitHub Settings → Secrets

### Android Signing Fails

**Error:** `Keystore file not found`

**Solution:**
1. Verify `ANDROID_KEYSTORE_BASE64` is set correctly
2. Check base64 encoding: `base64 -w 0 keystore.keystore`

### macOS Codesign Fails

**Error:** `errSecInternalComponent`

**Solution:**
1. Verify certificates are imported to keychain
2. Check certificate passwords match
3. Ensure `security unlock-keychain` is called

### Linux AppImage Fails

**Error:** `appimagetool: command not found`

**Solution:** Install appimagetool:
```bash
wget -O appimagetool https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool
sudo mv appimagetool /usr/local/bin/
```

### Windows MSIX Fails

**Error:** `msix:create not found`

**Solution:** Run `flutter pub add msix --dev` before building

### Web Build Size Too Large

**Solution:**
- Use `--web-renderer canvaskit` for better performance
- Enable `--tree-shake-icons` to remove unused icons
- Consider splitting code with deferred loading

## Best Practices

### 1. Test Locally First

Always test builds locally before pushing a release tag:

```bash
# Android
cd android && bundle exec fastlane build_apk

# macOS
cd macos && bundle exec fastlane build

# Windows
.\scripts\package-windows.ps1 -Version "test"

# Linux
./scripts/package-linux.sh all test

# Web
flutter build web --release
```

### 2. Use Semantic Versioning

- **MAJOR** (1.x.x): Breaking changes
- **MINOR** (x.1.x): New features
- **PATCH** (x.x.1): Bug fixes
- **BUILD** (+xxxx): Build number (auto-increment)

### 3. Create Pre-releases for Testing

```bash
# Beta release
git tag v1.0.15-beta.1
git push origin v1.0.15-beta.1

# Mark as pre-release in GitHub UI
```

### 4. Keep Secrets Secure

- **NEVER** commit secrets to repository
- Rotate secrets periodically
- Use different secrets for staging/production
- Limit secret access to necessary team members

### 5. Monitor Build Times

| Platform | Typical Build Time |
|----------|-------------------|
| Android | 10-15 minutes |
| macOS | 20-30 minutes |
| Windows | 15-20 minutes |
| Linux | 15-25 minutes |
| Web | 5-10 minutes |

### 6. Automated vs Manual Deployment

**Automated (recommended for):**
- Internal testing builds
- Beta releases
- GitHub Releases

**Manual (recommended for):**
- Production store releases
- First-time store submissions
- When store metadata needs updating

## Support

For issues with:
- **Fastlane**: https://docs.fastlane.tools/
- **GitHub Actions**: https://docs.github.com/en/actions
- **Play Store**: https://support.google.com/googleplay/android-developer
- **App Store**: https://developer.apple.com/support/
- **Microsoft Store**: https://docs.microsoft.com/en-us/windows/uwp/publish/

## License

This release pipeline is part of chuk_chat. Modify as needed for your project.
