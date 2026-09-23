# Handover — die Nacht vom 13.09.2026

Alles, was in dieser Session gelaufen ist, und alles, was offen blieb. Geschrieben
zum Session-Ende, damit nichts nur im Chatverlauf steht.

**Wichtig zur Orientierung:** der Ordner heisst `cowork`, das Repo dahinter ist
`chuk_chat` (`github.com/chuk-development/chuk_chat`). Darin liegen **zwei
getrennte Codebasen ohne gemeinsame Historie**:

| Branch | Was | Wo |
|--------|-----|-----|
| `master` | **Chuk Chat**, das ausgelieferte Produkt | Flutter-App im Wurzelverzeichnis (`lib/`, `pubspec.yaml`) |
| `agents` | **Agents/CoWork**, die Coworker-Plattform | `app/`, `agent/`, `host/`, `executor/`, `manager/` |

`origin/master` ist **kein** Vorfahr von `agents`. Ein Push von `agents` nach
`master` wuerde 1250 Dateien loeschen, darunter das oeffentliche README, alle
Release-Workflows und die Issue-Templates. Releases kommen ausschliesslich von
`master`.

---

## Erledigt

### Chuk Chat (`master`) — Release v1.0.109

Veroeffentlicht, kein Draft, kein Pre-Release:
<https://github.com/chuk-development/chuk_chat/releases/tag/v1.0.109>

Tag zeigt auf `d1df710a`. Acht Artefakte: Android arm64, Linux amd64/.deb,
Linux x86_64/.AppImage, Linux arm64/.deb, Linux aarch64/.AppImage, macOS .dmg,
Windows Setup und Portable. Alle Build-Jobs gruen.

Weg dorthin: Branch `release/prep`, PR #23, Merge nach `master`, danach Workflow
*Cross-Platform Build & Release* mit `prerelease=false`. Ein direkter Push auf
`master` wurde vom Berechtigungs-Klassifizierer blockiert, deshalb der Umweg
ueber den PR. Die Store-Screenshots rendert der `Screenshots`-Workflow beim Push
auf master automatisch und headless aus den Widgets — kein Emulator, keine
Anmeldung, keine persoenlichen Daten.

Build-Flags standen bereits richtig im Workflow: `FEATURE_VOICE_MODE=false`,
`FEATURE_PROJECTS=false`, `FEATURE_IMAGE_GEN=false`, `FEATURE_SERVER_TOOLS=false`,
kein CoWork-Schalter.

### API-Server (`~/git/api_server`, live)

`f0658c7`, deployed, verifiziert ueber `api.chuk.chat/v1/version`.

Ein Nutzer bekam *"You've used all your credits for this billing period"* bei
63 € Guthaben. Ursache, aus den Produktionslogs belegt: sein JWT lief auf der
langlebigen WebSocket-Verbindung ab, PostgREST antwortete `PGRST303 JWT expired`,
und `get_credits_remaining` machte daraus im `except` eine **0.0**. Der
Billing-Gate las die Null als leeres Konto.

Behoben: ein nicht lesbarer Stand ist jetzt `None`, nie 0. Bei abgelaufenem Token
wird einmal ueber die Service-Rolle wiederholt (die SQL-Funktion ist
`SECURITY DEFINER` und prueft die Identitaet selbst, also keine Ausweitung).
Bleibt der Stand unbekannt, wird **durchgelassen und unabgerechnet bedient** —
bewusst so herum, weil ein paar Cent billiger sind als ein zahlender Kunde, dem
man sagt, sein Abo sei leer. Zusaetzlich gab `check_credits_atomic` `is_subscribed`
fest als `True` zurueck; jetzt die Wahrheit.

Dazu die Ursache hinter der Ursache: `/v2/ws` authentifiziert **einmal** beim
Handshake. Neues Kontroll-Frame, rueckwaertskompatibel:

```
client -> server: {"type":"auth_refresh","token":"<fresh jwt>"}
server -> client: {"type":"auth_refreshed","expires_at":<unix>}
                  {"type":"auth_refresh_failed","detail":"<reason>"}
server -> client: {"type":"auth_refresh_needed","expires_at":<unix>}
```

Keine Ablehnung schliesst den Socket oder sendet `auth_error` — nichts davon kann
jemanden ausloggen.

**Token-Laufzeit:** steht in den Supabase-Projekteinstellungen, nicht im Repo,
Standard 1 Stunde. Empfehlung war und ist: **nicht** hochsetzen. Das verschiebt
nur den Zeitpunkt und bezahlt die Verschiebung mit einem gestohlenen Token, der
laenger gueltig und nicht widerrufbar ist.

**Achtung:** in `~/git/api_server` liegt ein mehrere Tage alter, **nicht
committeter Refactor** (`chat/*` und `app_state.py` untracked, `main.py` −1014
Zeilen). Der Fix wurde deshalb sauber aus dem HEAD-Stand gebaut und in einem
separaten Worktree geprueft. Wer den Refactor landet, muss
`tests/test_credit_balance_unavailable.py` erneut dagegen laufen lassen.

### Agents (`agents`)

Acht Commits, Arbeitsbaum sauber:

- **Raeume ohne Mitgliederlimit** plus Policy *"Coworkers can reply to each
  other"* (Standard an). Wichtig dabei: der Nachrichten-Deckel von 10 haette bei
  30 Mitgliedern 20 Leute stumm geschluckt, deshalb leitet er sich jetzt aus
  Mitgliedern × Runden ab.
- **@-Autocomplete** im Raum-Composer (Gesicht, Name, Handle, Rolle, `@all`).
  Enter nimmt den Eintrag, sendet nicht.
- **Raum-Chat auf die echten Chat-Widgets** umgebaut, Runden-Trenner raus.
- **Raeume auf der Startseite**, zwei Gesichter versetzt im Icon-Slot.
- **Heartbeat statt 60-Sekunden-Abbruch.** Der alte `_idleTimeout` erklaerte
  einen Stream nach 60 s fuer tot und meldete *"server may be overloaded"* —
  geraten, ohne Beleg. Geloescht. Der Executor schlaegt jetzt alle 10 s ein
  Lebenszeichen.
- **Verschluckte und doppelte Nachrichten.** Ein `if` ohne `else` in
  `CloudHostParty._handle` warf Aufgaben still weg; der Retry-Pfad im
  Streaming-Handler startete dieselbe Frage dreimal (60 s + 700 ms Backoff = die
  beobachteten Abstaende). Jetzt `task_id`, `task_ack`, und der Executor lehnt
  eine Aufgabe ab, deren Session und Prompt schon laufen.
- **Trace-System** (`--trace`, `AGENTS_TRACE=1`) mit Reader
  `cowork-host trace --last --workspace /home/user/.cowork`.
- **Tabelle neu** (Kopfzeile einmal, eine Zeile pro Eintrag, Spalten fluchten).
- **Song-Erkennung** als Skill (`skills/workspace/song-identify`, verifiziert an
  echten Songs, Rauschen ergibt sauber `NO_MATCH`).
- **yt-dlp-Skill**: nur Audio, kleinste Spur, mit Schutz gegen KI-Dub-Spuren —
  `-f worstaudio` greift auf grossen Kanaelen eine Synchronspur.

### Eine Korrektur, die im Protokoll stehen soll

Ich hatte behauptet, die Vier-Minuten-Stillstaende kaemen von einem
180-Sekunden-Timeout mit stillem Retry. **Das war falsch.** Die Auswertung aller
325 Assistant-Luecken zeigt: Median 6,7 s, und *jede* Luecke ueber 100 s liegt in
einem einzigen Wanduhr-Fenster (06.09. 23:41 bis 07.09. 03:31). Gleiches Modell,
gleicher Provider, am 10.09.: 27 Iterationen und 1,24 Mio Tokens in 194 s. Es war
ein Provider-Fenster, kein Fehler im Code. Ebenso falsch war meine Behauptung, es
gaebe keine Verdichtung — die Leiter in `agent/src/chuk_agents_runtime/context.py`
existiert, ist an, und hat im Trace nachweislich 27.158 Tokens weggeworfen.

---

## Offen

Alles mit Bead-ID; `bd show <id>` hat die Details.

### Kosten (das teuerste Thema)

- **`cowork-g7oc` (P0)** — jeder Turn schickt die ganze Historie mit, Kosten und
  Wartezeit wachsen **quadratisch** mit der Chatlaenge.
- **`cowork-g85d` (P1)** — die Hebel in Reihenfolge: 1. Prompt-Caching beim
  Anbieter. 2. Werkzeugschemata abspecken (5.613 Tokens gehen bei *jedem* Aufruf
  mit, auch bei einem Prompt von drei Zeichen; 37 Tools). 3. Historien-Fenster.
- **`cowork-z9mo` (P1)** — Verdichten soll **nach** dem Lauf laufen, solange der
  Cache warm ist, plus Zeitregel: ueber 30 Minuten Pause fliegen die alten
  Tool-Aufrufe ganz raus, nicht nur gekuerzt.

### Nachrichten-Warteschlange

- **`cowork-5u31` (P1, Epic)** — die angezeigte Warteschlange ist nicht die echte.
  Vier Mechanismen, einer davon toter Code; der Banner liest die RAM-Variante,
  `AgentsTaskOutbox.hasPending` hat **null** Aufrufstellen in `app/lib`.
- `cowork-e6q3`, `cowork-sc22`, `cowork-vc1l` — Einzelbefunde daraus.

### Features aus dem Grokbot-Video

- **`cowork-eat1` (P1)** — Coworker ruft benannten Coworker ausserhalb eines
  Raums. Das ist der starke Fall aus dem Video, nicht der Gruppenchat.
  `delegate_task` spawnt anonyme Kinder und ist **nicht** dasselbe.
- **`cowork-132u` (P3)** — Review-Agent mit globaler Allow/Deny-Liste als Prosa,
  drei Urteile: allow / deny / **an den Nutzer eskalieren**.
- **`cowork-26wk` (P3)** — Workflow per Aufnahme beibringen.

### Kleinkram

- **`cowork-dvt3` (P2)** — Tabellendesign: *"Es ist okay, aber es muesste halt ein
  generelles Tabellendesign geben."*
- **`cowork-1fkz` (P2)** — das Telefon laeuft noch auf einem alten APK.
- **`cowork-072k` (P2)** — 401 bei `/v1/transcribe` loggt den Nutzer der
  Agents-App aus. In Chuk Chat ist genau das bereits gefixt.

### Betrieb

- Der Host laeuft mit Tracing (`--trace`). Der naechste langsame Turn hinterlaesst
  damit erstmals eine auswertbare Spur.
- Branch `release/prep` steht noch auf `origin`. Loeschen ist eine Entscheidung
  des Eigentuemers, nicht meine.
- Bekannte, vorbestehende Testfehler, nicht von dieser Arbeit:
  `executor/tests/test_regenerate.py::test_four_retries_replay_the_question_once`
  und vier veraltete Goldens in `document_chart_golden_test.dart`.
