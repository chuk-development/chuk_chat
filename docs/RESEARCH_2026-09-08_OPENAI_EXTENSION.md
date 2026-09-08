# Recherche: OpenAIs eigene Browser-Erweiterung, zerlegt

Session cowork-3c, 2026-09-08. Gegenstück zu
`docs/RESEARCH_2026-09-08_BROWSER_CONTROL_APIS.md`, in dem Claude for Chrome
(`fcoeoabgfenejglbffodgkkbkcdhcgfn`, 1.0.91) auseinandergenommen wurde. Alles
statisch aus dem öffentlich ladbaren CRX. **Kein Code übernommen**, das Bundle
liegt unter `_scratch/ext/` und ist gitignored.

## 0. Was es überhaupt gibt

Der Chrome Web Store ist eine JS-SPA, aber die **Suchseite liefert
serverseitig gerendertes JSON aus — inklusive der vollständigen
`manifest.json` jedes Treffers.** Damit ist die ID-Suche ein einziger
`curl` auf `chromewebstore.google.com/search/<begriff>`, kein Browser nötig.
Das ist der bessere Trick als die Doku-Seiten abzugrasen: OpenAIs eigene Doku
(`learn.chatgpt.com/codex/chrome-extension.md`, dorthin leitet
`developers.openai.com/codex/browser` um) verlinkt den Store **nicht**,
sondern schickt einen durch die Desktop-App.

Erste-Party-Lage:

| Was | ID | Status |
|---|---|---|
| **ChatGPT** ("Control your browser with ChatGPT") | `hehggadaopoacecdllhhajmbjkdcmajg` | öffentlich, Stable, **analysiert** |
| **Codex** (Beta-Kanal derselben Erweiterung) | `lfkehkpjohcoelkpembgemeipeppanef` | im Store, aber **unlisted** — CRX-Endpoint antwortet 401, Detailseite ohne Titel |
| Edge-Add-on | `odlomjlbamekndcpllcnffbgeohgkmjh` | Edge-Store, gleiche Codebasis |

**Es gibt keine getrennte Codex-Erweiterung.** ChatGPT- und Codex-Erweiterung
sind dasselbe Artefakt in zwei Release-Kanälen; die IDs stehen in
`content-scripts/chatgpt-website.js` nebeneinander in einer
Distributions-Tabelle (`dev` / `internal` / `prod`). Intern heißt alles
"codex": Side-Panel-Pfad `codex-sidepanel/`, Native-Host
`com.openai.codexextension`, Content-Script `codex.js`.

Für Firefox: **nichts von OpenAI**, wie schon in der Vorrecherche für
Anthropic festgestellt. ChatGPT Atlas ist ein eigenständiger Chromium-Browser
und keine Erweiterung — für die Frage "wie steuert man einen fremden,
eingeloggten Browser" also irrelevant.

Analysiertes Artefakt: Version **1.26.901.11451**, `build_flavor: release`,
`release_channel: stable`, sha `834ab2c3…`. CRX 21,5 MB, entpackt **63 MB in
1636 Dateien**.

## 1. manifest.json

```json
"name": "ChatGPT",
"description": "Control your browser with ChatGPT.",
"minimum_chrome_version": "116",
"host_permissions": ["<all_urls>"],
"permissions": [
  "alarms","bookmarks","debugger","declarativeNetRequestWithHostAccess",
  "downloads","favicon","history","nativeMessaging","notifications",
  "scripting","sessions","storage","tabGroups","tabs","topSites",
  "webNavigation","contextMenus","sidePanel"
],
"optional_permissions": ["downloads.open"],
"side_panel": { "default_path": "codex-sidepanel/index.html" },
"content_scripts": [
  { "matches": ["https://chatgpt.com/*"], "js": ["content-scripts/chatgpt-website.js"],
    "run_at": "document_end", "all_frames": false },
  { "matches": ["https://chatgpt.com/*"], "js": ["content-scripts/codex-work-media-permission.js"],
    "run_at": "document_start", "all_frames": true, "world": "MAIN" }
],
"web_accessible_resources": [{ "matches": ["<all_urls>"], "resources": ["images/cursor-chat.png"] }],
"content_security_policy": {
  "extension_pages": "script-src 'self'; object-src 'none'; connect-src 'self'
     http://127.0.0.1:* http://localhost:* ws://127.0.0.1:* ws://localhost:*
     https://ab.chatgpt.com https://chatgpt.com https://api.openai.com
     https://api.openai.org; font-src 'self' https://cdn.openai.com;",
  "sandbox": "sandbox allow-scripts; default-src 'none'; script-src 'self' 'unsafe-eval';
     worker-src blob:; connect-src 'none';"
}
```

Direkt gegen Claude gehalten:

* **Kein `<all_urls>`-Content-Script.** Claude hängt `accessibility-tree.js`
  auf jede Seite, in jeden Frame, ab `document_start`. OpenAI deklariert
  Content-Scripts **nur für `chatgpt.com`**. Alles, was auf einer fremden
  Seite passiert, wird zur Laufzeit per `chrome.scripting.executeScript` in
  genau den Tab injiziert, der gerade an den Agenten verpachtet ist.
* **Kein `externally_connectable`.** Claude lässt `https://claude.ai/*` direkt
  mit der Erweiterung reden. OpenAI löst dasselbe über ein normales
  Content-Script auf `chatgpt.com`, das per `data-*`-Attributen und
  CustomEvents mit der Seite spricht (`data-chatgpt-extension-status`,
  `chatgpt-extension-request-browser-tabs`, …). Umständlicher, aber es
  braucht keinen Manifest-Eintrag und funktioniert auch für Staging-Domains.
* **Kein `activeTab`, kein `identity`, kein `offscreen`, kein
  `unlimitedStorage`.** Dafür `bookmarks`, `history`, `topSites`, `sessions`,
  `favicon` — Browserdaten, die Claude gar nicht anfasst.
* `connect-src` erlaubt **`http://127.0.0.1:*` und `ws://127.0.0.1:*`** neben
  `chatgpt.com`. Claude hat dort `wss://bridge.claudeusercontent.com`, also
  ein Cloud-Relay; OpenAI hat den **lokalen** Loopback stehen.
* Die `sandbox`-CSP erlaubt `'unsafe-eval'` — es gibt also einen
  Sandbox-Kontext, in dem generierter Code laufen darf. Passt zu Punkt 4.

## 2. Ja, `debugger` — aber als reines Rohr

`"debugger"` steht in den Permissions, und die Erweiterung hängt sich mit
Protokollversion `1.3` an:

```js
await chrome.debugger.attach({ tabId: e }, "1.3")
await chrome.debugger.attach({ targetId: t }, "1.3")   // auch OOPIFs
```

Der entscheidende Unterschied: **im Bundle steht kein CDP-Vokabular.** Die
Suche nach `"Input.*"`, `"Page.*"`, `"DOM.*"`, `"Accessibility.*"`,
`"Runtime.*"` findet **fünf** Treffer im ganzen 63-MB-Baum:
`Target.getTargets`, `Target.closeTarget`, `Page.close`,
`Emulation.setDeviceMetricsOverride`, `Emulation.clearDeviceMetricsOverride`.
Sonst nichts. Kein `Input.dispatchMouseEvent`, kein `Page.captureScreenshot`,
kein `chrome.tabs.captureVisibleTab`.

Weil der Weg so aussieht:

```js
chrome.debugger.sendCommand(target, e.method, e.commandParams)
chrome.debugger.onEvent.addListener((source, method, params) =>
  sendCdpEvent({ source, method, params }))
```

`e.method` kommt von außen. Die Erweiterung ist ein **generischer,
bidirektionaler CDP-Proxy**: Kommandos rein (`tab_cdp_call`), Events raus
(`tab_cdp_events` / JSON-RPC-Notification `onCDPEvent`), Detach-Meldungen
(`onCDPDetach`). Welche CDP-Domain benutzt wird, entscheidet die
**Desktop-App**, nicht die Erweiterung.

Das ist die architektonische Hauptdifferenz. Claude hat das Kommando-Vokabular
in der Erweiterung; OpenAI hat in der Erweiterung nur den Transport plus
Richtlinien, und die Intelligenz sitzt im lokalen Prozess. Praktischer
Vorteil: neue Fähigkeiten brauchen **kein Store-Review**, weil sich nur die
Desktop-App ändert.

Die Rohr-Fähigkeit ist dem Modell sogar als eigene Capability beschrieben:

> `{ id: "cdp", description: "Send raw Chrome DevTools Protocol commands and
> read debugger events through a supported tab for developer use cases." }`

## 3. Wie die Seite ans Modell geht: drei Ebenen statt einer

Claude hat genau eine Form (eigener leichter Baum) plus Screenshot als Beigabe.
OpenAI hat **drei parallele Ebenen**, alle im Schema von `background.js`
nachlesbar.

### Ebene A — `axState` mit Diffing

```js
{ browser_id, tab_id,
  content: "axState" | "screenshot" | "axStateAndScreenshot",
  disable_diffing?: boolean }
→ { state?, data?, screenshot_unavailable? }
```

Screenshot separat mit `fullPage`, `cropX/cropY/cropWidth/cropHeight`.

Zwei Dinge daran sind neu gegenüber Claude:

1. **`disable_diffing`.** Der Normalfall ist also, dass nur die *Änderung*
   gegenüber dem letzten Zustand geschickt wird. Bei einem Agenten, der zehn
   Schritte auf derselben Seite macht, ist das der Unterschied zwischen
   10× vollem Baum und 1× Baum + 9 Deltas.
2. **Ein Schalter für die Kombination.** `axStateAndScreenshot` ist ein
   eigener Modus, nicht zwei Aufrufe.

Die Elementbeschreibung sieht so aus:

```js
{ nodeId, tagName, role, visibleText, ariaName, testId, boundingBox,
  preview, selector }
```

`testId` ist bemerkenswert — `data-testid` wird als eigenes, stabiles Feld
mitgeschickt. `selector` ebenso: jedes Element bringt seinen eigenen
Playwright-Selektor mit. Claudes Baum hat
`role`/`name`/`value`/`placeholder`/`interactive` und sonst nichts.

Dazu gibt es einen **Koordinaten-Treffertest**:
`{ browser_id, tab_id, x, y, include_non_interactable }` → Liste solcher
Elemente. Also: "was liegt an dieser Bildschirmposition".

Den Textbaum baut ein per `executeScript` injizierter Walker im Seitenkontext.
Er läuft über `getComputedStyle` (Block-Grenzen aus `display`), behandelt
`a`, `button`, `input`, `textarea`, `select`, `img`, `br`, `table/tr/td/th`
gesondert, respektiert `contenteditable`, `white-space: pre` — **und steigt in
`shadowRoot` ab** (`chrome.dom.openOrClosedShadowRoot`, also auch *closed*
Shadow DOM). Das ist deutlich mehr Sorgfalt als Claudes 6,8-KB-Skript.

### Ebene B — die Playwright-Locator-API, in der Erweiterung

Das ist der Fund, mit dem ich nicht gerechnet habe. Es gibt ein komplettes,
typisiertes Kommando-Set:

```
playwright_locator_click            playwright_locator_dblclick
playwright_locator_fill             playwright_locator_press
playwright_locator_press_sequentially
playwright_locator_select_option    playwright_locator_set_checked
playwright_locator_wait_for         playwright_locator_count
playwright_locator_is_visible       playwright_locator_is_enabled
playwright_locator_inner_text       playwright_locator_text_content
playwright_locator_all_text_contents
playwright_locator_get_attribute    playwright_locator_read_all
playwright_locator_download_media   playwright_evaluate
```

mit den Playwright-Parametern eins zu eins:

```js
{ browser_id, tab_id, selector,
  modifiers?: ["Alt"|"Control"|"ControlOrMeta"|"Meta"|"Shift"],
  button?: "left"|"right"|"middle", force?: bool, timeout_ms? }
```

Das Modell schreibt also **Playwright-Code gegen den echten, eingeloggten
Browser des Nutzers**. Die Auto-Waiting-Semantik (`wait_for`, `timeout_ms`,
`force`) kommt gratis mit, und das gesamte Playwright-Wissen aus dem Training
greift. Claude hat dafür nichts Vergleichbares — dort ist die einzige
Ansprache "Ref aus dem Snapshot".

### Ebene C — die Low-Level-Aktionen

Daneben existiert eine kompakte Aktions-Union, die eher nach Computer-Use
aussieht:

```js
click        { target: element_index | [x,y], mouse_button?, click_count? }
drag         { from: [x,y], to: [x,y] }
scroll       { target, direction: up|down|left|right, pages? }
press_key    { key }
type_text    { text }
set_value    { element_index, value }
select_text  { element_index, text, prefix?, suffix?,
               selection_type: text|cursor_before|cursor_after }
perform_secondary_action { element_index, action }
```

Wichtig: `target` akzeptiert **entweder einen Element-Index aus dem axState
oder ein rohes Koordinatenpaar**. Dasselbe Feld, zwei Adressierungsarten.
Darunter liegen noch rohere Formen mit `x`,`y`,`keys[]`, `scroll_x/scroll_y`,
Maus-`path: [{x,y},…]` für gezeichnete Drags, und eine dritte Adressierung
über `node_id` (String).

Kurz: OpenAI zwingt das Modell nicht in eine Repräsentation, sondern gibt ihm
Selektoren, Indizes, Node-IDs **und** Pixel und lässt es wählen.

## 4. Was das Modell tatsächlich sieht

Die Erweiterung meldet beim Handshake ihre Fähigkeiten an die App:

```js
{ agentRequestHeaderEnabled, capabilities: { browser: […], tab: […] },
  metadata: { extensionId, extensionInstanceId } }
```

Jede Capability ist ein Objekt mit `id`, einer **prompt-tauglichen englischen
Beschreibung** und einer `documentation()`-Methode, die bei Bedarf
`capabilities/tab/<id>` nachlädt. Die Doku wird also **lazy** geholt, nicht in
jeden Systemprompt gekippt. Die Beschreibungen im Klartext:

* `management` — "Organize windows, tabs, tab groups, and bookmarks. **Use
  only for user-requested browser organization.**"
* `viewport` — "…for responsive or device-size testing. … **Reset temporary
  overrides before finishing** unless the user asked to keep them."
* `visibility` — "Use to show or hide the browser to the user… **Keep browser
  work in the background unless the user asks to see it**…"
* `cdp` — "…for developer use cases."
* `webmcp` — "Fetch page-defined WebMCP tools bound to the current document,
  then call them through the returned object."
* (Auth) — "**MUST read its documentation before the first interaction with
  any authentication or sign-in flow** required for the task."
* (Bot-Erkennung) — "Use when the current tab is blocked by bot detection, a
  failed CAPTCHA, a hard access denial, or a repeated challenge/login loop."
* (Assets) — "List assets already observed in the current page state and
  bundle selected assets into a temporary local artifact."

Und die Rückgabe der WebMCP-Toolliste ist wörtlich:

> "WebMCP tools available in this document: … **Call tools.call(name, input)
> to invoke one.**"

Das ist keine Tool-JSON-Schnittstelle, das ist eine **JS-Objekt-API, gegen die
das Modell Code schreibt** — und dazu passt die Sandbox-CSP mit
`'unsafe-eval'`. Die Fähigkeiten sind Objekte mit Methoden (`set(true)`,
`fetchTools()`, `tools.call(…)`, `send(method, params)`), nicht flache
Funktionsaufrufe.

## 5. WebMCP — vorbereitet, aber (noch) nicht ausgeliefert

`background.js` registriert dynamisch zwei Content-Scripts:

```js
[{ matches:["<all_urls>"], runAt:"document_start", world:"MAIN",
   id:"codex-webmcp",        js:["content-scripts/webmcp.js"] },
 { matches:["<all_urls>"], runAt:"document_start", world:"ISOLATED",
   id:"codex-webmcp-bridge", js:["content-scripts/webmcp-bridge.js"] }]
```

plus die Kommandos `webmcp_list_tools` und `webmcp_invoke_tool` mit
Schema (`tool_name`, `tool_title`, `tool_description`, `readOnlyHint`,
`sourceHostname`, `outputJson`, `input`, `timeout_ms`).

**Die beiden Dateien sind im CRX nicht enthalten.** Kein Treffer in 1636
Dateien. Der Pfad ist hinter einem Statsig-Gate (`codex-app-webmcp`) und wird
offenbar erst mit einem späteren Build ausgeliefert. Trotzdem: OpenAI baut
gerade daran, dass **Webseiten dem Agenten eigene Tools anbieten**
(`navigator.modelContext`-Klasse), und die Erweiterung reicht sie durch —
MAIN-World-Skript zum Abgreifen, ISOLATED-Bridge zum Weiterleiten.

## 6. Transport

`nativeMessaging`, JSON-RPC 2.0 über den Port, mit Reconnect über
`chrome.alarms`:

```js
Yt = { dev:        "com.openai.codexextension.dev",
       internal:   "com.openai.codexextension.internal",
       production: "com.openai.codexextension" }
chrome.runtime.connectNative(this.application)
```

Ein Host-Name pro Kanal, mit `applicationCandidates` als Fallback-Liste —
also dieselbe Idee wie Claudes Zweierliste ("Desktop" / "Claude Code"), nur
nach Release-Kanal statt nach Produkt sortiert.

Protokoll: sauberes JSON-RPC 2.0 mit `id`/`method`/`params`,
`pendingRequests`-Map, `sendNotification` für Einwegmeldungen.
Notifications aus der Erweiterung: `onCDPEvent`, `onCDPDetach`,
`onPageEvent`, `onDownloadChange`, `onBrowserTabMentionsInvalidated`.
Request: `ping`. Lokaler Runtime-Kanal daneben: `codexRuntime/hello`,
`codexRuntime/ensure`, `codexRuntime/restart`, `codexRuntime/openLocalFile`
und ein Chunk-Upload für Tab-Kontext
(`codexRuntime/tabContextAsset/create|appendChunk|finish|abort|remove`) —
große Seiteninhalte gehen also **gestückelt** über den Port, nicht in einer
Nachricht.

Der Cloud-Weg existiert, aber an anderer Stelle: im Side-Panel-Bundle stehen

```js
"wss://codex-cloud-backend.chatgpt.com/"   // Codex Cloud
"ws://localhost:8098/"                     // lokal
"__codex_browser_initialize__"
```

Das ist die Codex-Cloud-Verbindung des Panels, **nicht** ein Relay für die
Browsersteuerung. Ein Äquivalent zu `wss://bridge.claudeusercontent.com` —
Agent auf fremder Maschine steuert diesen Browser — habe ich **nicht**
gefunden. Die Browsersteuerung ist bei OpenAI strikt lokal.

Kein `externally_connectable`. Die Brücke zu `chatgpt.com` läuft über das
Content-Script mit DOM-Attributen und Events:
`GET_CHATGPT_EXTENSION_STATUS`, `GET_CHATGPT_BROWSER_TAB_CONTEXT`,
`SHOW_CODEX_INSTALLER`, `OPEN_CODEX_SIDE_PANEL`.

## 7. Panel, Anzeigen, Besitzverhältnisse

**Zwei Side Panels.**
`codex-sidepanel/index.html` ist die gebündelte Codex-App — **62 MB**, React,
ein `vscode-singleton.browser`-Chunk, `pdf.worker`, Syntax-Highlighting für
Dutzende Sprachen, Sprach-`.wav`-Samples, IDE-Icons (Cursor, Devin,
Android Studio, Antigravity, Emacs, BBEdit…). Das ist der komplette
Desktop-Client im Panel. Daneben `codex-work-sidepanel.html`: ein
minimales Gerüst, das schlicht
`https://chatgpt.com/?surface=browser_side_chat` in einem iframe lädt.
Claudes `sidepanel.html` ist dagegen eine schlanke Seite.

**Kontextmenü.** Ein Eintrag "Ask ChatGPT" auf
`page, frame, selection, link, editable, image, video, audio`.

**Tab-Gruppen.** `chrome.tabGroups.get/update/onRemoved` — wie bei Claude
bekommt der Agent eine eigene Gruppe.

**"Der Agent fährt gerade" — drei Signale statt einem:**

1. **Cursor-Overlay.** `content-scripts/codex.js`, 35 KB, ist fast
   ausschließlich Cursor-Animation: Bézier-Pfade mit Kandidatenauswahl,
   Bogenkrümmung, Feder-Dämpfung (`dampingFraction: .9`), fester
   Klickwinkel −44°, `boundsMargin`. Dazu `images/cursor-chat.png` als
   `web_accessible_resource` auf `<all_urls>`. Es wird also ein
   **sichtbarer, physikalisch plausibel bewegter Mauszeiger** auf die Seite
   gezeichnet, samt Rückmeldung `AGENT_CURSOR_ARRIVED` /
   `GET_AGENT_CURSOR_STATE`, damit der nächste Klick erst nach der Animation
   feuert. Claude hat dafür einen statischen Rahmen.
2. **Favicon-Badge.** `TAB_FAVICON_BADGE` überschreibt das Favicon des Tabs
   mit einem Zustandsabzeichen: `active`, `deliverable`, `handoff`. Der
   Nutzer sieht am **Tab-Streifen**, was der Agent gerade tut, ohne den Tab
   zu öffnen. Cache über `chrome.storage`, 64-KB-Limit pro Data-URL.
3. **Notifications.** `chrome.notifications.create` für Fertigmeldungen.

**Tab-Leases.** Es gibt eine echte Besitzverwaltung: pro Tab ein Lease mit
`sessionId`, `turnId`, `origin: "agent" | "user"`, `claimedAt`,
`instanceId`, `state: "active" | "handoff"`, `isActiveHandoff`,
`mark: "active" | "deliverable" | "handoff"`, `viewportSize`, persistiert in
`chrome.storage` unter `TAB_LEASES`. Ein Tab gehört zu einem Zeitpunkt
entweder dem Agenten oder dem Nutzer, und "handoff" ist ein *modellierter*
Zustand — nicht "der Agent hört auf", sondern "der Nutzer übernimmt jetzt
diesen Tab, z. B. um sich anzumelden". Claude hat nichts dergleichen.

## 8. Fünf Dinge, die Claude gar nicht macht

**a) Selbstauskunft per HTTP-Header.**
`declarativeNetRequestWithHostAccess` wird **nicht** zum Sperren von Domains
benutzt (Claude macht damit die Freigabe im Netz-Layer plus `blocked.html`),
sondern zum Setzen eines Headers auf allen Anfragen aus verpachteten Tabs:

```js
action: { type: MODIFY_HEADERS, requestHeaders: [
  { header: "x-browser-agent", value: `ChatGPT/${version}`, operation: SET } ] }
```

Session-Rules, ID-Bereich 1 000 000–1 004 999, mit
`excludedInitiatorDomains: [chrome.runtime.id]`. Die Erweiterung sagt der
besuchten Website also **freiwillig, dass hier ein Agent tippt** — abschaltbar
über `agentRequestHeaderEnabled`. Kein Verstecken, sondern eine
Bot-Deklaration. Geschäftlich ist das die interessantere Wette: Seiten können
Agenten gezielt *durchlassen* statt sie als Betrug zu behandeln.
Die Domain-Erlaubnis selbst sitzt bei OpenAI **in der Desktop-App**
(Settings → Computer Use → Allow-/Blocklist), nicht in der Erweiterung.

**b) Anmeldedaten ohne Modellkontakt.**
Es gibt ein Schema für eine Anmelde-Anforderung:

```js
{ origin, fields: [{ id, label, type, required, selector, autocomplete? }] (max 6),
  options?: [{ id, label, field_ids?, selector? }] (2–10),
  qr_code?: true,
  submit?: { selector, action: "click" | "press_enter" } }
```

Der Agent beschreibt also **das Formular** (Feld-Labels, Selektoren,
`autocomplete`-Hinweise, Wahl zwischen mehreren Anmeldewegen, QR-Code für
2FA) und die Erweiterung/App fragt den Nutzer und füllt selbst aus. Das
Passwort läuft nie durch den Modellkontext. Dazu die harte Prompt-Regel
"MUST read its documentation before the first interaction with any
authentication flow".

**c) Meldeweg für Bot-Blockaden.**
`tab_bot_detection_report` und `tab_browser_auth_handoff`: wenn CAPTCHA,
Zugriffsverweigerung oder eine Login-Schleife greift, **meldet** der Agent
das strukturiert und übergibt den Tab an den Nutzer (`handoff`), statt es
weiter zu versuchen. Genau das, was einem sonst Accounts kostet.

**d) Fremd-Erweiterungs-Wächter.**
`content-scripts/foreign-frame-monitor.js` sucht in der Seite (inklusive
*closed* Shadow Roots) nach `chrome-extension://`-iframes **anderer**
Erweiterungen und meldet sie. Also: erkennen, wenn eine dritte Erweiterung
UI über die Seite legt — Schutz sowohl gegen Fehlklicks als auch gegen
Prompt-Injection durch fremde Overlays.

**e) Sichtbarkeit und Viewport als Modell-Fähigkeit.**
`browser_visibility_get/set` (Browser zeigen/verstecken, Standard:
Hintergrund) und `browser_viewport_set/reset` mit Aufräum-Pflicht. Dazu
`browser_offline`, `browser_management_call` mit
`browser_management_get_audit_trail` — jede Fenster-/Tab-/Lesezeichen-Änderung
landet in einem **Audit-Trail**. Und `tab_page_assets_list` /
`tab_page_assets_bundle`: gesehene Bilder/Dateien einer Seite auflisten und
zu einem lokalen Artefakt bündeln. Plus `seek_youtube_timestamp` als
Spezialfall (Transkript-Sprung).

## 9. Gegenüberstellung in einer Tabelle

| | Claude for Chrome 1.0.91 | ChatGPT 1.26.901 |
|---|---|---|
| CDP | ja, festes Vokabular im Bundle | ja, **generischer Proxy**, Vokabular in der App |
| Content-Script `<all_urls>` | ja, permanent, `document_start`, alle Frames | **nein**, nur `chatgpt.com`; sonst `executeScript` in verpachtete Tabs |
| Seitenmodell | eigener Baum, `role/name/value/placeholder/interactive` | `axState` **mit Diffing**, Felder inkl. `testId`, `selector`, `boundingBox` |
| Adressierung | Ref aus dem Snapshot | Element-Index **oder** `[x,y]` **oder** `node_id` **oder** CSS/Playwright-Selektor |
| Hochsprache | — | **komplette Playwright-Locator-API** + `evaluate` |
| Shadow DOM | nicht erkennbar | ja, inkl. *closed* über `chrome.dom.openOrClosedShadowRoot` |
| Transport lokal | `connectNative`, 2 Hosts | `connectNative`, 3 Kanäle, JSON-RPC 2.0, Chunk-Upload |
| Transport remote | `wss://bridge.claudeusercontent.com` | **keiner** für Steuerung |
| Web-App-Brücke | `externally_connectable: claude.ai` | Content-Script + `data-*`/CustomEvents |
| Domain-Freigabe | dNR-Blockade + `blocked.html` in der Erweiterung | in der Desktop-App; dNR stattdessen für `x-browser-agent` |
| Agent-Anzeige | statischer Indikator | animierter Cursor + **Favicon-Badge** + Notifications |
| Tab-Besitz | Tab-Gruppe | Tab-Gruppe + **Lease mit `agent`/`user`/`handoff`** |
| Anmeldung | — | Formular-Schema, Nutzer füllt, QR/2FA |
| Bot-Blockade | — | `tab_bot_detection_report` + Handoff |
| Seiten-eigene Tools | — | **WebMCP** (vorbereitet, Dateien fehlen noch) |
| Größe | 20 MB `assets/` | 63 MB, davon 62 MB Side-Panel-App |

## 10. Was wir uebernehmen

Konkret, gegen `docs/PLAN_2026-09-08_BROWSER_EXTENSION.md` und den
Nachtrag aus der Vorrecherche:

1. **Die Erweiterung wird ein dummes CDP-Rohr.** Ein `cdp.call`-Kommando mit
   freiem `method`/`params` plus ein Event-Kanal zurück — genau OpenAIs
   `sendCommand(target, e.method, e.commandParams)`-Muster. Alles Fachliche
   in den Host. Damit braucht jede neue Fähigkeit **kein Store-Review**. Das
   ist der teuerste Fehler, den man sonst macht: Vokabular einbetonieren und
   dann drei Tage auf Google warten.
2. **Playwright-Locators als primäre Hochsprache**, nicht Snapshot-Refs.
   `click/fill/press/select_option/set_checked/wait_for/count/is_visible/
   text_content/get_attribute` mit `selector`, `timeout_ms`, `force`,
   `modifiers`. Das Modell kann Playwright bereits; wir sparen uns eine
   erfundene Abstraktion und deren Prompt-Erklärung.
3. **Kein permanentes `<all_urls>`-Content-Script.** Injektion per
   `chrome.scripting.executeScript` nur in Tabs mit aktivem Lease. Weniger
   Angriffsfläche, ehrlichere Store-Begründung, und der Nutzer sieht nicht
   auf jeder Seite ein fremdes Skript.
4. **Snapshot mit Diffing als Standard**, Vollzustand nur auf Anforderung
   (`disable_diffing`). Bei zehn Schritten auf derselben Seite spart das den
   Löwenanteil der Tokens — direkt Geld pro Turn.
5. **Element-Felder: `selector` und `testId` mitschicken.** Jedes Element
   bringt seinen eigenen Selektor mit, damit Punkt 2 ohne Rätselraten
   funktioniert. `boundingBox` dazu, dann ist der Koordinatenweg gratis.
6. **`target` polymorph**: Index, `[x,y]`, `node_id` oder Selektor im selben
   Feld. Das Modell wählt, wir zwingen nicht.
7. **Favicon-Badge statt nur Seiten-Overlay.** Zustände `active` /
   `deliverable` / `handoff`. Der Nutzer sieht im Tab-Streifen, welcher Tab
   fertig ist — die billigste sichtbare Verbesserung im ganzen Bericht.
8. **Tab-Leases mit `origin: agent|user` und explizitem `handoff`.**
   Persistiert in `chrome.storage`. Ohne das wird jeder Login-Fall zum
   Sonderfall.
9. **Anmeldedaten nie ins Modell.** Formular-Schema
   (`fields[{id,label,type,required,selector,autocomplete}]`, `submit`,
   `qr_code`), Host fragt den Nutzer, Host füllt per Selektor.
10. **Bot-Blockade als eigener Rückgabeweg.** CAPTCHA/Denial/Login-Schleife
    ⇒ melden und an den Nutzer übergeben, nicht weiterprobieren.
11. **`x-browser-agent`-Header per dNR, abschaltbar.** Kostet nichts und
    stellt uns auf die Seite der Seitenbetreiber statt auf die der Scraper.
    Der Header sitzt in Session-Rules, nicht im Manifest — also pro Lease
    an- und abschaltbar.
12. **Capabilities mit `documentation()` nachladen** statt alles in den
    Systemprompt. Kurze Beschreibung im Handshake, Details erst bei der
    ersten Nutzung.
13. **Shadow DOM inklusive `closed`** über `chrome.dom.openOrClosedShadowRoot`
    — ohne das ist die halbe moderne Web-UI unsichtbar.
14. **Chunk-Transfer über Native Messaging** für große Seiteninhalte. Der
    Port hat harte Nachrichtengrenzen; OpenAIs
    `tabContextAsset/create|appendChunk|finish` ist das fertige Muster.
15. **WebMCP im Hinterkopf behalten.** Noch nichts bauen, aber das
    Kommando-Paar (`list_tools` / `invoke_tool`) im Vokabular freihalten.
    Wenn Seiten anfangen, Agenten Tools anzubieten, will man nicht
    umbauen müssen.

Was wir **nicht** übernehmen: das 62-MB-Side-Panel. OpenAI schiebt seinen
kompletten Desktop-Client in die Erweiterung, weil sie ihn ohnehin haben.
Wir haben die Flutter-App; das Panel bleibt dünn.

Und: OpenAI hat **keinen** Remote-Weg für die Browsersteuerung. Unser
Relay-Zweig (Host auf dps) bleibt trotzdem, weil er bei uns der Normalfall
ist — Anthropic macht es genauso.

## Quellen

* `chromewebstore.google.com/search/{ChatGPT,Codex,OpenAI}` — SSR-JSON mit
  vollständigen Manifests, per curl gelesen, 08.09.2026.
* `learn.chatgpt.com/codex/chrome-extension.md` (Weiterleitungsziel von
  `developers.openai.com/codex/browser`).
* ChatGPT-Erweiterung `hehggadaopoacecdllhhajmbjkdcmajg`, Version
  1.26.901.11451, CRX über `clients2.google.com/service/update2/crx`
  entpackt und gelesen. **Kein Code übernommen.**
* Codex-Erweiterung `lfkehkpjohcoelkpembgemeipeppanef` — im Store gelistet,
  CRX-Abruf 401 (unlisted/Beta).
* `docs/RESEARCH_2026-09-08_BROWSER_CONTROL_APIS.md` (Claude-Vergleichsbasis).
