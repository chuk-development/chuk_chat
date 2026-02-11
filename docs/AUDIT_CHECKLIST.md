# Audit Checklist

Zusammengeführte Findings aus:
- `AUDIT_REPORT_2025-12-31.md` (Multi-Agent Security & Quality Audit)
- `GREPTILE_REVIEW_FINDINGS.md` (Greptile Code Review, 2026-02-10)

Zuletzt geprüft: **2026-02-11**

---

## Behoben

- [x] **Hardcoded Supabase Credentials** — KRITISCH
  `supabase_config.dart` — Keine hardcoded URLs/Keys mehr. Verwendet `--dart-define`, `web_env.dart` oder `.env` mit Placeholdern.
  *Quelle: Audit*

- [x] **Android Release Signing** — HOCH
  `android/app/build.gradle.kts` — 3-stufig: Env-Vars > `key.properties` > Debug-Fallback.
  *Quelle: Audit*

- [x] **withOpacity() deprecated** — MITTEL
  0 Instanzen im gesamten Codebase. Alle migriert.
  *Quelle: Audit*

- [x] **Network Security Config fehlt** — MITTEL
  `AndroidManifest.xml` referenziert `@xml/network_security_config`.
  *Quelle: Audit*

- [x] **BuildContext across async gaps** — HOCH
  251 `mounted`-Checks in 28 Dateien. `flutter analyze` zeigt keine async-gap-Warnungen mehr.
  *Quelle: Audit*

- [x] **flutter analyze Issues** — MITTEL
  Von 22 auf 11 Issues reduziert (nur info/warnings, keine deprecated-Warnungen).
  *Quelle: Audit*

- [x] **SharedPreferences Magic Strings** — MITTEL
  Alle 18 Keys als `static const String` in `main.dart:111-127` zentralisiert.
  *Quelle: Audit*

- [x] **Strukturierte Fehlerbehandlung** — HOCH
  `lib/utils/service_error_handler.dart` mit Dio-Handling, HTTP-Codes, Retry-Logik, Error-Predicates.
  *Quelle: Audit*

- [x] **Session Timeout / Session Management** — MITTEL
  `lib/services/session_tracking_service.dart` mit `registerSession()`, `updateLastSeen()`, `revokeSession()`. Dazu UI in `session_management_page.dart`.
  *Quelle: Audit*

- [x] **Web Credentials sicher** — MITTEL
  `web_env.dart` hat leere Werte in Git, wird nur via `Dockerfile.web` zur Buildzeit befüllt.
  *Quelle: Audit*

- [x] **Chat-Pagination / Lazy Loading** — MITTEL
  Sidebar lädt nur Titel (`id, encrypted_title, created_at, is_starred`). Volle Nachrichten werden erst bei Klick geladen. `ChatPreloadService` lädt im Hintergrund nach. Erste 15 Chats werden batch-entschlüsselt, Rest lazy.
  *Quelle: Audit*

- [x] **Markdown Streaming-Optimierung** — MITTEL
  `markdown_message.dart` — Widget-Caching mit Change-Detection. Code-Highlighting läuft async in Background-Isolate mit 50ms Debounce und 2s Timeout.
  *Quelle: Audit*

- [x] **Image Validation Bypass** — KRITISCH
  `lib/services/image_compression_service.dart` — Dreifach-Validierung eingebaut:
  1. Max Raw Input Size (50 MB Sanity-Check) vor dem Decoden
  2. Magic-Byte-Prüfung (JPEG, PNG, GIF, BMP, WebP, TIFF) — Dateien ohne gültige Signatur werden abgelehnt
  3. Post-Decode Dimensions-Check (max 10.000×10.000 Pixel) gegen Decompression Bombs
  *Quelle: Greptile #3*

- [x] **Keine Tests (0% Coverage)** — KRITISCH
  418 Unit-Tests in 16 Test-Dateien. Abgedeckt: Encryption, InputValidator, ImageCompression, TokenEstimator, SecureTokenHandler, ExponentialBackoff, ApiRateLimiter, UploadRateLimiter, ApiRequestQueue, ServiceErrorHandler, FileUploadValidator, alle Models (ChatMessage, StoredChat, ChatModel, AttachedFile, ChatStreamEvent, Project, ProjectFile), NetworkStatusService, MessageCompositionService. Noch offen: chat_storage_service, streaming_chat_service (benötigen Mock-Infrastruktur).
  *Quelle: Audit*

- [x] **Password-Mindestlänge inkonsistent** — HOCH
  `input_validator.dart` auf 6 Zeichen angepasst (Supabase-Setting). `password_change_service.dart` nutzt jetzt `InputValidator.validatePassword()` statt eigenem Length-Check. Beide Pfade (Registration + Passwort-Änderung) erzwingen identisch: 6 Zeichen + Uppercase + Lowercase + Digit + Symbol. Supabase prüft zusätzlich HaveIBeenPwned.
  *Quelle: Greptile #5*

---

## Kein echtes Problem (aus der Liste gestrichen)

- [x] **Token im WebSocket Body** *(Audit: HOCH, Greptile: Critical)*
  Standard-Pattern für WebSocket-Auth. Verbindung über `wss://` (TLS). Token wird validiert (`SecureTokenHandler`) und in Logs maskiert. HTTP hat Header-Auth, WebSockets nicht — Token in erster Nachricht ist die übliche Lösung.

- [x] **PrivacyLogger nicht adoptiert** *(Audit: MITTEL)*
  Das eigentliche Problem sind die ungeschützten `debugPrint`-Aufrufe. `pLog()` ist nur ein Wrapper. Wenn alle Logs geschützt wären, bräuchte man `pLog` nicht. Gelistet unter "Debug-Logs in Release".

- [x] **Kein State Management Framework** *(Audit: MITTEL)*
  `ValueNotifier` + `StreamController` + `StatefulWidget` ist pragmatisch für die App-Größe. Prop-Drilling bleibt als separates Issue gelistet.

- [x] **Certificate Pinning nur in Release** *(Audit: NIEDRIG, Greptile: Low #9)*
  Standard-Praxis (OWASP). Debug braucht Proxy-Tools. Korrekt implementiert. Dass Pinning insgesamt Scaffolding ist, ist das eigentliche Problem (separat gelistet).

---

## Offen — Hoch

- [ ] **Image-Cache ohne Memory-Limit** — HOCH
  `lib/services/image_storage_service.dart:55` — Einfaches `Map<String, Uint8List>` ohne LRU, Max-Size oder Eviction. Bilder werden bei Delete entfernt, aber nie proaktiv. ~14MB RAM pro entschlüsseltes 1920x1920-Bild. Zusätzlich: Entschlüsselte Bilder liegen unverschlüsselt im RAM — auf gerooteten Geräten auslesbar.
  *Quelle: Audit + Greptile #7*

- [ ] **allowBackup nicht deaktiviert** — HOCH
  `android/app/src/main/AndroidManifest.xml` — `android:allowBackup` nicht gesetzt (Default = `true`). Encryption-Keys und Nachrichten könnten in Google-Cloud-Backups landen.
  Fix: `android:allowBackup="false"` in `<application>` setzen.
  *Quelle: Audit*

- [ ] **Debug-Logs in Release** — HOCH
  `debugPrint()` ist in Flutter **kein No-Op in Release** — es ruft `print()` in allen Build-Modi auf. ~616 von 714 `debugPrint`-Aufrufen sind nicht in `kDebugMode` gewrappt. String-Interpolation wird in Release ausgeführt. Betrifft u.a. Credit-Balances (`credit_display.dart:86`), Markdown-Parsing-Errors mit User-Content (`markdown_message.dart:270`), Chat-State (`chat_ui_desktop.dart`, `chat_ui_mobile.dart`).
  Positives Beispiel: `websocket_chat_service.dart` — alle 34 Calls korrekt geschützt.
  *Quelle: Audit + Greptile #11-16*

- [ ] **Prop Drilling in RootWrapper** — HOCH
  `root_wrapper_desktop.dart` und `root_wrapper_mobile.dart` nehmen je **34 required Parameter**. Kein Config-Objekt, kein InheritedWidget.
  *Quelle: Audit*

- [ ] **WebSocket ohne Timeout** — HOCH
  `lib/services/websocket_chat_service.dart` — Keine Connection-Timeout oder Idle-Timeout. Hängende Verbindungen können endlos bestehen.
  *Quelle: Greptile #8*

---

## Offen — Mittel

- [ ] **Certificate Pinning ist Scaffolding** — MITTEL
  `lib/utils/certificate_pinning.dart` — Infrastruktur existiert, aber `configureDio()` erzwingt Pinning auf **keiner** Plattform (Kommentar Zeile 98-101: "Skipped here"). `validateCertificateBytes()` wird nie aufgerufen. Die identischen Hashes (Zeile 72-73) sind das kleinere Problem. Außerdem: WebSocket-Verbindungen haben gar kein Pinning.
  *Quelle: Audit + Greptile #2, #9*

- [ ] **God Classes (teilweise entschärft)** — MITTEL
  Logik wurde in Handler-Dateien extrahiert (~1.865 Zeilen): `streaming_message_handler.dart` (453), `file_attachment_handler.dart` (373), `audio_recording_handler.dart` (330), `chat_persistence_handler.dart` (190), `message_actions_handler.dart` (106), `desktop_chat_widgets.dart` (123), `mobile_chat_widgets.dart` (290).
  Restliche Dateien sind trotzdem noch groß (Desktop 3.725 / Mobile 2.784), aber primär UI-Layout.
  *Quelle: Audit*

- [ ] **WebSocket Parse-Errors werden verschluckt** — MITTEL
  `lib/services/websocket_chat_service.dart:174` — Wenn eine WebSocket-Nachricht nicht geparst werden kann, wird sie still verworfen. User bekommt keine Fehlermeldung. Debug-Logging ist korrekt in `kDebugMode` gewrappt, aber der User-seitige Feedback fehlt.
  *Quelle: Greptile #4*

- [ ] **Stream cancelOnError: false** — MITTEL
  `lib/services/streaming_manager_io.dart:77` — `cancelOnError: false` kann bei Fehlern zu mehrfachen Error-Callbacks und unerwartetem Verhalten führen.
  *Quelle: Greptile #6*

- [ ] **Image cacheWidth/cacheHeight fehlt** — MITTEL (teilweise entschärft)
  `lib/widgets/encrypted_image_widget.dart` nutzt kein `cacheWidth`/`cacheHeight` bei `Image.memory()`. Bilder werden aber vor Upload auf max 1920x1920 komprimiert, was den schlimmsten Fall begrenzt. Für Chat-Bubbles wird trotzdem das volle Bild im RAM dekodiert.
  *Quelle: Audit*

- [ ] **Keine Root/Jailbreak Detection** — MITTEL
  Kein Plugin (`freerasp`, `flutter_jailbreak_detection` etc.) vorhanden. Auf kompromittierten Geräten könnten Encryption-Keys von anderen Apps ausgelesen werden.
  *Quelle: Audit*

---

## Offen — Niedrig

- [ ] **Encryption-Key-Fehler werden still gehandelt** — NIEDRIG
  `lib/main.dart:56-59` — Wenn der Encryption-Key nicht geladen werden kann, wird er gelöscht (`clearKey()`) und ein `debugPrint` ausgegeben, aber nicht in `kDebugMode` gewrappt. Debugging von Key-Problemen ist schwierig.
  *Quelle: Greptile #10*

---

## Statistik

| Kategorie | Anzahl |
|-----------|--------|
| Behoben | 15 |
| Kein echtes Problem | 4 |
| Offen — Kritisch | 0 |
| Offen — Hoch | 4 |
| Offen — Mittel | 6 |
| Offen — Niedrig | 1 |
| **Gesamt geprüft** | **31** |
| **Wirklich offen** | **11** |
