# Recherche: womit steuert eine KI einen laufenden, eingeloggten Browser?

Session cowork-3c, 2026-09-08. Quellen unten, alles am selben Tag geprüft.

## 0. Die Ausgangsfrage, richtig gestellt

"Kann man einen laufenden Browser in einen Playwright-Browser umwandeln?" —
**Nein, und seit Chrome 136 nicht mal mehr über den alten Umweg.**

Playwright/Puppeteer/CDP hängen sich über `--remote-debugging-port` an. Google
hat das im März 2025 dichtgemacht:

> "Therefore, from Chrome 136 we're making changes to the behavior of
> `--remote-debugging-port` and `--remote-debugging-pipe`. These switches will
> no longer be respected if attempting to debug the default Chrome data
> directory. These switches must now be accompanied by the `--user-data-dir`
> switch to point to a non-standard directory."
> — developer.chrome.com/blog/remote-debugging-port

Grund war Cookie-Diebstahl: Angreifer umgingen App-Bound Encryption, indem sie
CDP am echten Profil ansetzten. Ergebnis für uns: an das Profil, in dem der
Nutzer eingeloggt ist, kommt **kein externer Prozess** mehr über CDP heran.
Firefox ist nicht besser: Marionette und WebDriver BiDi müssen beim Start
scharfgeschaltet sein, ein bereits laufender normaler Firefox lässt sich nicht
nachträglich anhängen.

Deshalb ist die Erweiterung nicht "eine von mehreren Optionen", sondern der
**einzige** Weg. Und genau deshalb ist "Claude for Chrome" eine Erweiterung.

## 1. Was Claude for Chrome wirklich tut (dekompiliert, nicht geraten)

Extension-ID `fcoeoabgfenejglbffodgkkbkcdhcgfn`, Version 1.0.91, gezogen über
`clients2.google.com/service/update2/crx`, entpackt. 20 MB `assets/`.

### manifest.json, die relevanten Zeilen

```json
"permissions": ["sidePanel","storage","activeTab","scripting","debugger",
                "tabGroups","tabs","alarms","notifications","webNavigation",
                "declarativeNetRequestWithHostAccess","offscreen",
                "nativeMessaging","unlimitedStorage","downloads","identity"],
"host_permissions": ["<all_urls>"],
"content_scripts": [
  {"js":["assets/accessibility-tree.js-…"],   "matches":["<all_urls>"],
   "run_at":"document_start","all_frames":true},
  {"js":["assets/agent-visual-indicator.js-…"],"matches":["<all_urls>"],
   "run_at":"document_idle","all_frames":false}
],
"content_security_policy": { "extension_pages":
  "… connect-src 'self' https://api.anthropic.com wss://api.anthropic.com
   … wss://bridge.claudeusercontent.com …" }
```

### Die drei Fragen, die ich stellen wollte, beantwortet

**1. CDP oder synthetische Events?** → **CDP.** `"debugger"` steht in den
Permissions, und im Bundle stehen die Kommandos:

```
Input.dispatchMouseEvent   Input.dispatchKeyEvent   Input.insertText
Page.captureScreenshot     Page.handleJavaScriptDialog
Runtime.evaluate           Network.requestWillBeSent  …
```

`Input.dispatch*` erzeugt **echte, trusted Eingaben** — auf Ebene des Browsers,
nicht des DOM. Keine `isTrusted:false`-Probleme, keine Seite kann es von einer
echten Maus unterscheiden. Genau die Klasse, die `chrome.debugger` freischaltet
und die ein reines Content-Script nie erreicht.

**2. Was geht ans Modell?** → Ein **eigener, sehr leichter Baum** aus dem
Content-Script (`accessibility-tree.js`, 6,8 KB unminifiziert-gemessen, Felder
`role`, `name`, `value`, `placeholder`, `interactive`), nicht die CDP-Domain
`Accessibility` und nicht Screenshot-plus-Koordinaten. Screenshots gibt es
zusätzlich über `Page.captureScreenshot`, aber der Baum ist die Primärform.
Das ist die billige Variante und deckt sich mit dem, was Playwright-MCP als
Snapshot liefert.

**3. Wie ist die Freigabe modelliert?** → `declarativeNetRequestWithHostAccess`
plus eine `blocked.html`. Die Sperre sitzt also im **Netzwerk-Layer** des
Browsers, nicht in der Prompt. Dazu `managed_schema.json` für
Unternehmens-Policy.

### Der wichtigste Nebenfund: der Transport

`"nativeMessaging"` in den Permissions, und im Service-Worker:

```js
const t = [{name:"com.anthropic.claude_browser_extension", label:"Desktop"},
           {name:"com.anthropic.claude_code_browser_extension", label:"Claude Code"}];
for (const r of t) chrome.runtime.connectNative(r.name) …
```

Die Erweiterung **sucht sich einen lokalen Prozess** über Chrome Native
Messaging — einmal Claude Desktop, einmal **Claude Code**. Das ist exakt unser
Fall: ein lokaler Agent-Prozess redet über stdio mit der Erweiterung. Kein
WebSocket, kein Port, kein Token.

Die Authentisierung steckt in der Host-Manifest-Datei, die der lokale Prozess
installiert:

```json
// ~/.config/google-chrome/NativeMessagingHosts/dev.chuk.cowork.json
{ "name": "dev.chuk.cowork", "type": "stdio",
  "path": "/usr/local/bin/agents-browser-bridge",
  "allowed_origins": ["chrome-extension://<unsere-id>/"] }
```

`allowed_origins` ist die ganze Sicherheit: nur diese eine Erweiterung darf den
Prozess starten, und nur der lokale Nutzer kann die Datei schreiben. Damit
entfällt der ganze Aufbau mit Loopback-Port, Origin-Prüfung und Pairing-Token,
den ich vorher geplant hatte.

Für den Fall, dass der Agent **nicht** auf demselben Rechner läuft, hat
Anthropic den zweiten Weg in der CSP stehen:
`wss://bridge.claudeusercontent.com` — ein Relay-WebSocket. Beide Wege
nebeneinander, genau wie wir es brauchen (Host auf dps ⇒ Relay; Host lokal ⇒
Native Messaging).

Weitere Details, die Arbeit sparen:

* `tabGroups` — der Agent bekommt eine eigene Tab-Gruppe.
* `agent-visual-indicator.js` auf `<all_urls>` — sichtbarer Hinweis im Tab,
  solange der Agent fährt.
* `pairing.html`, `options.html`, `offscreen.html`, `sidepanel.html` — die
  Seitenstruktur, die wir 1:1 brauchen.
* `externally_connectable: https://claude.ai/*` — die Web-App redet direkt mit
  der Erweiterung.
* `minimum_chrome_version: 116`.

## 2. Chrome: die API-Landschaft

| Was | API | Reicht wofür |
|---|---|---|
| Tabs öffnen, navigieren, schließen | `chrome.tabs` | Grundgerüst, meist ohne Permission |
| Eigene Tab-Gruppe für den Agenten | `chrome.tabGroups` | Nutzer-Tabs unberührt lassen |
| JS in eine Seite einspeisen | `chrome.scripting` + `host_permissions` | Seite lesen, Baum bauen |
| Panel rechts | `chrome.sidePanel` (MV3, ab Chrome 114) | die Zeitleiste |
| Rechtsklick-Eintrag | `chrome.contextMenus` | der Einstieg |
| **Echte Eingaben, Screenshots, Netzwerk** | **`chrome.debugger`** (Permission `debugger`) | das eigentliche Steuern |
| Verbindung zu lokalem Prozess | `chrome.runtime.connectNative` | Transport |
| Domain-Sperre im Netz-Layer | `declarativeNetRequestWithHostAccess` | Freigabe erzwingen |

`chrome.debugger` gibt CDP auf den Tab, **auf dem echten Profil des Nutzers** —
das ist der Punkt, an dem der externe Weg (§0) scheitert und der Erweiterungsweg
funktioniert. Freigegebene CDP-Domains laut Doku: Accessibility, Audits,
CacheStorage, Console, CSS, Database, Debugger, DOM, DOMDebugger, DOMSnapshot,
Emulation, Fetch, IO, **Input**, Inspector, Log, Network, Overlay, **Page**,
Performance, Profiler, Runtime, Storage, Target, Tracing, WebAudio, WebAuthn.

Kosten: Chrome zeigt eine Leiste "… debuggt diesen Browser", solange
`debugger.attach` hält. Claude lebt damit, es gibt keinen Trick im Bundle. Auf
verwalteten Geräten kann `ExtensionSettings`/`runtime_blocked_hosts` oder
`DisableScreenshots` das `attach()` komplett blocken — irrelevant für uns.

## 3. Firefox: die schlechte Nachricht

MDN, "Chrome incompatibilities", Abschnitt *Unsupported APIs*:

> **Debugger API** — In Firefox: Chrome's `debugger` API is not implemented.

Damit gibt es in Firefox **keine** trusted Eingaben aus einer Erweiterung. Was
bleibt:

* `browser.tabs`, `browser.scripting`, `browser.contextMenus`,
  `sidebar_action` (statt `sidePanel`), `runtime.connectNative` — alles da.
* Steuerung nur über **synthetische DOM-Events** aus dem Content-Script.
  `isTrusted:false`, echte Datei-Uploads gehen nicht, manche Seiten wehren ab.
* Alternative für Poweruser: Firefox mit `--marionette` bzw. dem Remote Agent
  starten, dann volles WebDriver BiDi auf das echte Profil. Firefox hat hier
  keine Chrome-136-Sperre. Kostet aber einen Neustart mit Flag.

Erste-Party-Lage geprüft über die AMO-API: **kein Add-on von Anthropic, keins
von OpenAI für Firefox.** Nur Drittanbieter.

Konsequenz: Chrome zuerst, mit `debugger`. Firefox als zweite Stufe mit
reduziertem Funktionsumfang, ehrlich benannt.

## 4. Was das für Agents ändert

Gegenüber `docs/PLAN_2026-09-08_BROWSER_EXTENSION.md`:

1. **Transport wird Native Messaging**, wenn Agent und Browser auf einer
   Maschine liegen. Der Loopback-WebSocket in der Flutter-App entfällt dort
   ersatzlos, samt Pairing-Token und Origin-Prüfung — `allowed_origins` in der
   Host-Manifest-Datei erledigt das.
2. **Der Relay-Weg bleibt** für den Fall Host-auf-dps. Zwei Transporte, ein
   Kommando-Vokabular. Anthropic macht es genauso.
3. **Steuerung über `chrome.debugger`/CDP, nicht über synthetische Events.**
   Das war im alten Plan die optionale Stufe 2; es ist in Wahrheit Stufe 1.
4. **Snapshot-Format**: eigener leichter Baum aus dem Content-Script mit
   `role`/`name`/`value`/`placeholder`/`interactive` + stabile Refs. Screenshot
   nur zusätzlich.
5. Store-Auflage bleibt ein Build-Constraint: kein nachgeladenes JS, festes
   Kommando-Vokabular. Claudes Bundle hält sich daran (CSP `script-src 'self'`).

## Quellen

* developer.chrome.com/blog/remote-debugging-port (17.03.2025)
* developer.chrome.com/docs/extensions/reference/api/debugger
* developer.chrome.com/docs/extensions/reference/api/{tabs,scripting}
* developer.mozilla.org/…/WebExtensions/Chrome_incompatibilities
* firefox-source-docs.mozilla.org/remote/index.html
* addons.mozilla.org/api/v5/addons/search
* support.claude.com/en/articles/12012173-getting-started-with-claude-for-chrome
* Claude for Chrome 1.0.91, CRX entpackt und gelesen. Kein Code übernommen.
