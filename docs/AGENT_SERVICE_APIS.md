# Agent Service APIs — eBay, Booking.com, Spotify

Recherche-Stand: 2026-09-04. Ziel: native Tools / MCP-Server im cowork-Agenten, die auf
echten Diensten im Namen des Endnutzers handeln (verkaufen, suchen, abspielen). Jeder Dienst
braucht in unserem App-Layer eine eigene Pro-Nutzer-OAuth-/Verifizierungs-Schicht.

bd-Tracking: `cowork-95i` (Umbrella), `cowork-95i.1` eBay, `cowork-95i.2` Booking, `cowork-95i.3` Spotify.

Nicht jetzt implementieren — Doku für spätere Umsetzung. Wo Fakten frisch/instabil sind, ist es
unten als Flag markiert. Vor dem Bauen die jeweils verlinkte Doc-Seite nochmal gegenlesen.

---

## 1. eBay — verkaufen + monitoren im Namen des Nutzers (`cowork-95i.1`)

**Machbarkeit: hoch. Das ist der klarste Kandidat.**

### Kosten
- API-Zugang gratis. Kein Per-Call-Preis, kein Abo. Das alte Pay-per-Call-Modell ist weg.
- API-Kosten != Marktplatz-Gebühren. Geld kostet nur normales Verkaufen: Insertion Fee,
  Final Value Fee, optional Store-Abo — trifft das Verkäuferkonto, nicht unsere App.

### Auth für fremde Verkäufer (Multi-User)
- OAuth 2.0 Authorization Code Grant. Jeder Endnutzer loggt auf eBays Consent-Seite ein und
  gibt Scopes frei; wir bekommen User Access Token (~2 h) + Refresh Token (~18 Monate).
- Refresh Token pro Nutzer speichern, Access Token ohne erneutes Prompt erneuern.
- Genau das Modell von Sellbrite / inkFrog / Vendio. Explizit erlaubt.
- Für Onboarding im großen Stil: Client Registration API (dynamic client registration).
- OAuth-Limits: auth-code 10.000/Tag, refresh-token 50.000/Tag.

### Verkaufs-Flow (Sell Inventory API)
1. `createOrReplaceInventoryItem` — SKU-Record: Zustand, Menge, Produktdaten.
2. `createOffer` — sku, marketplaceId, format; vor Publish nötig: Location, Preis, Menge,
   eBay-Kategorie + Referenzen auf Payment-/Return-/Fulfillment-Business-Policies.
3. `publishOffer` — offerId, erzeugt das Live-Listing.
- Business Policies sind für die Inventory API Pflicht (Konto muss opted-in sein, verwaltet
  über die Account API). Zustand + Kategorie Pflicht. Varianten: `...InventoryItemGroup` +
  `publishOfferByInventoryItemGroup`.
- Inventory API Default-Limit großzügig (~2 Mio Calls/Tag).

### Verifizierung / Prod-Keys — die eine echte Pflicht-Hürde
- Free Developer Account -> Production Keyset (App ID / Cert ID / Dev ID).
- **Marketplace Account Deletion Notification ist Pflicht.** Bevor der Prod-Keyset aktiv wird
  und der erste Prod-Call geht, MUSS ein öffentlicher HTTPS-Webhook existieren, der eBays
  User-Deletion-Events (GDPR) per Challenge-Response beantwortet — oder formell opt-out.
  Nichteinhaltung = Keyset deaktiviert. Laufende Pflicht, nicht einmalig.
  -> Unser MCP-Backend braucht diesen Endpoint. Früh einplanen.
- Sell APIs sonst ohne Extra-Review nutzbar, sobald Keyset aktiv. (Gated sind die Buy APIs.)

### Monitoring / Suche (MacBook-Case: "finde X mit Specs, alle 15 min prüfen, Beschreibung lesen, melden")
- Richtige API: **Buy Browse API**. `item_summary/search` (Filter, Keywords, Aspects) +
  `getItem` / `getItemByLegacyId` für Volldetail inkl. Beschreibung.
- **Gating**: Buy APIs sind in Produktion beschränkt. Sandbox frei; Prod braucht Eligibility,
  eBay-Freigabe (Application Growth Check), in der Praxis teils Vertrag. Default nur ~5.000
  Calls/Tag bis erhöht. Ein 15-min-Poll über viele Suchen ist damit knapp -> Calls budgetieren,
  Growth Check anpeilen.
- **Marketplace Insights API** (echte Verkaufspreise / Sold-History) ist Limited Release, nur
  für ausgewählte Devs. 2026 nicht offen. Für kleine App unrealistisch.
- **Fallback**: der Shell-Skill `ebscrape` liest eBay inkl. Sold-Listings ohne API-Key. Deckt
  genau die Research-Seite, die die API dicht macht. Aufgabenteilung: API = Aktion (unser
  Verkauf), Scraper = Research (Konkurrenz, Sold-Preise).

### Geld-relevante Risiken
- Developer: Webhook überspringen oder Call-Limit-Terms brechen -> schnellster Weg zum Keyset-Verlust.
- Verkäufer: Payouts werden bei Policy-Verstoß, offenen Käufer-Fällen, "unusual activity"
  (aggressives Massen-Listing auf frischem Konto!), Fee-Schulden oder fehlender Identity-
  Verifizierung eingefroren. Prohibited-Items / IP-Verstöße = Suspendierung — als Listing-Agent
  erzeugen wir die, also Kategorie-/Prohibited-Checks einbauen. Die Sell Compliance API meldet
  Verstöße programmatisch.

### Flags
- Exaktes Browse-Default-Limit (5.000/Tag ist 2025/26-Stand, eBay tuned das).
- Ob Browse in Prod mit App-Token + Growth Check reicht oder ein Buy-API-Vertrag nötig ist —
  vor Commit auf das Monitoring-Feature bei eBay-Support klären.

### Kern-Doc-Links
- OAuth: developer.ebay.com/api-docs/static/oauth-details.html
- Inventory-Flow: developer.ebay.com/api-docs/sell/static/inventory/inventory-item-to-offer.html
- Account Deletion: developer.ebay.com/develop/guides/sell/marketplace-user-account-deletion
- Browse: developer.ebay.com/api-docs/buy/browse/overview.html
- Buy Requirements/Gating: developer.ebay.com/api-docs/buy/static/buy-requirements.html
- Call-Limits: developer.ebay.com/develop/get-started/api-call-limits

---

## 2. Booking.com — Hotelsuche (`cowork-95i.2`)

**Machbarkeit über Booking.com direkt: praktisch geschlossen für Indie. Alternative nehmen.**

### APIs
- **Demand API** = Nachfrage-Seite (Affiliates/OTAs), sucht + bucht. Das wäre die richtige.
  Endpoints: `POST /accommodations/search` (Ort/Freitext) -> `POST /accommodations/availability`
  (Preis + Verfügbarkeit).
- Connectivity/Content APIs = Angebots-Seite (Hoteliers), irrelevant.
- Normales Affiliate-Programm = nur Widget/Deep-Links/Banner, keine strukturierten API-Daten.

### Zugang / Verifizierung — gated
- Kein Self-Signup. Nötig: Registrierung als **Managed Affiliate Partner** (nicht das normale
  Affiliate-Konto), unterzeichneter Vertrag, zugewiesener Booking.com Account Manager,
  Partner-Centre-Freischaltung. Erst danach API-Key + `X-Affiliate-Id`. Sandbox nutzt dieselben
  Credentials — kein anonymer Developer-Tier.
- **AI-Klausel (geschäftsrelevant):** General Partner Terms v5 verlangen *vorherige schriftliche
  Genehmigung*, bevor ein KI-System zur Vertragserfüllung eingesetzt wird. Da unser Produkt eine
  AI-Agent-App ist, ist das ein echtes Freigabe-Thema, keine Formalität.
- Buchen (nicht nur Suchen) braucht nochmal separate "Search, Look & Book"-Freigabe + Business
  Case + ggf. PCI-DSS. Zwei Hürden übereinander.

### Kosten
- Kein öffentlicher Preis, keine Setup-/Per-Call-Fee dokumentiert. Revenue-Share/Provision
  (Anteil an Bookings Hotel-Provision, gestaffelt bis grob ~40%). Konditionen vom Account Manager.

### IP-Allowlist
- Offiziell nicht dokumentiert. Auth über Bearer-Token + Affiliate-ID, nicht IP. Das
  Anthropic-MCP-IP-Problem ist Anthropics eigener Deal, kein Merkmal der API selbst.

### Realistische Einschätzung + Alternativen
- Für kleinen Indie-Dev ohne OTA-Traffic 2026 de facto nicht in Reichweite (Firmenstatus,
  Vertrag, Account Manager, AI-Freigabe). Ohne Traffic kein Hebel.
- **Empfehlung fürs Bauen: Amadeus Self-Service Hotel Search API** — echter Self-Signup, gratis
  Test-Key sofort, Verfügbarkeit+Preise ab erstem Call. Prod = kostenpflichtiger Umstieg.
- Zweitquelle wenn Buchung/Provision gewollt: **RateHawk / Emerging Travel Group** (Affiliate
  gratis beitretbar, 3,3 Mio Unterkünfte, niedrigere Schwelle als Booking).
- Weitere: Hotelbeds (B2B, Vertrag, für Volumen), Expedia EPS Rapid (Partner-Approval),
  RapidAPI/StayAPI (schnellster Prototyp, aber Datenherkunft/Lizenz prüfen).
- **Nicht mehr nutzen:** Travelpayouts/Hotellook-Affiliate ist eingestellt.

### Flags
- Provisions-% und Rate-Limits der Demand API nur über Account Manager.
- Datenqualität/Lizenz der RapidAPI-Reseller vor Produktivnutzung prüfen.

---

## 3. Spotify — Playlist + Playback (`cowork-95i.3`)

**Technisch machbar. Killer ist die Skalierung: ohne Firmenstatus max. 5 Testnutzer.**

### Kosten
- Web API gratis, kein bezahlter Tier. Man kann höhere Limits NICHT kaufen — Zugang hängt an
  Kriterien, nicht an Geld.

### Auth
- Empfohlen: **Authorization Code + PKCE** (Mobile/SPA ohne sicheren Secret-Store). Client
  Credentials scheidet aus (kein User-Kontext).
- Scopes: Playlist = `playlist-modify-public` / `playlist-modify-private`; Playback =
  `user-modify-playback-state` (+ meist `user-read-playback-state`).

### Premium-Zwang beim Playback — bestätigt
- Player/Connect (Start/Resume, Transfer) verlangt **Endnutzer mit Premium**. Free -> `403
  PREMIUM_REQUIRED`, auch mit korrektem Scope. Der Voice-Case "spiel diesen Song" geht nur für
  Premium-User.
- Playlist anlegen/ändern + Search gehen auch mit Free-Accounts.
- Zusätzlich (Feb 2026): auch der **App-Owner** braucht selbst Premium, sonst stellt die App im
  Development Mode den Dienst ein.

### Verifizierung / Quota — das echte Problem
- Ablauf Development Mode -> Extended Quota Mode.
- **Development Mode** (Stand 2026): nur noch **max. 5 User pro App**, App-Owner muss Premium
  haben. (Die alte "25 User"-Zahl ist veraltet.)
- Bis zu 25 Client-IDs pro Account, aber Quota zählt pro Account — mehr IDs = keine höheren
  User-Limits.
- **Extended Quota Mode** (unbegrenzt) seit 15.05.2025 **nur für Firmen**: juristische Person,
  gelaunchter Dienst, **mind. 250.000 MAU**, Marktpräsenz. Keine Einzelentwickler. Prüfung ~6 Wochen.
- **Realität**: für Indie/Solo praktisch nicht bekommbar (Catch-22: 250k MAU nötig, aber ohne
  Quota kein Wachstum). App bleibt de facto bei 5 Testnutzern.

### Deprecations (für neue Apps weg — Use-Cases NICHT betroffen)
- Seit 27.11.2024 gesperrt für neue Apps ohne Extended: Related Artists, Recommendations, Audio
  Features/Analysis, Featured/Category Playlists, 30s-Preview-URLs.
- Feb-2026-Migration streicht für Dev-Mode zusätzlich Browse/Categories, New Releases, Artist Top
  Tracks; Search-`limit` max 10; Endpoint-Umstellungen (`/tracks` -> `/items`).
- **Unsere Cases (Playlist create/modify, Tracks add, Search, Playback-Control) bleiben verfügbar.**

### Ban/ToS-Risiko (Geschäftsrisiko)
- Zugang jederzeit widerrufbar bei Policy-Verstoß — reales Risiko ist gesperrte App, nicht Geld direkt.
- **Monetarisierung rund um Streaming verboten**: kein Weiterverkauf, keine Ads/Paywall an
  Streaming-Features. Wenn die Fitness-App Playback als Premium-Feature verkauft = ToS-Bruch, Ban-Risiko.
- Keine ML-Trainings-/Bulk-Nutzung. Agent-Automatisierung an sich nicht verboten, aber
  Rate-Limits (429) + "normales App-Verhalten" einhalten.

### Bottom line
- Spotify-Playback taugt höchstens als Nische-Feature für Premium-User, nicht als tragende
  Funktion für die breite Basis. Playlist/Search geht auch Free, aber die 5-User-Grenze macht
  jeden echten Rollout unmöglich, solange kein Firmen-/250k-MAU-Status da ist.

### Flags
- "5 User" + Owner-Premium-Zwang sind frisch (Feb-2026-Migration, von TechCrunch bestätigt) —
  vor Umsetzung Quota-Modes-Seite nochmal prüfen.
- Developer Terms zu "Agent/Automatisierung" nicht Satz-für-Satz aus der Terms-Seite gezogen
  (SPA); vor Launch `developer.spotify.com/terms` selbst gegenlesen.

---

## 4. Reddit — lesen (Datenquelle) + posten (`cowork-95i.5`)

**Machbar für kleinen Scope. Lesen gratis genug, Posten easy, Massen-Nutzung teuer.**

### Kosten / Tiers
- **Free (non-commercial):** 100 Queries/Minute pro OAuth-Client (rollierendes 10-min-Fenster,
  Bursts ok). Kein Zugang mehr ohne OAuth ("Traffic not using OAuth ... will be blocked").
  100 QPM ≈ 144k Calls/Tag — dick genug für on-demand-Reads.
- **Commercial (paid):** grob **$0,24 / 1.000 Calls**, Einstieg ~**$12.000/Monat** für ~50 Mio.
  Calls. FLAG: diese Zahlen sind aus Reddits 2023-Presse/Dev-Aussagen (die Apollo killten),
  überall zitiert, aber nie auf einer offiziellen Preisliste. Referenz, kein Angebot.
- **Enterprise/Data-Licensing:** privat verhandelt, v.a. für AI-Training (Google-Deal ~$60M/Jahr).
  Für uns irrelevant, solange wir keine Modelle auf Reddit-Content trainieren.

### Zugang
- Free-Credentials self-signup (reddit.com/prefs/apps -> Client-ID/Secret -> OAuth2). Aber unter
  "Responsible Builder Policy" — echter/erweiterter Zugang läuft über Antrag + Freigabe.
- **Commercial use** erzwingt paid Tier + manuelle Prüfung (~2-4 Wochen). "Commercial" = Reddit-
  Daten monetarisieren, Resale, Ad-/Paid-App at scale, Brand-Intelligence, und v.a. **AI/ML-
  Training** auf Reddit-Content. Exakte Grenze für kleine App nicht sauber publiziert -> Reddit
  entscheidet case-by-case.

### Posten im Namen des Nutzers
- Scopes: `identity` + `submit` (posten/kommentieren), + `edit`, `read`, `vote`, `save`, `flair`
  nach Bedarf. Nutzer bestätigt im OAuth-Consent. Keine Extra-Freigabe über den Grant hinaus.
- **Ban-Risiko ist real und Geld-Risiko:** automatisiertes Posten ist erlaubt, aber Massen-/Promo-
  Automation (feste Intervalle, gleicher Domain-Link, junge Accounts, VPN-IPs) -> Shadowban/
  Suspend. Für einen App-Promo-Bot ist ein verbrannter Account + verbrannte Domain die Hauptgefahr.
  Throttlen, Timing variieren, authentisch bleiben.

### Read-Alternativen (Reddit-API umgehen)
- **Brave Search API — brauchbar.** Braves Index trägt reddit.com, das "Discussions"-Feature zieht
  gezielt Reddit + StackExchange. Reddit-Content ohne Reddit-API-Vertrag. Aber: nur Snippets, kein
  strukturierter Comment-Tree, und Brave hat den echten Free-Tier 2026 gekippt -> ~$5/Monat Credit,
  dann metered (~$0,003-0,005/Query), Karte nötig.
- **Firecrawl — unzuverlässig für Reddit.** Reddit hat Mai 2026 Anti-Bot verschärft, 403 auch auf
  den alten `.json`-Trick. Off-Terms, fragil. Nicht drauf verlassen.

### Empfehlung
- Lesen: Free-Tier-OAuth (100 QPM) für on-demand; Brave Search API für breite "was sagt Reddit über
  X"-Fragen. Posten: OAuth auf dem eigenen Account des Nutzers, Bans als echten Kostenpunkt behandeln.
  Den $12k/Monat-Tier meiden, solange kein Bulk-Ingest/AI-Training.

---

## 5. Gmail + Google Calendar (`cowork-95i.6`)

**Machbar, gratis, easy. Kein Scale-Gate. Nur Bauen, keine offene Machbarkeitsfrage.**

- Offizielle Google APIs (Gmail API + Calendar API), OAuth2, kostenlos, self-service über Google
  Cloud Console. Pro-Nutzer-OAuth in unserem App-Layer.
- Voice-Cases: "schreib Mail", "lies meine Mails", "leg Termin an", "was hab ich heute".
- Der bestehende claude.ai-Gmail/Calendar-MCP ist unzuverlässig -> lieber direkt auf den Google APIs
  bauen statt drauf verlassen.
- Einzige Reibung: Google verlangt für sensible Scopes (Mail lesen/senden) einen **OAuth-Consent-
  Screen-Review / App-Verification**, wenn die App öffentlich viele Nutzer bedient (sonst
  "unverified app"-Warnung + 100-User-Limit). Für uns lösbar, aber einplanen. FLAG: Verification-
  Aufwand vor breitem Rollout prüfen.

---

## 6. Food-Delivery / Ride (`cowork-95i.7`)

**Kein einfacher Win. Konsumenten-Bestellung per offizieller API praktisch geschlossen.**

- **Lieferando / Just Eat, Wolt, DoorDash** geben nur Restaurant-/POS-/Logistik-Seite raus — keine
  Endkunden-Bestellung. Die "order food"-MCP-Server sind alle reverse-engineered / Browser-Automation,
  ToS-Bruch + Ban-Risiko, kein stabiler Vertrag.
- **Der eine legale Weg: Ubers Consumer Delivery API** — explizit für "voice assistants, chatbots"
  gebaut (browse, Cart, Order, Track über verknüpften Uber-Account). Aber: schriftliche Uber-Freigabe,
  early-access, case-by-case, wahrscheinlich US-first. FLAG: EU-Verfügbarkeit + Preise nicht publiziert.
- **Delivery-as-a-Service** (Uber Direct self-serve, ~$6,99+/Lieferung; Wolt Drive EU, merchant-gated;
  DoorDash Drive non-EU) schickt nur einen Kurier für eine Bestellung, die *uns* schon gehört. Nur
  relevant, wenn wir selbst Händler/Küche sind. Für "hol Essen vom Restaurant" nutzlos.
- Fazit: entweder Uber-Consumer-Delivery-Freigabe erkämpfen (nur wenn Kern-Feature) oder lassen.

---

## Verworfen (mit Begründung, damit wir's nicht nochmal durchkauen)

- **Banking / Open Banking (PSD2) — komplett raus.** Entscheidung 2026-09-04: nicht bauen. Selbst
  read-only (AIS) braucht BaFin-AISP-Status oder einen Aggregator-Vertrag (GoCardless/Tink), also
  Registrierung + keine offene self-serve API. PIS (Zahlungen) ist noch schwerer (regulierter PISP,
  keine öffentliche API). Regel des Nutzers: Registrierungspflicht + keine öffentliche API = raus.
  Prinzip fürs Protokoll, falls je wieder aufkommt: Bankdaten NIE bei uns eingeben — immer Bank-
  gehosteter OAuth/SCA-Redirect, wir bekommen nur ein Token per Callback, nie Login/PIN.

- **YouTube-Upload API** — Profis spannen/uploaden nicht per API, schadet dem Kanal. Lesen/Transcript
  läuft eh über yt-dlp-Skill + gscrape + vidIQ.
- **Instagram Graph API** — Buffer MCP deckt das Hochladen schon ab.
- **TikTok Content Posting API** — kein Mehrwert; Video-Runterladen+Zusammenfassen ist ein anderes Thema.
- **Amazon SP-API** — Nutzer verkauft nicht auf Amazon, kein Bedarf.
- **Maps / Geocoding, Stripe, Crypto.com** — schon vorhanden, nicht doppeln (Stripe-MCP reicht).

---

## Zusammenfassung / Priorisierung

| Dienst | Kosten | Verifizierungs-Hürde | Indie machbar? | Empfehlung |
|---|---|---|---|---|
| eBay | API gratis | Account-Deletion-Webhook (Pflicht); Buy API gated | Ja | Bauen. Sell zuerst, Monitoring über Browse (Growth Check) + ebscrape-Fallback |
| Booking | Revenue-Share | Managed Partner + Vertrag + AI-Freigabe | Nein (direkt) | Phase 2. Bis dahin Amadeus Self-Service |
| Spotify | gratis | 250k MAU + Firmenstatus für Skalierung | Nein (nur 5 Testuser) | Phase 2. Nur Nische/Premium-Feature |
| Reddit | Free bis 100 QPM, sonst ~$0,24/1k | self-signup (Free); paid ab commercial use | Ja (kleiner Scope) | Free-OAuth lesen/posten, Brave für Breitensuche, Ban-Risiko throttlen |
| Gmail+Calendar | gratis | OAuth-Consent-Review bei breitem Rollout | Ja | Bauen. Direkt auf Google APIs, nicht auf wackligem MCP |
| Food/Ride | per Lieferung | Konsumenten-API zu; Uber Consumer Delivery gated | Nein (praktisch) | Lassen, außer Uber-Freigabe wird erkämpft |

eBay ist der einzige, der ohne Firmen-/Vertrags-Gate für echte Nutzer skaliert. Booking und
Spotify sind technisch trivial, aber am Zugang blockiert — dort auf Alternativen (Amadeus) bzw.
begrenzten Scope ausweichen.

### Phasen (Zugang ist skalengebunden)

Booking und Spotify folgen demselben Muster: der Zugang öffnet sich erst mit Nutzerzahl. Das ist
kein Nein, sondern ein "später". Sobald das Projekt Masse hat (Booking: nachweisbarer Traffic für
den Managed-Partner-Vertrag; Spotify: 250.000 MAU + Firmenstatus für Extended Quota), kippt deren
Kalkül und wir bekommen Zugriff.

- **Phase 1 (jetzt, ohne Scale-Gate):** eBay (voll). Hotel-Suche via Amadeus Self-Service als
  Zwischenlösung. Spotify höchstens Nische-Feature für die 5 Testnutzer + Premium-User.
- **Phase 2 (bei Skalierung):** Booking.com Demand API statt/neben Amadeus; Spotify Extended
  Quota für vollen Rollout. Beide erst anpeilen, wenn die Nutzerzahl den Hebel gibt.
