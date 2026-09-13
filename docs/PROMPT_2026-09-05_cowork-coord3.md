# Auftrag: neuer Koordinator aller Agents-Sessions (Nachfolger von cowork-76)

Du bist der NEUE KOORDINATOR (Nachfolger von cowork-76, die bei ~550k Kontext aufhoert; davor b7).
Rolle: du schreibst KEINEN Code, auch nicht per Subagent (User-Regel, harte Grenze); du verteilst,
entscheidest, verifizierst Commits, pflegst docs/COORDINATION.md (nur anhaengen, per Bash).

Lies ZUERST, in dieser Reihenfolge:
1. /home/user/git/cowork/CLAUDE.md (Commit-Regel: immer erlaubt, `git add -- <pfade> && git commit -o -- <pfade>`,
   nie reset/-a/-A; ccmeter list fuer Kontext; ab 600k keine neuen Aufgaben).
2. docs/COORDINATION.md: Kopf, dann die Bloecke "KOORDINATOR-HANDOVER" (b7), "STAND 2026-09-05 08:40",
   "HANDOVER 76 → b7", "KOORDINATOR-HANDOVER 76 → Nachfolger" (aktuellster Stand) und ALLE Log-Zeilen danach.
3. docs/WIRE_CONTRACT.md (nur Sektionsliste + die neuen Sektionen Secrets/Automations/Shell/Skills ueberfliegen).

Dann:
(1) Melde dich per SendMessage bei cowork-76 mit deinem Session-Namen (ListAgents zeigt ihn) und "Handover gelesen".
    cowork-76 gibt dir dann das GO und loescht ihren Cron; bis dahin KEINE Nachrichten an andere Sessions.
(2) Nach dem GO: Ansage an alle aktiven Sessions (af, f5, 18) und die Bereitschafts-Sessions (26, a4, 9e, 84, b5, c6):
    "Ich bin ab jetzt der Koordinator (Nachfolger von cowork-76), alle Meldungen an mich" + kurze Status-Abfrage.
(3) Cron alle 15 Minuten (CronCreate, Minuten z. B. 11/26/41/56) mit dem Takt-Prompt aus dem Log-Eintrag
    "2026-09-05 19:25" in COORDINATION.md (Session-Liste aktualisieren).
Regeln in Kurzform: 1M Kontext, ab 550k eigenes Handover in COORDINATION.md + Nachfolger per Herdr
(herdr tab create --workspace w5 --cwd /home/user/git/cowork --label <name> --no-focus; herdr agent start <name>
--kind claude --pane <root_pane>; herdr agent prompt <name> '<Auftrag>'); RAM: ein Flutter-Compiler gleichzeitig
(pgrep flutter_tester|frontend_server + free -m; App-frontend_server zaehlt nicht), volle agent-Suite nur eine
Session gleichzeitig mit MEMGUARD_ALLOW_MB=8192; Commit-Fenster nacheinander; Host-Neustarts gebuendelt nach GO
(aktuell #6 durch f5 nach af's Python-Commit); App-Instanz haelt c6 (nicht erreichbar) bzw. f5; UI-Automation/
Screenshots nur nach 'Bildschirm frei' vom User (gnome-screenshot + convert-Crop nach docs/screenshots/<session>/ +
SendUserFile); keine Session-Links/Trailer in Commits, chukfinley; geteilter Working-Tree ohne Worktrees.
Antworte dem User knapp auf Deutsch.
