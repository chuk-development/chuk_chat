# Audit Checklist

Konsolidierte Findings aus:
- `AUDIT_REPORT_2025-12-31.md` (Multi-Agent Security & Quality Audit)
- `SECURITY_AUDIT_2026-01-29.md` (Security Audit, Flutter + API Server + Supabase)
- `REFACTORING_PLAN.md` (Architecture Analysis, 2026-01-21)
- `GREPTILE_REVIEW_FINDINGS.md` (Greptile Code Review, 2026-02-10)

Zuletzt konsolidiert: **2026-02-13**

---

## Behoben

- [x] **Hardcoded Supabase Credentials** — KRITISCH
  `supabase_config.dart` — Keine hardcoded URLs/Keys mehr. Verwendet `--dart-define`, `web_env.dart` oder `.env` mit Placeholdern.
  *Quelle: Audit 2025-12*

- [x] **Android Release Signing** — HOCH
  `android/app/build.gradle.kts` — 3-stufig: Env-Vars > `key.properties` > Debug-Fallback.
  *Quelle: Audit 2025-12*

- [x] **withOpacity() deprecated** — MITTEL
  0 Instanzen im gesamten Codebase. Alle migriert.
  *Quelle: Audit 2025-12*

- [x] **Network Security Config fehlt** — MITTEL
  `AndroidManifest.xml` referenziert `@xml/network_security_config`.
  *Quelle: Audit 2025-12*

- [x] **BuildContext across async gaps** — HOCH
  251 `mounted`-Checks in 28 Dateien. `flutter analyze` zeigt keine async-gap-Warnungen mehr.
  *Quelle: Audit 2025-12*

- [x] **flutter analyze Issues** — MITTEL
  Von 22 auf 11 Issues reduziert (nur info/warnings, keine deprecated-Warnungen).
  *Quelle: Audit 2025-12*

- [x] **SharedPreferences Magic Strings** — MITTEL
  Alle 18 Keys als `static const String` in `main.dart:111-127` zentralisiert.
  *Quelle: Audit 2025-12*

- [x] **Strukturierte Fehlerbehandlung** — HOCH
  `lib/utils/service_error_handler.dart` mit Dio-Handling, HTTP-Codes, Retry-Logik, Error-Predicates.
  *Quelle: Audit 2025-12*

- [x] **Session Timeout / Session Management** — MITTEL
  `lib/services/session_tracking_service.dart` mit `registerSession()`, `updateLastSeen()`, `revokeSession()`. Dazu UI in `session_management_page.dart`.
  *Quelle: Audit 2025-12*

- [x] **Web Credentials sicher** — MITTEL
  `web_env.dart` hat leere Werte in Git, wird nur via `Dockerfile.web` zur Buildzeit befüllt.
  *Quelle: Audit 2025-12*

- [x] **Chat-Pagination / Lazy Loading** — MITTEL
  Sidebar lädt nur Titel (`id, encrypted_title, created_at, is_starred`). Volle Nachrichten werden erst bei Klick geladen. `ChatPreloadService` lädt im Hintergrund nach. Erste 15 Chats werden batch-entschlüsselt, Rest lazy.
  *Quelle: Audit 2025-12*

- [x] **Markdown Streaming-Optimierung** — MITTEL
  `markdown_message.dart` — Widget-Caching mit Change-Detection. Code-Highlighting läuft async in Background-Isolate mit 50ms Debounce und 2s Timeout.
  *Quelle: Audit 2025-12*

- [x] **Image Validation Bypass** — KRITISCH
  `lib/services/image_compression_service.dart` — Dreifach-Validierung: Max Raw Input Size (50 MB), Magic-Byte-Prüfung, Post-Decode Dimensions-Check (max 10.000×10.000).
  *Quelle: Greptile #3*

- [x] **Keine Tests (0% Coverage)** — KRITISCH
  418 Unit-Tests in 16 Test-Dateien. Noch offen: chat_storage_service, streaming_chat_service (benötigen Mock-Infrastruktur).
  *Quelle: Audit 2025-12*

- [x] **Password-Mindestlänge inkonsistent** — HOCH
  `input_validator.dart` auf 6 Zeichen angepasst (Supabase-Setting). Beide Pfade erzwingen identisch: 6 Zeichen + Uppercase + Lowercase + Digit + Symbol. Supabase prüft zusätzlich HaveIBeenPwned.
  *Quelle: Greptile #5*

---

## Kein echtes Problem (aus der Liste gestrichen)

- [x] **Token im WebSocket Body** *(Audit: HOCH, Greptile: Critical)*
  Standard-Pattern für WebSocket-Auth. Verbindung über `wss://` (TLS). Token wird validiert (`SecureTokenHandler`) und in Logs maskiert.

- [x] **PrivacyLogger nicht adoptiert** *(Audit: MITTEL)*
  Das eigentliche Problem sind die ungeschützten `debugPrint`-Aufrufe. Gelistet unter "Debug-Logs in Release".

- [x] **Kein State Management Framework** *(Audit: MITTEL)*
  `ValueNotifier` + `StreamController` + `StatefulWidget` ist pragmatisch für die App-Größe. Prop-Drilling bleibt als separates Issue.

- [x] **Certificate Pinning nur in Release** *(Audit: NIEDRIG, Greptile: Low)*
  Standard-Praxis (OWASP). Debug braucht Proxy-Tools. Dass Pinning insgesamt Scaffolding ist, ist separat gelistet.

- [x] **Network Security Config erlaubt User-Certs in Debug** *(Security Audit L1)*
  Standard-Praxis, nur Debug-Builds betroffen. Minimal risk.

---

## Offen — Flutter Client

### Hoch

- [x] **Image-Cache ohne Memory-Limit** — HOCH
  `lib/utils/lru_byte_cache.dart` + `lib/services/image_storage_service.dart` — LRU-Cache mit 50 MB Byte-Limit implementiert. Nutzt `dart:collection.LinkedHashMap` für O(1) Operationen. Älteste Einträge werden automatisch evicted. 12 Unit-Tests.
  *Quelle: Audit 2025-12 + Greptile #7*

- [x] **allowBackup nicht deaktiviert** — HOCH
  `AndroidManifest.xml` — `android:allowBackup="false"` + `android:fullBackupContent="false"` (Android <=11) + `android:dataExtractionRules` (Android 12+) gesetzt. Cloud- und Device-Transfer-Backups vollständig deaktiviert.
  *Quelle: Audit 2025-12*

- [x] **Debug-Logs in Release** — HOCH
  Alle 873 `debugPrint()`-Aufrufe in 53 Dateien in `if (kDebugMode)` gewrappt. `flutter analyze` zeigt 0 Issues.
  *Quelle: Audit 2025-12 + Security Audit H1 + Greptile #11-16*

- [x] **Prop Drilling in RootWrapper** — HOCH
  `AppShellConfig` bündelt alle 34 Parameter. Refactored in 9 Dateien: main.dart, root_wrapper_io/stub/desktop/mobile, settings_page, customization_page, theme_page. ChatUI-Dateien behalten eigene Parameter (haben zusätzliche UI-spezifische Felder).
  *Quelle: Audit 2025-12 + Refactoring Plan #7*

- [x] **WebSocket ohne Timeout** — HOCH
  Connection-Timeout (15s), First-Chunk-Timeout (120s), Idle-Timer (60s) im StreamingManager. Bei Timeout wird "Thinking..."-State aufgeräumt und User bekommt Fehlermeldung. Alle debugPrints in kDebugMode gewrappt.
  *Quelle: Greptile #8*

### Mittel

- [x] **Certificate Pinning ist Scaffolding** — MITTEL
  Echtes SHA-256 Certificate Pinning implementiert. `badCertificateCallback` auf `IOHttpClientAdapter` validiert Leaf + Intermediate CA Hashes in Release-Builds. Conditional Import (IO/Web) via `certificate_pinning_register.dart`. Registration in `main()`.
  *Quelle: Audit 2025-12 + Security Audit M3 + Greptile #2, #9*

- [ ] **God Classes (teilweise entschärft)** — MITTEL
  Handler-Extraktion erfolgt (~1.865 Zeilen ausgelagert). Restliche Dateien trotzdem groß: Desktop 3.725 / Mobile 2.784 LOC, aber primär UI-Layout.
  *Quelle: Audit 2025-12*

- [ ] **WebSocket Parse-Errors werden verschluckt** — MITTEL
  `lib/services/websocket_chat_service.dart:174` — Ungeparste Nachrichten werden still verworfen. User bekommt keine Fehlermeldung.
  *Quelle: Greptile #4*

- [ ] **Stream cancelOnError: false** — MITTEL
  `lib/services/streaming_manager_io.dart:77` — Kann bei Fehlern zu mehrfachen Error-Callbacks führen.
  *Quelle: Greptile #6*

- [ ] **Image cacheWidth/cacheHeight fehlt** — MITTEL
  `lib/widgets/encrypted_image_widget.dart` — Volles Bild im RAM dekodiert statt skaliert. Bilder sind auf 1920x1920 begrenzt, was den schlimmsten Fall limitiert.
  *Quelle: Audit 2025-12*

- [ ] **Keine Root/Jailbreak Detection** — MITTEL
  Kein Plugin vorhanden. Auf kompromittierten Geräten könnten Encryption-Keys ausgelesen werden.
  *Quelle: Audit 2025-12*

- [ ] **Encryption Key im Secure Storage** — MITTEL
  `lib/services/encryption_service.dart:266` — Abgeleiteter Key wird gespeichert statt bei Login neu abzuleiten. Device-Kompromittierung exponiert alle Daten ohne Passwort-Brute-Force.
  *Quelle: Security Audit M1*

- [ ] **Breite Android-Permissions** — MITTEL
  `AndroidManifest.xml` — `BLUETOOTH_ADVERTISE` deklariert, aber möglicherweise nicht benötigt.
  *Quelle: Security Audit L2*

### Niedrig

- [ ] **Encryption-Key-Fehler werden still gehandelt** — NIEDRIG
  `lib/main.dart:56-59` — Key-Load-Fehler: `clearKey()` + `debugPrint` ohne `kDebugMode`-Guard.
  *Quelle: Greptile #10*

---

## Offen — Architektur / Performance (Refactoring Plan)

### Kritisch

- [x] **UI Freeze: PBKDF2 auf Main Thread** — KRITISCH
  War bereits gefixt: `_deriveKey()` nutzt `compute()` mit top-level `_deriveKeyInBackground()` Funktion (Zeile 602-610). PBKDF2 läuft in Isolate, nicht auf Main Thread.
  *Quelle: Refactoring Plan #1*

- [x] **UI Freeze: flutter_secure_storage blockiert (Linux)** — KRITISCH
  Alle sequentiellen `_storage` Calls parallelisiert: `clearKey()` 3 deletes → `Future.wait()`, `_syncMetadataInBackground()` 2 reads → `Future.wait()`. `initializeForPassword()` und `rotateKeyForPasswordChange()` waren bereits parallelisiert. Zusätzlich: `_initializeApp()` in main.dart parallelisiert (NotificationService + Theme laden gleichzeitig), `_persistToPrefs()` 14 writes → `Future.wait()`, `resetServices()` 2 resets → `Future.wait()`. *Hinweis:* `Future.wait()` parallelisiert die async Calls, löst aber nicht das fundamentale Problem, dass libsecret auf Linux synchron über DBus blockt. Vollständige Lösung wäre `compute()` Isolate für Storage-Operationen, was aber API-Änderungen an flutter_secure_storage erfordern würde.
  *Quelle: Refactoring Plan #2*

### Hoch

- [x] **Dreifaches Chat-Loading (Race Condition)** — HOCH
  `loadSavedChatsForSidebar()` wurde von 5+ Stellen aufgerufen, die beim Startup/Login raceten. Fix: (1) Login-Page-Call entfernt — AuthGate triggert `initializeUserSession()` automatisch. (2) Post-Delete-Calls in beiden Sidebars entfernt — `deleteChat()` aktualisiert lokalen State + feuert `notifyChanges()`. (3) Post-NewChat-Call in Mobile entfernt — `persistChat()` feuert ebenfalls `notifyChanges()`. (4) Pull-to-Refresh in beiden Sidebars auf `ChatSyncService.syncNow()` umgestellt statt redundantem Cache-Reload. Einzige Startup-Load-Stelle: `AppInitializationService._loadUserData()`.
  *Quelle: Refactoring Plan #3*

- [ ] **Doppelte Auth Subscription** — HOCH
  `main.dart:133` + `auth_gate.dart:45` — Zwei separate Listener auf `onAuthStateChange`. Potentielle Race Conditions.
  Fix: AuthGate vereinfachen, nur einmaligen Session-Check statt Subscription.
  *Quelle: Refactoring Plan #4*

- [ ] **Global Mutable State ohne Reaktivität** — HOCH
  `lib/services/chat_storage_service.dart:286-319` — `selectedChatId` ist static ohne Notifier. UI-Updates nicht garantiert. Mobile setzt es außerhalb von `setState`.
  Fix: `ValueNotifier<String?>` verwenden.
  *Quelle: Refactoring Plan #5*

### Mittel

- [ ] **Mobile fehlt isLoadingChat Guard** — MITTEL
  `lib/platform_specific/root_wrapper_mobile.dart:241` — Desktop hat Guard gegen rapid Chat-Switching, Mobile nicht. Außerdem: `selectedChatId` wird außerhalb von `setState` gesetzt.
  *Quelle: Refactoring Plan #6*

- [ ] **Mobile 5-Sekunden Auto-Refresh Timer** — MITTEL
  `lib/platform_specific/sidebar_mobile.dart:122-125` — Timer läuft parallel zu ChatSyncService. Redundant und verursacht UI Jank.
  *Quelle: Refactoring Plan #8*

### Niedrig

- [ ] **Theme Loading Race Condition** — NIEDRIG
  `lib/main.dart:145, 181, 187` — Theme wird von 3 Stellen gleichzeitig geladen. Potentielles Flackern bei App-Start.
  Fix: Definierte Sequenz: erst Prefs, dann einmal Supabase.
  *Quelle: Refactoring Plan #7, #9*

---

## Offen — API Server (FastAPI)

### Hoch

- [ ] **Service Role Key als Default Client** — HOCH
  `api_server/main.py:104` — API Server nutzt `SUPABASE_SERVICE_KEY` für alle Operationen. Bypassed alle RLS-Policies.
  Fix: Per-Request Supabase Clients mit User-JWT für user-scoped Operationen.
  *Quelle: Security Audit H2*

- [ ] **CORS erlaubt Wildcard Methods/Headers** — HOCH
  `api_server/main.py:430-442` — `allow_methods=["*"]` und `allow_headers=["*"]` mit `allow_credentials=True`.
  Fix: Auf spezifische Methods/Headers einschränken.
  *Quelle: Security Audit H3*

### Mittel

- [ ] **In-Memory Rate Limiting (nicht verteilt)** — MITTEL
  `api_server/main.py:186-191` — Rate Limiting mit `defaultdict` statt Redis. Bei mehreren Replicas: Limits = N × Limit.
  *Quelle: Security Audit M4*

- [ ] **JWT ohne Signatur-Verifikation im Rate Limiter** — MITTEL
  `api_server/main.py:250` — `jwt.decode(token, options={"verify_signature": False})`. Angreifer kann fake `sub`-Claims nutzen.
  *Quelle: Security Audit M5*

- [ ] **Webhook Idempotency Race Condition** — MITTEL
  `api_server/main.py:2516-2531` — Bei non-unique DB-Errors wird Processing fortgesetzt statt übersprungen. Mögliche doppelte Credit-Zuweisung.
  *Quelle: Security Audit M6*

### Niedrig

- [ ] **File Upload Filename direkt verwendet** — NIEDRIG
  `api_server/main.py:778` — Dateiendung aus Upload-Filename ohne Whitelist-Validierung.
  *Quelle: Security Audit L3*

- [ ] **Kein globales Request-Size-Limit** — NIEDRIG
  `api_server/main.py` — Einzelne Endpoints haben Limits, aber kein globales. `await request.body()` liest alles in den Speicher.
  *Quelle: Security Audit L4*

- [ ] **Health Endpoint zeigt Connection Count** — NIEDRIG
  `api_server/main.py:486` — Unauthentifizierter Endpoint gibt `active_connections` zurück.
  *Quelle: Security Audit L5*

---

## Offen — Supabase / Infrastruktur

- [ ] **Widersprüchliche Migrations (get_credits_remaining)** — MITTEL
  `api_server/supabase/migrations/20260124_get_credits_remaining.sql` vs. `20260120210546_fix_free_messages_security.sql` — API-Server-Version hat keinen `auth.uid()` Check. Welche zuletzt deployed wurde, ist unklar.
  *Quelle: Security Audit M7*

- [ ] **Passwort-Minimum auf 6 Zeichen (Supabase)** — NIEDRIG
  `supabase/config.toml:142` — Client erzwingt strengere Regeln, aber API akzeptiert 6 Zeichen ohne Requirements.
  Fix: `minimum_password_length = 8`, `password_requirements = "lower_upper_letters_digits"`.
  *Quelle: Security Audit L6*

- [ ] **CAPTCHA deaktiviert** — NIEDRIG
  `supabase/config.toml:164-167` — Kein Captcha für Signup. Rate Limits existieren (30/5min), aber automatisierte Account-Erstellung möglich.
  *Quelle: Security Audit I3*

- [ ] **MFA deaktiviert** — NIEDRIG
  `supabase/config.toml:241-254` — Alle MFA-Methoden (TOTP, Phone, WebAuthn) deaktiviert.
  *Quelle: Security Audit I4*

- [ ] **Edge Function CORS Wildcard** — NIEDRIG
  `supabase/functions/revoke-session/index.ts:14` — `Access-Control-Allow-Origin: *` statt eingeschränkter Origins.
  *Quelle: Security Audit*

---

## Statistik

| Kategorie | Anzahl |
|-----------|--------|
| Behoben | 24 |
| Kein echtes Problem | 5 |
| **Offen — Flutter Client** | **8** |
| **Offen — Architektur/Performance** | **5** |
| **Offen — API Server** | **8** |
| **Offen — Supabase/Infra** | **5** |
| **Gesamt offen** | **26** |
