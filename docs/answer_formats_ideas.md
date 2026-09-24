# Neue Antwort-Visualisierungen (Ideen)

Stand: 2026-09-24. Ergänzung zu `docs/ANSWER_FORMATS_ANALYSIS.md`.

Ziel: echte, themen-eigene Darstellungen — so wie eine Tabelle die natürliche
Form für tabellarische Daten ist. **Kein Markdown in Karten.** Blöcke wie
`<verdict>`/`<steps>`/`<callout>` sind bewusst nicht hier: die stehen schon in
der Analyse und sind dem Owner zu langweilig.

Grundlage sind die 939 echten Chats in `_scratch/chat_analysis/part0..5.jsonl`.
Chat-IDs sind die ersten 8 Zeichen. Keine privaten Daten zitiert.

Schon vergeben, nicht wiederholt: Regler-Antwort, Weiche, Gewichtungs-Duell,
Tagesband.

Bewertung: `wow` 1–5 (visueller Reiz + „das kann Text nicht"). `Häufigkeit` ist
die geschätzte Zahl echter Chats des Typs. Rang = Häufigkeit × wow.

Rendering-Hinweis (gilt für alle): neuer Tag → in `_richBlockRegex` und
`_visualBlockStartRegex` (`lib/widgets/message_bubble.dart`), ein Zweig in
`message_bubble/rich_blocks.dart`, Fallback auf Markdown bei kaputtem JSON.
Große Schemas als Skill nach dem Muster `news-cards`.

---

## Rangliste

| # | Name | Typ | Häuf. | wow | Score |
|---|---|---|---|---|---|
| 1 | Modell-Steckbrief | „ist X open-weight / Kontext / Preis" | ~70 | 5 | 350 |
| 2 | Offen-jetzt-Ring | Öffnungszeiten | ~30 | 4 | 120 |
| 3 | Kompatibilitäts-Schacht | „passt Teil X in Y" | ~30 | 4 | 120 |
| 4 | Kurs-Warum | „warum ging X hoch/runter" | ~20 | 4 | 80 |
| 5 | Rechts-/Steuer-Ampel | Recht, Business, Steuern | ~20 | 4 | 80 |
| 6 | Netz-Faden | ÖPNV: nächster Halt, Zugteil | ~15 | 4 | 60 |
| 7 | Terminal-Replay | eingefügter Shell-Output | ~15 | 4 | 60 |
| 8 | Schichten-Stack | „wie funktioniert X" | ~12 | 5 | 60 |
| 9 | Meinungs-Positionskarte | strittige/politische Fragen | ~12 | 4 | 48 |
| 10 | Lern-Deck | Konzept Schritt für Schritt lernen | ~12 | 4 | 48 |
| 11 | Umrechen-Band | Einheiten umrechnen | ~15 | 3 | 45 |
| 12 | Skala-Einordnung | „warmweiß? / laut? / welche Zone" | ~10 | 4 | 40 |
| 13 | Foto-Hotspots | Bildanalyse mit Punkten | ~10 | 4 | 40 |
| 14 | Quellen-Waage | Sicherheit + widersprüchliche Quellen | ~10 | 4 | 40 |
| 15 | Energie-Budget | Akku/Laufzeit/Solar | ~8 | 4 | 32 |
| 16 | Vorher/Nachher-Schieber | Foto-Edit, „ist das KI" | ~10 | 3 | 30 |
| 17 | Verkabelungs-Diagramm | „wie verkabel ich das" | ~6 | 5 | 30 |
| 18 | Personen-Dossier | „wer ist X / net worth" | ~8 | 3 | 24 |
| 19 | Was-wäre-wenn-Baum | Konsequenz-/Hypothese-Fragen | ~6 | 4 | 24 |
| 20 | Watch-Order-Regal | Film-/Serienreihenfolge | ~8 | 3 | 24 |
| 21 | Frag-zurück-Chips | mehrdeutige Frage | ~8 | 2 | 16 |
| 22 | Rezept mit Schritt-Timer | Kochen | ~4 | 3 | 12 |

---

## 1. Modell-Steckbrief (`<modelcard>`)

- **Typ:** die mit Abstand häufigste Frageklasse des Owners — „ist Modell X
  open-weight, kann man es runterladen, wie groß ist der Kontext, was kostet es,
  wo läuft es". Beispiele: 4a91f40f („is minimax 2.7 openwieght"), 629cb90e
  („ist glm 5.1 open Wight"), 974391ec („composer 2.5 context window"), 8f6c33e3
  (glm-5-turbo download?), bd1a4f32 (gemma-4 open weight?), 49f1aedd (DeepSeek
  V4 Pro), 6c307dd8 (Step-3.7-Flash-NVFP4 vs andere).
- **Was man sieht/tut:** eine Karte mit einem großen Status-Badge —
  **OPEN WEIGHT** (grün) / **API ONLY** (grau) / **PROPRIETÄR** — plus vier
  Kacheln: Lizenz, Parameter (mit aktiven/MoE), Kontextfenster als Balken (z. B.
  128k von 1M), Stand. Darunter eine Zeile Provider-Chips mit €/1M-Token; Tap
  öffnet den Provider. Ein „Download"-Knopf nur wenn Gewichte da sind (führt zu
  HF-Repo). Antippen des Badges klappt die Begründung/Quelle auf.
- **Warum besser als Text:** die Ja/Nein-Info („open-weight?") geht heute in
  3–14k Zeichen mit H2 und Tabellen unter; die Quelle steht roh im Fließtext.
  Der Steckbrief macht genau die vier Fakten sofort sichtbar, die er immer will,
  in fester Reihenfolge, mobil lesbar.
- **Skizze:**
  ```
  <modelcard>{"name":"MiniMax M2.7","status":"api_only",
   "license":"proprietär","params":"230B-A10B","ctx":204800,"ctxMax":1000000,
   "asof":"2026-04","hf":null,
   "providers":[{"name":"MiniMax API","in":0.3,"out":1.2}]}</modelcard>
  ```
- **Häufigkeit:** ~70. **wow:** 5.

## 2. Offen-jetzt-Ring (`<hoursdial>`, Feld in `<map>`/`<place>`)

- **Typ:** Öffnungszeiten. b6903efb (IKEA Kiel bis wann), 192dbfc2 (Hermis heute),
  4069970b (Erdkorn Küche heute), 3de02d8d (Bistro im Erkoren), 3bdc7b8b (VR-Bank
  Automat), ff75e3e3 (Bäcker am Hbf), 28fd504b (Mülldeponie Samstag).
- **Was man sieht/tut:** eine 24-Stunden-Uhr als Ring. Grüner Bogen = offen,
  ein Zeiger auf „jetzt", darunter ein Satz „offen · schließt in 1 h 40". Tap
  blättert Wochentage durch. Die Rechnung „offen jetzt?" macht der Client aus
  `hours`, nicht das Modell (das rechnet es heute oft falsch).
- **Warum besser als Text:** „bis wann offen" ist eine Zeitspanne relativ zu
  jetzt — genau das, was eine Textliste „Mo–Sa 10:00–20:00" den Nutzer selbst
  ausrechnen lässt. Der Ring zeigt Rest-Zeit auf einen Blick.
- **Skizze:**
  ```
  <hoursdial>{"name":"IKEA Kiel","tz":"Europe/Berlin",
   "hours":{"mo-sa":"10:00-20:00","su":null},"now":"2026-09-24T18:20"}</hoursdial>
  ```
- **Häufigkeit:** ~30. **wow:** 4.

## 3. Kompatibilitäts-Schacht (`<fitcheck>`)

- **Typ:** „passt Teil X in Gerät Y" — CPU-Upgrade, GPU-Einbau, RAM, Netzteil,
  Speicher. d61bd8a8 (beste CPU für HP EliteDesk 800 G2 65W), 94cea34e (welche
  GPU in Supermicro-Server), 81127681 (Pixel 7 Pro Speicher upgraden?), ab40439a
  (Dell R920 Strom-Anschlüsse), e076fbf6 (2014-MacBook max specs / SSD tauschbar),
  13a2b5ab (Pi-Alternativen).
- **Was man sieht/tut:** links das Ziel-Gerät (Sockel/Slot als Umriss), rechts
  das Teil, das per Animation einrastet (grün) oder abprallt (rot). Darunter drei
  bis fünf Prüf-Gates als Ampel-Zeilen: Sockel, TDP-Budget, BIOS/Firmware,
  Bauhöhe, Speichergrenze. Tap auf eine rote Zeile erklärt das Hindernis.
- **Warum besser als Text:** das eigentliche Ergebnis ist ein Ja/Nein plus die
  eine Bedingung, die kippt (TDP, BIOS-Version). Im Fließtext steht das verstreut;
  der Schacht macht Passen/Nicht-Passen und den kritischen Faktor sofort klar.
- **Skizze:**
  ```
  <fitcheck>{"target":"HP EliteDesk 800 G2 DM 65W","part":"i7-6700T",
   "fits":true,"gates":[{"k":"Sockel","ok":true,"v":"LGA1151"},
    {"k":"TDP","ok":true,"v":"35W ≤ 65W"},{"k":"BIOS","ok":"maybe","v":"≥ 2.40 nötig"}]}</fitcheck>
  ```
- **Häufigkeit:** ~30. **wow:** 4.

## 4. Kurs-Warum (`<pricemove>`)

- **Typ:** „warum ging X heute hoch/runter" — genau die Kombi aus Kurs + Grund.
  dbea781e (Monero-Spike auf 500/600 warum), 2d96a340 (why did Roku go up),
  b0291d9e (Bitget: warum nicht 20 % hoch), 5a7f9cf8 (BTC rn + Chart), 375ef161
  (was ist mit btc los), b576d20c (bitcoin up today + Chart).
- **Was man sieht/tut:** eine Sparkline mit Δ %, und an den Ausschlägen sitzen
  nummerierte Pins. Jeder Pin ist ein Auslöser in einem Satz mit Quelle. Kein
  voller Chart, bis man tippt.
- **Warum besser als Text:** die Frage verknüpft Bewegung und Ursache. Eine
  Tabelle trennt beides; hier klebt der Grund optisch an der Stelle der Kurve,
  wo er wirkte.
- **Skizze:**
  ```
  <pricemove>{"sym":"XMR","chg":38.0,"win":"24h","spark":[..],
   "pins":[{"at":0.6,"t":"Binance-Delisting-Gerücht dementiert","src":"…"}]}</pricemove>
  ```
- **Häufigkeit:** ~20. **wow:** 4.

## 5. Rechts-/Steuer-Ampel (`<legal>`)

- **Typ:** Recht, Steuer, Gewerbe — wo die Antwort ein Risiko mit Geldfolge ist.
  4689f803 (3 Jahre keine Steuer gezahlt), bf37debe (Cofounder im Kleingewerbe),
  455f987d (mehrere Kleingewerbe), 211dafba (GPL3 proprietär verkaufen), fa64ca5f
  (Airbnb in Berlin-Moabit erlaubt), b992df00 (Schlagrattenfallen erlaubt),
  39fa17aa (Ziegen anpflocken).
- **Was man sieht/tut:** eine Ampel-Karte: grün „erlaubt" / gelb „mit Auflage" /
  rot „verboten/riskant", ein Satz Kern, darunter der konkrete Bezug (Paragraf,
  Norm, Frist) als Chip und eine abgesetzte Geld-Folge-Zeile („Nachzahlung bis 4
  Jahre + Zinsen"). Tap auf den Paragraf-Chip zeigt den Wortlaut.
- **Warum besser als Text:** das Geldrisiko und die Rechtsgrundlage stehen heute
  im Fließtext; der Nutzer will Farbe (geht das?) + Betrag + Fundstelle. Die
  Ampel trennt die drei sauber und macht Rot unübersehbar.
- **Skizze:**
  ```
  <legal>{"light":"red","claim":"3 Jahre keine Steuererklärung",
   "risk":"Schätzung + Verspätungszuschlag + 0,5 %/Monat Zinsen",
   "refs":[{"label":"§ 152 AO","note":"Verspätungszuschlag"}]}</legal>
  ```
- **Häufigkeit:** ~20. **wow:** 4.

## 6. Netz-Faden (`<transit>`)

- **Typ:** ÖPNV konkret unterwegs — nächster Halt, welcher Zugteil, sind wir
  schon durch. d66d40e8 (wohin fährt der RB37 jetzt), 8e3cd58d (RE70: welcher
  Teil nach Kiel, welche Halte), 40e56180 (nächste Haltestelle Rathaus),
  25e38797 (Dammtor→Kiel: schon am Hbf?), 8616eb1d (nächster Halt Brunsbüttel),
  13a6b6a0 (Gleis gegenüber).
- **Was man sieht/tut:** ein waagerechter Faden aus Halte-Punkten, „du bist
  hier" markiert, Fahrtrichtung als Pfeil. Bei Flügelzügen teilt sich der Faden
  in zwei Äste mit Zielschildern („vorderer Teil → Kiel"). Tap auf einen Halt
  zeigt Ankunft.
- **Warum besser als Text:** Richtung, Rest-Halte und die Zugteilung sind
  räumlich; eine nummerierte Liste verliert genau die „wo bin ich, welcher Teil"-
  Orientierung, die der Owner mehrfach braucht.
- **Skizze:**
  ```
  <transit>{"line":"RE70","dir":"Kiel Hbf","here":"Neumünster",
   "stops":["Hamburg","Elmshorn","Neumünster","Bordesholm","Kiel Hbf"],
   "split":{"at":"Neumünster","front":"Kiel","rear":"Flensburg"}}</transit>
  ```
- **Häufigkeit:** ~15. **wow:** 4.

## 7. Terminal-Replay (`<console>`)

- **Typ:** Nutzer fügt Shell-Output ein und will Befund + nächsten Befehl.
  5f8d2c9f (tar.gz entpacken, dann System-Info), 38487c4c (Actions-Runner remove
  token failed), 5131cf53 (opencode installer läuft), e25315f6 (rar/7z entpacken
  im Hintergrund), dfb9fbcb (`zsh: correct 'codex' to 'code'`).
- **Was man sieht/tut:** der eingefügte Output wird als echtes Terminal-Panel
  gerendert; die eine relevante Zeile ist markiert, daneben eine Sprechblase
  „das ist das Problem". Darunter der Fix als Copy-Chip, direkt ausführbar. Bei
  mehreren Schritten spielt ein „Replay" die Befehle nacheinander durch.
- **Warum besser als Text:** heute geht der Fix zwischen Prosa unter, und der
  Bezug „welche Zeile ist das Problem" fehlt. Das Panel klebt die Diagnose an die
  Zeile und macht den Befehl kopierbar.
- **Skizze:**
  ```
  <console>{"lines":[{"t":"zsh: correct 'codex' to 'code' [nyae]?","mark":true}],
   "finding":"zsh-Autokorrektur, codex ist nicht im PATH",
   "fix":{"cmd":"echo 'export PATH=$HOME/.codex/bin:$PATH' >> ~/.zshrc"}}</console>
  ```
- **Häufigkeit:** ~15. **wow:** 4.

## 8. Schichten-Stack (`<stack>`)

- **Typ:** „wie funktioniert X" mit klaren Ebenen — Compiler, Internet, Netzwerk,
  Protokolle. 928c9a7f (Compiler von Source bis Executable: Lexer/Parser/…),
  71202c73 / f6a3e2ce (how does the internet work), f90c689d (IPv4 vs IPv6),
  0ce4b032 (fugu model), 10c20e01 (Embeddings). Der Owner lehnt Excalidraw dafür
  ausdrücklich ab (fe286860) — er will kein Freihand-Diagramm, sondern Struktur.
- **Was man sieht/tut:** ein vertikaler Stapel benannter Schichten. Ein
  Daten-Token wandert animiert von oben nach unten durch die Ebenen (Quelltext →
  Tokens → AST → IR → Maschinencode). Tap auf eine Schicht klappt zwei Sätze +
  Beispiel auf. Optional Umschalter „rauf/runter".
- **Warum besser als Text:** lange Absätze verlieren die Reihenfolge und das
  „was geht rein, was kommt raus" pro Stufe. Der Stack macht die Pipeline und den
  Durchlauf sichtbar, ohne die Freihand-Beliebigkeit von Excalidraw.
- **Skizze:**
  ```
  <stack>{"flow":"down","token":"int x = 2+3;",
   "layers":[{"name":"Lexer","out":"Tokens: int, x, =, 2, +, 3, ;"},
    {"name":"Parser","out":"AST"},{"name":"Codegen","out":"x86"}]}</stack>
  ```
- **Häufigkeit:** ~12. **wow:** 5.

## 9. Meinungs-Positionskarte (`<stances>`)

- **Typ:** strittige, politische, „darf man"-Meinungsfragen, wo eine einzige
  „Wahrheit" falsch wäre. cfcff90a (darf man AfD rechtsextrem nennen), 077a3ec4
  (ist Kuba eine Demokratie), da76cd35 (rechte Position argumentieren), 9a19f4c6
  (Vermögensteuer der Linken), b158aa39 (kann man als Bürger verfassungsfeindlich
  sein).
- **Was man sieht/tut:** eine waagerechte Achse (z. B. „klar erlaubt ↔ klar
  verboten" oder „pro ↔ contra") mit 2–4 Positions-Pins, jeder mit „wer das so
  sieht" und einem Satz Begründung. Darüber ein grauer Anker-Streifen mit dem,
  was gesichert/gerichtlich geklärt ist. Tap auf einen Pin zeigt die Quelle.
- **Warum besser als Text:** Prosa zu solchen Fragen driftet in einen einzigen
  Standpunkt oder in Geschwafel. Die Karte trennt sichtbar den gesicherten Anker
  vom Meinungsspektrum — und zeigt, dass es ein Spektrum ist.
- **Skizze:**
  ```
  <stances>{"axis":["zulässig","unzulässig"],
   "anchor":"Gerichte: Einstufung als Verdachtsfall bestätigt",
   "pins":[{"x":0.2,"who":"Verfassungsschutz","t":"…"},
           {"x":0.8,"who":"Partei","t":"…"}]}</stances>
  ```
- **Häufigkeit:** ~12. **wow:** 4.

## 10. Lern-Deck (`<deck>`)

- **Typ:** ein Konzept Schritt für Schritt lernen, oft über viele Turns, mit
  „nicht verstanden". a94237fb (LLM von Grund auf, Schritt für Schritt), 10c20e01
  (Embeddings), 4d1bfdec (was ist GAN), 928c9a7f (Compiler), c88021a0 (Flutter
  lernen), 132f5326 (Tensor-Prozessor).
- **Was man sieht/tut:** ein Stapel wischbarer Karten, eine Idee pro Karte, mit
  Fortschritt „3/7". Nach je 2–3 Karten eine Mini-Verständnisfrage mit zwei bis
  drei Antwort-Chips; falsch → die Karte davor kommt zurück. Kein Wall of Text.
- **Warum besser als Text:** der Owner sagt mehrfach „nicht verstanden", weil
  alles als langer Absatz kommt. Das Deck erzwingt eine Idee pro Schritt und
  prüft, ob es saß, bevor es weitergeht.
- **Skizze:**
  ```
  <deck>{"topic":"LLM von Grund auf",
   "cards":[{"h":"Token","b":"Text wird in Stücke zerlegt …"},
    {"h":"Embedding","b":"jedes Token wird ein Vektor …",
     "quiz":{"q":"Was ist ein Embedding?","opts":["ein Vektor","ein Wort"],"a":0}}]}</deck>
  ```
- **Häufigkeit:** ~12. **wow:** 4.

## 11. Umrechen-Band (`<convert>`)

- **Typ:** Einheiten umrechnen. c41ece32 (59 lbs in bar — Druck/Masse-Falle),
  6a5abf9d (Pace m/km), e2e103d1 (3 km/min → kmh, dann min/km), d5616d42 (Hektar
  vs qm), c61090fd (Meilen im Marathon).
- **Was man sieht/tut:** ein waagerechtes Band mit zwei (oder mehr) Skalen
  übereinander; ein Griff, den man zieht, verschiebt alle Skalen synchron. Das
  Ergebnis steht groß, der Umrechenfaktor als Untertitel. Falsche Einheiten-Deutung
  (lbs↔bar) wird als Hinweis-Chip markiert.
- **Warum besser als Text:** heute ist das Ergebnis nicht hervorgehoben und der
  Rechenweg wird bei jeder Nachfrage neu als Prosa wiederholt. Das Band gibt den
  Wert sofort und lässt Nachbarwerte durch Ziehen ablesen, ohne neue Frage.
- **Skizze:**
  ```
  <convert>{"from":{"v":4.5,"u":"km","t":21.516667,"tu":"min"},
   "to":{"u":"min/km","v":"4:47"},"note":"Pace = Zeit ÷ Strecke"}</convert>
  ```
- **Häufigkeit:** ~15. **wow:** 3.

## 12. Skala-Einordnung (`<gauge>`)

- **Typ:** einen Messwert auf einer benannten Skala einordnen — Farbtemperatur,
  Lautstärke, Trainingszone, Sternzeichen. 718fdc59 (Lampe warmweiß? Kelvin),
  500baa2d (Geburtsdatum → Sternzeichen), potenziell Lumen/dB/Herzfrequenz.
- **Was man sieht/tut:** ein Farb-/Wertband mit benannten Regionen (2700 K warm …
  6500 K kalt) und einem Marker auf dem gemessenen Wert, dazu das Label der Region
  („warmweiß"). Beim Sternzeichen ist die Skala ein Datums-Ring.
- **Warum besser als Text:** die Antwort ist ein Punkt auf einem Kontinuum
  („warm oder kalt?") — ein bloßer Zahlwert im dritten Absatz sagt dem Nutzer
  nicht, wo das liegt. Das Band gibt Zahl + Einordnung zugleich.
- **Skizze:**
  ```
  <gauge>{"scale":"kelvin","min":2000,"max":6500,"value":3000,
   "bands":[{"to":3300,"label":"warmweiß"},{"to":5300,"label":"neutral"}]}</gauge>
  ```
- **Häufigkeit:** ~10. **wow:** 4.

## 13. Foto-Hotspots (`<hotspots>`)

- **Typ:** Bildanalyse, wo die Antwort an Stellen im Bild hängt. da32b3ea (rote
  LED blinkt — was heißt das), ac3f0bb6 (welches Casio-Symbol ist aktiv), 93ce5e6e
  (Gerät so einstellen dass es nicht ausgeht), 396b3701 (Rechteck für Schraube),
  162ab97d (Pixel-7-Akku — Grund im Bild).
- **Was man sieht/tut:** das eingesandte Bild bleibt stehen, darauf sitzen
  antippbare Marker; jeder Marker öffnet einen kurzen Befund („diese LED = Akku
  schwach"). Optional eine Lupe.
- **Warum besser als Text:** „was bedeutet das da" braucht einen Ortsbezug zum
  Bild; eine reine Textantwort zwingt den Nutzer, die beschriebene Stelle selbst
  zu suchen. Marker zeigen direkt worauf.
- **Skizze:**
  ```
  <hotspots>{"img":"<url|attach>","points":[
   {"x":0.62,"y":0.31,"t":"rote LED = Ladefehler / Akku schwach"},
   {"x":0.20,"y":0.80,"t":"Reset-Knopf 10 s halten"}]}</hotspots>
  ```
- **Häufigkeit:** ~10. **wow:** 4.

## 14. Quellen-Waage (`<balance>`)

- **Typ:** Fakten, die man belegen muss, und Fragen mit zwei widersprechenden
  Quellen. bc084dcc (loggt Fireworks Trainingsdaten — Quelle vs Behauptung),
  8e3cd58d (widersprüchliche Angaben zur Zugstrecke), allgemein alle Fälle aus
  Muster 7 der Analyse (selbstsichere Falschaussage, dann Kehrtwende).
- **Was man sieht/tut:** eine Balkenwaage; links und rechts liegen Quellen-Chips
  als Gewichte, ihre Größe = Verlässlichkeit (Primärquelle > Forum). Der Zeiger
  kippt zur belegteren Seite; oben eine Sicherheits-Nadel (niedrig/mittel/hoch).
  Bei Widerspruch stehen beide Aussagen als Waagschalen nebeneinander.
- **Warum besser als Text:** heute sehen Fakt und Vermutung gleich aus und Links
  liegen roh im Text. Die Waage macht sichtbar, wie sicher etwas ist und worauf
  sich das stützt — und zeigt Widerspruch statt ihn glattzubügeln.
- **Skizze:**
  ```
  <balance>{"claim":"Fireworks loggt keine Trainingsdaten","confidence":"mittel",
   "for":[{"src":"Fireworks ToS","weight":3}],
   "against":[{"src":"Reddit-Thread","weight":1}]}</balance>
  ```
- **Häufigkeit:** ~10. **wow:** 4.

## 15. Energie-Budget (`<powerbudget>`)

- **Typ:** Laufzeit/Kapazität rechnen — Akku, Powerbank, Solar, Kondensator.
  503efef3 (Gel-Akku 12V 9Ah, wie lange Pi Zero 2W), 890ecdeb (Powerbank 10.000
  mAh Laufzeit), a5f77562 (10.000 mAh bei 3,7 V → Wh), c8102594 (kWh-Verbrauch),
  573a1a94 (Solaranlage Eigenbetrieb).
- **Was man sieht/tut:** eine Batterie-Kachel: Kapazität in Wh, ein Regler für
  die Last in Watt, darunter die Laufzeit als große Zahl, die sich beim Ziehen
  live ändert. Wirkungsgrad als Schalter (85 %). Zeigt auch die mAh↔Wh-Umrechnung,
  die der Owner oft selbst falsch macht.
- **Warum besser als Text:** die eigentliche Frage ist „was passiert bei anderer
  Last" — ein einzelner Textwert beantwortet nur einen Fall. Der Regler ersetzt
  die Nachfrage „und bei 14 Ah?" (kam in 503efef3 wörtlich).
- **Skizze:**
  ```
  <powerbudget>{"capacity_wh":108,"cap_label":"12V 9Ah",
   "load_w":2,"efficiency":0.85,"hours":45.9}</powerbudget>
  ```
- **Häufigkeit:** ~8. **wow:** 4.

## 16. Vorher/Nachher-Schieber (`<beforeafter>`)

- **Typ:** Foto-Edit-Ergebnisse und „ist das KI / was wurde verändert". 3f35738a
  (ist das Bild KI oder nicht), 3dec4000 (image edit retry), plus jede Bild-zu-
  Bild-Bearbeitung der image-gen-Pipeline.
- **Was man sieht/tut:** zwei Bilder übereinander, ein vertikaler Griff, den man
  zieht, deckt links das eine, rechts das andere auf. Bei „ist das KI" markieren
  optionale Pins die verdächtigen Regionen im Nachher-Bild.
- **Warum besser als Text:** Unterschiede zwischen zwei Bildern in Worten zu
  beschreiben ist zäh; der Schieber lässt den Nutzer die Änderung direkt sehen.
- **Skizze:**
  ```
  <beforeafter>{"before":"<url>","after":"<url>",
   "labels":["Original","bearbeitet"]}</beforeafter>
  ```
- **Häufigkeit:** ~10. **wow:** 3.

## 17. Verkabelungs-Diagramm (`<wiring>`)

- **Typ:** „wie verkabel ich das" — Schalter, Lampe, Lüfter, Trafo, Router.
  b2f553d6 (Schalter + Lampe + 3-adriger Lüfter), d7217e7c (Trafo mit Hoch/Runter-
  Schalter, 4 Kabel), 85acfbe4 (Cat7 an welchen Router).
- **Was man sieht/tut:** die Bauteile als Kästchen mit benannten Klemmen (L, N,
  PE, S1); farbige Adern verbinden sie. Tap auf eine Ader hebt sie hervor und
  nennt Farbe + Zweck. Optional ein „Schritt für Schritt"-Modus, der die Adern
  einzeln einblendet.
- **Warum besser als Text:** Klemmen und Aderfarben in Prosa sind kaum
  nachvollziehbar und fehleranfällig (Stromschlag-Risiko). Das Diagramm zeigt
  jede Verbindung eindeutig.
- **Skizze:**
  ```
  <wiring>{"parts":[{"id":"sw","name":"Schalter","terminals":["L","S1"]},
   {"id":"lamp","name":"Lampe","terminals":["L","N"]}],
   "wires":[{"from":"sw.S1","to":"lamp.L","color":"schwarz"}]}</wiring>
  ```
- **Häufigkeit:** ~6. **wow:** 5.

## 18. Personen-Dossier (`<dossier>`)

- **Typ:** „wer ist X, was macht er, net worth". f9c846d1 (Julian Petroulas net
  worth), 3fa2318f (Rosemary Leith Karriere), 16c90e9f (Liam Ottley), 38245675
  (Iman Gazi), b780e453 (Truett Hanes Alter), 7434af36 (Peter Thiel deutsch?).
- **Was man sieht/tut:** eine Steckbrief-Karte: Foto, Rolle, geschätztes Vermögen
  als Spanne mit Sicherheits-Punkt, eine kurze Rollen-Zeitleiste (WEF → Proton),
  Links. Kein Fließtext-Lebenslauf.
- **Warum besser als Text:** der Owner will die 3–4 Eckdaten, nicht einen
  Aufsatz; die Vermögens-Spanne (statt Scheingenauigkeit) passt zu „Schätzung".
- **Skizze:**
  ```
  <dossier>{"name":"…","role":"Investor","netWorth":{"min":100,"max":300,"unit":"Mio €","confidence":"niedrig"},
   "timeline":[{"year":2015,"t":"WEF"},{"year":2024,"t":"Proton-Board"}]}</dossier>
  ```
- **Häufigkeit:** ~8. **wow:** 3.

## 19. Was-wäre-wenn-Baum (`<whatif>`)

- **Typ:** Konsequenz- und Hypothesefragen. 534d5b45 (Drohne gegen
  Hochspannungsleitung eines Zuges — was passiert, und wenn sie nur eine Leitung
  berührt), 448d8507 (ohne Secure Boot: kann Malware das BIOS hacken), 44f726c9
  (eigener GTA-Server).
- **Was man sieht/tut:** ein Ausgangsknoten, aus dem sich Verzweigungen öffnen
  („berührt eine Leitung" / „berührt zwei"). Jeder Ast endet in einem Ergebnis mit
  Schweregrad-Farbe. Tap klappt Zwischenschritte auf.
- **Warum besser als Text:** solche Fragen haben mehrere Fälle mit
  unterschiedlichem Ausgang; Prosa mischt sie. Der Baum trennt die Fälle und macht
  „ab hier wird es gefährlich" sichtbar.
- **Skizze:**
  ```
  <whatif>{"start":"Drohne nähert sich Oberleitung",
   "branches":[{"cond":"berührt 1 Leitung","result":"Lichtbogen, Drohne zerstört","sev":"mid"},
    {"cond":"überbrückt 2 Leitungen","result":"Kurzschluss, Streckensperrung","sev":"high"}]}</whatif>
  ```
- **Häufigkeit:** ~6. **wow:** 4.

## 20. Watch-Order-Regal (`<watchorder>`)

- **Typ:** Reihenfolge von Filmen/Serien. 17129183 (Jason Bourne erster Teil +
  Reihenfolge), 7a9791a1 (James Bond nach 2008), cf8bf10b (Serienreihenfolge),
  1c3abbd5 (V wie Vendetta Release), 82179038 (1923 Staffeln).
- **Was man sieht/tut:** eine Reihe von Poster-Karten in Reihenfolge, mit einem
  Umschalter „Erscheinung ↔ Handlung/Chronologie". „Schon gesehen"-Häkchen pro
  Karte, „du bist hier"-Marker. Tap zeigt Jahr + Ein-Satz-Worum-geht-es.
- **Warum besser als Text:** eine nummerierte 26-Zeilen-Liste ist unübersichtlich
  und kann Release- vs Handlungsreihenfolge nicht gleichzeitig zeigen. Das Regal
  schaltet zwischen beiden um und merkt sich den Stand.
- **Skizze:**
  ```
  <watchorder>{"title":"Jason Bourne","order":"release",
   "items":[{"name":"Die Bourne Identität","year":2002,"poster":"<url>"},
    {"name":"Die Bourne Verschwörung","year":2004}]}</watchorder>
  ```
- **Häufigkeit:** ~8. **wow:** 3.

## 21. Frag-zurück-Chips (`<clarify>`)

- **Typ:** mehrdeutige Frage, wo heute 3–4 Interpretationen aufgezählt werden.
  396b3701, 8e9a3c0d, e4ee03ab. (In der Analyse als `<choices>` erwähnt — hier als
  eigenständige, minimale Form.)
- **Was man sieht/tut:** die wahrscheinlichste Deutung wird sofort beantwortet;
  darunter ein bis zwei Chips „meintest du eher …?", Tap schickt die Rückfrage als
  neue Nutzernachricht.
- **Warum besser als Text:** eine Optionsliste blockiert die Antwort; die Chips
  liefern die beste Antwort trotzdem und bieten die Korrektur mit einem Tap.
- **Skizze:**
  ```
  <clarify>{"assumed":"du meinst die Schraube am Glasrand",
   "chips":["nein, das Scharnier","nein, der Rahmen"]}</clarify>
  ```
- **Häufigkeit:** ~8. **wow:** 2.

## 22. Rezept mit Schritt-Timer (`<recipe>`)

- **Typ:** Kochen. 6557a40e (was koche ich mit Hähnchen und Reis), am Rand
  839218e3 (Käse/Zusatzstoffe).
- **Was man sieht/tut:** oben eine abhakbare Zutatenliste mit Mengen, darunter
  Schritt-Karten; Schritte mit Zeit haben einen eingebauten Countdown-Knopf
  („15 min köcheln" → Timer läuft im Chat).
- **Warum besser als Text:** ein Rezept in Prosa lässt Zutaten und laufende Zeiten
  untergehen; die Karten haken ab und der Timer ersetzt eine separate App.
- **Skizze:**
  ```
  <recipe>{"title":"Hähnchen-Reis-Pfanne","serves":2,
   "ingredients":[{"q":"250 g","n":"Hähnchenbrust"},{"q":"150 g","n":"Reis"}],
   "steps":[{"t":"Reis 12 min kochen","timer":720}]}</recipe>
  ```
- **Häufigkeit:** ~4. **wow:** 3.

---

## Umsetzungshinweise

- **Zuerst bauen:** Modell-Steckbrief (klar die #1-Frageklasse), dann
  Offen-jetzt-Ring und Kompatibilitäts-Schacht. Diese drei treffen zusammen einen
  großen Teil seiner echten Chats.
- **Live-Rechnung immer im Client**, nie im Modell: Offen-jetzt, Umrechnung,
  Energie-Laufzeit, Pace. Das Modell liefert nur die Rohwerte; das Modell rechnet
  Zeit-/Einheitensachen in den Daten oft falsch.
- **Interaktion ohne neuen Turn:** Regler (Energie-Budget, Umrechen-Band), Wisch
  (Deck, Vorher/Nachher), Umschalter (Watch-Order, Stack-Richtung) sollen ohne
  neue Modellanfrage funktionieren — das spart Tokens und wirkt sofort.
- **Große Schemas als Skill** (Modell-Steckbrief, Stack, Deck, Transit, Wiring),
  kleine inline (Gauge, Clarify, Convert). Pro Skill-Block eine harte Trigger-Zeile
  im Prompt, sonst wird der Block wie heute `<news>`/`<map>` zu selten genutzt.
