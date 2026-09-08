# Runbook: den Coworker im eigenen Browser fahren lassen

Stand 2026-09-08, Session cowork-3c. Alles committet auf `cowork`.

## Was schon geht und was nicht

Getestet ohne Browser, grün:

* MCP-Server ↔ gefälschtes Add-on über den Unix-Socket (6 Tests)
* MCP-Server ↔ echte Bridge ↔ Chrome-Native-Messaging-Framing (4 Tests)
* Add-on-Vokabular, Adressierung, Leases (10 Tests)
* Ziel-Auswahl im Executor (5 Tests)

Nicht getestet: das Browser-Ende. Dafür ist dieser Runbook da.

## 0. Browser

Auf dieser Maschine liegen Chrome 151, Brave 151 und Firefox 154. Alle drei
können Manifest v3, es muss nichts installiert werden. **Nimm Chrome oder
Brave** — siehe Abschnitt "Firefox" unten.

## 1. Add-on bauen und laden

```bash
cd ~/git/cowork/extension
./build.sh chrome
```

Dann in Chrome: `chrome://extensions` → Entwicklermodus an → *Entpackte
Erweiterung laden* → `~/git/cowork/extension/dist/chrome`.

Chrome zeigt danach eine ID (32 Kleinbuchstaben). Die brauchst du im nächsten
Schritt.

## 2. Bridge registrieren

```bash
~/git/cowork/tools/cowork-browser-bridge/install_host_manifest.py --chrome-id <die ID>
```

Das schreibt `dev.chuk.cowork.json` nach
`~/.config/google-chrome/NativeMessagingHosts/` (und für Chromium und Brave
gleich mit). In der Datei steht `allowed_origins` mit genau dieser einen
Erweiterung — das ist die komplette Zugriffsregel, es gibt keinen Port und
kein Token.

Danach die Erweiterung einmal neu laden, damit sie den Host findet.

## 3. Host auf das Nutzer-Ziel stellen

Der laufende Host muss neu, weil die Ziel-Wahl beim Start gelesen wird:

```bash
pkill -f cowork-host          # oder den laufenden sauber beenden
cd ~/git/cowork/host
COWORK_BROWSER_TARGET=user_browser \
  ./.venv/bin/cowork-host run --sandbox docker \
  --model z-ai/glm-5.3-flash --provider fireworks/serverless --reasoning-effort none
```

`--sandbox local` geht auch und ist für einen ersten Versuch leichter: dann ist
gar kein Container im Spiel.

Ohne die Variable bleibt alles wie bisher — Sandbox-Browser mit VNC.

## 4. App starten

```bash
cd ~/git/cowork/app
GDK_BACKEND=x11 FLUTTER_HOT_EXTRA='' flutter-hot start linux
```

## 5. Den Coworker losschicken

Im Chat, sinngemäß:

> Ich hab die Seite hier schon offen. Schau dir meine Tabs an und übernimm den
> mit \<X\>, dann \<Aufgabe\>.

Er sollte dann `browser_tabs` mit `action: "list"` aufrufen, deinen Tab in der
Liste sehen, `action: "select"` mit der `tabId` schicken und ab da mit
`browser_snapshot` / `browser_click` / `browser_type` arbeiten. Am oberen Rand
der Seite läuft ein farbiger Streifen, solange er fährt.

Soll er selbst etwas aufmachen, reicht `browser_navigate` — dann legt er sich
einen eigenen Tab in einer lila Tab-Gruppe "CoWork" an und fasst deine nicht an.

## Wenn nichts passiert

* **Der Socket existiert nur, solange ein Task läuft.** `cowork-extension-mcp`
  wird pro Sitzung gestartet und legt dabei
  `~/.cowork/browser-bridge.sock` an. Die Erweiterung versucht im Minutentakt
  neu zu verbinden, es kann also bis zu einer Minute dauern, bis sie nach dem
  ersten Task hängt. Nachsehen: Optionsseite der Erweiterung, oder das Panel —
  dort steht `CoWork · native · cdp input`, wenn es steht.
* **`ls -l ~/.cowork/browser-bridge.sock`** — ist die Datei da, läuft der
  MCP-Server. Ist sie weg, läuft gerade kein Task.
* **Service-Worker-Log**: `chrome://extensions` → bei CoWork auf
  *Service Worker* klicken, das öffnet die DevTools des Hintergrundskripts.
* **Bridge-Log**: die Bridge schreibt nichts; wenn der Socket fehlt, schickt sie
  einmal `browser_attach_error` und beendet sich.

## Firefox

Geht, aber schwächer, und das liegt nicht an uns:

* **`chrome.debugger` gibt es in Firefox nicht** (MDN, "Chrome
  incompatibilities", *Unsupported APIs*). Damit fallen echte Eingaben weg. Das
  Add-on schaltet automatisch auf synthetische DOM-Events um; das Panel schreibt
  `synthetic input` statt `cdp input`.
* Was funktioniert: Panel (als `sidebar_action`), Kontextmenü, Seiten-Chat,
  Tabs auflisten und übernehmen, Snapshot, Navigieren, Scrollen, Screenshot
  (über `tabs.captureVisibleTab`), Klicken und Tippen auf den meisten Seiten.
* Was nicht: Seiten, die auf `isTrusted` prüfen, echte Datei-Uploads, Tastatur
  in manchen Editoren, Tab-Gruppen (die API fehlt auch).
* Laden: `./build.sh firefox`, dann `about:debugging#/runtime/this-firefox` →
  *Temporäres Add-on laden* → `dist/firefox/manifest.json`. Temporär heißt: beim
  Neustart weg. Dauerhaft braucht eine über AMO signierte XPI.
* Für volle Kontrolle in Firefox gäbe es einen zweiten Weg: Firefox mit
  `--marionette` starten und WebDriver BiDi sprechen. Firefox hat die
  Chrome-136-Sperre nicht, das läuft also auch auf dem echten Profil. Ist aber
  eine andere Baustelle als dieses Add-on.

**Kurz: für den ersten Versuch Chrome oder Brave.**
