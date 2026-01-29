# Android Release Signing - Anleitung

## Was ist Android Signing?

Jede Android-App muss **digital signiert** werden, bevor sie installiert oder im Play Store veroeffentlicht werden kann. Die Signatur:

1. **Beweist Identitaet** - Nur du kannst Updates fuer deine App veroeffentlichen
2. **Schuetzt Integritaet** - Niemand kann die APK manipulieren ohne die Signatur zu brechen
3. **Ist dauerhaft** - Der gleiche Key muss fuer ALLE zukuenftigen Updates verwendet werden

## Zwei Arten von Keys

| Key | Verwendung | Sicherheit |
|-----|------------|------------|
| **Debug Key** | Entwicklung, Testing | Unsicher, jeder hat den gleichen |
| **Release Key** | Play Store, Production | Einzigartig, MUSS sicher aufbewahrt werden |

## Aktueller Status

Dein Release-Keystore wurde erstellt:

```
📁 /home/user/android_keystore/
└── chuk_chat_release.keystore  ← Dein Release-Key
```

Die Konfiguration ist in:
```
📁 chuk_chat/android/
├── key.properties     ← Passwoerter (NICHT in Git!)
└── app/build.gradle.kts  ← Laedt key.properties automatisch
```

## Wie es funktioniert

### 1. key.properties (lokal, nicht in Git)

```properties
storePassword=changeme123    # Passwort fuer den Keystore
keyPassword=changeme123      # Passwort fuer den Key
keyAlias=chuk_chat           # Name des Keys im Keystore
storeFile=/home/user/android_keystore/chuk_chat_release.keystore
```

### 2. build.gradle.kts (liest automatisch)

```kotlin
// Laedt key.properties wenn vorhanden
val keystorePropertiesFile = rootProject.file("key.properties")

// Verwendet Release-Key wenn verfuegbar, sonst Debug
signingConfig = if (keystorePropertiesFile.exists()) {
    signingConfigs.getByName("release")
} else {
    signingConfigs.getByName("debug")
}
```

## Release APK bauen

```bash
# Standard Build (verwendet jetzt Release-Signatur)
flutter build apk --release

# Oder mit allen Features:
flutter build apk \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_PROJECTS=true \
  --tree-shake-icons \
  --target-platform android-arm64
```

## Signatur verifizieren

Nach dem Build kannst du pruefen, ob die Signatur korrekt ist:

```bash
# APK-Signatur anzeigen
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk

# Sollte zeigen:
# Owner: CN=Chuk Chat, OU=Development, O=Chuk, ...
# (NICHT: CN=Android Debug, ...)
```

## WICHTIG: Sicherheit

### Diese Dateien NIEMALS teilen oder committen:

| Datei | Warum |
|-------|-------|
| `chuk_chat_release.keystore` | Wer den Key hat, kann Updates fuer deine App signieren |
| `key.properties` | Enthaelt Passwoerter im Klartext |

### Backup machen!

Wenn du den Keystore verlierst, kannst du **KEINE Updates** mehr im Play Store veroeffentlichen. Du muessstest eine NEUE App mit neuer ID erstellen.

```bash
# Backup erstellen
cp /home/user/android_keystore/chuk_chat_release.keystore /pfad/zum/sicheren/backup/
```

## Keystore-Passwort aendern

Das aktuelle Passwort ist `changeme123`. Um es zu aendern:

```bash
# Store-Passwort aendern
keytool -storepasswd -keystore /home/user/android_keystore/chuk_chat_release.keystore

# Key-Passwort aendern
keytool -keypasswd -alias chuk_chat -keystore /home/user/android_keystore/chuk_chat_release.keystore
```

Danach `key.properties` aktualisieren!

## Neuen Keystore erstellen (falls noetig)

Falls du einen neuen Keystore brauchst (z.B. andere App):

```bash
keytool -genkey -v \
  -keystore /pfad/zum/neuen.keystore \
  -storetype PKCS12 \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias mein_alias \
  -storepass DEIN_PASSWORT \
  -keypass DEIN_PASSWORT \
  -dname "CN=Dein Name, OU=Team, O=Firma, L=Stadt, S=Bundesland, C=DE"
```

## Troubleshooting

### "keystore was tampered with, or password was incorrect"
→ Falsches Passwort in key.properties

### "Key with alias not found"
→ `keyAlias` in key.properties stimmt nicht mit dem Alias im Keystore ueberein

### "Cannot read file"
→ `storeFile` Pfad in key.properties ist falsch oder Datei existiert nicht

### Signatur pruefen mit Debug-Key vs Release-Key:

```bash
# Zeigt Owner der Signatur
unzip -p app-release.apk META-INF/CERT.RSA | keytool -printcert

# Debug: CN=Android Debug, O=Android, C=US
# Release: CN=Chuk Chat, OU=Development, O=Chuk, ...
```

---

**Erstellt:** 2025-12-31
