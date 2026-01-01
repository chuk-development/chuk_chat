# GitHub Workflows

## Cross-Platform Build & Release

Der `build-cross-platform.yml` Workflow baut die App für alle unterstützten Plattformen **UND** erstellt automatisch eine neue Version mit GitHub Release.

### 🚀 Platforms

- **Android** (APK, ARM64)
- **Linux** (x64, tar.gz)
- **Windows** (x64, zip)
- **macOS** (Universal Binary, zip)
- **iOS** (Unsigned, zip)

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
   - Alle 5 Plattformen parallel (~30-40 Min)
   - Mit optionalen Feature Flags

4. ✅ **GitHub Release erstellen**
   - Tag: `v1.0.7` (ohne Build-Nummer)
   - Release mit allen Artifacts
   - Automatische Release Notes
   - Download-Links für alle Plattformen

### 📋 Workflow Starten

**Manuell triggern:**

1. Gehe zu **Actions** → **Cross-Platform Build & Release**
2. Klicke auf **Run workflow**
3. Optional: Deaktiviere "Build with all features enabled" für Basic Build
4. Klicke auf **Run workflow**

**Das war's!** Der Workflow erledigt den Rest automatisch.

### 🎯 Was passiert

```
1. Version Bump
   ├─ Liest aktuelle Version aus pubspec.yaml
   ├─ Erhöht Patch & Build-Nummer
   ├─ Updated pubspec.yaml
   └─ Committed & pushed neue Version

2. Build (parallel)
   ├─ Android APK
   ├─ Linux x64
   ├─ Windows x64
   ├─ macOS
   └─ iOS

3. GitHub Release
   ├─ Erstellt Tag (z.B. v1.0.7)
   ├─ Erstellt Release
   ├─ Uploaded alle Artifacts
   └─ Generiert Release Notes

4. Summary
   └─ Build-Status für alle Plattformen
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

### 🔐 Android Signing (Optional)

Für **signierte Android APKs** müssen folgende **GitHub Secrets** gesetzt werden:

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

**Ohne Secrets**: Unsigned APK wird erstellt (funktioniert trotzdem).

### 📦 Artifacts & Downloads

**Nach dem Build:**

1. Gehe zu **Releases** im GitHub Repo
2. Finde die neueste Version (z.B. `v1.0.7`)
3. Downloade die gewünschte Plattform:

| Datei | Plattform | Größe |
|-------|-----------|-------|
| `chuk_chat-v1.0.7-android.apk` | Android ARM64 | ~50 MB |
| `chuk_chat-v1.0.7-linux-x64.tar.gz` | Linux x64 | ~60 MB |
| `chuk_chat-v1.0.7-windows-x64.zip` | Windows x64 | ~70 MB |
| `chuk_chat-v1.0.7-macos.zip` | macOS Universal | ~80 MB |
| `chuk_chat-v1.0.7-ios.zip` | iOS (unsigned) | ~50 MB |

**Artifacts werden auch in Actions gespeichert** (30 Tage).

### ⏱️ Build-Zeiten

Ungefähre Dauer (parallel):

| Plattform | Zeit | Runner |
|-----------|------|--------|
| Version Bump | ~30s | Ubuntu |
| Android | ~10-15 Min | Ubuntu |
| Linux | ~10-15 Min | Ubuntu |
| Windows | ~15-20 Min | Windows |
| macOS | ~15-20 Min | macOS |
| iOS | ~15-20 Min | macOS |
| Release | ~2 Min | Ubuntu |

**Gesamt: ~30-40 Min** (alles läuft parallel).

### 📝 Release Notes Beispiel

```markdown
## 🚀 chuk_chat v1.0.7

Cross-platform build with version 1.0.7+4005

### 📦 Downloads

- **Android**: APK for ARM64 devices
- **Linux**: x64 archive (tar.gz)
- **Windows**: x64 archive (zip)
- **macOS**: Universal binary (zip)
- **iOS**: Unsigned build (zip) - requires manual signing

### ✨ Features

- ✅ All features enabled (Media Manager, Image Gen, Projects, Voice Mode)

### 📝 Installation

**Android**: Install the APK directly on your device

**Linux**: Extract and run
```bash
tar -xzf chuk_chat-v1.0.7-linux-x64.tar.gz
./chuk_chat
```

**Windows**: Extract and run `chuk_chat.exe`

**macOS**: Extract and move `chuk_chat.app` to Applications

**iOS**: Requires manual code signing with Xcode
```

### 🐛 Troubleshooting

**Build schlägt fehl:**
1. Prüfe die Logs im Actions Tab
2. Stelle sicher, dass `flutter analyze` lokal erfolgreich ist
3. Bei Android: Prüfe Secrets (falls verwendet)

**Version-Bump schlägt fehl:**
- Prüfe, ob `pubspec.yaml` im richtigen Format ist (`version: X.Y.Z+BUILD`)
- Stelle sicher, dass der Bot Push-Rechte hat

**Release wird nicht erstellt:**
- Prüfe, ob alle Builds erfolgreich waren
- Ein fehlgeschlagener Build verhindert das Release

**iOS Code Signing:**
- Der Workflow erstellt unsigned iOS Builds (`--no-codesign`)
- Für App Store Deployment: Verwende Xcode lokal oder fastlane

### 🎯 Workflow-Details

**Permissions:**
```yaml
permissions:
  contents: write  # Für Version Bump Commit & Release
```

**Job-Abhängigkeiten:**
```
version-bump
    ├─> build-android
    ├─> build-linux
    ├─> build-windows
    ├─> build-macos
    └─> build-ios
            └─> create-release
                    └─> summary
```

**Version-Bump Logik:**
```bash
# Beispiel: 1.0.6+4004 → 1.0.7+4005
MAJOR=1
MINOR=0
PATCH=6 → 7
BUILD=4004 → 4005
```

### 💡 Tipps

**Schneller testen:**
- Deaktiviere Plattformen, die du nicht brauchst (kommentiere Jobs aus)
- Verwende Basic Build für schnellere Builds

**Eigene Release Notes:**
- Editiere den Release nach der Erstellung in GitHub
- Füge Changelog, Screenshots, etc. hinzu

**Versioning:**
- Der Workflow erhöht automatisch nur PATCH
- Für MAJOR/MINOR Bumps: Ändere manuell vor dem Workflow
- Build-Nummer wird immer automatisch erhöht
