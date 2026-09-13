# Agents — Szenarien

Konkrete Alltags-Aufgaben, die der Agent können muss. Jedes Szenario ist ein
Realfall, kein abstraktes Feature. Aus den Szenarien leiten wir ab, welche
Fähigkeiten (Tools, MCP, Browser, Memory, Cron) die Basis wirklich braucht.

Vorlage pro Szenario:

- **Auslöser** — was passiert, wie kommt die Aufgabe rein.
- **Nutzer sagt** — der wörtliche Auftrag.
- **Agent tut** — die Schritte, die er selbstständig gehen muss.
- **Braucht** — Fähigkeiten / Tools, die das Szenario voraussetzt.
- **Output** — was am Ende beim Nutzer landet.

---

## Szenario 1 — PDF in Bild umwandeln

Eine der simpelsten Aufgaben überhaupt. Muss sitzen.

- **Auslöser** — der Bruder schickt ein PDF in den Chat und einen kurzen Satz
  dazu.
- **Nutzer sagt** — "mach mal ein Bild draus".
- **Agent tut**
  1. Die angehängte Datei (PDF) entgegennehmen und im Workspace ablegen.
  2. PDF in ein Bild rendern. Zwei Wege: lokal per Tool im Sandbox
     (`pdftoppm` / ImageMagick / `pdf2image`) oder, falls kein Tool da,
     eine Webseite / API nutzen. Lokal ist billiger und schneller — bevorzugt.
  3. Ergebnis-Bild (PNG/JPG) erzeugen; bei mehrseitigem PDF entweder pro Seite
     ein Bild oder eine zusammengesetzte Grafik — im Zweifel Seite 1, sonst
     kurz nachfragen.
  4. Das Bild zurück an den Nutzer liefern.
- **Braucht**
  - Datei-Empfang (Anhang aus dem Chat in den Workspace).
  - `run_command` im Sandbox mit vorhandenem PDF-Tool.
  - Datei-Rückgabe an den Chat / Notification "fertig".
- **Output** — ein Bild der PDF-Seite(n), direkt im Chat.
