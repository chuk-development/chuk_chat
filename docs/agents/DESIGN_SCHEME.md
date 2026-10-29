# Agents: eigenes Design-Schema

Stand: 2026-10-29. Status: Vorschlag, noch nicht umgesetzt.
Gilt nur für die Agents-Hälfte (`FEATURE_AGENTS=true`).

Rangfolge bleibt: `docs/AGENTS_UI_UNIFY.md` > `docs/DESIGN.md` > diese Datei.
Diese Datei fügt eine Identitätsschicht hinzu. Sie baut keine zweite Optik.
Wo sie eine Regel biegt, steht es in Abschnitt 4.

Im UI heißen sie immer "Agents" / "Agent". Nie "Bot", nie "CoWork", nie
"Coworker". Die früheren "Artifacts" heißen "Pages".

Anlass: Grok hat im Oktober 2026 Schrift, Mobile-Layout und Voice-Modus
(Körnung/"Noise") erneuert. Wir kopieren nichts davon. Wir nehmen nur die
Frage mit: Woran erkennt man unsere Agents auf einen Blick?

## 1. Was es heute gibt

Gut und bleibt:

- **Gesicht** `AgentFace` / `ExpressiveFace` (`lib/ui/expressive/agent_face.dart`):
  expressive Silhouette aus der Agent-ID, Monogramm oder Foto, Präsenzpunkt.
  Die Silhouette ist schon unser stärkstes Merkmal.
- **Statuszeile** `AgentStatusLine` (`lib/ui/expressive/agent_status.dart`):
  sagt nur, was die App beobachtet. Punkt auf der Grundlinie, x-Höhe.
- **Einheitliche Chrome**: Chips, Pill, Composer, Bubbles sind chuks
  Komponenten (UNIFY-Ergebnis A–D).

Generisch oder kaputt (geprüft im Code):

1. **Kontrast im Hellmodus fällt durch.** `agentAccent` nimmt HSL mit
   L = 0,62. Weißes Monogramm darauf: 1,9–2,4 : 1 bei Gelb, Grün, Türkis,
   Cyan, Hellblau, Blaugrau (6 von 13 Farben). Grenze für großen Text: 3 : 1.
   Ursache: HSL-Helligkeit ist nicht Wahrnehmungshelligkeit.
2. **Zwei Paletten-Plätze sind dieselbe Farbe.** `0xFF40C4FF` und
   `0xFF607D8B` haben beide Farbton ≈ 200°. Mit fester Sättigung werden sie
   gleich. 13 Plätze, aber nur 12 Farben.
3. **Editor-Vorschau zeigt eine andere Farbe.** `AgentFace` mit
   `profileOverride` nimmt `AgentAvatar.hueOf` (roher Hash). Das echte
   Gesicht nimmt den Paletten-Farbton. Ohne gewählte Farbe weichen beide ab.
4. **Gewählte Farbe geht roh durch.** `Color(profile.colorValue)` ohne
   Anpassung. `0xFFFFC400` mit weißem Monogramm ist kaum lesbar.
5. **Statusfarben sind iOS-Hex, sechsmal hart kodiert** (`0xFF34C759`,
   `0xFFFF9F0A` in `agent_face.dart`, `agent_status.dart`,
   `mobile_chat_chrome.dart`). Gleich in Hell und Dunkel.
6. **"Arbeitet" und "bereit" sehen gleich aus.** Beide grüner Vollpunkt.
   Nur Farbe trägt die Information; der Unterschied fehlt ganz.
7. **Ungelesen ist auf Telefon und Desktop verschieden.** Telefon: Zeile mit
   Agent-Farbe 13 % getönt. Desktop (§14.3): fett + kleiner Punkt.
8. **Mono ist zufällig.** `fontFamily: 'monospace'` (Systemschrift, je OS
   anders) in `agent_run_views.dart`, `agent_activity_timeline.dart`,
   `agents_action_approval_card.dart`. Das gebündelte JetBrains Mono wird
   dort nicht genutzt.
9. **Material-Glyphen im Inbox-Code**: `Icons.push_pin_rounded` u. a. direkt
   als `Icon` in `mobile_agent_list.dart`. Verstößt gegen DESIGN.md §5.
10. **Gesichtsgrößen wild**: 18, 28, 32, 44, 48, 96, 104 px.
11. **Voice ist neutral grau** (`VoiceStageFrame`: `surfaceContainerHighest`).
    Nichts zeigt, mit wem man spricht.
12. **Monogramm trägt wenig.** Auto-Namen wie `brisk-heron`: 7 von 34
    Adjektiven beginnen mit S, 6 mit C. Silhouette und Farbe müssen die
    Arbeit machen. Das ist ok, wenn Farbe sauber ist.

## 2. Das Schema

### 2.0 Erstes Prinzip: Weniger ist besser

Regel des Owners. Sie schlägt jede andere Regel in dieser Datei.

- **Weniger Knöpfe.** Ein Header hat links Zurück + Agent-Pill, rechts
  höchstens einen Knopf ("…"). Alles andere geht ins Menü. Ein Menü hat
  höchstens 5 Einträge.
- **Weniger Flächen.** Keine Karte in einer Karte. Eine Liste ist eine
  Gruppe. Ein Profil hat höchstens 2 Gruppen über der Falz.
- **Weniger Farben.** Pro Screen: Theme-Flächen + Nutzer-Akzent + die
  Gesichtsfarben. Keine Statusfarbe ohne Status. Kein Akzent für Deko.
- **Weniger Text.** Ein Untertitel nur, wenn er etwas sagt, das der Titel
  nicht sagt. Keine Erklärzeile unter jeder Einstellung.
- **Weniger Schriften.** Eine Schrift für UI und Chat, Mono nur für Code und
  Maschinen-Werte.
- Prüffrage vor jedem neuen Element: Was fehlt, wenn es weg ist? Fehlt
  nichts, kommt es nicht rein.

Leitidee in einem Satz: **chuk bleibt die Bühne, der Agent bringt sein
Gesicht, seine Farbe und eine "Maschinenstimme" in Mono mit.**

Drei Merkmale, sonst nichts:

- **Gesicht**: Silhouette + Farbton, stabil aus der ID.
- **Maschinenzeile**: was der Agent tut, in JetBrains Mono.
- **Körnung**: feines Korn auf Agent-Flächen (Voice, Inbox, Profilkopf).

### 2.1 Identität pro Agent

**Farbe aus HCT, nicht aus HSL.** HCT-Ton (Tone) ist Wahrnehmungshelligkeit.
Gleicher Ton = gleicher Kontrast, für jeden Farbton. Flutter bringt das mit
(`material_color_utilities`, `Hct.from(hue, chroma, tone)`, schon im Lock).

- 12 Farbton-Plätze, 30° Abstand: 25, 55, 85, 115, 145, 175, 205, 235, 265,
  295, 325, 355.
- Platz = FNV-1a(`agent.id`) mod 12. Eigener Hash wie heute, getrennt vom
  Silhouetten-Hash. 12 Farben × 8 Silhouetten = 96 Kombinationen.
- Die ID ändert sich nie (auch nicht bei Umbenennen). Also bleibt die Farbe.
- Gesichtsfüllung: **Ton 45, Chroma 48** (Gamut kappt bei Gelb/Cyan).
  **Gleich in Hell und Dunkel.** Ein Agent hat überall dieselbe Farbe.
- Monogramm: Weiß, w800, 0,38 × Größe (wie heute).
- Wählt der Nutzer eine Farbe, speichern wir den **Farbton-Platz**, nicht den
  Hex-Wert. Er geht durch dieselbe Formel. Alte Hex-Werte: nächster Platz.
- Neutral ("Graphit", Farbton 250, Chroma 6, Ton 45) nur als Nutzerwahl.

Gemessen (Skript `_scratch/agent_hct_tokens.dart`, WCAG-Formel):

| Platz | Hex (T45 C48) | Weiß darauf | vs. Dunkel `#111318` | vs. Hell `#F8F9FF` |
|---|---|---|---|---|
| 25 | `#AC4D44` | 5,39 | 3,45 | 5,13 |
| 55 | `#A3560E` | 5,39 | 3,45 | 5,13 |
| 85 | `#896500` | 5,35 | 3,47 | 5,09 |
| 115 | `#697000` | 5,36 | 3,47 | 5,10 |
| 145 | `#367835` | 5,39 | 3,45 | 5,13 |
| 175 | `#007961` | 5,37 | 3,46 | 5,11 |
| 205 | `#00767F` | 5,39 | 3,45 | 5,13 |
| 235 | `#00739C` | 5,34 | 3,48 | 5,08 |
| 265 | `#3D6AB5` | 5,35 | 3,47 | 5,09 |
| 295 | `#6E5EB3` | 5,36 | 3,46 | 5,10 |
| 325 | `#90539D` | 5,37 | 3,46 | 5,11 |
| 355 | `#A54D75` | 5,36 | 3,47 | 5,10 |

Alle ≥ 4,5 : 1 für das Monogramm (heute teils 1,9). Alle ≥ 3 : 1 als
Fläche gegen beide Hintergründe. Die Werte sind gedämpfter als die heutige
Palette. Das passt zu chuks "warm paper"-Marke und wirkt weniger nach
Material-Standard.

**Agent-Container** (nur Voice, siehe 2.4): Ton 94 / Chroma 12 (hell),
Ton 18 / Chroma 12 (dunkel). Beispiel Platz 265: `#E9EDFE` / `#272C38`.

**Silhouette**: bleibt wie heute (`expressiveShapeFor(id)` oder Nutzerwahl).

**Gesichtsgrößen** (eine Skala, sonst keine):

| Token | px | Wo |
|---|---|---|
| `face.xs` | 20 | Room-Turn, Erwähnung, Mitgliederliste inline |
| `face.s` | 28 | Header-Pill, Mention-Picker, Room-Mitglieder |
| `face.m` | 40 | Desktop-Roster, Quick-Switcher, Sheets |
| `face.l` | 48 | Telefon-Inbox-Zeile (DESIGN §10) |
| `face.xl` | 96 | Profil, Einstellungen, Voice-Bühne |

### 2.2 Typografie-Rollen

**Befund am Telefon des Owners (2026-10-29, `23_chuk_theme.png`,
`24_chuk_theme_2.png`):** Interface-Schrift = **Merriweather (Serif)**,
Chat-Schrift = **JetBrains Mono**. Theme-Pack "Cappuccino". Das Pack selbst
setzt Merriweather (`lib/theme/theme_presets.dart`, `uiFont:
kChatFontFamilyMerriweather`). Er hat die Serife also nicht bewusst gewählt:
das Pack hat sie mitgebracht. Mono als Chat-Schrift war eine eigene Wahl.

Warum sich das schlecht liest:

- **Mono für Fließtext**: jeder Buchstabe gleich breit. Wortbilder zerfallen,
  "i" und "m" gleich breit, etwa 15–20 % weniger Wörter pro Zeile. Gut für
  Code, schlecht für Absätze.
- **Merriweather in der UI**: kräftige Serifen, breit, auf dunklem Grund bei
  14 px laut und unruhig. Serife in Knöpfen und Pills wirkt wie ein Buch,
  nicht wie eine App.
- **Arimo** (heutiger Chat-Standard): Arial-Maße, x-Höhe ≈ 0,52 em, eng
  laufend, altes Design. Lesbar, aber nicht angenehm.
- **System** (heutiger UI-Standard): auf Pixel Roboto, gut. Auf Linux und
  Windows je nach System anders (Cantarell, Noto, Segoe). Die App sieht auf
  jedem Gerät anders aus.

**Empfehlung: eine Schrift für UI und Chat: Inter (variabel, SIL OFL),
gebündelt.**

- x-Höhe ≈ 0,55 em (1118/2048). Wirkt bei 15–16 px so groß wie andere bei 17.
- Offene Formen, klare Unterscheidung `Il1`, `0O`. Für Bildschirm gezeichnet.
- Volles Latin Extended: ä ö ü ß und großes ẞ, Umlaut-Punkte sitzen frei
  über der x-Höhe, stoßen nicht an die Zeile darüber.
- Android: rendert als gebündelte TTF in Flutter/Impeller überall gleich.
  Kein Hinting-Problem wie bei alten Arial-Klonen. Variable Achse `wght`
  deckt 400–800 mit einer Datei ab.
- `tnum` (Tabellenziffern) für Kosten und Zeiten in der Maschinenzeile.
- Kosten: volle variable TTF ≈ 800 KB; Latin-Subset ≈ 300 KB. Dafür können
  Arimo und Merriweather als Standard raus (sie bleiben wählbar).
- Größen: Chat-Text **16 px, Zeilenhöhe 1,5** (heute 15). UI-Text 14–15 px,
  Zeilenhöhe 1,35. Absatzabstand 0,6 em.

Ohne neue Datei (Sofortlösung): UI = System, Chat = System. Auf dem Pixel
ist das Roboto, deutlich angenehmer als Serife + Mono.

Zwei Regeln dazu:

- **Ein Theme-Pack setzt keine Schrift.** Farbe und Schrift sind zwei
  Entscheidungen. Ein Pack, das still die Schrift tauscht, ist genau der
  "Font-Scheiß", den der Owner nicht eingestellt haben will.
- **Mono ist als Chat-Schrift wählbar, aber nie Standard und nie Teil
  eines Packs.**

Neu für Agents ist nur eine Rolle: **die Maschinenzeile in JetBrains Mono** (schon
gebündelt, `pubspec.yaml`). Mono passt zur Marke (chuk.chat: warm paper +
mono). In der Chat-Hälfte steht Mono nur in Code. In Agents spricht damit
"die Maschine": was gerade läuft, was es kostet.

| Rolle | Schrift | Größe / Gewicht | Wo |
|---|---|---|---|
| Agent-Name, Zeile | UI-Schrift | `titleMedium`, w600 (ungelesen w800) | Inbox, Roster |
| Agent-Name, Header-Pill | UI-Schrift | 15 px, w800 | Thread-Header |
| Agent-Name, groß | UI-Schrift | `headlineSmall`, w700 | Profil, Voice |
| Monogramm | UI-Schrift | 0,38 × Größe, w800, −0,5 Laufweite | Gesicht |
| Status-Wort ("Active now") | UI-Schrift | 11 px, w700 | Statuszeile |
| **Maschinenzeile** | **JetBrains Mono** | 11–12 px, w500, `tabularFigures` | Tool-Name im Status, Run-Kosten, Tokens, Laufzeit, Modell-ID, Pfade, Argument-Blöcke |
| Nachricht | Chat-Schrift (Standard Inter) | 16 px, Zeilenhöhe 1,5 | Thread |

Regel: Mono nur für Maschinen-Werte. Nie für Sätze, die der Agent schreibt.
Ein Token-Stil `agentsMachineStyle(context)` ersetzt jedes `'monospace'`.

### 2.3 Flächen und Körnung

Flächen bleiben chuks Theme. Neu ist eine **Körnung** (Grain) auf wenigen
Agent-Flächen. Sie ist farbneutral und tönt nicht.

Wo:

- Voice-Bühne und Vollbild-Anruf (immer).
- Agents-Inbox-Hintergrund (Telefon) und Roster-Fläche (Desktop).
- Profilkopf (`AgentProfileEditPage`, Kopf von `AgentSettingsView`).

Wo nicht: Thread (Lesefläche), Composer, Chips, Buttons, Menüs, Dialoge,
die Chat-Hälfte. Nie auf einem Control.

Die Körnung liegt unter Inhalt und Veils. Das Veil blendet sie oben weich
aus. Das ist gewollt: ein Verlauf ohne Kante, keine Bandgrenze.

**Umsetzung, Stufe 1 (Standard): vorgerenderte Kachel.**

- `tool/generate_grain.py` erzeugt `assets/textures/grain_256.png`:
  256 × 256 px, fester Seed, jedes Pixel schwarz oder weiß (50/50) mit
  zufälligem Alpha. Mittelwert neutral, verschiebt keine Farbe. ≈ 20 KB.
- Widget `GrainLayer` (`lib/ui/expressive/grain.dart`): `CustomPainter`
  mit `ImageShader(image, TileMode.repeated, TileMode.repeated, matrix)`.
  Matrix skaliert mit `1 / devicePixelRatio`, also 1 Korn = 1 physisches
  Pixel (sonst wird das Korn auf 3,5× unscharf). Ein Draw-Call, keine
  Kachel-Schleife (nicht `DecorationImage(repeat:)`, das zeichnet jede
  Kachel einzeln).
- In `RepaintBoundary`, `shouldRepaint` nur bei Größe/Theme. Statisch:
  nach dem ersten Frame kostet es nichts mehr.
- Kosten Android (Pixel 7 Pro, Impeller): eine Textur, ein Sample pro Pixel,
  nur beim ersten Raster. Praktisch null. Läuft auch auf Web und Desktop.
- Aus bei `MediaQuery.highContrastOf(context)`.

**Stufe 2 (optional, nur Voice): `FragmentShader`.**

- `shaders/grain.frag` (Hash-Noise, Uniforms `uSize`, `uTime`, `uAlpha`),
  in `pubspec.yaml` unter `flutter: shaders:`, Laden mit
  `FragmentProgram.fromAsset`.
- Impeller kompiliert offline (impellerc). Kein Erst-Frame-Ruckler auf
  Android/iOS. Web nur mit CanvasKit/skwasm; Fallback = Stufe 1.
- Kosten: animiert heißt Neuzeichnen pro Frame. Vollbild 1440 × 3120 sind
  ≈ 4,5 Mio. Fragmente pro Frame. Billige Rechnung, aber die GPU bleibt wach:
  Akku und Wärme bei langen Anrufen.
- Darum: nur während der Agent spricht, gedrosselt auf **12 fps**, sonst
  statisch. Erst messen (`flutter run --profile`, Raster-Thread < 4 ms),
  dann einschalten. Ohne Messung bleibt Stufe 1.

### 2.4 Voice-Fläche

Voice ist der Ort, wo der Agent "ganz Gesicht" ist. Hier darf seine Farbe
die Fläche tragen (Regelbiegung, siehe 4).

- Bühne (`VoiceStageFrame`): Füllung = Agent-Container (T94/T18, C12),
  Rand `outlineVariant` (statt `outline`), Radius 28 (bleibt), Körnung drauf.
- Kopf: `face.xl` (96) mittig, Name darunter, Status darunter in
  Maschinenzeile ("Listening", "Speaking", Tool-Name).
- Balken (`voice_bars.dart`): `onSurface`, folgen nur dem Pegel. In Ruhe
  stehen sie still, keine Leerlauf-Schleife.
- Kein Glow, kein farbiger Schatten, kein Verlauf. Nur Fläche + Korn.

### 2.5 Bewegung

Bleibt bei chuks Federn (`ui/expressive/motion.dart`). Regeln:

- **Run startet**: Gesicht dreht sich einmal um 1/12 Umdrehung
  (`kSpatialSpring`, ≈ 350 ms). "Der Agent wendet sich der Arbeit zu."
  Run endet: zurück, einmal. Kein Dauerdrehen.
- **Statuswechsel**: Punkt und Wort blenden über, `kExpressiveShort` 180 ms,
  `kExpressiveDecelerate`.
- **Während der Arbeit**: genau ein Loop pro Bildschirm, und nur im offenen
  Thread-Header (`WorkingDots`, 1100 ms). Inbox-Zeilen loopen nie, auch bei
  fünf laufenden Agents: dort Vollpunkt + "Working…".
- **Voice**: Balken nach Pegel. Körnung statisch (Stufe 2: 12 fps beim
  Sprechen).
- **Reduzierte Bewegung** (`MediaQuery.disableAnimationsOf`): keine Drehung,
  Punkte statisch bei 0,65 Deckkraft, kein Korn-Loop.

### 2.6 Icons

- Nur HugeIcons (DESIGN §5). In Agents-Dateien kein direktes
  `Icon(Icons.…)`. Entweder `HugeIcon(...)` oder `AppIcon` mit Map-Eintrag.
- **Nie Text-Glyphen als Icon**: kein `✓ → × ● … ›` in Pills, Kreisen,
  Buttons. Sie sitzen auf der Grundlinie und sind nie mittig. Status-Punkte
  sind gemalte Formen (`StatusDot`), keine Zeichen.
- Icon in Flex-Box mit `CrossAxisAlignment.center`. Neben mehrzeiligem Text:
  Box so hoch wie eine Zeile, `start`-Ausrichtung.
- Status nie nur über Farbe: Vollpunkt = arbeitet/geplant, Ring = bereit,
  Ring grau = nicht verbunden.
- Fehlt ein Icon (z. B. Pin): in `tool/generate_hugeicons.py` `WANTED`
  eintragen, nicht auf Material ausweichen.

### 2.7 Komponenten

| Komponente | Datei heute | Was sich ändert |
|---|---|---|
| Agent-Gesicht | `ui/expressive/agent_face.dart` | HCT-Farbe, eine Farbfunktion für Gesicht + Vorschau, Größen-Tokens, Dreh-Feder bei Run-Start |
| Agent-Header | `mobile_chat_chrome.dart` (`AgentChromePill`), `agents_thread_header.dart` | `face.s`, Status mit Maschinenzeile, einziger Arbeits-Loop |
| Status-Pill/-Zeile | `ui/expressive/agent_status.dart` | Status-Tokens, Ring vs. Vollpunkt, Tool-Name in Mono |
| Inbox-Zeile | `mobile_agent_list.dart`, Desktop `SbChatTile` via `agent_roster_view.dart` | Ungelesen = fett + Punkt in Nutzer-Akzent (wie §14.3), keine Agent-Tönung, Pin als HugeIcon, Körnung im Hintergrund |
| Voice-Fläche | `voice/widgets/voice_call_stage.dart`, `voice_call_fullscreen_page.dart`, `voice_call_panel.dart` | Agent-Container, Korn, `face.xl`, Status in Mono |
| Composer | chuks `_buildSearchBar` | **Keine Änderung.** Ein Akzent (Nutzer), keine Agent-Farbe am Senden-Knopf |

### 2.8 Tokens

Farb-Formeln über `Hct.from(hue, chroma, tone)`; Hex-Werte siehe 2.1.

| Token | Hell | Dunkel | Hinweis |
|---|---|---|---|
| `agent.hue` | Platz aus FNV-1a(id) mod 12 | gleich | 25 … 355, Schritt 30 |
| `agent.face` | T45, C48 | T45, C48 | gleich in beiden Modi |
| `agent.onFace` | `#FFFFFF` | `#FFFFFF` | ≥ 5,3 : 1 garantiert |
| `agent.container` | T94, C12 | T18, C12 | nur Voice-Bühne |
| `agent.faceNeutral` | H250, C6, T45 | gleich | nur Nutzerwahl |
| `status.working` | `#367835` (H145 C48 T45) | `#83C97C` (T75) | Vollpunkt; 5,1 / 9,4 : 1 |
| `status.scheduled` | `#B97500` (H70 C50 T55) | `#FFB960` (T80) | Vollpunkt; 3,6 / 10,9 : 1 |
| `status.ready` | = `status.working` | = `status.working` | **Ring** 1,5 px, nicht gefüllt |
| `status.offline` | `outline` des Themes | `outline` | Ring 1,5 px |
| `status.dot` | 0,55 em | gleich | wie heute (`kStatusDotSizeFactor`) |
| `status.faceDot` | 0,30 × Gesicht, 9–18 px, Rand 2,5 px `surface` | gleich | wie heute |
| `grain.alpha` | 0,035 | 0,055 | Deckkraft der Kachel |
| `grain.tile` | 256 px physisch | gleich | `1 / dpr` skaliert |
| `grain.fps` | 0 (statisch) | 0 | Stufe 2: 12 beim Sprechen |
| `face.xs … xl` | 20 / 28 / 40 / 48 / 96 | gleich | siehe 2.1 |
| `type.machine` | JetBrains Mono 11–12, w500, tabular | gleich | Farbe `onSurfaceVariant` |
| `type.body` | Inter 16 / 1,5 | gleich | Chat-Text, Standard |
| `type.ui` | Inter 14–15 / 1,35 | gleich | UI, Standard |
| `motion.turn` | 30°, `kSpatialSpring` | gleich | einmal pro Run-Start/-Ende |
| `motion.status` | 180 ms, `kExpressiveDecelerate` | gleich | Überblenden |
| `motion.working` | `WorkingDots` 1100 ms | gleich | nur Thread-Header |
| `voice.stageRadius` | 28 | 28 | bleibt (`kVoiceStageRadius`) |

Achtung `kAgentAccents`: `lib/widgets/charts/chart_palette.dart` liest diese
Liste für Diagrammfarben. Erst entkoppeln, dann die Agent-Farben ändern,
sonst ändern sich nebenbei alle Diagramme.

## 3. Rollout

Jeder Schritt ist ein Bead (Label `design`), in dieser Reihenfolge. Jeder
Schritt: `flutter test` grün, Layout bei 360 px und 1,3 Textskala, Bild in
Hell und Dunkel im echten Target ansehen.

1. **Agent-Farbe auf HCT, eine Funktion.** `agentFaceColor(id, profile)`
   mit 12 Plätzen; Vorschau nutzt dieselbe Funktion (Fehler 3); Nutzerwahl
   speichert Platz, alte Hex-Werte auf nächsten Platz; Picker zeigt 12 + Graphit.
   Vorher `chart_palette.dart` eine eigene Liste geben. Kontrast-Test: alle
   Plätze, Weiß ≥ 4,5 : 1. Dateien: `lib/ui/expressive/agent_face.dart`,
   `lib/widgets/agent_avatar.dart`, `lib/pages/agent_profile_edit_page.dart`,
   `lib/services/agents/agent_profile_store.dart`,
   `lib/services/agents/agent_templates.dart`,
   `lib/widgets/charts/chart_palette.dart`, Tests.
2. **Status-Tokens + Ring für "bereit".** Eine Klasse `AgentStatusColors`;
   sechs harte Hex-Werte ersetzen; Ring = bereit/offline. Dateien:
   `lib/ui/expressive/agent_status.dart`, `lib/ui/expressive/agent_face.dart`,
   `lib/platform_specific/mobile/mobile_chat_chrome.dart`, Tests.
3. **Gesichtsgrößen-Skala.** `AgentFaceSize` (xs…xl) und alle Aufrufer.
   Dateien: `agent_face.dart`, `mobile_agent_sheet.dart`,
   `mobile_chat_chrome.dart`, `agent_roster_view.dart`, `quick_switcher.dart`,
   `room_*.dart` (thread, members, list, faces, mention picker, create sheet),
   `mobile_agents_settings_page.dart`, `agent_profile_edit_page.dart`.
4. **Maschinenzeile in JetBrains Mono.** `agentsMachineStyle(context)`;
   ersetzt `'monospace'`; Tool-Name in der Statuszeile und Run-Kosten in Mono.
   Dateien: neu `lib/ui/expressive/agents_type.dart`, `agent_run_views.dart`,
   `agent_activity/agent_activity_timeline.dart`,
   `agents_action_approval_card.dart`, `agents_run_cost_meta.dart`,
   `ui/expressive/agent_status.dart`.
5. **Inbox-Zeile angleichen + Icons.** Ungelesen = fett + Nutzer-Akzent-Punkt
   (wie Desktop §14.3), keine Agent-Tönung; Pin und die übrigen Material-
   Glyphen als HugeIcons. Dateien: `lib/platform_specific/mobile/mobile_agent_list.dart`,
   `tool/generate_hugeicons.py`, `assets/icons/hugeicons/`,
   `lib/widgets/icons/huge_icon.dart`, `lib/widgets/icons/icon_map.dart`.
6. **Körnung: Asset + `GrainLayer`.** Generator mit festem Seed, PNG,
   Widget mit `ImageShader`, aus bei hohem Kontrast, Golden-Test. Dateien:
   neu `tool/generate_grain.py`, `assets/textures/grain_256.png`,
   `lib/ui/expressive/grain.dart`, `pubspec.yaml` (assets), Test.
7. **Körnung auf Agent-Flächen.** Inbox-Hintergrund (Telefon), Roster-Fläche
   (Desktop), Profilkopf. Dateien: `mobile_agent_list.dart`,
   `agent_roster_view.dart`, `agent_profile_edit_page.dart`,
   `mobile_agents_settings_page.dart`.
8. **Voice-Fläche mit Agent-Identität.** Container-Füllung, Korn, `face.xl`,
   Status in Mono, Rand `outlineVariant`. Dateien:
   `lib/voice/widgets/voice_call_stage.dart`,
   `lib/voice/widgets/voice_call_fullscreen_page.dart`,
   `lib/voice/widgets/voice_call_panel.dart`.
9. **Bewegung: Dreh-Feder, Überblenden, ein Loop.** Run-Start/-Ende dreht
   das Gesicht einmal; Inbox ohne Loop; reduzierte Bewegung. Dateien:
   `agent_face.dart`, `agent_status.dart`, `working_dots.dart`,
   `mobile_agent_list.dart`, Tests.
10. **Regeln in DESIGN.md übernehmen.** §7 und §8 um die zwei Biegungen
    ergänzen (Abschnitt 4), §6 um die Größen-Skala; diese Datei auf
    "umgesetzt" setzen. Dateien: `docs/DESIGN.md`, `docs/agents/DESIGN_SCHEME.md`.
11. **Optional: Korn-Shader für Voice.** Erst messen (Pixel 7 Pro,
    `--profile`, Raster < 4 ms), dann 12 fps beim Sprechen. Dateien: neu
    `shaders/grain.frag`, `pubspec.yaml` (shaders), `lib/ui/expressive/grain.dart`,
    `voice_call_stage.dart`.
12. **Lesbare Standardschrift + Packs ohne Schrift.** Inter (Latin-Subset)
    bündeln, Standard für UI und Chat, Chat 16/1,5; Theme-Packs setzen keine
    `uiFont` mehr (Cappuccino). Gilt für beide Hälften. Dateien:
    `assets/fonts/`, `pubspec.yaml` (fonts), `lib/constants.dart`
    (`kDefaultChatFontFamily`, `kDefaultUiFontFamily`, Liste),
    `lib/utils/chat_font_resolver.dart`, `lib/theme/theme_presets.dart`,
    `lib/pages/theme_page.dart`, Tests.
13. **Weniger-ist-besser-Durchgang Agents.** Header: rechts höchstens "…"
    (+ Anruf, wenn aktiv); Menüs ≤ 5 Einträge; Agent-Profil oben ≤ 2
    Gruppen, Rest unter "Mehr"; Untertitel ohne Mehrwert streichen.
    Dateien: `lib/platform_specific/mobile/mobile_chat_chrome.dart`,
    `lib/widgets/agents_thread_header.dart`,
    `lib/pages/mobile_agents_settings_page.dart`, `lib/pages/settings_page.dart`.

Beads: 1 `chuk_chat-ixxd`, 2 `chuk_chat-xjhe`, 3 `chuk_chat-7gof`,
4 `chuk_chat-mhjf`, 5 `chuk_chat-uopi`, 6 `chuk_chat-huk2`,
7 `chuk_chat-6l4w`, 8 `chuk_chat-q0ee`, 9 `chuk_chat-2t0g`,
10 `chuk_chat-gexn`, 11 `chuk_chat-jtuj`, 12 `chuk_chat-rv5y`,
13 `chuk_chat-vzxg`; Suche unten (Abschnitt 5) `chuk_chat-375r`.

## 4. Regeln, die das Schema biegt

| Regel | Biegung | Warum |
|---|---|---|
| DESIGN §7: "Die Farbe eines Agents ist nur für sein Gesicht." | Die **Voice-Bühne** trägt den Agent-Container (C12, sehr blass). | Im Anruf gibt es keinen Thread-Text. Die Bühne ist das Gesicht in groß, wie ein Kontaktfoto im Anrufbild. Nirgends sonst. Thread, Composer, Bubbles bleiben im Nutzer-Akzent. |
| DESIGN §8: "Translucency nur wo nötig … nichts Dekoratives." | Die **Körnung** ist dekorativ. | Sie ist das eine Erkennungszeichen der Agents-Hälfte. Farbneutral (Mittelwert grau), ≤ 5,5 % Deckkraft, nie auf Controls, nie im Thread, aus bei hohem Kontrast. |
| DESIGN §7: "Ein Screen tönt nie eine Fläche." | Körnung ist keine Tönung; nur die Voice-Bühne (Zeile 1) tönt. | wie oben |

Bewusst nicht gebogen:

- Kein Glow, kein farbiger `BoxShadow`, kein Verlauf auf Controls.
- Keine Agent-Farbe im Thread (`AgentTheme` bleibt gelöscht).
- Ungelesen nicht mehr in Agent-Farbe (heute eine stille Biegung, Schritt 5
  hebt sie auf).
- Inter ist eine neue gebündelte Datei. Das biegt keine Regel, kostet aber
  ≈ 300 KB (Subset). Grund: Lesbarkeit war die Beschwerde des Owners.

Verworfen:

- **Farbe aus dem Namen** ("amber-otter" = Bernstein). Hübsch, aber 28 der
  34 Adjektive landen auf 4 Farbtönen (Orange/Braun). Verteilung schlechter
  als der Hash.
- **Zwei Initialen.** Bei `adjective-noun` wenig Gewinn, kostet Breite bei 20 px.
- **Dauerhaftes "Atmen" des Gesichts.** Verstößt gegen §8 (nichts pulsiert
  ewig) und frisst Akku in langen Listen.

## 5. Grok-App Durchsicht (2026-10-29)

Pixel 7 Pro des Owners, `ai.x.grok.bot`, nur angesehen. Nichts gesendet,
kein Anruf, nichts geändert. Bilder: `_scratch/grok/1029/` (gitignored,
nur lokal).

| Bild | Was |
|---|---|
| `01_home.png` | Start: oben Konto + "+", große Bot-Gesichter, darunter Chats, unten "Suchen" + App-Knopf |
| `02_chat.png` | Chat: Pill mit Gesicht + Name, "…", Composer "Main fragen" |
| `03_chat_menu.png` | "…"-Menü: 4 Einträge |
| `04_profile.png` | Bot-Profil: Gesicht, Name, "Bearbeiten", 3 Zeilen + 1 Schalter |
| `05_library.png` | "Bibliothek": Links/Dateien des Bots, nach Zeit gruppiert |
| `07_composer_plus.png` | "+" im Composer: 3 Einträge |
| `09_grid.png` | "Apps verbinden": Filter-Chips, Liste, Suche unten |
| `10_account.png`, `11_account_scroll.png` | Konto/Einstellungen, inkl. "Tresor" |
| `20_chuk_open.png` … `24_chuk_theme_2.png` | zum Vergleich: unsere App auf demselben Telefon |

Voice-Modus nicht gesehen: der Knopf startet einen Anruf. Die Körnung kennen
wir nur aus der Beschreibung des Owners.

Was sie besser platzieren:

- **Suche unten**, in Daumenhöhe, auf Start und in "Apps verbinden". Bei uns
  steht die Suche oben (Connectors) oder fehlt in der Inbox.
- **Wenig Knöpfe.** Chat-Header: Zurück, Pill, "…". Menü 4 Einträge.
  Composer: "+", Feld, Mikro, Voice. Kein Modell-Wähler im Composer.
- **Profil in einem Blick**: 3 Zeilen (Routinen, Bibliothek, Computer) + ein
  Schalter. Unsere Agent-Einstellungen haben über 15 Zeilen.
- **Status-Wort rechts in der Zeile** ("0 aktiv", "Inaktiv"). Spart
  Untertitel.
- **Einstellungen kurz**: keine Schriftwahl, kein Farbwähler, keine
  Erklärzeile unter fast jeder Zeile. "Erscheinungsbild: System folgen".
- **Bibliothek pro Bot**: alles, was der Bot gesammelt hat, an einem Ort.
  Bei uns verteilt (Files, Pages, Media).
- **Gesichter mit Augen**: zwei Striche machen aus einer Form ein Wesen. Die
  Form wechselt pro Bot, die Augen bleiben gleich.

Was wir nicht übernehmen (und warum):

- **Bot-Farbe als Akzent im Thread** (Voice-Knopf, Ladepunkte, Schalter im
  Profil sind orange wie der Bot). Bei uns bleibt ein Akzent (Nutzer), sonst
  hat jeder Screen eine andere Farbe. Siehe 2.0 "weniger Farben".
- **AI-Antwort in einer Karte.** chuk zeigt die Antwort ohne Bubble (UNIFY,
  Ergebnis B). Mehr Platz, eine Fläche weniger.
- **Augen im Gesicht.** Das ist ihr Zeichen. Unser Zeichen ist die
  expressive Silhouette + Monogramm + HCT-Farbe.
- **Ihre Schrift.** Wir lösen Lesbarkeit mit Inter (2.2), nicht mit einer
  Nachahmung.

Was wir besser machen können:

- **Suche in die Inbox, unten**, neben dem Navigations-Pill (statt oben).
  Eigener Bead nötig, falls gewollt; passt zu 2.0.
- **Agent-Profil auf 3 Zeilen + Mehr** (Rollout 13).
- **Bibliothek = Pages + Files + Links pro Agent**, eine Zeile im Profil
  statt drei Wege.
- **Einstellungen kürzen**: Untertitel weg, wo der Titel reicht; Schrift
  und Farbe in eine Zeile "Erscheinungsbild".
- **Statuswort rechts** statt Untertitel in Einstellungszeilen.

Nebenbefund: Die installierte chuk-App auf dem Telefon zeigt noch
"coworker(s)" in vier Untertiteln (`22_chuk_settings2.png`). Im Quellcode ist
das schon weg. Der Build auf dem Telefon ist älter.
