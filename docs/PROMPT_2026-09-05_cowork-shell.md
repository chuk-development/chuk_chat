# Auftrag fuer Session cowork-shell (P3-Rest Shell), 2026-09-05

Du bist eine Flutter-Session im Repo /home/user/git/cowork (Branch cowork, geteilter
Working-Tree, KEIN Worktree). Koordinator ist die Session `cowork-76` — melde dich
ZUERST per SendMessage bei `cowork-76` mit deinem Session-Namen (ListAgents zeigt ihn)
und "Auftrag gelesen", danach alle Meldungen an cowork-76.

## Lesen, in dieser Reihenfolge
1. docs/COORDINATION.md — nur Kopf + letzte 40 Log-Zeilen (Regeln, wer was besitzt).
2. docs/HANDOVER_2026-09-05_SHELL_SETTINGS_cowork-5c.md — KOMPLETT (dein Vorgaenger).
3. docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md — Abschnitt WS-1 (Shell).
4. docs/diffs_c6_messenger_shell.md, docs/HANDOVER_2026-09-05_MOBILE.md (Mobile-Layer
   von cowork-c6, schon eingebaut).
5. `bd show cowork-b6h`, `bd show cowork-8y2` und den hxh-Folgebead (bd ready).

## Auftrag
P3-Rest = WS-1 Shell, Bead cowork-b6h + cowork-8y2 + hxh-Folgebead:
- chuk root-wrapper Layout (~/git/chuk_chat master ist die Vorlage, verbatim-Regel:
  importierte chuk-Dateien nicht anpassen, cowork-Dateien duerfen es).
- AppBar weg; Copy-full-chat-Button in chuks vierten Slot oben rechts (zwei Tests
  finden ihn heute per Tooltip — Tests mitziehen, Aussage nicht abschwaechen).
- Agents-Sidebar auf chuk-Chrome (Roster ist schon auf sidebar_chrome, 5c).
- rechter Bereich Rooms/Browser, CoworkShellHost oberhalb des Desktop/Mobile-Switch.
- cowork-8y2: AppShellConfig an MessengerShell durchreichen (zwei Leser des Statics:
  cowork_thread_view._buildChat und messenger_shell._openSettings; Fixture
  test/support/shell_config.dart), CoworkApp.shellConfig-Static abraeumen.
- hxh-Folgebead: Modell-Einstieg umhaengen, Wrapper ModelSettingsPage loeschen.
- Phone-Pfad (c6) und Notification-Listener (c6, additiv in initState/dispose) in
  messenger_shell.dart MUESSEN erhalten bleiben; Phone-Test 420 px, Tablet 660 px,
  Wide 720+.

## Dateibesitz (deine Dateien)
app/lib/pages/messenger_shell.dart, app/lib/main.dart (nur Shell-Zeilen),
app/lib/widgets/agent_roster_view.dart, cowork_shell_state (neu, falls noetig),
app/lib/pages/settings/model_settings_page.dart (loeschen), zugehoerige Tests
(messenger_shell_test, widget_test, agent_roster_view_test, model_settings_page_test).
NICHT deine: cowork_thread_view.dart (9e/84/c6 Hooks; nur mit Ansage an cowork-76),
services/**, platform_specific/**, chuk-verbatim-Dateien (tools/chat_ui_manifest.txt),
browser_view_page.dart, third_party/**, Python.

## Regeln (hart)
- Kein Commit, nie, ausser der User gibt es DIR direkt in dieser Session.
- Ein Flutter-Compiler gleichzeitig auf der Maschine: vor JEDEM flutter test/analyze/build
  `pgrep -af 'flutter_tester|frontend_server'` (der frontend_server der laufenden App
  zaehlt nicht) und `free -m` (>1,5 GB frei); Compiler-Fenster vergibt cowork-76 —
  frage "Fenster?" und starte erst nach "Fenster frei (shell)". Tests einzeln, eine Datei
  pro Lauf; scoped analyze beim Iterieren, voller analyze nur am Gate.
- Die laufende App-Instanz haelt cowork-c6 (flutter-hot). Nicht anfassen, kein Hot Reload.
- Keine UI-Automation/Screenshots bis der User "Bildschirm frei" sagt; dann
  gnome-screenshot + convert-Crop nach docs/screenshots/shell/ + SendUserFile.
- Signaturaenderungen mit allen Fakes/Tests im selben Schritt; Tree muss zwischen
  Schritten kompilieren.
- Subagenten: nur Opus 5, einer gleichzeitig. Bei 429: 60 s warten, retry.
- Kontext: ab 550k stoppen, Handover docs/HANDOVER_2026-09-05_SHELL_cowork-shell.md.
- Status-Antworten an cowork-76 in 3-5 Zeilen, mit Testzahlen; nie gruen melden, was du
  nicht gesehen hast. Antworte dem User knapp auf Deutsch.
- Bug gefunden, nicht sofort gefixt → `bd create`. Fertig → `bd close`.
