# Plan: der Browser des Nutzers als zweites Browser-Target (Firefox/Chrome-Add-on)

Session cowork-3c, 2026-09-08. Status: Entwurf. **Abschnitte 2, 4, 5 und 6 sind durch
`docs/RESEARCH_2026-09-08_BROWSER_CONTROL_APIS.md` (gleicher Tag) ueberholt** —
dort steht, was Chrome und Firefox wirklich anbieten und was Claude for Chrome
tatsaechlich benutzt. Gueltig bleiben Abschnitt 1 (die Naht) und 3 (Panel).

Heute fährt der Agent einen Browser **in der Sandbox** (Docker + Xvfb + VNC,
`cowork-browser-mcp`, Tools `mcp__playwright__browser_*`). Das bleibt der
Hauptweg. Dieses Dokument beschreibt ein **zweites Target**: den echten Browser
des Nutzers, angebunden über ein Add-on.

## 1. Die eine Erkenntnis, die alles klein macht

`executor.py::_browser_mcp_server()` liefert nur eine Spec:

```python
{"name": "playwright", "command": <docker>, "args": [..., cid, "cowork-browser-mcp"]}
```

Das ist die **einzige** Naht. Wer dahinter sitzt, weiß der Rest des Systems
nicht. Tauscht man die Spec gegen einen zweiten stdio-MCP-Server aus, der
**dieselben Tool-Namen** anbietet, dann funktionieren ohne eine Zeile Änderung
weiter:

* `protocol.browser_state_from_tool` (Prefix `mcp__playwright__`),
* `run_state.browser_open` / `browser_view opened|closed`,
* `BrowserPresence` in Dart, der "Agent's browser"-Button, Tool-Karten, Replay.

**Also: Tool-Namen NICHT umbenennen.** Nicht `extension_navigate`, sondern
weiter `browser_navigate` usw. Neu ist nur die Auswahl des Targets pro Session:

```
browser_target = "sandbox" (Default) | "user_browser"
```

Bei `user_browser` gibt `_browser_mcp_server()` statt des Docker-Prefixes
`{"name": "playwright", "command": "cowork-extension-mcp", "args": [...]}`
zurück — ein Prozess auf dem Host, kein Container. VNC (`browser_view started`)
entfällt dort: der Nutzer sieht seinen Browser ja selbst.

## 2. Transport: Add-on ↔ Agent

Der Host läuft auf dem Server, der Browser auf dem Laptop. Direktes
`ws://127.0.0.1` zum Host scheidet damit aus. Der Weg ist der vom Nutzer
genannte:

```
Agent (Python, Host)
  └─ cowork-extension-mcp (stdio, Host)
       └─ neues Frame-Paar über den bestehenden Relay
            └─ Flutter-Desktop-App (schon authentifiziert, schon verbunden)
                 └─ lokaler WebSocket 127.0.0.1:<zufälliger Port>
                      └─ Add-on (Background/Service-Worker)
                           └─ Content-Script im Tab
```

Sechs Sprünge, aber fünf existieren bereits. Die App ist der einzige Knoten mit
Identität auf beiden Seiten — deshalb dort und nicht woanders.

Neue Wire-Frames (additiv, `docs/WIRE_CONTRACT.md`):

```json
{"type": "browser_cmd",   "target": "user_browser", "cmd_id": "<id>",
 "op": "navigate|snapshot|click|type|scroll|screenshot|tabs|close|new_tab",
 "args": {...}}
{"type": "browser_result","cmd_id": "<id>", "ok": true|false,
 "data": {...}, "error": "<text>"}
{"type": "browser_attach","attached": true|false, "browser": "chrome|firefox",
 "version": "<x>", "domains": ["..."]}
```

`browser_attach` ist die Präsenz: nur wenn ein Add-on hängt, darf der Host
`browser_target=user_browser` überhaupt anbieten.

### Lokale Kopplung App ↔ Add-on (Sicherheit, weil Geld)

Der lokale WS ist ein Fernsteuer-Port für den eingeloggten Browser des Nutzers.
Ohne Absicherung kann **jede beliebige Webseite** darauf verbinden und über den
Agenten im Namen des Nutzers handeln. Also hart:

* Bind ausschließlich `127.0.0.1`, Port zufällig, nie `0.0.0.0`.
* `Origin` muss exakt `chrome-extension://<id>` bzw. `moz-extension://<uuid>`
  sein; alles andere sofort schließen.
* Pairing-Token: die App zeigt einen Code, die Optionsseite des Add-ons nimmt
  ihn entgegen, Token landet in `storage.local`. Ohne Token kein Kommando.
* Domain-Allowlist, default-deny. Der Agent darf nur auf freigegebenen Domains
  handeln; eine neue Domain geht als `approval_request` an den Nutzer (das
  Frame gibt es schon).

## 3. Rechtsklick-Zeitleiste (Seitenpanel)

Zwei getrennte Dinge, nicht vermischen:

**a) Nutzer chattet über die Seite.** Rechtsklick → "Mit CoWork über diese Seite
reden" → Panel rechts. Das Add-on schickt Seitenkontext (URL, Titel,
Readability-Text, optional Screenshot, optional Auswahltext) als Anhang an ein
ganz normales `task`-Frame. **Kein neues Agent-Tool nötig**, nur eine neue
Anhangsquelle. Modellwahl kommt aus dem bestehenden `chat_mode_service`.

**b) Agent fährt selbst.** Das ist §2, die `browser_*`-Tools. Der Agent macht
sich einen **eigenen Tab** auf (eigene Tab-Gruppe, eingefärbt, Titelpräfix),
fasst die Tabs des Nutzers nie an. Regel im Code, nicht in der Prompt.

Panel-API unterscheidet sich:

| | Chrome | Firefox |
|---|---|---|
| Panel | `chrome.sidePanel` (MV3) | `sidebar_action` (seit je) |
| Kontextmenü | `contextMenus` | `contextMenus` (identisch) |
| Hintergrund | `service_worker` | `background.scripts` / Event-Page |
| CDP im Add-on | `chrome.debugger` (mit gelbem Banner) | **existiert nicht** |
| API-Stil | `chrome.*`, Callbacks + Promises | `browser.*`, Promises |

Ein Quellbaum, zwei Manifeste, ein dünner `polyfill`-Layer
(`webextension-polyfill`). Die Panel-Unterschiede sind ~30 Zeilen.

## 4. Wie die Seite gesteuert wird

Zwei Modi, der zweite optional:

1. **Content-Script + synthetische Events** (Default, beide Browser). Snapshot
   als Accessibility-artiger Baum mit stabilen `ref`-IDs — genau die Form, die
   Playwright-MCP liefert, damit die Tool-Signaturen gleich bleiben.
   Grenzen: `isTrusted:false` bricht bei manchen Seiten, echte Datei-Uploads
   gehen nicht, cross-origin-iframes sind zäh.
2. **`chrome.debugger` (CDP)**, nur Chrome, nur hinter einem Schalter. Echte
   Eingaben, aber Chrome zeigt dauerhaft "… debuggt diesen Browser". Für
   Seiten, die Modus 1 abweist.

## 5. Claude-/ChatGPT-Add-on dekompilieren: ja, aber 2–3 Stunden, nicht ein Jahr

Was es bringt und was nicht:

* **Ihre Backend-Endpunkte sind für uns wertlos** — wir haben ein eigenes
  Backend. Das ist NICHT der Grund, es zu tun.
* **Wertvoll sind genau drei Antworten**, und die stehen zu 80 % schon in der
  `manifest.json`, also in zwei Minuten:
  1. Nutzt Claude `chrome.debugger` (CDP) oder synthetische Events? Das
     entscheidet unseren §4 direkt.
  2. Welche Repräsentation geht ans Modell — Screenshot + Koordinaten, DOM, oder
     Accessibility-Baum?
  3. Wie ist die Domain-Freigabe modelliert (pro Seite, pro Sitzung, global)?
* ChatGPT lohnt kaum: Atlas ist ein eigener Chromium-Fork, kein Add-on; die
  Store-Erweiterung von OpenAI ist im Kern eine Suchmaschinen-Umstellung.

Vorgehen:

```bash
# CRX ziehen (ID aus der Store-URL)
curl -L -o ext.crx "https://clients2.google.com/service/update2/crx\
?response=redirect&prodversion=131&acceptformat=crx2,crx3&x=id%3D<EXT_ID>%26uc"
unzip -o ext.crx -d ext/          # CRX3-Header stört unzip meist nicht
cat ext/manifest.json             # <- hier steht das Meiste
npx webcrack ext/*.js -o unpacked/   # Webpack-Module auseinandernehmen
rg -o 'https?://[a-z0-9.-]+' unpacked/ | sort -u
rg -n 'chrome\.(debugger|scripting|sidePanel|tabs)\.' unpacked/
```

**Nichts davon wird kopiert.** Gelesen wird, um Entscheidungen zu treffen;
Code-Übernahme wäre der einzige Punkt an der Sache, der wirklich Geld kosten
könnte.

## 6. Geschäftsrisiken (nur die, die Geld kosten)

* **Account-Sperren bei Zielseiten.** Der Agent handelt in der echten Sitzung
  des Nutzers. LinkedIn, Amazon, Banken sperren Automatisierung. Gegenmittel ist
  die Domain-Allowlist aus §2, nicht guter Wille.
* **Store-Review.** Chrome Web Store und Mozilla AMO werfen Erweiterungen raus,
  die ferngesteuerten **Code** ausführen. Ferngesteuerte **Kommandos** aus einem
  festen Vokabular sind zulässig. Also: im Store-Build **kein `eval`, kein
  Nachladen von JS, kein `browser_run_code`**. Wer das braucht, nimmt den
  unsignierten Entwickler-Build. Firefox prüft zusätzlich den Quelltext, also
  Build reproduzierbar halten (kein minifiziertes Bundle ohne Quellen).
* **Firefox-Verteilung**: signierte XPI über AMO ist Pflicht (auch für
  Self-Hosting), Review dauert. Chrome: einmalig 5 USD Entwicklergebühr.

## 7. Erste-party-Add-ons: Bestandsaufnahme (geprüft 2026-09-08)

AMO-API (`addons.mozilla.org/api/v5/addons/search`) durchsucht: **kein
Add-on von Anthropic und keins von OpenAI für Firefox.** Was oben steht, ist
alles Drittanbieter (Glasp, "Default Search with Anthropic", Multi AI Sidebar).
Heißt: wer zuerst ein brauchbares Firefox-Add-on hat, hat das Feld für sich.

## 8. Reihenfolge

1. `cowork-extension-mcp`: stdio-MCP-Server mit den `browser_*`-Tools, zuerst
   gegen einen Fake-Bridge in den Tests. Kein Browser nötig.
2. Wire-Frames `browser_cmd` / `browser_result` / `browser_attach` +
   `browser_target` auf `task`.
3. Add-on-Skelett: Manifest v3 (Chrome) + Manifest v3 (Firefox), Kontextmenü,
   Panel, WS-Client, Pairing-Seite.
4. Lokaler WS-Server in der Flutter-Desktop-App + Pairing-Dialog.
5. Snapshot/Click/Type im Content-Script.
6. Seiten-Chat (Anhangsquelle) — davon hat der Nutzer am schnellsten etwas.
7. Optionaler CDP-Modus.

Schritt 6 ist unabhängig von 1–5 und könnte vorgezogen werden, wenn schnell
etwas Sichtbares gebraucht wird.
