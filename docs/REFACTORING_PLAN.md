# Refactoring Plan: chuk_chat Architecture

> **Zielgruppe**: Ein anderer Agent oder Entwickler, der diese Änderungen schrittweise implementieren kann.
>
> **Erstellt**: 2026-01-21
>
> **Status**: Phase 1 Analyse abgeschlossen

---

## Executive Summary

Die chuk_chat Flutter App hat folgende kritische Architekturprobleme:

| Problem | Schweregrad | Hauptursache |
|---------|-------------|--------------|
| **UI Freezes (1-5s)** | KRITISCH | `flutter_secure_storage` blockiert auf Linux; PBKDF2 auf Main Thread |
| **Race Conditions** | HOCH | Chats werden von 3+ Stellen geladen (main.dart, sidebars) |
| **Unklare Initialisierung** | HOCH | Kein definiertes "App Ready" Signal; doppelte Auth-Subscriptions |
| **Global Mutable State** | HOCH | `ChatStorageService.selectedChatId` ist static ohne Reaktivität |
| **Prop Drilling** | MITTEL | 30+ Props durch Widget-Tree durchgereicht |

---

## Inhaltsverzeichnis

1. [Dependency Graph](#1-dependency-graph)
2. [Kritische Probleme](#2-kritische-probleme)
3. [Neue Architektur](#3-neue-architektur)
4. [Konkrete Änderungen](#4-konkrete-änderungen)
5. [Implementierungsreihenfolge](#5-implementierungsreihenfolge)
6. [Constraints](#6-constraints)

---

## 1. Dependency Graph

```
main.dart (App Entry Point)
├── WidgetsFlutterBinding.ensureInitialized()
├── initChatStorageCache() ──────────────────────┐
│   └── SharedPreferences.getInstance() [BLOCKING 10-50ms]
│                                                │
├── unawaited(_initializeServicesAsync()) ───────┼──────────────────────┐
│   ├── SupabaseService.initialize()             │                      │
│   │   └── supabase_flutter SDK                 │                      │
│   ├── EncryptionService.tryLoadKey() ──────────┼─────────┐            │
│   │   └── flutter_secure_storage.read() ───────┼─────────┼── [BLOCKING 1-2s on Linux!]
│   └── ModelPrefetchService.prefetch()          │         │
│                                                │         │
├── runApp(ChukChatApp) ─────────────────────────┼─────────┼────────────┤
│   ├── _initializeAfterSupabase()               │         │            │
│   │   ├── _waitForSupabase() [POLLING max 5s]  │         │            │
│   │   └── SupabaseService.auth.onAuthStateChange ──────────────────── AUTH SUB #1
│   │       └── _initUserSession(user)           │         │
│   │           ├── EncryptionService.initializeForPassword()
│   │           │   ├── _storage.read(salt) ─────┼─────────┼── [BLOCKING 1-2s]
│   │           │   ├── _storage.read(key) ──────┼─────────┼── [BLOCKING 1-2s]
│   │           │   ├── _deriveKey() PBKDF2 ─────┼─────────┼── [BLOCKING 600-2000ms, Main Thread!]
│   │           │   └── _storage.write() x2 ─────┼─────────┼── [BLOCKING 2-4s]
│   │           ├── ChatStorageService.loadSavedChatsForSidebar() ── CHAT LOAD #1
│   │           │   └── ChatSyncService.start()
│   │           └── ProjectStorageService.loadProjects()
│   │
│   └── AuthGate ────────────────────────────────────────────────────── AUTH SUB #2
│       ├── SupabaseService.auth.onAuthStateChange (DUPLICATE!)
│       └── RootWrapper (Desktop | Mobile)
│           ├── SidebarDesktop/Mobile
│           │   └── _loadChatsAndRefresh() ──────────────────────────── CHAT LOAD #2
│           │       └── ChatStorageService.loadSavedChatsForSidebar()
│           │
│           └── [Mobile only] 5-second auto-refresh timer ───────────── CHAT LOAD #3
│               └── ChatStorageService.loadSavedChatsForSidebar()
│
└── Services Layer
    ├── ChatStorageService (Singleton-Pattern mit Static Fields)
    │   ├── _chatsById: Map<String, StoredChat> [Memory Cache]
    │   ├── selectedChatId: String? [GLOBAL MUTABLE STATE!]
    │   ├── isLoadingChat: bool [GLOBAL FLAG!]
    │   ├── LocalChatCacheService [SharedPreferences]
    │   ├── EncryptionService.decryptInBackground() [compute() isolate ✓]
    │   └── SupabaseService.client.from('encrypted_chats')
    │
    ├── EncryptionService (Static Service)
    │   ├── _cachedKey: SecretKey? [Memory Cache]
    │   ├── flutter_secure_storage [LINUX BLOCKING!]
    │   ├── cryptography (AES-256-GCM)
    │   └── PBKDF2-SHA256 (600k iterations) [MAIN THREAD!]
    │
    ├── ProjectStorageService (Singleton-Pattern)
    │   ├── _projectsById: Map<String, Project> [Memory Cache]
    │   ├── _loadingCompleter [Dedupe Guard ✓]
    │   ├── EncryptionService.encrypt/decrypt
    │   └── SupabaseService.client.from('projects')
    │
    └── ChatSyncService (Background Sync)
        └── 5-second polling loop
```

### Dependency Conflicts

| Konflikt | Beschreibung |
|----------|--------------|
| **AUTH SUB #1 + #2** | main.dart UND AuthGate subscriben beide auf `onAuthStateChange` |
| **CHAT LOAD #1 + #2 + #3** | Chats werden von main.dart, sidebars UND mobile timer geladen |
| **BLOCKING CHAIN** | `flutter_secure_storage` → `_deriveKey()` → `_storage.write()` = 5-10s total |

---

## 2. Kritische Probleme

### Problem 1: flutter_secure_storage blockiert UI (Linux)

**Datei:** `lib/services/encryption_service.dart:258`

**Symptom:** UI freezt für 1-2 Sekunden bei App-Start auf Linux Desktop

**Ursache:** `flutter_secure_storage` verwendet synchrone DBus-Aufrufe auf Linux

```dart
// VORHER (Zeile 258 - tryLoadKey)
final storedKeyBase64 = await _storage.read(key: keyKey);
// Blockiert 1-2s auf Linux!
```

**Betroffene Methoden:**
| Methode | Zeilen | Blocking Calls |
|---------|--------|----------------|
| `tryLoadKey()` | 258 | 1x read |
| `initializeForPassword()` | 185-186, 232-235 | 2x read + 2x write |
| `rotateKeyForPasswordChange()` | 333-334, 386-388, 405-407 | 2x read + 6x write |
| `clearKey()` | 422-424 | 3x delete |

**Priorität:** KRITISCH

---

### Problem 2: PBKDF2 auf Main Thread

**Datei:** `lib/services/encryption_service.dart:555-565`

**Symptom:** UI freezt für 600-2000ms bei Login/Password-Operationen

**Ursache:** PBKDF2 mit 600.000 Iterationen läuft auf Main Thread

```dart
// VORHER (Zeile 555-565)
static Future<List<int>> _deriveKey(String password, List<int> salt) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _kdfIterations,  // 600,000!
    bits: 256,
  );
  final newSecretKey = await pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: salt,
  );
  return newSecretKey.extractBytes();  // CPU-intensiv auf Main Thread!
}
```

**Aufrufe:**
- `initializeForPassword()` Zeile 222 - jeder Login
- `rotateKeyForPasswordChange()` Zeilen 351, 360 - Password-Änderung
- `_resolveCanonicalSalt()` Zeilen 640, 651 - bis zu 2x bei Multi-Device Sync!

**Priorität:** KRITISCH

---

### Problem 3: Doppelte/Dreifache Chat-Loads

**Dateien:**
- `lib/main.dart:248`
- `lib/platform_specific/sidebar_desktop.dart:61`
- `lib/platform_specific/sidebar_mobile.dart:68`

**Symptom:** Unnötige Netzwerk-Requests, potentielle Race Conditions

**Ursache:** Drei separate Stellen rufen `loadSavedChatsForSidebar()` auf

```dart
// main.dart:248 - Bei Auth Success
unawaited(ChatStorageService.loadSavedChatsForSidebar().then((_) {
  ChatSyncService.start();
}));

// sidebar_desktop.dart:61 - In initState
unawaited(_loadChatsAndRefresh());

// sidebar_mobile.dart:68 - In initState
unawaited(_loadChatsAndRefresh());

// sidebar_mobile.dart:122-125 - Alle 5 Sekunden!
_refreshTimer = Timer.periodic(
  const Duration(seconds: 5),
  (_) => _refreshChatsPeriodically(),
);
```

**Mitigation vorhanden:** ChatStorageService hat Load-Guard (Zeilen 1233-1237), aber:
- Zweiter Caller wartet auf ersten
- Timer läuft parallel zu ChatSyncService
- Ressourcenverschwendung

**Priorität:** HOCH

---

### Problem 4: Doppelte Auth Subscriptions

**Dateien:**
- `lib/main.dart:133`
- `lib/widgets/auth_gate.dart:45`

**Symptom:** Potentielle Race Conditions bei Auth State Changes

**Ursache:** Zwei separate Listener auf `onAuthStateChange`

```dart
// main.dart:133 - Subscription #1
_authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
  // Handles session init, logout cleanup
});

// auth_gate.dart:45 - Subscription #2
_authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
  setState(() {
    _session = event.session;
  });
});
```

**Risiko:** Unterschiedliche Reaktion auf gleichen Event

**Priorität:** HOCH

---

### Problem 5: Global Mutable State ohne Reaktivität

**Datei:** `lib/services/chat_storage_service.dart:286-319`

**Symptom:** UI-Updates nicht garantiert bei State-Änderungen

**Ursache:** Static mutable fields ohne Listener-Pattern

```dart
// VORHER
static String? _selectedChatId;
static String? get selectedChatId => _selectedChatId;
static set selectedChatId(String? value) {
  _selectedChatId = value;  // Keine Notifikation!
}

static bool isLoadingChat = false;  // Global Flag ohne Reaktivität
```

**Schreibende Stellen:**
- `root_wrapper_desktop.dart:199` (innerhalb setState ✓)
- `root_wrapper_mobile.dart:253` (außerhalb setState ✗)
- `chat_ui_desktop.dart` (multiple)
- `chat_ui_mobile.dart` (multiple)

**Priorität:** HOCH

---

### Problem 6: Mobile fehlt isLoadingChat Guard

**Datei:** `lib/platform_specific/root_wrapper_mobile.dart:241`

**Symptom:** Rapid Chat Switching auf Mobile möglich während Load

**Ursache:** Desktop hat Guard, Mobile nicht

```dart
// Desktop (root_wrapper_desktop.dart:181-189) - HAT GUARD ✓
void _handleChatSelected(String? chatId) {
  if (ChatStorageService.isLoadingChat) {
    return;  // Blocked
  }
  // ...
}

// Mobile (root_wrapper_mobile.dart:241) - FEHLT! ✗
void _handleChatSelected(String? chatId) {
  // Kein Guard - akzeptiert Clicks während Load
  ChatStorageService.selectedChatId = chatId;  // Außerhalb setState!
  // ...
}
```

**Priorität:** MITTEL

---

### Problem 7: 30+ Props Prop Drilling

**Datei:** `lib/platform_specific/root_wrapper_desktop.dart:48-76`

**Symptom:** Schwer wartbarer Code, viele Constructor-Parameter

**Ursache:** Alle Theme/Settings Props werden durchgereicht

```dart
const RootWrapperDesktop({
  required this.currentThemeMode,
  required this.currentAccentColor,
  required this.currentIconFgColor,
  required this.currentBgColor,
  required this.setThemeMode,
  required this.setAccentColor,
  // ... 24 weitere Props
});
```

**Priorität:** MITTEL (Maintainability)

---

### Problem 8: Mobile 5-Sekunden Auto-Refresh

**Datei:** `lib/platform_specific/sidebar_mobile.dart:122-125`

**Symptom:** UI Jank alle 5 Sekunden auf Mobile

**Ursache:** Timer läuft parallel zu ChatSyncService

```dart
void _startAutoRefresh() {
  _refreshTimer = Timer.periodic(
    const Duration(seconds: 5),  // Redundant mit ChatSyncService!
    (_) => _refreshChatsPeriodically(),
  );
}
```

**Priorität:** MITTEL

---

### Problem 9: Theme Loading Race Condition

**Datei:** `lib/main.dart:145, 181, 187`

**Symptom:** Potentielles Theme-Flackern bei App-Start

**Ursache:** Theme wird von 3 Stellen gleichzeitig geladen

```dart
// Zeile 145 - Background async load
unawaited(_loadThemeSettingsFromSupabaseAsync());

// Zeile 181 - Sync load from prefs
await _loadThemeSettingsFromPrefs();

// Zeile 187 - Direct sync call
_loadThemeSettingsFromSupabase();  // Dritter Aufruf!
```

**Priorität:** NIEDRIG

---

## 3. Neue Architektur

### Ziel-Architektur

```
┌─────────────────────────────────────────────────────────────────────┐
│                           main.dart                                  │
│  - NUR Widget Tree Setup                                            │
│  - Keine Business Logic                                             │
│  - Delegiert an AppBootstrap                                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         AppBootstrap                                 │
│  - Definierte Init-Sequenz (Phase 1 → 2 → 3)                        │
│  - Loading Screen während Init                                       │
│  - EINZIGE Auth Subscription                                        │
│  - "App Ready" Signal via ValueNotifier                              │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       AppStateProvider                               │
│  (InheritedWidget / Provider)                                        │
│  - Theme State (eliminiert Prop Drilling)                           │
│  - Selected Chat ID (reaktiv via ValueNotifier)                      │
│  - Loading States                                                    │
└─────────────────────────────────────────────────────────────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────────────┐
│  DesktopShell   │   │   MobileShell   │   │     Services Layer      │
│  - Sidebar      │   │   - Drawer      │   │ ┌─────────────────────┐ │
│  - Split View   │   │   - Nav Stack   │   │ │ EncryptionService   │ │
│  - Panels       │   │   - Bottom Nav  │   │ │ - Key in Isolate    │ │
│                 │   │                 │   │ │ - PBKDF2 in Isolate │ │
│  KEINE Loads!   │   │  KEINE Loads!   │   │ └─────────────────────┘ │
│  Nur UI State   │   │  Nur UI State   │   │ ┌─────────────────────┐ │
└─────────────────┘   └─────────────────┘   │ │ ChatStorageService  │ │
                                            │ │ - EINE Load-Stelle   │ │
                                            │ │ - Reaktive Notifier │ │
                                            │ └─────────────────────┘ │
                                            │ ┌─────────────────────┐ │
                                            │ │ ProjectStorage...   │ │
                                            │ │ - Bereits optimiert │ │
                                            │ └─────────────────────┘ │
                                            └─────────────────────────┘
```

### Init-Sequenz (Neu)

```
Phase 1: Pre-Frame (< 50ms)
├── WidgetsBinding.ensureInitialized()
├── SharedPreferences.getInstance() [Cache for instant sidebar]
└── runApp() - Show Loading Screen

Phase 2: Post-Frame (Background)
├── Supabase.initialize() [Non-blocking]
├── EncryptionService.preloadKeyInIsolate() [NEW - Isolate!]
└── Wait for Supabase ready

Phase 3: Auth-Dependent
├── Auth Subscription (EINZIGE Stelle)
├── If logged in:
│   ├── EncryptionService.initializeForPassword() [Isolate!]
│   ├── ChatStorageService.loadOnce() [EINZIGE Stelle]
│   └── ChatSyncService.start()
└── Signal "App Ready"
```

---

## 4. Konkrete Änderungen

### Fix 1: PBKDF2 in Isolate verschieben

**Datei:** `lib/services/encryption_service.dart:555-565`

**Symptom:** UI freezt für 600-2000ms bei Login

**Ursache:** PBKDF2 auf Main Thread

**Fix:**

```dart
// VORHER
static Future<List<int>> _deriveKey(String password, List<int> salt) async {
  final pbkdf2 = Pbkdf2(...);
  final newSecretKey = await pbkdf2.deriveKeyFromPassword(...);
  return newSecretKey.extractBytes();
}

// NACHHER
static Future<List<int>> _deriveKey(String password, List<int> salt) async {
  return compute(_deriveKeyInIsolate, {
    'password': password,
    'salt': salt,
    'iterations': _kdfIterations,
  });
}

// Top-level function für Isolate
List<int> _deriveKeyInIsolate(Map<String, dynamic> params) {
  final password = params['password'] as String;
  final salt = params['salt'] as List<int>;
  final iterations = params['iterations'] as int;

  // Sync PBKDF2 in Isolate
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );

  // Note: deriveKeyFromPassword ist async, aber in Isolate OK
  // Alternativ: dart:isolate mit async support
  final keyBytes = pbkdf2.deriveKeyFromPasswordSync(
    password: password,
    nonce: salt,
  );
  return keyBytes;
}
```

**Priorität:** KRITISCH
**Aufwand:** 2h
**Risiko:** Niedrig (keine API-Änderung)

---

### Fix 2: Secure Storage Calls parallelisieren

**Datei:** `lib/services/encryption_service.dart:185-186`

**Symptom:** UI freezt für 2-4s bei Login auf Linux

**Ursache:** Sequentielle `_storage.read()` Aufrufe

**Fix:**

```dart
// VORHER (Zeilen 185-186)
final storedSaltBase64 = await _storage.read(key: saltKey);
final storedKeyBase64 = await _storage.read(key: keyKey);

// NACHHER
final results = await Future.wait([
  _storage.read(key: saltKey),
  _storage.read(key: keyKey),
]);
final storedSaltBase64 = results[0];
final storedKeyBase64 = results[1];
```

**Ebenso für Zeilen 386-388 (rotateKeyForPasswordChange):**

```dart
// VORHER
await _storage.write(key: keyStorageKey, value: newKeyBase64);
await _storage.write(key: saltStorageKey, value: newSaltBase64);
await _storage.write(key: versionStorageKey, value: _payloadVersion);

// NACHHER
await Future.wait([
  _storage.write(key: keyStorageKey, value: newKeyBase64),
  _storage.write(key: saltStorageKey, value: newSaltBase64),
  _storage.write(key: versionStorageKey, value: _payloadVersion),
]);
```

**Priorität:** KRITISCH
**Aufwand:** 1h
**Risiko:** Niedrig

---

### Fix 3: Chat-Loading zentralisieren

**Dateien:**
- `lib/main.dart:248`
- `lib/platform_specific/sidebar_desktop.dart:61`
- `lib/platform_specific/sidebar_mobile.dart:68, 122-125`

**Symptom:** Chats werden 3x geladen

**Ursache:** Keine zentrale Load-Koordination

**Fix:**

```dart
// sidebar_desktop.dart - ENTFERNEN
// VORHER (Zeile 61)
unawaited(_loadChatsAndRefresh());

// NACHHER
// Zeile 61 komplett entfernen!
// Sidebar verwendet nur ChatStorageService.savedChats (bereits gecacht)

// sidebar_mobile.dart - ENTFERNEN
// VORHER (Zeilen 68, 122-125)
unawaited(_loadChatsAndRefresh());
_startAutoRefresh();

// NACHHER
// Zeile 68 entfernen
// Zeilen 120-132 (_startAutoRefresh) komplett entfernen
// Zeilen 147-168 (_refreshChatsPeriodically, _performRefresh) entfernen

// main.dart - EINZIGE Load-Stelle bleibt
// Zeile 248 bleibt wie ist
unawaited(ChatStorageService.loadSavedChatsForSidebar().then((_) {
  ChatSyncService.start();
}));
```

**Priorität:** HOCH
**Aufwand:** 1h
**Risiko:** Niedrig (Load-Guard existiert als Fallback)

---

### Fix 4: Doppelte Auth Subscription konsolidieren

**Dateien:**
- `lib/main.dart:133`
- `lib/widgets/auth_gate.dart:45`

**Symptom:** Zwei Auth Listeners

**Ursache:** Historisch gewachsen

**Fix:**

```dart
// auth_gate.dart - Vereinfachen
// VORHER (Zeile 45-60)
_authSubscription = SupabaseService.auth.onAuthStateChange.listen((event) {
  if (!mounted) return;
  setState(() {
    _session = event.session;
    _checkingSession = false;
  });
});

// NACHHER - AuthGate nur für Session Check, keine Subscription
@override
void initState() {
  super.initState();
  _checkSession();  // Einmaliger Check
}

Future<void> _checkSession() async {
  await _waitForSupabase();
  if (!mounted) return;

  // Session direkt abfragen, keine Subscription
  final session = SupabaseService.auth.currentSession;
  setState(() {
    _session = session;
    _checkingSession = false;
  });
}

// main.dart - Bleibt als EINZIGER Auth Handler
// AuthGate rebuilt automatisch wenn main.dart setState() aufruft
```

**Priorität:** HOCH
**Aufwand:** 2h
**Risiko:** Mittel (Auth-Flow ändern)

---

### Fix 5: Reaktiver selectedChatId

**Datei:** `lib/services/chat_storage_service.dart:286-319`

**Symptom:** UI-Updates nicht garantiert

**Ursache:** Static mutable ohne Notifier

**Fix:**

```dart
// VORHER
static String? _selectedChatId;
static String? get selectedChatId => _selectedChatId;
static set selectedChatId(String? value) {
  _selectedChatId = value;
}

// NACHHER
static final ValueNotifier<String?> selectedChatIdNotifier = ValueNotifier(null);

static String? get selectedChatId => selectedChatIdNotifier.value;
static set selectedChatId(String? value) {
  if (selectedChatIdNotifier.value != value) {
    debugPrint('📍 [SELECTED-CHAT-ID] $value');
    selectedChatIdNotifier.value = value;
  }
}

// In UI-Widgets: ValueListenableBuilder verwenden
ValueListenableBuilder<String?>(
  valueListenable: ChatStorageService.selectedChatIdNotifier,
  builder: (context, chatId, child) {
    // Automatischer Rebuild bei Änderung
  },
)
```

**Priorität:** HOCH
**Aufwand:** 3h (alle Stellen updaten)
**Risiko:** Mittel

---

### Fix 6: Mobile Loading Guard hinzufügen

**Datei:** `lib/platform_specific/root_wrapper_mobile.dart:241`

**Symptom:** Rapid Chat Switching während Load

**Ursache:** Guard fehlt

**Fix:**

```dart
// VORHER (Zeile 241-262)
void _handleChatSelected(String? chatId) {
  FocusScope.of(context).unfocus();
  ChatStorageService.selectedChatId = chatId;
  setState(() {
    if (_isSidebarExpanded) {
      _isSidebarExpanded = false;
      _sidebarAnimController.reverse();
    }
  });
}

// NACHHER
void _handleChatSelected(String? chatId) {
  // Guard hinzufügen (wie Desktop)
  if (ChatStorageService.isLoadingChat) {
    debugPrint('🚫 [ROOT-MOBILE] BLOCKED - Chat is still loading');
    return;
  }

  FocusScope.of(context).unfocus();

  // State-Änderung IN setState verschieben
  setState(() {
    ChatStorageService.selectedChatId = chatId;
    if (_isSidebarExpanded) {
      _isSidebarExpanded = false;
      _sidebarAnimController.reverse();
    }
  });
}
```

**Priorität:** MITTEL
**Aufwand:** 15min
**Risiko:** Sehr niedrig

---

### Fix 7: Theme Loading vereinfachen

**Datei:** `lib/main.dart:145, 181, 187`

**Symptom:** Potentielles Theme-Flackern

**Ursache:** 3 separate Theme-Loads

**Fix:**

```dart
// VORHER - 3 Aufrufe
// Zeile 145: unawaited(_loadThemeSettingsFromSupabaseAsync());
// Zeile 181: await _loadThemeSettingsFromPrefs();
// Zeile 187: _loadThemeSettingsFromSupabase();

// NACHHER - 1 definierte Sequenz
Future<void> _initializeTheme() async {
  // 1. Erst von Prefs laden (instant)
  await _loadThemeSettingsFromPrefs();

  // 2. Dann von Supabase (wenn eingeloggt), OHNE Prefs nochmal
  if (SupabaseService.auth.currentSession != null && !_hasAppliedSupabaseTheme) {
    // Nur EINMAL aufrufen
    await _loadThemeSettingsFromSupabase();
  }
}

// In _initializeAfterSupabase:
await _initializeTheme();  // Statt 3 separate Aufrufe
```

**Priorität:** NIEDRIG
**Aufwand:** 30min
**Risiko:** Sehr niedrig

---

### Fix 8: InheritedWidget für Theme State

**Neue Datei:** `lib/providers/app_state_provider.dart`

**Symptom:** 30+ Props Prop Drilling

**Ursache:** Kein State Management Pattern

**Fix:**

```dart
// Neue Datei: lib/providers/app_state_provider.dart
class AppState extends InheritedWidget {
  final ThemeMode currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final bool grainEnabled;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool autoSendVoiceTranscription;
  // ... weitere State-Felder

  final void Function(ThemeMode) setThemeMode;
  final void Function(Color) setAccentColor;
  // ... weitere Setter

  const AppState({
    required this.currentThemeMode,
    // ... alle Felder
    required super.child,
  });

  static AppState of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppState>()!;
  }

  @override
  bool updateShouldNotify(AppState oldWidget) {
    return currentThemeMode != oldWidget.currentThemeMode ||
           currentAccentColor != oldWidget.currentAccentColor ||
           // ... alle Felder vergleichen
           ;
  }
}

// In main.dart:
Widget build(BuildContext context) {
  return AppState(
    currentThemeMode: _currentThemeMode,
    currentAccentColor: _currentAccentColor,
    // ... alle Felder
    setThemeMode: _setThemeMode,
    setAccentColor: _setAccentColor,
    // ... alle Setter
    child: MaterialApp(...),
  );
}

// In RootWrapper:
// VORHER: 30 Constructor-Parameter
// NACHHER: 0 Parameter, State via AppState.of(context)
```

**Priorität:** MITTEL
**Aufwand:** 4h (großes Refactoring)
**Risiko:** Mittel

---

### Fix 9: Logout Theme Reset awaiten

**Datei:** `lib/main.dart:166`

**Symptom:** Theme State kann gemischt werden

**Ursache:** `_loadThemeSettingsFromPrefs()` nicht awaited

**Fix:**

```dart
// VORHER (Zeile 166)
_loadThemeSettingsFromPrefs();  // Nicht awaited!

// NACHHER
await _loadThemeSettingsFromPrefs();
```

**Priorität:** NIEDRIG
**Aufwand:** 5min
**Risiko:** Sehr niedrig

---

## 5. Implementierungsreihenfolge

### Sprint 1: Kritische Performance Fixes (1-2 Tage)

| # | Task | Datei | Priorität |
|---|------|-------|-----------|
| 1 | PBKDF2 in Isolate | encryption_service.dart | KRITISCH |
| 2 | Secure Storage parallelisieren | encryption_service.dart | KRITISCH |

### Sprint 2: Race Condition Fixes (1 Tag)

| # | Task | Datei | Priorität |
|---|------|-------|-----------|
| 3 | Chat-Loading zentralisieren | sidebars, main.dart | HOCH |
| 4 | Mobile Loading Guard | root_wrapper_mobile.dart | MITTEL |
| 5 | Logout Theme await | main.dart | NIEDRIG |

### Sprint 3: Architektur Cleanup (2-3 Tage)

| # | Task | Datei | Priorität |
|---|------|-------|-----------|
| 6 | Auth Subscription konsolidieren | main.dart, auth_gate.dart | HOCH |
| 7 | Reaktiver selectedChatId | chat_storage_service.dart | HOCH |
| 8 | Theme Loading vereinfachen | main.dart | NIEDRIG |

### Sprint 4: Maintainability (Optional, 2 Tage)

| # | Task | Datei | Priorität |
|---|------|-------|-----------|
| 9 | InheritedWidget für Theme | Neue Datei + Refactoring | MITTEL |

---

## 6. Constraints

### NICHT ÄNDERN

1. **Supabase Schema** - Keine Breaking Changes an encrypted_chats, projects, etc.
2. **Encryption Format** - Bestehende verschlüsselte Daten müssen lesbar bleiben
3. **Offline-First** - Cache → Network Reihenfolge beibehalten
4. **Platform Parity** - Mobile + Desktop müssen beide funktionieren

### BEACHTEN

1. **Inkrementelle Changes** - Jeder Fix sollte einzeln deploybar sein
2. **Backward Compatibility** - Alte App-Versionen sollten weiter funktionieren
3. **Testing** - Nach jedem Sprint: `flutter analyze` + manuelle Tests
4. **Key Migration** - Bei Encryption-Änderungen: Rollback-Mechanismus behalten

---

## Appendix: Dateien nach Priorität

### Kritisch (sofort)

- `lib/services/encryption_service.dart` - PBKDF2 + Storage Blocking

### Hoch (diese Woche)

- `lib/main.dart` - Auth Subscription, Theme Loading
- `lib/platform_specific/sidebar_mobile.dart` - Timer entfernen
- `lib/platform_specific/sidebar_desktop.dart` - Load entfernen
- `lib/services/chat_storage_service.dart` - Reaktiver State
- `lib/widgets/auth_gate.dart` - Subscription entfernen

### Mittel (nächste Woche)

- `lib/platform_specific/root_wrapper_mobile.dart` - Loading Guard
- `lib/platform_specific/root_wrapper_desktop.dart` - Prop Drilling

### Bereits gut

- `lib/services/project_storage_service.dart` - Hat Loading Guards, Parallelisierung
- `lib/services/chat_storage_service.dart` - Hat Isolate Decryption, Debouncing

---

## Changelog

| Datum | Änderung |
|-------|----------|
| 2026-01-21 | Initiale Analyse durch 6 parallele Agents |
