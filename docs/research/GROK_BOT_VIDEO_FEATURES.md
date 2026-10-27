# Grok Bot "What's new" (18.10.2026): was wir nachbauen können

Quelle: YouTube `zNgCdQt1qB8`, "What's new in Grok Bot - Oct 18, 2026" (Matt Palmer, 5:06).
Rohtranskript und Metadaten: `_scratch/yt/` (nicht committen).
Dazu der Tweet von @bot: Plus-Aliase (`my-bot+newsletters@…`, `+receipts`, `+signups`),
Routine nur auf Mail an einen Alias, Senden und Empfangen über eigene Aliase.
UI: Adresse als farbige Pills pro Alias plus Mail-Icon.

Das Video zeigt fast nur Sprechertext. Das Aussehen ist darum oft nur aus dem Text geschlossen.

## Funktionen

| Zeit | Funktion | Was / wie sieht es aus | Haben wir es? | Aufwand |
|---|---|---|---|---|
| 0:04 | Neue Chat-Cards | Antworten mit Struktur kommen als Card. Eigene Card-Optik für Rückfragen und Markdown-Tabellen ("Facelift"). | Teilweise. Cards: `<email>`, `<chart>`, `<map>`, OpenUI-Fence. Tabellen: `lib/widgets/chuk_table_classic.dart`. Ein Redesign läuft gerade (anderer Agent, `*answer*`, `ask_user_card.dart`). | M |
| 0:17 | Multi-Select-Fragen (A/B/C) | Frage-Card mit mehreren ankreuzbaren Optionen, dann ein Absenden. | Nein. `lib/widgets/ask_user_card.dart` kann nur eine Option (`onSelect(String)`), keine Mehrfachauswahl. | S–M |
| 0:31 | Bot-Computer 3x schneller | Antworten, die aus der Sandbox kommen, sind schneller. Reines Backend. | Kein UI-Thema. Für uns: Latenz Host/Relay messen. | – |
| 0:53 | Markierte Änderungen in Entwürfen | Überarbeitet der Bot einen Slack- oder Gmail-Entwurf, sind die Änderungen hervorgehoben. | Teilweise. `lib/widgets/diff_widget.dart` gibt es (Code-Diff, Zeilen). Kein Wort-Diff für Mail-Entwürfe, keine Revision in `agent_mail_widgets.dart` oder in der Freigabe-Card (`agents_action_approval_card.dart`). | M |
| 1:08 + Tweet | Plus-Aliase für die Agent-Mail | `bot+receipts@…`: unbegrenzt viele Adressen. Anlegen per Chat ("mach mir eine Plus-Adresse"). Routine nur für Mail an einen Alias. Senden über einen Alias. UI: farbige Pill pro Alias + Mail-Icon. | Nein. Eine feste Adresse pro User (`docs/AGENT_MAIL.md` §1, "Mehr als eine Adresse" steht unter Offene Punkte). Mail-Trigger filtert nur `from`/`subject` (`agents/runtime/.../automations.py`, `KIND_MAIL`). | M |
| 1:33 | X-Chat-DMs lesen und beantworten | Bot liest DMs und antwortet mit Limit gegen Spam. | Nein. Kein X-Kanal. Muster existiert für Mail (eingeschränkter Lauf für fremde Absender). | L |
| 1:55 | @bot in einem X-Thread | Mention im öffentlichen Thread startet eine Aufgabe (speichern, recherchieren). Erst X-Plugin verbinden. | Nein. | L |
| 2:31 | Neue Konnektoren | Robinhood, Coinbase, Trello, PostHog u. a. | Teilweise. MCP-Konnektoren (`lib/services/mcp/mcp_catalogue.dart`). Fehlende nachtragen ist je Eintrag S. | S je Stück |
| 2:48 | Sprachanruf merkt sich den letzten Anruf | Erneuter Anruf innerhalb 30 min: Bot kennt das ganze Transkript des letzten Anrufs. | Nein. Voice-Call (`lib/voice/`, owner-only) speichert Transkripte (`voice_transcript.dart`, `voice_call_store.dart`), gibt sie aber nicht an den nächsten Anruf weiter. | S–M |
| 3:27 | Eine Benachrichtigung, nur auf dem aktiven Gerät | Statt Ping auf Handy, Uhr und Laptop nur dort, wo man gerade aktiv ist. | Teilweise. `lib/services/notifications/agents_notifications.dart` unterdrückt im Vordergrund, aber pro Gerät. Kein geräteübergreifender "zuletzt aktiv"-Abgleich. | M |
| 3:56 | Teammitglieder einladen | Team-/Enterprise-Accounts laden Kollegen ein. | Nein. Kein Team-Konzept. | L |
| 4:06 | Android-Standardassistent | Bot als Android-Assistent setzen. | Ja. `docs/ASSISTANT_SURFACE.md` (Assist-Rolle, Overlay). | – |
| 4:19 | Zugriffslisten für Team-Bots | Festlegen, wer einen Team-Bot nutzen darf. | Nein (hängt an Teams). | L |
| 4:28 | Ungelesen-Pill | Mobil: Pill antippen, springt zur ersten ungelesenen Nachricht. | Teilweise. Ungelesen-Punkt pro Thread in der Inbox (`lib/pages/messenger_shell.dart`, `_readMarks`). Kein Sprung zur ersten ungelesenen Nachricht im Thread. | S |
| 4:38 | Bessere Routine-Zeiten | Zeitplan einer Routine leichter einstellbar. | Teilweise. Schedules gibt es (`automations.py`, cron/Intervall; `lib/pages/automations_page.dart`). Anlegen nur per Chat, kein Zeit-Picker in der UI. | S–M |
| 4:46 | Besserer Slack-Login-Link | Fehlt die Verbindung, kommt ein klarer Anmelde-Link im Chat. | Teilweise. `lib/widgets/mcp_connect_card.dart` für MCP. Für Server-Tools (Slack, Gmail) prüfen, ob dieselbe Card kommt. | S |

Schon vorhanden und im Video nicht neu, aber verwandt: Freigabe vor Mail-Versand
(`MAIL_SEND_TOOLS` in `action_policy.py`, `agents_action_approval_card.dart`),
Mail-Trigger für Automationen, `<email>`-Card im Chat.

## Empfehlung: zuerst bauen

1. **Plus-Aliase für Agent-Mail** (M). Größter Produktwert: ein Postfach für Newsletter,
   Belege, Anmeldungen, und Routinen nur pro Alias. Server: Worker akzeptiert `local+tag@`,
   speichert `to_tag`; Trigger-Spec bekommt `to`/`alias`; `mail_send` mit `from_alias`.
   App: Alias-Pills auf der Mailbox-Seite. Passt in die bezahlte Agents-Stufe.
2. **Multi-Select-Fragekarte** (S–M). Billig, macht jede Rückfrage schneller.
   Erst nach dem laufenden Redesign von `ask_user_card.dart` angehen.
3. **Markierte Änderungen in Mail-Entwürfen** (M). Wort-Diff in Entwurf und Freigabe-Card.
   Schafft Vertrauen genau vor dem Versand, also vor der Aktion mit Risiko.
4. **Ungelesen-Pill im Thread** (S). Schnell gebaut, spürbar bei vielen Agenten.
5. **Zeit-Picker für Routinen** (S–M). Senkt die Hürde für Automationen, also für tägliche Nutzung.
6. **Sprachanruf-Gedächtnis 30 min** (S–M), dann **Benachrichtigung nur aufs aktive Gerät** (M).

Nicht jetzt: X-DMs und @bot auf X (L, API-Kosten und Ban-Risiko auf X), Teams und
Zugriffslisten (L, kein Team-Produkt).
