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

- [x] **WebSocket Parse-Errors werden verschluckt** — MITTEL
  `websocket_chat_service.dart` — `catch`-Block aufgeteilt: `FormatException` (JSON-Parse-Error) und generischer `catch` yielden jetzt `ChatStreamEvent.error()` mit user-facing Fehlermeldung und breaken den Stream ab, statt still weiterzulaufen.
  *Quelle: Greptile #4*

- [x] **Stream cancelOnError: false** — MITTEL
  `streaming_manager_io.dart` + `streaming_manager_stub.dart` — `cancelOnError` auf `true` gesetzt. Subscription wird vom Framework automatisch gecancelt bevor `onError` läuft, was Subscription-Leaks verhindert (`_cleanupStream` cancelled die Subscription nicht explizit).
  *Quelle: Greptile #6*

- [x] **Image cacheWidth/cacheHeight fehlt** — MITTEL
  `cacheWidth`/`cacheHeight` zu Thumbnail-Contexts hinzugefügt: `encrypted_image_widget.dart` (2× display size), `attachment_preview_bar.dart` (60px für 30px Chips), `media_manager_page.dart` (400px für 200px Grid), `model_selector_page.dart` (2× icon size für Image.network). Fullscreen-Viewer (InteractiveViewer) bleiben ohne Limit (User will volle Auflösung).
  *Quelle: Audit 2025-12*

- [ ] **Keine Root/Jailbreak Detection** — MITTEL
  Kein Plugin vorhanden. Auf kompromittierten Geräten könnten Encryption-Keys ausgelesen werden. *Bewusste Entscheidung: Root-Detection ist leicht zu umgehen (Speed Bump). Für eine v1 akzeptabel.*
  *Quelle: Audit 2025-12*

- [ ] **Encryption Key im Secure Storage** — MITTEL
  `lib/services/encryption_service.dart:266` — Abgeleiteter Key wird gespeichert statt bei Login neu abzuleiten. *Bewusster UX-Tradeoff: Re-Derivation würde bei jedem App-Start Passwort-Eingabe erfordern.*
  *Quelle: Security Audit M1*

- [x] **Breite Android-Permissions** — MITTEL
  `AndroidManifest.xml` — `BLUETOOTH_ADVERTISE` entfernt. Permission wurde nicht benötigt (Chat-App bewirbt sich nicht als BLE Peripheral). Verbleibende Bluetooth-Permissions (`CONNECT`, `SCAN`) bleiben für Audio-Geräte (Voice-Mode).
  *Quelle: Security Audit L2*

### Niedrig

- [x] **Encryption-Key-Fehler werden still gehandelt** — NIEDRIG
  Alle `debugPrint`-Aufrufe in `app_initialization_service.dart` (ehemals `main.dart`) sind mit `kDebugMode`-Guard versehen. `_preloadEncryptionKey` loggt Fehler korrekt und ruft `clearKey()` im Fehlerfall auf.
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

- [x] **Doppelte Auth Subscription** — HOCH
  Zwei Listener bleiben bestehen, haben aber klar getrennte Verantwortung: (1) `AuthGate` — rein UI, switcht zwischen Login/RootWrapper. (2) `SessionManagerService` — Business-Logik, handhabt Session-Validierung, Password-Revision, User-Session-Init. Fix: AuthGate von 20-Iteration Retry-Loop auf einfachen Session-Check + Stream vereinfacht. Manuellen `initializeUserSession()`-Call aus `main.dart` entfernt — wird jetzt ausschließlich von `SessionManagerService._handleSessionActive()` getriggert (mit Guard gegen Duplikate bei Token-Refresh). `SessionManager.initialize()` nach `waitForSupabase()` verschoben.
  *Quelle: Refactoring Plan #4*

- [x] **Global Mutable State ohne Reaktivität** — HOCH
  `selectedChatId` hatte bereits einen `ValueNotifier` (war teilweise gefixt). Verbleibende Fixes: (1) Mobile `root_wrapper_mobile.dart` — `selectedChatId`-Zuweisung in `setState` verschoben. (2) Legacy `selectedChatIndex` (plain static int ohne Notifier) komplett entfernt — wird von keinem UI-Code mehr gelesen. Index-Adjustierung in crud/sync durch `selectedChatId`-basierte Null-Clear ersetzt. (3) `selectedChatId`-Null-Clear bei Chat-Delete in CRUD hinzugefügt (sync hatte es schon). (4) Verbose Stack-Trace-Logging im Setter durch einzeilige Ausgabe ersetzt.
  *Quelle: Refactoring Plan #5*

### Mittel

- [x] **Mobile fehlt isLoadingChat Guard** — MITTEL
  Guard existiert bereits (`root_wrapper_mobile.dart:163`). `selectedChatId` außerhalb von `setState` wurde im Rahmen des Global-State-Fixes behoben.
  *Quelle: Refactoring Plan #6*

- [x] **Mobile 5-Sekunden Auto-Refresh Timer** — MITTEL
  Dead Code entfernt: `_refreshTimer` Feld, Timer-Cancel in `dispose()`, auskommentierte `_startAutoRefresh()`/`_refreshChatsPeriodically()` Methoden. Pull-to-Refresh via `_loadChatsAndRefresh()` bleibt (nutzt `ChatSyncService.syncNow()`).
  *Quelle: Refactoring Plan #8*

### Niedrig

- [x] **Theme Loading Race Condition** — NIEDRIG
  `main.dart` — `loadFromPrefs()` wird jetzt VOR `SessionManager.initialize()` abgeschlossen. Da Supabase `onAuthStateChange` synchron beim Subscribe feuert, racete `loadFromPrefs()` vorher mit `loadFromSupabaseAsync()`. Neue Sequenz: (1) Supabase ready → (2) `loadFromPrefs()` + Notifications parallel → (3) `SessionManager.initialize()` → (4) Auth-Event → `loadFromSupabaseAsync()` sequentiell.
  *Quelle: Refactoring Plan #7, #9*

---

## Offen — API Server (FastAPI)

### Hoch

- [x] **Service Role Key als Default Client** — HOCH
  `payment_service.py` — Alle user-scoped Methoden (`get_credits_remaining`, `check_sufficient_credits`, `check_credits_atomic`, `create_checkout_session`, `create_portal_session`) haben jetzt optionalen `user_client` Parameter. Alle Caller in `main.py` (Transcription, HTTP Chat, WebSocket, Image Gen, Checkout, Portal, User Status) übergeben `user.client`. Admin-Client bleibt korrekt für: `log_usage` (Server-only Write), `sync_single_subscription`/`sync_all_subscriptions_from_stripe` (Webhook/Startup), `delete_user_account` (Admin-Op).
  *Quelle: Security Audit H2*

- [x] **CORS erlaubt Wildcard Methods/Headers** — HOCH
  `api_server/main.py` — Bereits in Commit `259d923` (2026-02-11) gefixt: Explizite `allow_methods` (GET/POST/PUT/DELETE/OPTIONS), explizite `allow_headers` (Authorization, Content-Type, etc.), explizite `allow_origins`.
  *Quelle: Security Audit H3*

### Mittel

- [x] **In-Memory Rate Limiting (nicht verteilt)** — MITTEL
  `api_server/main.py` — Bereits in Commits `259d923`/`a277a89` (2026-02-11) gefixt: Verteiltes Rate-Limiting via Supabase RPC `check_rate_limit()`. `slowapi` bleibt als IP-basierter Fallback. Residual-Risiko: Bei Supabase-RPC-Fehler fail-open (akzeptabel für Verfügbarkeit).
  *Quelle: Security Audit M4*

- [x] **JWT ohne Signatur-Verifikation im Rate Limiter** — MITTEL
  `parse_jwt_scopes()` wird NUR nach `supabase.auth.get_user()` aufgerufen (verify_token Dependency + WebSocket Auth Loop). Safety-Invariant dokumentiert im Docstring. Kein Risiko, da Token bereits serverseitig validiert ist.
  *Quelle: Security Audit M5*

- [x] **Webhook Idempotency Race Condition** — MITTEL
  `api_server/main.py` — TOCTOU-Race eliminiert: Bei Duplicate-Key-Error wird jetzt ein atomischer `UPDATE ... WHERE status = 'failed'` ausgeführt statt SELECT → Check → Process. Nur eine Instanz kann ein fehlgeschlagenes Webhook reclaimen. Bei `status = 'processing'` oder `status = 'completed'` wird sofort übersprungen. Error-Handler markiert Events als `failed` statt sie als `processing` hängen zu lassen.
  *Quelle: Security Audit M6*

### Niedrig

- [x] **File Upload Filename direkt verwendet** — NIEDRIG
  `convert_files.py` — `sanitize_filename()` Funktion hinzugefügt: Strippt Path-Komponenten (Traversal-Schutz), entfernt Control Characters und HTML-signifikante Zeichen (`<>&"'`), truncated auf 255 Zeichen. Wird im `/v1/ai/convert-file` Response und im Log-Message verwendet. Audio-Endpoint (`file.filename`) ist nur intern genutzt (Groq API, nicht im Response).
  *Quelle: Security Audit L3*

- [x] **Kein globales Request-Size-Limit** — NIEDRIG
  `api_server/main.py` — Content-Length-Check war bereits vorhanden. Neu: ASGI receive-Channel wird gewrappt um Streaming/Chunked-Uploads zu begrenzen. Zählt empfangene Bytes und wirft HTTP 413 bei Überschreitung von `MAX_REQUEST_BODY_SIZE` (100 MB). Schützt auch gegen fehlenden/gefälschten Content-Length Header.
  *Quelle: Security Audit L4*

- [x] **Health Endpoint zeigt Connection Count** — NIEDRIG
  `api_server/main.py` — Bereits in Commit `259d923` (2026-02-11) gefixt: Gibt nur `{"status": "ok"}` zurück.
  *Quelle: Security Audit L5*

---

## Offen — Supabase / Infrastruktur

- [x] **Widersprüchliche Migrations (get_credits_remaining)** — MITTEL
  Diskrepanz aufgelöst: API-Server-Version (`20260124`) ist kanonisch (berechnet `allocated - SUM(usage)`, korrektere Logik). `auth.uid()` Check hinzugefügt: Authentifizierte User können nur eigene Credits abfragen, Service Role (webhooks/sync) darf beliebige User abfragen. `SECURITY DEFINER` hinzugefügt. chuk_chat-Version (`20260120`) als Stub markiert mit Verweis auf kanonische Version.
  *Quelle: Security Audit M7*

- [x] **Passwort-Minimum auf 6 Zeichen (Supabase)** — NIEDRIG
  `supabase/config.toml` — `minimum_password_length` auf 8 erhöht, `password_requirements` auf `"lower_upper_letters_digits"` gesetzt. Client-seitig `InputValidator.minPasswordLength` ebenfalls auf 8 angehoben. Test-Suite angepasst (7-Zeichen-Test, min-length-Test). *Hinweis: Produktions-Supabase muss separat über Dashboard aktualisiert werden.*
  *Quelle: Security Audit L6*

- [ ] **CAPTCHA deaktiviert** — NIEDRIG
  `supabase/config.toml:164-167` — Kein Captcha für Signup. Rate Limits existieren (30/5min), aber automatisierte Account-Erstellung möglich. *Erfordert Captcha-Provider (hCaptcha/Turnstile) API-Keys und Client-seitige Integration.*
  *Quelle: Security Audit I3*

- [ ] **MFA deaktiviert** — NIEDRIG
  `supabase/config.toml:241-254` — Alle MFA-Methoden (TOTP, Phone, WebAuthn) deaktiviert. *Erfordert Client-seitige MFA-Flows (Enrollment, Verification) bevor Server-seitig aktiviert werden kann. Feature Request, kein Quick Fix.*
  *Quelle: Security Audit I4*

- [x] **Edge Function CORS Wildcard** — NIEDRIG
  `supabase/functions/revoke-session/index.ts` — `Access-Control-Allow-Origin: *` durch Origin-Allowlist ersetzt (`chat.chuk.chat`, `localhost:8080/8081`). Dynamische Origin-Prüfung mit `Vary: Origin` Header. Nicht-gelistete Origins erhalten leeren CORS-Header.
  *Quelle: Security Audit*

---

## Statistik

| Kategorie | Anzahl |
|-----------|--------|
| Behoben | 45 |
| Kein echtes Problem | 5 |
| **Offen — Flutter Client** | **3** |
| **Offen — Architektur/Performance** | **0** |
| **Offen — API Server** | **0** |
| **Offen — Supabase/Infra** | **2** |
| **Gesamt offen** | **5** |
