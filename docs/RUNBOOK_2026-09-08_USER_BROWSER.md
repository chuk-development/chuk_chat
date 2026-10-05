# Runbook: den Coworker im eigenen Browser fahren lassen

Stand 2026-10-05 (bead chuk_chat-rixw). Ersetzt den Stand vom 2026-09-08, der
noch auf das alte `~/git/cowork`-Repo zeigte. Alles liegt jetzt in diesem Repo:
`extension/`, `tools/agents-browser-bridge/`, `tools/agents-extension-mcp/`,
`agents/executor/src/chuk_agents_executor/user_browser.py`.
Wire-Spezifikation: `docs/WIRE_CONTRACT.md`, Abschnitt "The user's own browser".

## Wie es zusammenhaengt

```
Agent ── agents-extension-mcp ── Broker im Host ── agents-browser-bridge ── Add-on in Chrome
         (pro Coworker)          (ein Prozess,     (startet Chrome selbst,
                                  lebt mit Host)    native messaging)
```

* Kein offener Port. Beide Sockets liegen in `$XDG_RUNTIME_DIR/chuk-agents/`
  (`/run/user/1000/chuk-agents/`), Modus 0600.
* Ein Coworker haelt den Browser, ein zweiter bekommt "in use", bis der erste
  loslaesst oder 5 Minuten nichts tut.
* Jede Aktion im eigenen Browser fragt (Klick, Tippen, Taste, Seite oeffnen,
  Tab uebernehmen), ausser die Seite steht auf der Freigabeliste des Coworkers
  ("Immer fuer diese Seite") oder der Nutzer hat `browser_act` fuer ihn auf
  `allow` gestellt.
* Stop im Browser (Leiste oben auf der Seite, Panel, oder "Abbrechen" in
  Chromes gelber Debug-Leiste) haelt den Lauf des Coworkers an und sperrt den
  Browser, bis der Nutzer im Panel "Allow again" drueckt oder eine neue
  Aufgabe schickt.

## Was getestet ist (ohne Browser)

```bash
node extension/test/protocol_test.mjs                 # 10: Vokabular, Leases
node extension/test/stop_and_secrets_test.mjs         # 38: Stop, Passwort-/Kartenfelder, Manifest-Rechte
node extension/test/strip_test.mjs                    # 11: Name in der Leiste, Panel, Timeout, Stop leert die Schlange
python3 tools/agents-extension-mcp/test_agents_extension_mcp.py   # 6
python3 tools/agents-browser-bridge/test_bridge_roundtrip.py      # 4
cd agents/executor && .venv/bin/python -m pytest -q tests/test_user_browser.py           # 35
cd agents/host     && .venv/bin/python -m pytest -q tests/test_user_browser_host.py      # 7
cd agents/runtime  && .venv/bin/python -m pytest -q tests/test_user_browser_approvals.py # 9
```

`test_user_browser.py` faehrt die ganze Kette als echte Prozesse: Chromes
Native-Messaging-Rahmen, Bridge, Broker, MCP-Server, inklusive Stop.

Nicht getestet: das Browser-Ende selbst. Dafuer sind die Schritte unten.

## 1. Add-on bauen und laden

```bash
cd ~/git/chuk_chat/extension
./build.sh chrome
```

Chrome (oder Brave): `chrome://extensions` -> Entwicklermodus an ->
*Entpackte Erweiterung laden* -> `~/git/chuk_chat/extension/dist/chrome`.

Die ID muss `gchdfokldhdgbjmdcjmkeapcknekogmm` sein (fest durch den `key` im
Manifest). Steht dort eine andere ID, ist ein altes `dist/` geladen.

## 2. Bridge registrieren (das ist das Pairing)

```bash
~/git/chuk_chat/tools/agents-browser-bridge/install_host_manifest.py
```

Schreibt `dev.chuk.cowork.json` fuer Chrome, Chromium, Brave und Firefox.
`allowed_origins` nennt genau diese eine Erweiterung. Danach die Erweiterung
einmal neu laden.

## 3. Host neu starten und Coworker umstellen

Der Broker startet mit dem Host. Ein Host von vor diesem Stand hat ihn nicht,
also einmal neu starten (wie ueblich, nicht mitten in einem Lauf).

Dann in der App beim Coworker unter *Permissions* "Your browser" einschalten.
Gilt ab der naechsten Aufgabe.

Pruefen ohne App:

```bash
ls -l /run/user/1000/chuk-agents/        # browser-bridge.sock und browser-broker.sock
```

Optionsseite der Erweiterung (Rechtsklick aufs Icon -> Optionen): "connected
to Agents on this computer". Sonst: Host laeuft nicht, oder Schritt 2 fehlt.

## 4. Manueller Test (in dieser Reihenfolge)

1. **Verbindung.** Panel oeffnen (Icon klicken). Oben gruener Punkt,
   `Agents · native · cdp input`.
2. **Erste Seite fragt.** Dem Coworker schreiben: "Oeffne github.com in meinem
   Browser und sag mir, was oben steht." Erwartet: eine Freigabe-Karte "Open
   github.com", Kennzeichen "in your own browser". "Immer fuer diese Seite"
   waehlen. Ein neuer Tab in der lila Gruppe "Agents" oeffnet sich, oben auf
   der Seite eine farbige Leiste mit "<Name des Coworkers> is using this tab"
   und "Stop". Das Panel sagt "<Name> is using a tab in this browser."
3. **Freigabe gilt fuer die Seite.** "Klick dort auf Pull requests." Erwartet:
   keine Karte, der Klick passiert.
4. **Andere Seite fragt wieder.** "Oeffne jetzt example.org." Erwartet: Karte
   "Open example.org". Ablehnen. Der Coworker meldet, dass es nicht passiert ist.
5. **Eigenen Tab uebergeben.** Einen Tab mit einer Seite oeffnen, auf der du
   eingeloggt bist. "Schau dir meine Tabs an und uebernimm den mit <Seite>."
   Erwartet: `browser_tabs list` ohne Karte, dann Karte "Take over your tab on
   <Seite>". Nach Ja: Leiste auf deinem Tab.
6. **Kein Passwort ans Modell.** Auf einer Login-Seite mit vom Passwortmanager
   gefuelltem Passwortfeld: "Mach einen Snapshot und sag mir, was im
   Passwortfeld steht." Erwartet: `[hidden]`.
7. **Stop auf der Seite.** Waehrend er arbeitet, in der Leiste auf "Stop".
   Erwartet: Leiste wird grau "Agents stopped" und verschwindet, der Lauf in
   der App endet als gestoppt, das Panel zeigt "Stopped" und "Allow again".
   Ein neuer Versuch des Coworkers bekommt "the user pressed Stop".
8. **Stop aufheben.** Neue Aufgabe in der App schicken -> geht wieder. Oder im
   Panel "Allow again".
9. **Chromes eigene Leiste.** Waehrend er klickt, in Chromes gelber Leiste
   "... debuggt diesen Browser" auf "Abbrechen". Erwartet: wie Stop.
10. **Zwei Coworker.** Zwei Coworker mit "Your browser" gleichzeitig etwas
    oeffnen lassen. Erwartet: der zweite bekommt "in use by another coworker".
11. **Panel.** Rechtsklick auf eine Seite -> "Talk to Agents about this
    page", im Panel etwas fragen. Erwartet: sofort "Sent to <Name>. ...", der
    Lauf erscheint in der App im Thread dieses Coworkers mit der ersten Zeile
    `[from your browser panel]`, die Antwort kommt danach ins Panel. Ohne
    Coworker im Browser geht die Nachricht an den eigenen Coworker des Hosts.
12. **Status live.** App mit offenem "Your browser"-Schalter, dann Chrome
    schliessen und wieder oeffnen. Erwartet: der Status wechselt ohne Neuladen
    (`user_browser_status`).
13. **Zurueck auf Sandbox.** "Your browser" ausschalten, neue Aufgabe:
    Sandbox-Browser mit VNC wie vorher.

## Wenn nichts passiert

* **Panel sagt "not connected".** `ls /run/user/1000/chuk-agents/` - fehlen die
  Sockets, laeuft kein Host mit Broker. Fehlt die Registrierung, Schritt 2.
  Die Erweiterung versucht alle 30 Sekunden neu.
* **Service-Worker-Log**: `chrome://extensions` -> bei Agents auf *Service
  Worker* klicken.
* **"Agents host is not running its browser broker"** im Tool-Ergebnis: der
  MCP-Server findet `browser-broker.sock` nicht. Host neu starten.
* **Host ohne `XDG_RUNTIME_DIR`** (z. B. als Systemdienst ohne Login-Session):
  dann liegen die Sockets in `~/.agents/`, Chrome sucht aber in
  `/run/user/1000/chuk-agents/`. Beiden dieselbe Umgebung geben, oder
  `AGENTS_BRIDGE_SOCKET` setzen.

## Firefox

Geht, aber schwaecher, und das liegt nicht an uns:

* `chrome.debugger` gibt es in Firefox nicht. Das Add-on nutzt synthetische
  DOM-Events; das Panel zeigt `synthetic input`. Seiten, die auf `isTrusted`
  pruefen, echte Datei-Uploads und manche Editoren gehen nicht. Tab-Gruppen
  fehlen.
* Laden: `./build.sh firefox`, dann `about:debugging#/runtime/this-firefox` ->
  *Temporaeres Add-on laden* -> `dist/firefox/manifest.json`. Beim Neustart
  weg; dauerhaft braucht eine ueber AMO signierte XPI.

**Fuer den ersten Versuch Chrome oder Brave.**

## Bekannte Grenzen

* Mit `--sandbox local` laeuft der Agent als der Nutzer und kommt am Broker
  vorbei direkt an den Socket (und an das Chrome-Profil auf der Platte). Der
  Broker ist nur fuer die Docker-Sandbox eine Grenze.
* Die App zeigt den Pairing-Status noch nicht an und liest den Push
  `user_browser_status` noch nicht (Arbeitsliste im Wire-Contract).
* Ein Panel-Lauf ist kein `origin: "app"`: ist das Wochenbudget des
  Coworkers aufgebraucht, wird er abgelehnt wie eine Automation.
