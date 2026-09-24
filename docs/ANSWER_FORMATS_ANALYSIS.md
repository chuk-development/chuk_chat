# Antwortformate: Analyse von 939 eigenen Chats

Stand: 2026-09-24. Grundlage: sechs Teilanalysen über den lokalen SQLite-Cache
(`chat_cache.db`) des Owners. Ziel: herausfinden, welche Fragen wirklich gestellt
werden, wie das Modell sie beantwortet, wo die Darstellung schlecht ist und
welche neuen UI-Blöcke den größten Gewinn bringen.

Alle Zahlen sind Schätzungen („ca.“) der Teilanalysen und hier nur addiert.
Chat-IDs sind die ersten 8 Zeichen der Chat-ID im Cache.

## 1. Datenbasis

| Teil | Chats | Ausgeklammert | Grund |
|---|---|---|---|
| 0 | 157 | ~55 | „hi“, „test“, 2+2, Umbenennen |
| 1 | 157 | ~40 | Smoke-Tests, Persona-Spiele, Jailbreaks |
| 2 | 157 | ~40 | Smoke-Tests, „hi“, Persona-Geplänkel |
| 3 | 157 | ~30 | Tool-Tests (weather/chart/calc), Fehler, Abbrüche |
| 4 | 157 | ~30 | keine Zahl genannt, geschätzt aus der Differenz |
| 5 | 154 | ~24 | Smoke-Tests |
| **Summe** | **939** | **~220** | |

Es bleiben rund **720 echte Chats**. Davon sind noch etwa **40** Eval-artige
Chats mitgezählt, aber niedrig gewichtet: wiederholte Eval-Prompts zu heiklen
Lebensfragen, App-Tool-Demos („show me a test chart“, „show me a test md table“)
und Refusal-Tests. Sie gehen nicht in die Block-Evidenz ein.

## 2. Fragekategorien

Aggregiert über alle sechs Teile. Beispiele sind gekürzt und ohne persönliche
Daten.

| Kategorie | Anzahl ca. | Typische Frage | Visuelles Hauptproblem |
|---|---|---|---|
| Tech-/KI-Recherche (Modelle, APIs, Preise, Datenschutz) | ~95 | „is minimax 2.7 open weight“, „composer 2.5 context window“ | 3–14k Zeichen mit H2, Listen und breiten Tabellen; das Ja/Nein geht unter; Quellen im Fließtext |
| How-to, Troubleshooting, Shell-Befehle | ~90 | „how to make a new ssh key id_ed25519“, „kann man via Cloudflare Länder blocken“ | Befehle im Fließtext verstreut, bis 17 Überschriften für 5 Befehle; Reihenfolge teils falsch; nicht abhakbar |
| Kurzfakten, Allgemeinwissen, Ja/Nein | ~90 | „gehört Sprite zu Coca-Cola?“, „seit wann gibt es 5G?“ | Antwort steht fett in Zeile 1, dann Hintergrund, Tabelle und Reflexions-Absatz – mehr Rauschen als Antwort |
| Orte, Öffnungszeiten, ÖPNV, Wetter | ~75 | „bis wann hat IKEA heute offen“, „wohin fährt der RB37 jetzt“ | Adresse/Zeiten/Telefon als Textliste; „jetzt offen?“ muss man selbst rechnen; `<map>` erst auf Nachfrage |
| Vergleich, Kaufberatung | ~50 | „T14 Gen 1 vs T480s CPU-wise“, „Gardena vs Worx mit Preis“ | Tabellen mit 4–7 Spalten und bis 26 Zeilen, auf dem Handy zu breit; Gewinner nur als Fettdruck; Fazit fehlt oder steht unten |
| Coaching, Gesundheit, Training | ~45 | „wie bekomme ich den besten Schlaf“, „Trainingsplan“ | 1,5–8k Zeichen pro Turn; Handlungsschritte vergraben; Wochenplan als 3–4 Tabellen hintereinander |
| Kreativ, Bild-Prompts, Artefakte | ~45 | „write a rap song about …“, „make an image of a cat“ | nach einem Artefakt wird der Inhalt als Liste nacherzählt; Bildfähigkeit widersprüchlich kommuniziert |
| News, Finanzen, Live-Kurse | ~35 | „current tech news“, „what is BTC/USD doing rn“ | Bullet-Wände mit Emoji-Überschriften statt `<news>`; Kurs als Tabelle, Chart erst auf Nachfrage |
| Reihenfolgen, Termine, Serien | ~25 | „Jason-Bourne-Reihenfolge“, „wann kann ich Film X streamen“ | nummerierte Listen mit 26 Einträgen oder Tabelle „Jahr / Ereignis“ |
| Identität, Smalltalk, Memory | ~25 | „who are you“, „what do you know about me“ | Endlos-Prosa statt kurzer Fakt |
| Recht, Business, Steuern | ~20 | „brauche ich ein Impressum?“, „Cofounder im Kleingewerbe“ | Risiko (Abmahnung, Nachzahlung) steht im Fließtext statt abgesetzt |
| Rechnen, Umrechnen | ~15 | „59 lbs in bar“, „4,5 km in 21:31 – welche Pace“ | Ergebnis nicht hervorgehoben; Rechenweg-Prosa wiederholt sich bei jeder Nachfrage; 43-Zeilen-Tabelle statt Chart |
| Foto-/Bildanalyse | ~10 | „ist diese Lampe warmweiß?“ | die Antwort ist ein Wert, steckt aber im dritten Absatz |
| Konzepte Schritt für Schritt lernen | ~8 | „erklär mir LLMs von Grund auf“ | lange Absätze; Nutzer sagt mehrmals „nicht verstanden“; kein Schritt-für-Schritt, kein Diagramm |
| Produktivität, Automation | ~7 | „welche GitHub-Issues habe ich offen“, Wahl-Monitor | Automation postet 30× dieselbe breite Tabelle statt Delta |

## 3. Vorgeschlagene UI-Blöcke

### Wie die Blöcke in die Architektur passen

- **Rendering:** Blöcke sind heute `<tag>{JSON}</tag>` im Antworttext.
  `lib/widgets/message_bubble.dart` erkennt sie über `_richBlockRegex` und
  `_visualBlockStartRegex` (Liste `chart|map|email|weather|news|image|diff`);
  `message_bubble/rich_blocks.dart` verzweigt nach `blockType` und parst das
  JSON nachsichtig (`_tryParseJson`). Ein neuer Block heißt also: Tag in beide
  Regexe, ein Zweig in `_buildVisualContent`, ein Widget.
- **Prompt:** `lib/services/tool_prompt_builder.dart` enthält die Tag-Schemas.
  Ist ein passender Skill im Katalog, lässt `_migratedToSkill()` den Block weg;
  im Prompt steht dann nur `name` + `description` (≤300 Zeichen), der Body
  kommt erst nach dem Aufruf des `skill`-Tools. Vorbilder: `news-cards`,
  `weather-cards`, `chart-authoring`.
- **Schon vorhanden:** `message_bubble/web_search_sources.dart` parst
  `web_search`-Ergebnisse bereits zu Quellen-Karten. Ein `<sources>`-Tag vom
  Modell ist deshalb nicht nötig.

Bewertung: Häufigkeit (Summe der Teile, Chats) × visueller Gewinn
(hoch = 3, mittel = 2, niedrig = 1). Aufwand: S ≈ ½–1 Tag, M ≈ 2–3 Tage,
L ≈ 1 Woche (Widget, Parser, Prompt/Skill, Tests).

### 3.1 Neue Blöcke, nach Rang

#### 1. `<steps>` – Schrittkarte mit Befehlen (inkl. `<command>`-Variante)

- **Was:** nummerierte, abhakbare Schritte. Jeder Schritt hat optional einen
  Befehl mit Copy-Knopf, eine erwartete Ausgabe und eine Warnmarkierung. Ein
  einzelner Schritt rendert als kompakte Befehlskarte; das ersetzt den
  eigenen `<command>`-Vorschlag aus Teil 2, 3 und 5. Voraussetzungen stehen
  zwingend vorn (`pre`). Mit `current` lässt sich ein Fortschritt über
  mehrere Turns zeigen („Schritt 3 von 6“).
- **Wann:** Anleitungen, Setup, Installation, Verkabelung, „give me the
  command“. Nicht bei Erklärfragen ohne Handlung.
- **Skizze:**
  ```
  <steps>{"title":"SSH-Key anlegen","shell":"bash",
   "pre":[{"cmd":"sudo dpkg --add-architecture i386"}],
   "items":[
    {"t":"Key erzeugen","cmd":"ssh-keygen -t ed25519 -C \"<mail>\""},
    {"t":"Public Key kopieren","cmd":"cat ~/.ssh/id_ed25519.pub"},
    {"t":"Partition wirklich die richtige?","warn":true}],
   "current":0}</steps>
  ```
- **Evidenz:** `<steps>` ~72 (alle 6 Teile) + `<command>` ~31 (Teile 2, 3, 5)
  = **~100 Chats**. Beispiele: 8e1ee42b (Home-Entschlüsselung über 9 Turns
  ohne Fortschritt), 56376f59 (SSH-Key/git, 17 Überschriften für 5 Befehle),
  d3a8476e (Voraussetzung nach dem Hauptbefehl).
- **Gewinn:** hoch. **Aufwand:** M (Widget mit Copy + Checkbox; Abhakzustand
  pro Nachricht lokal speichern).

#### 2. `<verdict>` – Antwortkarte oben

- **Was:** eine Karte am Anfang der Antwort: großes Ja / Nein / Teils oder
  ein Wert, ein Satz Kern, optional Sicherheit und Stand. Der Rest der Antwort
  folgt normal darunter; ab ~1500 Zeichen Rest klappt die UI ihn ein.
  Rechen- und Umrechnungsergebnisse (`<result>`/`<calc>` aus Teil 0 und 3)
  sind dieselbe Karte mit `value` + `formula`.
- **Wann:** geschlossene Fragen („ist X open-weight“, „gehört A zu B“, „hat
  der Laden offen“, „lohnt sich“) und Rechenfragen. Nicht bei offenen
  Erklärfragen.
- **Skizze:**
  ```
  <verdict>{"answer":"Nein","headline":"MiniMax M2.7 ist nur per API verfügbar",
   "confidence":"hoch","asof":"2026-04"}</verdict>

  <verdict>{"value":"4:47 min/km","formula":"21:31 ÷ 4,5 km",
   "inputs":{"Strecke":"4,5 km","Zeit":"21:31"}}</verdict>
  ```
- **Evidenz:** `<verdict>` ~110 (alle 6 Teile) + `<result>`/`<calc>` ~14
  (Teile 0, 3) = **~124 Chats**. Beispiele: 474ed0f0 (Sprite/Coca-Cola),
  4a91f40f (MiniMax open source), 6a5abf9d (Pace-Rechnung).
- **Gewinn:** mittel bis hoch – der Block allein kürzt nichts; er wirkt nur
  zusammen mit der Längenregel aus Abschnitt 4. **Aufwand:** S.

#### 3. `<compare>` – Vergleichskarten statt breiter Tabelle

- **Was:** 2–4 Optionen als Karten (Handy: wischbar oder gestapelt; Desktop:
  Spalten mit fester erster Spalte). Zeilen mit Gewinner pro Zeile,
  Gesamtsieger als Badge, ein Satz Fazit oben. Datenblatt einer einzelnen
  Sache (`<spec>`, Teil 4), Produkt- und Listing-Karten (`<product>`,
  `<listing>`, Teile 1 und 5) und Preisstufen (`<plans>`, Teil 3) sind
  Varianten: ein Item bzw. `kind:"plans"`, optional `price`, `url`, `seller`.
- **Wann:** „X vs Y“, Kaufberatung, Alternativen, Preisstufen eines Anbieters,
  Specs eines Geräts.
- **Skizze:**
  ```
  <compare>{"title":"T14 Gen 1 vs T480s",
   "items":[{"name":"T14 Gen 1","price":"~280 €"},{"name":"T480s","price":"~220 €"}],
   "rows":[{"k":"CPU","v":["i7-10510U","i5-8250U"],"win":0},
           {"k":"Turbo","v":["4,9 GHz","3,4 GHz"],"win":0}],
   "winner":0,"verdict":"T14: ~30 % mehr Multicore für ~60 € mehr"}</compare>
  ```
- **Evidenz:** `<compare>` ~74 (alle 6 Teile) + `<spec>`/`<product>`/
  `<listing>` ~18 + `<plans>` ~9 = **~100 Chats**. Beispiele: 298a4e1d
  (T14 vs T480s), 3fbee401 (Gardena vs Worx), ac899ced (5 eBay-Links, dieselbe
  Tabelle 3× pro Chat).
- **Gewinn:** hoch (Handy). **Aufwand:** M–L (responsives Layout ist der
  Hauptaufwand).

#### 4. `<place>` – Ortskarte (Erweiterung von `<map>`)

- **Was:** Name, „jetzt offen / schließt um 19:00“ (live aus `hours`
  berechnet, nicht vom Modell), Adresse, Telefon- und Routen-Knopf, Mini-Karte.
  Technisch am besten als neuer `type:"place"` bzw. als Marker-Felder in
  `<map>` (`hours`, `phone`, `desc`) statt als eigener Tag. Teil 1 meldet, dass
  das Modell heute `cuisine` für Beschreibungen und `website` für Freitext
  missbraucht – ein `desc`-Feld fehlt.
- **Wann:** Öffnungszeiten, „wo ist“, Telefonnummer, Restaurant-/Ausflugstipps.
- **Skizze:**
  ```
  <map>{"type":"place","name":"IKEA Kiel","lat":54.3,"lon":10.1,
   "hours":{"mo-sa":"10:00-20:00"},"phone":"…","desc":"Möbelhaus mit Restaurant"}</map>
  ```
- **Evidenz:** **~32 Chats** (Teile 0, 1, 2, 3, 4). Beispiele: b6903efb
  (Öffnungszeiten), 4069970b (Bistro heute offen), 192dbfc2 („zeig mir die
  auf der Karte“ als Nachfrage).
- **Gewinn:** hoch. **Aufwand:** S–M (vorhandenes `MapBlockWidget` erweitern).

#### 5. `<callout>` – Warn-, Risiko- und Korrekturbox

- **Was:** farbig abgesetzte Box, `type` = `warn` | `risk` | `correction` |
  `info`. `correction` ersetzt die Tabelle „Was ich sagte / Realität“ durch
  einen Satz.
- **Wann:** destruktive Befehle (`dd`, Formatieren), Geld- und Rechtsrisiko
  (Abmahnung, Scheinselbstständigkeit, Lizenz nicht kommerziell),
  Sicherheitsrisiko, Korrektur einer eigenen früheren Aussage. Höchstens eine
  Box pro Antwort.
- **Skizze:**
  ```
  <callout>{"type":"risk","text":"Scheinselbstständigkeit: Nachzahlung für bis zu 4 Jahre"}</callout>
  ```
- **Evidenz:** **~32 Chats** (Teile 0, 1, 2, 4; Teil 5 meldet dasselbe als
  `verdict` mit `tone:"warn"`). Beispiele: e305d324 (ISO mit `dd` flashen),
  bf37debe (Kleingewerbe), 6d21e300 (Korrektur-Tabelle).
- **Gewinn:** mittel. **Aufwand:** S.

#### 6. `<timeline>` – Zeitleiste und Reiseplan

- **Was:** vertikale Leiste mit Datum/Uhrzeit, Label, Status
  (erledigt/zukünftig). Mit `lat`/`lon` pro Eintrag wird es ein Reiseplan, der
  Punkte auf einer Karte verbindet (`<itinerary>` aus Teil 1).
- **Wann:** Reihenfolgen (Filme, Serien), Versionshistorie, Release-Termine,
  Tagesplan einer Reise, Fahrplan.
- **Skizze:**
  ```
  <timeline>{"items":[{"date":"2025-02","label":"Wan 2.1","status":"done"},
   {"date":"2026-05-12","label":"digital kaufen","status":"future"}]}</timeline>
  ```
- **Evidenz:** **~21 Chats** (Teile 1–4). Beispiele: cf8bf10b
  (Serienreihenfolge), f460a006 (4 Stunden in London).
- **Gewinn:** mittel bis hoch. **Aufwand:** S (ohne Karte), M (mit Karte).

#### 7. `<ticker>` – Kurs-Kachel

- **Was:** Symbol, Preis, Δ %, Sparkline, Markt offen/geschlossen. Voller
  Chart erst auf Tap. Daten nur aus Tool-Ergebnissen.
- **Wann:** „wie steht X“, „ging Y heute hoch“, Krypto-Kurs.
- **Skizze:** `<ticker>{"sym":"BTC/USD","price":70583,"chg":0.01,"spark":[…],"closed":false}</ticker>`
- **Evidenz:** **~15 Chats** (Teile 1, 2; Teil 5 hat ~9 Finanzfragen).
  Beispiele: d8f7f6d6 (BTC „rn“), c583d84d (Tesla heute).
- **Gewinn:** mittel. **Aufwand:** S–M. Alternative ohne neuen Tag: eine
  `<chart>`-Variante `type:"ticker"` im `chart-authoring`-Skill.

#### Seltene Vorschläge (nicht jetzt bauen)

| Block | Evidenz | Warum nicht jetzt |
|---|---|---|
| `<choices>` – Rückfrage als Antwort-Chips | ~8 (Teil 3), e4ee03ab | nützlich, aber besser zuerst per Prompt: eine Rückfrage statt Optionsliste |
| `<diagnosis>` – Befund/Ursache/nächster Befehl zu eingefügtem Terminal-Output | ~5 (Teil 1), 5f8d2c9f | lässt sich als `<steps>` mit `finding` abbilden |
| `<results>` – Live-Ranking mit Delta | 1 Chat, 30 Turns (Wahl-Monitor) | nur für Automationen; dort eher „Nachricht aktualisieren statt neu posten“ |
| `<explain>` – Lernkarten mit Verständnisfrage | ~4 (Teil 2), a94237fb | Excalidraw-Artefakt deckt das Diagramm schon ab |
| `<plan>` – Trainings-Wochenplan mit Tabs | ~2 (Teil 2), fb41b7b8 | wenig Evidenz, aber passt zum Fitness-Fokus; später prüfen |
| `<resources>` – Hilfekarte bei heiklen Themen | ~5 (Teil 1) | meist Eval-Chats |
| `<recipe>`, `<quiz>` | 1–2 | keine Datengrundlage |

### 3.2 Bestehende Blöcke besser nutzen

Diese Punkte brauchen kein neues Widget, nur Prompt- oder Client-Änderungen.
Sie sind deshalb billiger als jeder neue Block.

| Was | Problem | Evidenz | Fix |
|---|---|---|---|
| `<news>` | News-Fragen bekommen Bullet-Wände mit Emoji-Headern statt Karten | ~7 (Teil 1): b73de63c, c23f900a | Trigger „news“, „aktuell“, „current“ als harte Regel im Prompt belassen, auch wenn `news-cards` als Skill läuft; Beschreibung des Skills schärfer machen |
| `<map>` places | Karte kommt erst auf „zeig es auf der Karte“; davor eine H2-Liste, danach dieselbe Liste noch einmal | ~20 (Teile 0–4): d778a19c, 192dbfc2 | Regel „Ortsfrage → `<map>` in der ersten Antwort, keine Liste daneben“; Feld `desc` ergänzen |
| `<weather>` | Wetterfragen in Prosa beantwortet | 3 (Teil 1): 87b304bd | „Brauche ich einen Schirm“ als Wetter-Trigger in `weather-cards` aufnehmen |
| `<chart>` | Kurs nur als Tabelle, Chart erst auf Nachfrage; Chart-Daten als ASCII-Tabelle im Codeblock; 43-Zeilen-Tabelle statt Log-Chart | ~10 (Teile 1–3): d8f7f6d6, 379b597c, 89082c18 | Regel „Zeitreihe oder >10 Zahlenzeilen → `<chart>`“, `type:"line"` mit Log-Achse im Skill dokumentieren |
| Quellen | Links roh im Fließtext; Fakt und Vermutung sehen gleich aus | ~28 (Teile 3, 5): 21488ad0, ecee8001 | Kein Tag. Die vorhandenen Quellen-Karten aus `web_search_sources.dart` als kompakte Chip-Zeile unter die Antwort holen; im Prompt „keine Linklisten im Text“ |
| Markdown-Tabellen | ≥4 Spalten sind auf dem Handy unlesbar (17 Chats allein in Teil 3) | alle 6 Teile | Client-Fallback: auf schmalen Screens Tabellen ab 4 Spalten als gestapelte Karten rendern (Zeile = Karte, Spaltenkopf = Label). Hilft allen Altchats sofort, ganz ohne Modell |
| Lange Antworten | Deep-Dives über 5k Zeichen ohne Struktur | Teil 3: 94fc9247 | Client: Abschnitte ab H2 unterhalb von ~1500 Zeichen einklappbar |

## 4. Schlechte Antwortmuster unabhängig von der UI

Sortiert nach Verbreitung. „Fix“ ist, wo nicht anders gesagt, eine Regel im
Protokoll von `tool_prompt_builder.dart`.

| # | Muster | Evidenz | Fix |
|---|---|---|---|
| 1 | **Zu lang für kurze Fragen.** Ja/Nein-Fragen bekommen H2, Tabelle und 2,5–14k Zeichen; einmal fragt der Nutzer wörtlich, warum seine Frage nicht beantwortet wird. | 6/6 Teile; 604e8684, 13a2b5ab (8k), e915bd99 (12k) | Regel: „Antwortlänge folgt der Frage. Eine Frage mit einem Satz bekommt 1–3 Sätze, keine Überschrift, keine Tabelle. Details nur, wenn der Nutzer danach fragt. Sagt der Nutzer ‚nur kurz‘ oder ‚ich will nur wissen ob‘, dann höchstens 2 Sätze.“ |
| 2 | **Tool-Narration und Protokoll im Text.** „We need to emit tool call“, „Lass mich … suchen“, `</tool_call>`, `tool_call>{…}`, „ZWISCHENSTAND 1:“, sichtbares `<thinking>`. | 5/6 Teile; allein Teil 3: 31 Chats; 56b4235a, f7d8466e, 4381184c | Prompt: „Schreibe nie über Tool-Aufrufe. Kein ‚Ich suche jetzt‘, keine Tool-Namen im Text.“ Client: bekannte Protokoll-Reste (`tool_call>`, `</tool_call>`, „We need to …call“) aus dem sichtbaren Text filtern und Fortschritt nur im Tool-Block zeigen. |
| 3 | **Reflexions-Footer und Persona-Ton in Sachantworten.** Kursive „Selbstreflexion“/„INSIGHT“-Absätze, oft inhaltsleer, teils mit privaten Details in fremdem Kontext; Drill-Sergeant-Ton („harte Wahrheit“) bei neutralen Fragen. | 47 Antworten (Teil 2) + 29 Chats (Teil 3); Teile 1, 2, 3 zum Ton; 53695381, 4118beab | Kommt aus dem Soul-Text des Nutzers, nicht aus dem Code. Soul-Text entschärfen; zusätzlich Protokoll-Regel: „Persona betrifft Ton im Gespräch, nicht Fakten-, Recherche- und Ortsantworten. Keine Reflexions- oder Insight-Absätze am Ende.“ |
| 4 | **Doppelte Absätze und Antworten.** Derselbe Absatz oder dieselbe Antwort steht zweimal hintereinander. | 4/6 Teile; Teil 3: 16 Chats; 0bc87dbe, 6a1f7c72, c9ad2614 | Kein Prompt-Problem, sondern vermutlich Stream-/Merge-Bug über mehrere Tool-Pässe. Als Bug verfolgen; Client-seitig identische aufeinanderfolgende Absätze beim Zusammenführen verwerfen. |
| 5 | **Wiederholte Tabellen bei Nachfragen.** Nach einem Einwand kommt die ganze Tabelle neu; Rechenweg-Überschriften („Die Berechnung“) bei jeder Nachfrage; Automation postet 30× dieselbe Tabelle; nach einem Artefakt wird dessen Inhalt nacherzählt. | 5/6 Teile; ac899ced, 503efef3, Wahl-Monitor | Regel: „Bei Nachfragen nur die Änderung nennen, nie eine frühere Tabelle wiederholen. Nach einem Artefakt höchstens einen Satz schreiben.“ |
| 6 | **Fehlertexte als Assistenten-Nachricht.** „WebSocket streaming failed … 502“, „Model … not available“, „The model returned an empty response.“ | Teile 1–4; Teil 3: 16 Chats | Client: eigener Fehler-Zustand mit Retry-Knopf statt Text in der Blase; leere Antworten nicht speichern. |
| 7 | **Selbstsichere Falschaussagen, dann Kehrtwende; alte Tabelle bleibt stehen.** | Teile 2, 3, 4; bc084dcc, 8e3cd58d | Regel: „Bei Modell-, Preis- und Release-Fragen erst suchen, dann antworten.“ (`verify-online` existiert.) Korrekturen als `<callout type="correction">` mit einem Satz. |
| 8 | **Tool-Verleugnung oder erfundener Erfolg.** „Ich habe kein Chart-/Standort-Tool“, obwohl es existiert; Fake-Bildlinks; behaupteter offener Browser; Analyse eines nie gesehenen Dokuments. | Teile 0, 1, 5; 35ebb320, a4ddedcd, 5520b2d4 | Regel: „Behaupte nie, ein Tool fehle, ohne die Tool-Liste zu prüfen. Melde Erfolg nur, wenn ein Tool-Ergebnis ihn belegt.“ |
| 9 | **Emoji-Überladung.** Emoji-Header und Emoji-Ampeln in Fakten, Adressen und Tabellen. | Teile 0, 1, 5 | Regel: „Keine Emojis in Überschriften, Tabellen und Faktenantworten. Höchstens eines in lockeren Gesprächen.“ |
| 10 | **Rückfrage als Optionsliste.** 3–4 Interpretationen aufgezählt statt einer Rückfrage oder der besten Deutung. | Teil 3; 396b3701, 8e9a3c0d | Regel: „Bei unklarer Frage die wahrscheinlichste Deutung beantworten und in einem Satz die Alternative nennen.“ |
| 11 | **Falsche Sprache.** Englische Frage auf Französisch beantwortet. | Teil 1; 136ecfec | Regel: „Antworte in der Sprache der letzten Nutzernachricht.“ |

## 5. Empfehlung

### Reihenfolge

Vorher, ohne neue Blöcke (je S, sofort):

- Längen-, Leak-, Persona- und Wiederholungsregeln aus Abschnitt 4 (Punkte 1,
  2, 3, 5). Das trifft die meisten Chats, und jeder neue Block wirkt erst,
  wenn die Antwort drumherum kurz ist.
- Client-Fallback für breite Markdown-Tabellen und die Fehler-Blase (Punkt 6).
- Doppelte Absätze (Punkt 4) als Bug verfolgen.

Dann die Blöcke:

1. **`<verdict>`** (~124 Chats, Aufwand S). Billigster Block mit der größten
   Reichweite. Er gibt der Längenregel eine Form: Antwort in die Karte, Rest
   eingeklappt.
2. **`<steps>`** inkl. Befehlskarte (~100 Chats, M). Größter Nutzwert auf dem
   Handy: Befehl kopieren, abhaken, Reihenfolge stimmt.
3. **`<compare>`** mit Varianten Spec/Produkt/Plans (~100 Chats, M–L). Löst
   das Problem der breiten Tabellen dort, wo es am häufigsten auftritt; der
   Tabellen-Fallback überbrückt bis dahin.
4. **`<place>`** als Erweiterung von `<map>` (~32 Chats, S–M). Baut auf
   vorhandenem Code auf; zusammen mit der Regel „Karte in der ersten Antwort“.
5. **`<callout>`** (~32 Chats, S). Klein, und die Korrektur-Variante räumt
   Muster 7 mit auf.

`<timeline>` und `<ticker>` kommen danach, wenn die ersten fünf sitzen.

### Tags, Skills oder Structured Output?

- **Format bleibt `<tag>{JSON}</tag>` im Text.** Es passt zum vorhandenen
  Parser, streamt mit, mischt sich mit Markdown und funktioniert bei allen
  Anbietern.
- **Kein Structured-Output-Modus.** JSON-Schema-Modus wird nicht von allen
  genutzten Modellen und Providern (DeepSeek, GLM, Kimi über Fireworks und
  Router) gleich unterstützt, er verträgt sich schlecht mit Tool-Loops und
  Reasoning, und er zerstört das Streaming von Fließtext. Den Nutzen (strenge
  Validierung) erreicht man billiger mit dem nachsichtigen JSON-Parser plus
  Fallback auf Markdown, wenn ein Block nicht parst.
- **`<verdict>` und `<callout>` inline im Prompt.** Sie passen auf fast jede
  Antwort. Als Skill kostete jede Nutzung einen zusätzlichen Tool-Roundtrip
  (Skill-Aufruf, dann nächster Pass) – bei Kurzfragen genau die falsche
  Richtung. Das Schema ist klein (~60–80 Tokens für beide).
- **`<steps>`, `<compare>`, `<timeline>`, `<ticker>` als Skills**
  (`step-cards`, `compare-cards` usw.), nach dem Muster von `news-cards`. Die
  Schemas mit Varianten sind groß, die Fälle sind klar erkennbar, und ein
  Roundtrip bei Anleitungen und Vergleichen fällt nicht ins Gewicht. Im Prompt
  bleiben nur die ≤300 Zeichen der Beschreibung.
- **Aber: Trigger-Regel immer im Prompt.** Die Daten zeigen, dass das Modell
  schon vorhandene Blöcke (`<news>`, `<map>`, `<weather>`, `<chart>`) zu
  selten nutzt. Ein Skill, den das Modell nicht lädt, rendert nie. Deshalb pro
  Skill-Block eine Zeile im Protokoll („Vergleich von 2+ Optionen → Skill
  `compare-cards` laden und `<compare>` ausgeben, keine Tabelle“). Das kostet
  ~20 Tokens pro Block.
- **`<place>` in `<map>`**, nicht als eigener Tag: ein Parser, ein Widget, und
  das Modell muss sich keinen neuen Tag merken.
- **Bei jedem neuen Tag:** `_richBlockRegex` und `_visualBlockStartRegex` in
  `lib/widgets/message_bubble.dart` erweitern, Zweig in
  `message_bubble/rich_blocks.dart`, Fallback auf Markdown bei kaputtem JSON,
  Test für Parser und Streaming-Zwischenzustand. Nach dem Anlegen eines Skills
  `dart run tool/gen_skills.dart` laufen lassen.
