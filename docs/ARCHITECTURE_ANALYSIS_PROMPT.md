# Architecture Analysis Task

Du bist ein Senior Software Architect. Analysiere die chuk_chat Flutter Codebase und erstelle ein detailliertes Refactoring-Dokument.

## Kontext

Diese App hat:
- **Desktop UI** (`lib/platform_specific/*_desktop.dart`)
- **Mobile UI** (`lib/platform_specific/*_mobile.dart`)
- **Shared Services** (`lib/services/`)
- **E2E Encryption** (alle Chats/Projekte verschlüsselt)
- **Offline-First** Anspruch (Cache → Network)

## Bekannte Probleme

1. **UI Freezes** - Main Thread wird blockiert durch:
   - `flutter_secure_storage` auf Linux (1-2s für Key-Load)
   - Synchrone Encryption/Decryption
   - Cascading await chains

2. **Race Conditions** - Gleiche Daten werden von mehreren Stellen geladen:
   - `main.dart` lädt Chats
   - `sidebar_desktop.dart` lädt auch Chats
   - `sidebar_mobile.dart` lädt auch Chats

3. **Unklare Initialisierung** - Keine definierte Boot-Sequenz:
   - Auth State ändert sich mehrfach
   - Services initialisieren sich gegenseitig
   - Keine klare "App is ready" Signal

4. **Platform-Spezifischer Code** vermischt mit Business Logic

## Deine Aufgabe

### Phase 1: Analyse (spawn parallel agents)

Analysiere diese Dateien parallel:

| Agent | Dateien | Fokus |
|-------|---------|-------|
| 1 | `lib/main.dart` | Init flow, Auth handling |
| 2 | `lib/services/chat_storage_service.dart` | Chat CRUD, Caching |
| 3 | `lib/services/encryption_service.dart` | Crypto, Key management |
| 4 | `lib/services/project_storage_service.dart` | Project CRUD |
| 5 | `lib/platform_specific/sidebar_*.dart` | UI initialization |
| 6 | `lib/platform_specific/root_wrapper*.dart` | Platform routing |

Für jede Datei dokumentiere:
- Verantwortlichkeiten (was macht sie?)
- Dependencies (was ruft sie auf?)
- Blocking Calls (was blockiert UI?)
- Race Conditions (was wird doppelt aufgerufen?)

### Phase 2: Dependency Graph

Erstelle einen Dependency Graph:
```
main.dart
  ├── SupabaseService
  ├── EncryptionService
  │     └── flutter_secure_storage (BLOCKING!)
  ├── ChatStorageService
  │     ├── EncryptionService
  │     └── SharedPreferences
  └── ...
```

### Phase 3: Refactoring Plan

Schlage eine neue Architektur vor:

```
┌─────────────────────────────────────────────────────────┐
│                      main.dart                          │
│  - Nur Widget Tree setup                                │
│  - Keine Business Logic                                 │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                   AppBootstrap                          │
│  - Definierte Init-Sequenz                              │
│  - Loading Screen während Init                          │
│  - "App Ready" Signal                                   │
└─────────────────────────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
┌─────────────────┐ ┌─────────────┐ ┌─────────────────┐
│ DesktopShell    │ │ MobileShell │ │ Services Layer  │
│ - Desktop UI    │ │ - Mobile UI │ │ - Encryption    │
│ - Sidebar       │ │ - Drawer    │ │ - Storage       │
│ - Split View    │ │ - Nav Stack │ │ - Sync          │
└─────────────────┘ └─────────────┘ └─────────────────┘
```

### Phase 4: Konkrete Änderungen

Für jedes Problem, dokumentiere:

```markdown
## Problem: [Name]
**Datei:** `path/to/file.dart:123`
**Symptom:** UI freezt für 2 Sekunden
**Ursache:** Synchroner SecureStorage Aufruf
**Fix:**
\`\`\`dart
// Vorher
final key = await secureStorage.read(key: 'encryption_key');

// Nachher
// Key wird beim App-Start in Isolate geladen
// UI zeigt Loading Screen bis ready
\`\`\`
**Priorität:** HIGH/MEDIUM/LOW
```

## Output Format

Schreibe das Ergebnis in: `docs/REFACTORING_PLAN.md`

Das Dokument soll so strukturiert sein, dass ein anderer Agent es als Arbeitsanweisung nutzen kann um die Änderungen durchzuführen.

## Wichtige Constraints

1. **Keine Breaking Changes** an der Supabase Schema
2. **Encryption muss funktionieren** - Nutzer haben verschlüsselte Daten
3. **Offline-First bleibt** - Cache immer zuerst
4. **Mobile + Desktop** müssen beide funktionieren
5. **Inkrementelle Änderungen** - nicht alles auf einmal

## Starte jetzt

1. Spawn 6 parallel Agents für Phase 1
2. Warte auf alle Ergebnisse
3. Erstelle Dependency Graph
4. Schreibe `docs/REFACTORING_PLAN.md`
