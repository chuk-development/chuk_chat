# GitHub Workflows

## Cross-Platform Build & Release

Der `build-cross-platform.yml` Workflow baut die App für alle unterstützten Plattformen **UND** erstellt automatisch eine neue Version mit GitHub Release.

### 🚀 Platforms & Formats

| Platform | Formats | Beschreibung |
|----------|---------|--------------|
| **Android** | Split APKs + Universal APK | arm64, arm32, x64, universal |
| **Linux** | .deb, AppImage, .rpm | Debian/Ubuntu, Universal, Fedora/RHEL |
| **Windows** | MSIX | Windows Installer Package |
| **macOS** | .dmg | Disk Image (drag & drop) |
| **iOS** | .zip | Unsigned (optional, disabled by default) |

### ⚡ Automatische Version & Release

Der Workflow führt **automatisch** folgende Schritte aus:

1. ✅ **Version hochzählen**
   - Patch-Version: `1.0.6` → `1.0.7`
   - Build-Nummer: `4004` → `4005`
   - Update in `pubspec.yaml`

2. ✅ **Commit & Push**
   - Committed die neue Version
   - Pushed automatisch zum `master` Branch

3. ✅ **Builds erstellen**
   - Gewählte Plattformen parallel (~30-45 Min)
   - Mit optionalen Feature Flags
   - Mit/ohne Android Signing

4. ✅ **GitHub Release erstellen**
   - Tag: `v1.0.7` (ohne Build-Nummer)
   - Release mit allen Artifacts
   - Automatische Release Notes
   - Download-Links für alle Plattformen

### 📋 Workflow Starten

**Manuell triggern:**

1. Gehe zu **Actions** → **Cross-Platform Build & Release**
2. Klicke auf **Run workflow**
3. **Platforms**: Wähle Plattformen:
   - `all` - Alle Plattformen (außer iOS)
   - `android` - Nur Android
   - `linux` - Nur Linux
   - `windows` - Nur Windows
   - `macos` - Nur macOS
   - `android,linux` - Mehrere (comma-separated)
   - `ios` - iOS (explizit angeben)
4. **Features**: An/Aus für alle Feature Flags
5. **Signing**: An/Aus für Android APK Signing
6. Klicke auf **Run workflow**

**Beispiele:**
```yaml
platforms: "all"                  # Alle außer iOS
platforms: "android"              # Nur Android
platforms: "android,linux"        # Android + Linux
platforms: "windows,macos"        # Windows + macOS
platforms: "android,windows,ios"  # Mit iOS
```

### 🎯 Was passiert

```
1. Version Bump
   ├─ Liest aktuelle Version aus pubspec.yaml
   ├─ Erhöht Patch & Build-Nummer
   ├─ Updated pubspec.yaml
   └─ Committed & pushed neue Version

2. Build (parallel, pro Platform)
   │
   ├─ Android
   │  ├─ arm64 APK (modern devices)
   │  ├─ arm32 APK (older devices)
   │  ├─ x64 APK (emulators)
   │  └─ Universal APK (all devices)
   │
   ├─ Linux
   │  ├─ .deb (Debian/Ubuntu)
   │  ├─ AppImage (universal)
   │  └─ .rpm (Fedora/RHEL)
   │
   ├─ Windows
   │  └─ .msix (installer)
   │
   └─ macOS
      └─ .dmg (disk image)

3. GitHub Release
   ├─ Erstellt Tag (z.B. v1.0.7)
   ├─ Erstellt Release
   ├─ Uploaded alle Artifacts
   └─ Generiert Release Notes

4. Summary
   └─ Build-Status für alle Plattformen
```

### 📦 Output Files

**Android** (4 APKs):
```
chuk_chat-v1.0.7-android-arm64.apk      # Modern devices (recommended)
chuk_chat-v1.0.7-android-arm32.apk      # Older devices
chuk_chat-v1.0.7-android-x64.apk        # Emulators
chuk_chat-v1.0.7-android-universal.apk  # All devices (largest)
```

**Linux** (3 packages):
```
chuk_chat-v1.0.7-linux-amd64.deb        # Debian/Ubuntu
chuk_chat-v1.0.7-linux-x86_64.AppImage  # Universal (no install)
chuk_chat-v1.0.7-linux-x86_64.rpm       # Fedora/RHEL/openSUSE
```

**Windows**:
```
chuk_chat-v1.0.7-windows-x64.msix       # MSIX installer
```

**macOS**:
```
chuk_chat-v1.0.7-macos.dmg              # Disk image
```

### ✨ Build-Optionen

**Mit allen Features** (Standard):
```yaml
✅ FEATURE_MEDIA_MANAGER
✅ FEATURE_IMAGE_GEN
✅ FEATURE_PROJECTS
✅ FEATURE_VOICE_MODE
✅ PLATFORM_MOBILE (Android/iOS)
```

**Basic Build:**
- Nur Basis-Funktionalität
- Kleinere Build-Größe
- Schnellerer Build (~20% schneller)

**Android Signing:**
- Optional aktivierbar
- Benötigt GitHub Secrets
- Standard: unsigned (development)

### 🔐 Android Signing (Optional)

Für **signierte Android APKs** aktiviere "Enable Android signing" und setze diese **GitHub Secrets**:

| Secret | Beschreibung |
|--------|--------------|
| `ANDROID_KEYSTORE_BASE64` | Base64-kodierter Keystore (`.jks` Datei) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore Passwort |
| `ANDROID_KEY_PASSWORD` | Key Passwort |
| `ANDROID_KEY_ALIAS` | Key Alias (z.B. `upload`) |

**Keystore in Base64 konvertieren:**
```bash
base64 -i upload-keystore.jks | tr -d '\n' > keystore.base64.txt
cat keystore.base64.txt
```

**Secrets hinzufügen:**
1. Gehe zu **Settings** → **Secrets and variables** → **Actions**
2. Klicke **New repository secret**
3. Füge alle 4 Secrets hinzu

**Ohne Secrets oder ohne Aktivierung**: Unsigned APK wird erstellt.

### 📥 Installation

**Android:**
- Universal APK: Funktioniert überall (größer)
- ARM64 APK: Moderne Geräte (empfohlen, kleiner)
- ARM32 APK: Ältere Geräte
- x64 APK: Emulatoren

```bash
# APK installieren
adb install chuk_chat-*.apk
# Oder direkt auf dem Gerät (Unknown Sources aktivieren)
```

**Linux (Debian/Ubuntu):**
```bash
sudo dpkg -i chuk_chat-v1.0.7-linux-amd64.deb
sudo apt-get install -f  # Dependencies
chuk-chat
```

**Linux (AppImage - Universal):**
```bash
chmod +x chuk_chat-v1.0.7-linux-x86_64.AppImage
./chuk_chat-v1.0.7-linux-x86_64.AppImage
# Keine Installation nötig!
```

**Linux (Fedora/RHEL/openSUSE):**
```bash
sudo rpm -i chuk_chat-v1.0.7-linux-x86_64.rpm
# Oder:
sudo dnf install chuk_chat-v1.0.7-linux-x86_64.rpm
chuk-chat
```

**Windows:**
```powershell
# Doppelklick auf .msix
# Oder in PowerShell:
Add-AppxPackage .\chuk_chat-v1.0.7-windows-x64.msix
```

**macOS:**
```bash
# 1. DMG öffnen
# 2. App in Applications ziehen
# 3. Erste Start: Rechtsklick → Öffnen (Gatekeeper bypass)
```

### ⏱️ Build-Zeiten

Ungefähre Dauer (parallel):

| Plattform | Zeit | Output |
|-----------|------|--------|
| Version Bump | ~30s | pubspec.yaml update |
| Android | ~10-15 Min | 4 APKs |
| Linux | ~15-20 Min | .deb + AppImage + .rpm |
| Windows | ~15-20 Min | MSIX |
| macOS | ~15-20 Min | DMG |
| iOS | ~15-20 Min | ZIP (wenn aktiviert) |
| Release | ~2 Min | GitHub Release |

**Gesamt (alle Plattformen): ~30-45 Min**

### 🚀 Use Cases

**Nur Android bauen** (schnellster Build):
```yaml
platforms: "android"
enable_all_features: true
enable_signing: false
```
→ ~10-15 Min, 4 APKs

**Desktop-Plattformen** (Windows + macOS + Linux):
```yaml
platforms: "windows,macos,linux"
enable_all_features: true
```
→ ~30-40 Min, MSIX + DMG + 3 Linux packages

**Production Release** (alle Plattformen, signiert):
```yaml
platforms: "all"
enable_all_features: true
enable_signing: true
```
→ ~30-45 Min, alle Formate, signierte APKs

**Quick Test Build** (nur Android, basic):
```yaml
platforms: "android"
enable_all_features: false
enable_signing: false
```
→ ~8-10 Min, 4 unsigned APKs

### 📝 Release Notes Beispiel

```markdown
## 🚀 chuk_chat v1.0.7

Cross-platform build with version 1.0.7+4005

### 📦 Downloads

**Android APKs** (choose one):
- **Universal APK**: Works on all Android devices (larger size)
- **ARM64 APK**: For modern Android devices (recommended, smaller)
- **ARM32 APK**: For older Android devices
- **x64 APK**: For Android emulators and x86 devices

**Desktop**:
- **Windows**: MSIX installer (double-click to install)
- **Linux**: Choose your package format:
  - **.deb** for Debian/Ubuntu (`sudo dpkg -i`)
  - **AppImage** for universal Linux (just run it)
  - **.rpm** for Fedora/RHEL/openSUSE (`sudo rpm -i`)
- **macOS**: .dmg disk image (drag to Applications folder)

### ✨ Features
- ✅ All features enabled (Media Manager, Image Gen, Projects, Voice Mode)

### 🔐 Signing Status
- ⚠️ Android APKs are unsigned (development build)
- Windows MSIX is self-signed
- macOS .dmg is unsigned (requires "Open" via right-click)
- Linux packages are unsigned
```

### 🐛 Troubleshooting

**Build schlägt fehl:**
1. Prüfe die Logs im Actions Tab
2. Stelle sicher, dass `flutter analyze` lokal erfolgreich ist
3. Bei Android: Prüfe Secrets (falls signing enabled)

**Version-Bump schlägt fehl:**
- Prüfe, ob `pubspec.yaml` im richtigen Format ist (`version: X.Y.Z+BUILD`)
- Stelle sicher, dass der Bot Push-Rechte hat

**Release wird nicht erstellt:**
- Prüfe, ob alle gewählten Builds erfolgreich waren
- Ein fehlgeschlagener Build verhindert das Release

**AppImage funktioniert nicht:**
- `chmod +x` ausführen
- FUSE installieren: `sudo apt install fuse libfuse2`

**RPM/DEB Dependencies fehlen:**
- `.deb`: `sudo apt-get install -f`
- `.rpm`: `sudo dnf install` installiert Dependencies automatisch

**Windows MSIX lässt sich nicht installieren:**
- Developer Mode aktivieren
- Oder Zertifikat manuell vertrauen

**macOS "App kann nicht geöffnet werden":**
- Rechtsklick → Öffnen (Gatekeeper bypass)
- Oder in Systemeinstellungen → Sicherheit erlauben

### 💡 Tipps

**Schneller testen:**
- Nur eine Plattform wählen (`platforms: "android"`)
- Basic Build verwenden (`enable_all_features: false`)
- Builds laufen parallel - mehrere Plattformen dauern nicht viel länger

**Production Deployment:**
- Android: Signing aktivieren, signierte APKs hochladen
- Windows: MSIX im Microsoft Store veröffentlichen
- macOS: App signieren und notarisieren für App Store
- Linux: Repositories erstellen (PPA, AUR, etc.)

**AppImage ist universell:**
- Funktioniert auf allen Linux-Distros
- Keine Installation nötig
- Perfekt für User ohne Admin-Rechte

**Platform-spezifische Tipps:**
- Android: ARM64 APK für 99% der Geräte
- Linux: AppImage für maximale Kompatibilität
- Windows: MSIX für modernen Installer
- macOS: DMG für einfache Distribution

### 🎯 Workflow-Details

**Permissions:**
```yaml
permissions:
  contents: write  # Für Version Bump Commit & Release
```

**Job-Abhängigkeiten:**
```
version-bump
    ├─> build-android   (if platforms contains "android")
    ├─> build-linux     (if platforms contains "linux")
    ├─> build-windows   (if platforms contains "windows")
    ├─> build-macos     (if platforms contains "macos")
    └─> build-ios       (if platforms contains "ios")
            └─> create-release (if any build succeeded)
                    └─> summary
```

**Version-Bump Logik:**
```bash
# Beispiel: 1.0.6+4004 → 1.0.7+4005
MAJOR=1
MINOR=0
PATCH=6 → 7
BUILD=4004 → 4005

# Tag: v1.0.7 (ohne Build-Nummer)
```

**Platform Selection Logic:**
```bash
# Input: "android,linux"
# Output:
#   build_android=true
#   build_linux=true
#   build_windows=false
#   build_macos=false
#   build_ios=false

# Input: "all"
# Output: Alle true, außer iOS=false
```
