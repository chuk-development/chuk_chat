# Wachstum: Was Rakazo richtig gemacht hat (und was chuk_chat übernimmt)

Stand: 2026-10-17. Quellen: Video "How I Built an Open Source Grok Bot in a Day"
(Elie Steinbock, YouTube `xk-aLMQRYfk`, veröffentlicht 2026-10-15, ~24k Views),
GitHub-API (`elie222/rakazo`), rakazo.com, HN-Algolia-API. Zahlen unten sind
gemessen, nicht geschätzt, außer wo "Schätzung" steht.

## Kurzfassung

Rakazo: Repo angelegt 2026-08-13, heute **4 314 Stars, 756 Forks, 1 212 PRs
(969 gemerged), 135 externe PR-Autoren** in gut 2 Monaten. Kein Umsatz bisher
(Cloud nur Warteliste). Der Hebel war nicht Code-Qualität, sondern fünf Dinge
zusammen: Hype-Timing, ein Satz Positionierung, ein fertiger Vertrieb (eigene
Reichweite), SEO-Vergleichsseiten und ein Repo, in das Fremde billig beitragen
können und das der Maintainer billig mergen kann.

## 1. Positionierung: "Open-Source-Alternative zu <Hype-Produkt>"

- GitHub-Beschreibung: *"Open-source Grok Bot alternative. Choose your own
  model and sandbox."* Titel der Startseite: *"Rakazo | Open source Grok Bot
  alternative"*.
- Ein Satz, der drei Suchintentionen trifft: Markenname des Hype-Produkts,
  "open source", "self-hosted".
- Wertversprechen gegen das Original: eigenes Modell (BYOK, Claude/ChatGPT-Abo,
  Ollama), eigener Server, Apache-2.0. Also genau das, was das Original nicht
  kann (Grok Bot: gehostet, Modell an Abo gebunden).
- Das Hype-Produkt hat die UX-Entscheidungen schon getroffen ("Grok Bot had
  already figured out the difficult UX decisions"). Kopieren statt erfinden.

## 2. Timing: am Hype-Tag gebaut

- Grok Bot Launch: HN-Story "Grok Bot" am **2026-08-11**, 351 Punkte.
- Rakazo-Repo: **2026-08-13 06:28 UTC**, erste Release `v0.1.0-beta` am selben
  Tag 19:01 UTC. Also 2 Tage nach dem Launch, als alle nach "Grok Bot open
  source" gesucht haben.
- Gebaut "in a day": 1 h Plan, Claude Design für UI, `/goal` über Nacht,
  danach Security-Scan. Modell: das am selben Tag erschienene Grok 4.6.

## 3. Vergleichs- und SEO-Seiten (echte URLs)

Alle auf rakazo.com, alle in der Sitemap, alle mit JSON-LD inkl. `FAQPage`:

- https://rakazo.com/grok-bot-alternative/ (Title: "Open Source Grok Bot Alternative (Self-Hosted) – Rakazo")
- https://rakazo.com/muse-alternative/
- https://rakazo.com/dots-alternative/
- https://rakazo.com/instinct-alternative/
- https://rakazo.com/openclaw-alternative/
- https://rakazo.com/hermes-alternative/
- https://rakazo.com/hark-alternative/
- https://rakazo.com/alternatives/ (Hub, "2026 roundup")
- https://rakazo.com/self-hosted-ai-agent/ (Self-Hosting-Guide)
- Blog: `/blog/best-open-source-ai-agents-2026/`, `/blog/openclaw-vs-hermes-vs-rakazo/`, `/blog/self-host-an-ai-agent/`
- Lokalisierte Startseiten: `/de/`, `/ko/`, `/zh/`

Aufbau einer Vergleichsseite: "Updated <Datum>", Gegenüberstellung in 3 Zeilen
(wer hostet, wer zahlt das Modell, Lizenz), sachliche Beschreibung des
Konkurrenten mit Preis aus dessen eigener Doku, dann "was wir übernehmen",
dann "was anders ist", Screenshot des Produkts.

Wichtig: **Die Seiten kamen erst am 2026-10-07** (Commits #1223–#1247, alles an
einem Tag), also 8 Wochen nach Launch. Der frühe Schub kam nicht von SEO. SEO
ist der Langläufer, der nach dem Hype weiterzieht.

## 4. README-Aufbau

Reihenfolge in `README.md` (Commit-Daten aus der Git-Historie):

1. Badges groß (`for-the-badge`): Stars, Discord, App Store, Android-APK-Direktlink (Badges am 2026-08-18).
2. Hero-Bild (2026-08-14).
3. Ein Absatz "was ist es", dann **Liste der Produkte, zu denen es eine Alternative ist** (mit Links auf die Vergleichsseiten).
4. Features als Stichpunkte, Stack als Stichpunkte.
5. **Quick start in 3 Zeilen**: `curl … install-images.sh && bash install-images.sh`. Keine Node-Installation, kein Clone, Secrets werden generiert.
6. **Setup-Prompt** für Coding-Agents (`SETUP_PROMPT.md`, 2026-08-18): "copy this prompt and your agent will set it up".
7. Server-Betrieb, lokale Entwicklung, Contributing, Lizenz, Discord.

Testimonials stehen nicht im README, sondern auf der Startseite (6 Zitate von
X-Accounts, Laufband), u. a. *"it replaced totally grok bot for me"* und
*"Hermes is good but more complicated setup"*. Also Zitate, die genau den
Vergleich bestätigen.

## 5. Vorhandene Reichweite

- Inbox Zero (`elie222/inbox-zero`): **12 583 Stars**, seit 2023, laut Video
  "tens of thousands" Signups. Rakazo startete nicht bei null.
- Eigener YouTube-Kanal plus X. Das Video endet mit "give a star to Rakazo,
  give a star to Inbox Zero".
- Keine HN-Story zu "Rakazo" auffindbar (Algolia-Suche leer). HN war nicht der
  Kanal.

## 6. Contributor-Flywheel

Messung über die Pulls-API (Wochen ab 2026-08-13):

| Woche ab | PRs | gemerged | von Externen |
|----------|-----|----------|--------------|
| 08-13 | 72 | 65 | 18 |
| 08-20 | 157 | 90 | 94 |
| 08-27 | 191 | 151 | 120 |
| 09-03 | 301 | 247 | 140 |
| 09-10 | 36 | 31 | 19 |
| 09-17 | 81 | 67 | 54 |
| 09-24 | 96 | 90 | 64 |
| 10-01 | 128 | 116 | 66 |
| 10-08 | 114 | 93 | 69 |

- Ab Woche 2 kommen mehr PRs von Fremden als vom Maintainer. 669 externe PRs,
  davon 471 gemerged (70 %). Elie selbst: 543 PRs.
- **PRs sind billig**, weil Contributor Agents laufen lassen. Dafür braucht es:
  `AGENTS.md` mit harten Regeln ("kein Feature darf von einem Drittanbieter
  abhängen", "UI-Änderung = CI-Screenshot im PR verlinken"), und **17
  Emulatoren** im Repo (`packages/adapters/src/*-emulator.ts`: Composio,
  Daytona, E2B, Stripe, Email, GitHub-Webhook, MCP, Model …). Ein Fremder
  braucht keinen einzigen API-Key, um das Projekt zu testen.
- **Mergen ist billig**, weil (a) jeder PR Screenshots bekommt (Playwright,
  ~350 Screens, Kommentar im PR mit den geänderten Screens; Workflows
  `playwright.yml`, `mobile-android-screenshots.yml`,
  `desktop-macos-screenshot.yml`, `nightly-verification.yml`), und (b) ein
  Bot alle paar Stunden offene PRs prüft, kleine Fixes selbst merged und bei
  großen Features Screenshots zur Freigabe schickt (Skill `.agents/skills/pr-watch`).
  Ergebnis laut Video: 15 offene PRs bei 1 200 geschlossenen, nicht Vollzeit.
- GitHub Actions sind für öffentliche Repos kostenlos. Die ganze Screenshot-
  Pipeline kostet also nichts.

## 7. Star-/Fork-Verlauf und Auslöser

Die Stargazer-Liste von Rakazo ist über die API nicht abrufbar (REST 404,
GraphQL liefert 0). Proxy: Forks pro Tag (756 gesamt, Zeitstempel über
`/forks`). Ausschläge:

| Datum | Forks/Tag | Wahrscheinlicher Auslöser |
|-------|-----------|---------------------------|
| 08-13 – 08-15 | 14 / 20 / 15 | Launch 2 Tage nach Grok Bot |
| 08-17 | 36 | Launch-Welle, Badges/Setup-Prompt am 08-18 |
| 09-02 – 09-03 | 17 / 16 | `v0.1.0` + `v0.1.1` (Desktop-Release, notarisiert) |
| 09-14 | 19 | (kein Release, Quelle unklar) |
| 10-01 – 10-02 | 16 / 12 | (unklar) |
| 10-11 – 10-13 | 15 / 16 / 15 | `v0.2.0` + Android-APK (10-10), Vergleichsseiten (10-07) |
| 10-15 | 24 | YouTube-Video (10-15, 14:15 UTC) |
| 10-16 | **54** | Video-Welle. Video nennt 3 700 Stars, heute 4 314 |

Schätzung: Das Video hat in 2 Tagen ~600 Stars gebracht, mehr als jeder
Release. Releases geben kleine, aber verlässliche Stufen.

## 8. Was nicht übertragbar ist

- 12k-Stars-Vorgängerprojekt und Kanal. chuk_chat hat 1 Star und keine
  Reichweite. Den Vertrieb muss man erst bauen oder leihen (HN, Reddit,
  Communities).
- Apache-2.0 und Self-Hosting per Einzeiler. chuk_chat ist **BSL-1.1** (GitHub
  zeigt "NOASSERTION"), das Backend-Repo ist öffentlich nicht auffindbar
  (`chuk-development/api_server` → 404). Damit ist "open source" angreifbar
  und r/selfhosted fällt als Kanal weg.
- Rakazo verdient (noch) nichts. chuk_chat lebt vom 20-€-Abo. Wer das
  Geschäftsmodell nicht anfassen will, nimmt die Taktiken, nicht die Lizenz.

## Was chuk_chat konkret davon übernehmen kann

Ausgangslage: Repo-Beschreibung *"Private AI chat client — open-weight LLMs via
OpenRouter, E2E encrypted, cross-platform Flutter"*, 1 Star, BSL-1.1, README mit
Screenshots und 3 Badges (Flutter-Badge zeigt veraltet "3.24+"), keine
Vergleichsliste, kein Setup-Prompt. chuk.chat hat schon
`/en/private-chatgpt-alternative/`, `/en/private-ai-chat/`, `/en/german-ai-chat/`.

Priorisiert nach Wirkung pro Aufwand:

1. **Lizenzentscheidung treffen (1 h Entscheidung, 0,5 Tage Umsetzung).**
   Option A: Client unter AGPL-3.0 oder Apache-2.0, Backend bleibt zu. Dann
   ist "open-source client, E2E-verschlüsselt, auditierbar" ehrlich und HN
   zerlegt es nicht. Abo bleibt das Geschäft, weil der Client ohne
   chuk-Backend nichts kann. Option B: BSL lassen, dann nirgends "open source"
   schreiben, sondern "source-available". Geldrisiko bei B: Launch-Posts mit
   "open source" und BSL ziehen Kommentare, die den Post killen.
2. **Positionierungssatz + Repo-Beschreibung (1 h).** Gegen das Produkt
   positionieren, nach dem gerade gesucht wird. Kandidaten (Suchvolumen
   vorher mit `gscrape suggest`/`trends` prüfen): "ChatGPT", "Proton Lumo",
   "Confer", "Venice", "Duck.ai". Vorschlag: *"Open-source, end-to-end
   encrypted ChatGPT alternative. Open-weight models, every platform."*
   Topics ergänzen: `chatgpt-alternative`, `privacy`, `e2ee`, `open-weight`.
3. **README neu (0,5 Tage).** Rakazo-Reihenfolge: große Badges (Stars,
   Web-App, Android-APK-Direktlink, F-Droid sobald gelistet), Hero-GIF,
   ein Absatz, "Alternative to: ChatGPT, Lumo, …" mit Links auf
   Vergleichsseiten, Feature-Liste, "Try it: chat.chuk.chat" vor dem
   Dev-Teil, `SETUP_PROMPT.md` für Contributor-Agents. Flutter-Badge auf 3.47.
4. **Vergleichsseiten auf chuk.chat (1 Tag für 5 Seiten).** Muster wie oben:
   `/en/chatgpt-alternative/` (gibt es als private-chatgpt-alternative,
   umbauen), `/en/lumo-alternative/`, `/en/confer-alternative/`,
   `/en/venice-alternative/`, `/en/duck-ai-alternative/`, Hub `/en/alternatives/`,
   jeweils DE-Version. Kriterien: wer sieht den Klartext, Modell-Auswahl,
   Plattformen, Preis, Quellcode einsehbar. Nur Fakten aus der Doku des
   Konkurrenten, mit Datum. Geldrisiko: falsche Aussagen über Konkurrenten
   = Abmahnung (UWG §6 vergleichende Werbung). Jede Aussage belegen.
5. **Verifikation und Emulatoren fertig machen (läuft parallel).**
   `docs/VERIFICATION.md`, `docs/API_EMULATOR.md`, `docs/E2E_STACK.md`.
   Heute braucht ein Fremder Supabase-Credentials in `.env`, um die App zu
   starten. Das blockiert jeden externen PR. Mit Emulator + lokalem Supabase
   kann ein Agent eines Fremden das Repo klonen und testen. Danach
   Screenshot-Kommentar im PR (`e2e.yml`) und ein Auto-Merge-Bot für kleine
   Fixes.
6. **Contributor-Einstieg (2 h).** `CONTRIBUTING.md` mit "läuft ohne Keys",
   10 `good first issue` aus `bd`, `AGENTS.md` schon vorhanden, auf
   Englisch kürzen.
7. **Launch-Kanäle mit Termin** (erst nach 1–4):

   | Datum | Kanal | Aufwand | Hinweis |
   |-------|-------|---------|---------|
   | Di 2026-10-27, 15–16 Uhr MEZ | Show HN | 2 h + 1 Tag Kommentare beantworten | Titel: "Show HN: Chuk Chat – E2E-encrypted AI chat, open-weight models, every platform". Nur mit OSI-Lizenz (Punkt 1A) |
   | Mi 2026-10-28 | r/privacy, r/LocalLLaMA, r/FlutterDev | je 30 min | Pro Sub eigener Text, kein Crosspost. r/FlutterDev: Technik (E2E in Flutter, SQLite-Cache) |
   | Do 2026-10-29 | F-Droid-Antrag (fdroiddata MR) | 0,5 Tage | Metadaten liegen schon unter `fastlane/metadata/android/`. BSL ist für F-Droid ein Problem, AGPL nicht |
   | KW 45 | AlternativeTo.net, Privacy Guides Forum, Mastodon (#privacy) | je 30 min | AlternativeTo-Eintrag als "alternative to ChatGPT / Lumo" |
   | KW 46 | Product Hunt | 1 Tag Vorbereitung | Dienstag-Launch, Hero-GIF und Vergleichstabelle wiederverwenden |
   | laufend | Hype-Fenster | 1 Tag pro Anlass | Wenn ein großer Anbieter eine Datenschutz-Panne oder ein neues Privacy-Produkt hat: innerhalb von 48 h Vergleichsseite + Post. Genau das war Rakazos Trick |

8. **Video/Devlog (1 Tag).** "Wie ich E2E-Verschlüsselung für AI-Chats
   gebaut habe" auf YouTube (DE und EN). Bei Rakazo hat das Video mehr Stars
   gebracht als jeder Release.
9. **Testimonials sammeln (laufend).** Erste 10 Nutzer anschreiben, Zitate
   mit Handle auf die Startseite, bevorzugt Zitate mit Vergleich ("hab von X
   gewechselt, weil …").
10. **Releases als Anlässe nutzen.** Jede Minor-Version mit Changelog-Post auf
    X/Mastodon/Reddit. Bei Rakazo erzeugt jede Release eine kleine Fork-Stufe.
