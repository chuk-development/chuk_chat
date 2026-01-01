# GitHub Workflows

## Cross-Platform Build

Der `build-cross-platform.yml` Workflow baut die App für alle unterstützten Plattformen:
- **Android** (APK)
- **Linux** (x64)
- **Windows** (x64)
- **macOS** (Universal Binary)
- **iOS** (ohne Code Signing)

### Workflow Triggern

Der Workflow wird **nur manuell** getriggert:

1. Gehe zu **Actions** → **Cross-Platform Build**
2. Klicke auf **Run workflow**
3. Optional: Deaktiviere "Build with all features enabled" für einen Build ohne Feature Flags
4. Klicke auf **Run workflow**

### Build-Optionen

**Mit allen Features** (Standard):
- ✅ FEATURE_MEDIA_MANAGER
- ✅ FEATURE_IMAGE_GEN
- ✅ FEATURE_PROJECTS
- ✅ FEATURE_VOICE_MODE
- ✅ PLATFORM_MOBILE (Android/iOS)

**Ohne Features:**
- Nur Basis-Funktionalität
- Kleinere Build-Größe

### Android Signing (Optional)

Für signierte Android APKs müssen folgende **GitHub Secrets** gesetzt werden:

| Secret | Beschreibung |
|--------|--------------|
| `ANDROID_KEYSTORE_BASE64` | Base64-kodierter Keystore (`.jks` Datei) |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore Passwort |
| `ANDROID_KEY_PASSWORD` | Key Passwort |
| `ANDROID_KEY_ALIAS` | Key Alias |

**Keystore in Base64 konvertieren:**
```bash
base64 -i upload-keystore.jks | tr -d '\n' > keystore.base64.txt
```

Ohne Secrets wird ein unsigned APK erstellt.

### Artifacts

Alle Builds werden als **Artifacts** gespeichert (30 Tage):

| Artifact | Datei |
|----------|-------|
| `android-apk` | `app-release.apk` |
| `linux-build` | `chuk_chat-linux-x64.tar.gz` |
| `windows-build` | `chuk_chat-windows-x64.zip` |
| `macos-build` | `chuk_chat-macos.zip` |
| `ios-build` | `chuk_chat-ios.zip` |

Download über **Actions** → **Workflow Run** → **Artifacts**.

### Build-Zeiten

Ungefähre Dauer (bei allen Features):
- Android: ~10-15 Min
- Linux: ~10-15 Min
- Windows: ~15-20 Min
- macOS: ~15-20 Min
- iOS: ~15-20 Min

**Gesamt: ~30-40 Min** (parallel)

### Troubleshooting

**Build schlägt fehl:**
1. Prüfe die Logs im Actions Tab
2. Stelle sicher, dass `flutter analyze` lokal erfolgreich ist
3. Bei Android: Prüfe Secrets (falls verwendet)

**iOS Code Signing:**
- Der Workflow erstellt unsigned iOS Builds (`--no-codesign`)
- Für App Store Deployment: Verwende Xcode lokal oder fastlane

**Plattform-spezifische Probleme:**
- Linux: Dependencies werden automatisch installiert
- Windows: Verwendet Visual Studio Build Tools
- macOS/iOS: Verwendet Xcode Command Line Tools
