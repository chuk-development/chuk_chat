# Recherche: mit Link bezahlen lassen, ohne dass der Nutzer Karten eintippt

Session cowork-1b, 2026-09-09. Alle Quellen am selben Tag geprüft, Links am Ende.

## 0. Die Frage, richtig gestellt

Der Coworker fährt einen Browser (browser-use über CDP, `agent/src/cowork_agent/browser.py`).
Er landet auf einem Checkout. Der Nutzer soll dort **keine Kartendaten eingeben**
und wir wollen auch keine Karte im Klartext lagern. Stattdessen: Link ist in der
App **einmal** verknüpft, und pro Kauf gibt Link eine Zahlungsberechtigung heraus
— aber nur, wenn der Nutzer **jeden einzelnen Kauf freigibt**.

Antwort: genau dafür gibt es seit Stripe Sessions 2026 das **Link Agent Wallet**
und die **`link-cli`**. Das ist kein Bastelweg, das ist das dafür gebaute Produkt.
Es passt eins zu eins auf unseren Fall, inklusive Pflicht-Freigabe.

## 1. Produktlage (Stand 2026-09-09)

Stripe hat den agentischen Zahlungsraum in zwei Hälften geteilt:

| Wer | Was er tut | Produkt |
| --- | --- | --- |
| **Verkäufer** | bietet Katalog + Checkout für Agenten an | `agentic-commerce/for-sellers`, UCP/ACP, Machine Payments (MPP, x402) |
| **Agent** | kauft im Namen einer Person | **Link Agent Wallet / `link-cli`** |

Wir sind ausschließlich die **Agenten**-Seite. Alles, was ACP/UCP/„Instant
Checkout in ChatGPT" heißt, setzt voraus, dass der **Händler** mitspielt. Das ist
für uns wertlos, weil unser Coworker auf beliebigen fremden Shops landet, die
nichts von uns wissen.

Die Link-APIs sind **nicht** die Stripe-API:

* Aufrufe gehen an `api.link.com`, Auth gegen `login.link.com`.
* Kein Stripe-Secret-Key, sondern ein **OAuth-Access-Token** des Nutzers
  (`LINK_ACCESS_TOKEN`).
* Die Stripe-Server-SDKs decken diese Endpoints **nicht** ab. Es gibt die CLI
  (`npm i -g @stripe/link-cli`) oder rohes HTTP.
* Für reine Agentenzahlungen braucht man **kein Stripe-Konto**; für den
  registrierten OAuth-Client schon (und Sales-Kontakt).

### Drei Arten Zahlungsdaten

| Typ | `--credential-type` | Wo nutzbar |
| --- | --- | --- |
| **Einmal-Virtualkarte (PAN)** | `card` (Standard) | **jeder Händler, der Karten online akzeptiert** |
| Link Pay Token (LPT) | — | Stripe-gehostete Formulare mit Agent-Steering-Blöcken |
| Shared Payment Token (SPT) | `shared_payment_token` | nur Händler, die SPT/MPP akzeptieren |

**Für uns zählt nur `card`.** Der Coworker füllt ein fremdes Checkout-Formular
aus; dafür braucht er Nummer, CVC, Ablauf, Rechnungsadresse — also eine echte
Karte, die nach einer Nutzung tot ist. SPT ist der Weg für kooperierende
Händler und für Maschinenzahlungen (HTTP 402); interessant später für
API-Bezahlung, nicht für Shop-Checkouts.

## 2. Der Ablauf, den wir bauen

```
App (einmalig)                Executor / Agent (pro Kauf)              Link
─────────────                 ───────────────────────────              ────
OAuth-Verknüpfung  ──────────────────────────────────────────────────▶ login.link.com
  scope: payment_methods.agentic userinfo:read
  ◀── refresh_token (1 Jahr), access_token (1 h)

                              1. CoWork-Gate: approval_request  (unser Frame)
                              2. spend-request create ─────────────────▶
                                 ◀── approval_url, status pending_approval
     Nutzer tippt "Freigeben" in der Link-App/Web ────────────────────▶
                              3. spend-request retrieve (Polling) ◀────
                                 status: approved
                              4. retrieve --include card --output-file
                                 ◀── PAN, CVC, exp, Rechnungsadresse
                              5. browser-use füllt Checkout mit
                                 sensitive_data-Platzhaltern
                              6. link-cli report --outcome success ───▶
```

Der Nutzer bestätigt also **zweimal**, und beides ist gewollt:

1. **In CoWork**, über die vorhandene Maschinerie
   (`approval_request` / `approval_decision`, `executor/src/cowork_executor/protocol.py`,
   Muster: here.now-Publish). Das ist unser Gate: „Coworker will 35,00 USD bei
   press.stripe.com ausgeben." Ohne Antwort blockiert der Worker.
2. **In Link**, über `approval_url`. Das erzwingt Stripe, nicht wir. Ohne diese
   Freigabe gibt Link **keine** Zahlungsdaten heraus. Es gibt aktuell keinen
   Auto-Approve-Modus; Ausgabelimits ohne Rückfrage sind angekündigt, aber nicht
   verfügbar.

Punkt 1 ist streng genommen redundant, aber billig und richtig: er hält den Kauf
in unserem UI-Kontext, protokolliert die Entscheidung in unserem Replay-Log und
verhindert, dass der Agent überhaupt eine Ausgabeanfrage erzeugt (Rate-Limits!),
wenn der Nutzer schon im Chat nein sagt.

## 3. Schritt 1: einmal verknüpfen (OAuth)

Zwei Varianten, wir brauchen beide zu unterschiedlichen Zeitpunkten.

### 3a. Device-Flow — für die Entwicklung, sofort nutzbar

```bash
npm i -g @stripe/link-cli
link-cli auth login --client-name "CoWork" --interval 5 --timeout 300
```

Link zeigt eine URL und einen kurzen Bestätigungssatz; der Nutzer loggt sich in
sein Link-Konto ein und bestätigt. Es ist **kein registrierter Client nötig**,
die CLI benutzt einen eingebauten Public Client. Damit können wir sofort testen,
ohne auf Stripe-Sales zu warten.

### 3b. Confidential Client — für die ausgelieferte App

Das ist der Weg für einen gehosteten Agenten (unser Executor auf dem Server läuft
im Namen des Nutzers).

1. `client_id` / `client_secret` bei Stripe anfragen (Formular, Sales-Kontakt).
2. Autorisierungs-URL im App-Webview öffnen:

```
https://login.link.com/auth
  ?key=pk_live_...                     # unser Stripe Publishable Key
  &client_id=...
  &redirect_uri=https://<backend>/link/callback
  &response_type=code
  &scope=payment_methods.agentic%20userinfo:read
  &state=<zufall, CSRF>
  &code_challenge=<BASE64URL(SHA256(verifier))>
  &code_challenge_method=S256
```

Achtung Trennzeichen: `payment_methods.agentic` mit **Punkt**,
`userinfo:read` mit **Doppelpunkt**. PKCE ist Pflicht (`S256`).

3. Callback → `state` prüfen → Code binnen 10 Minuten tauschen:

```bash
curl -X POST https://login.link.com/auth/token \
  -d grant_type=authorization_code -d client_id=... -d client_secret=... \
  -d redirect_uri=... -d code=... -d code_verifier=...
```

```json
{ "access_token": "liwltoken_...", "refresh_token": "liwlrefresh_...",
  "token_type": "Bearer", "expires_in": 3600,
  "scope": "payment_methods.agentic userinfo:read" }
```

4. Token-Lebensdauer: **Access 1 Stunde**, **Refresh 1 Jahr, rotiert bei jeder
   Benutzung** — das neue Refresh-Token muss jedes Mal gespeichert werden, sonst
   ist die Verknüpfung tot.
5. Trennen: `POST https://login.link.com/auth/revoke` mit
   `token_type_hint=refresh_token`.

### Wo die Token bei uns liegen

Analog zu den MCP-Credentials (siehe `bd memories` zu
`chuk-chat-connectoren-quelle-der-wahrheit-ist-supabase` und
`docs/WIRE_CONTRACT.md`):

* **Refresh-Token**: verschlüsselt in Supabase (`EncryptionService`,
  AES-256-GCM), gleiches Schema wie `service_credentials`. Nie auf dem Executor
  persistent, nie in Git, nie in einer Skill-Datei.
* **Access-Token**: kurzlebig, wandert wie `mcp_servers` auf dem Task-Frame zum
  Executor und lebt dort nur als `LINK_ACCESS_TOKEN` in der Prozess-Umgebung des
  Zahlvorgangs. Läuft ohnehin nach einer Stunde ab.
* `client_secret` bleibt **serverseitig** im Backend, kommt nie in die
  Flutter-App.

Setzen wir `LINK_ACCESS_TOKEN`, umgeht die CLI ihre eigene Token-Datei komplett.
`LINK_NO_REFRESH=1` verhindert, dass sie eigenmächtig refresht — das machen wir
im Backend, weil nur dort das `client_secret` liegt.

## 4. Schritt 2: Ausgabeanfrage stellen

```bash
link-cli spend-request create \
  --amount 3500 \
  --currency usd \
  --merchant-name "Stripe Press" \
  --merchant-url "https://press.stripe.com" \
  --context "Purchasing 'Working in Public' from press.stripe.com. The customer initiated this purchase through the shopping assistant." \
  --line-item "name:Working in Public,unit_amount:3500,quantity:1" \
  --total "type:total,display_text:Total,amount:3500" \
  --request-approval
```

```json
{
  "id": "lsrq_abc123",
  "status": "pending_approval",
  "approval_url": "https://app.link.com/activity/approve/lsrq_abc123",
  "credential_type": "card",
  "_next": { "command": "spend-request retrieve lsrq_abc123 --interval 2 --max-attempts 300" }
}
```

Parameter, die wirklich zählen:

| Parameter | Pflicht | Anmerkung |
| --- | --- | --- |
| `--amount` | ja | kleinste Währungseinheit |
| `--context` | ja | **mindestens 100 Zeichen**, wird dem Nutzer im Freigabedialog angezeigt |
| `--merchant-name`, `--merchant-url` | bei `card` | bei SPT weglassen, dafür `--network-id` |
| `--payment-method-id` | nein | Standard: Standardzahlungsmethode des Nutzers |
| `--line-item`, `--total` | nein | steuern den Freigabebildschirm, wiederholbar |
| `--metadata` | nein | max. 50 Paare — hier gehören unsere Run-/Chat-IDs rein |
| `--test` | nein | Testmodus, gibt `4000009990001984` zurück, bucht nichts |

`--context` ist der sicherheitsrelevante Teil: das ist der Text, an dem der
Nutzer erkennt, was er freigibt. Er muss aus **unserem** Zustand kommen (Warenkorb,
den der Agent aufgebaut hat), nie aus einem Seitentext, den der Händler steuert.

`--line-item`-Schlüssel: `name` (Pflicht), `quantity`, `unit_amount`,
`description`, `sku`, `url`, `image_url`, `product_url`.
`--total`-Schlüssel (alle drei Pflicht): `type` aus
`subtotal|tax|total|items_base_amount|items_discount|discount|fulfillment|shipping|fee|gift_wrap|tip|store_credit`,
`display_text`, `amount`.

## 5. Schritt 3: auf die Freigabe warten

```bash
link-cli spend-request retrieve lsrq_abc123 --interval 2 --max-attempts 300
```

Der Nutzer hat **10 Minuten** ab Anfrage, dann `expired`. Polling-Fenster also
entsprechend auslegen (2 s × 300 = 10 min).

Neun Zustände, alle explizit behandeln:

| Status | Bedeutung | Aktion |
| --- | --- | --- |
| `created` | angelegt, Freigabe wird angefordert | weiter pollen |
| `pending_approval` | wartet auf den Nutzer | weiter pollen |
| `requires_action` | Nutzer muss etwas erledigen | `next_action` auswerten, siehe unten |
| `approved` | freigegeben, Daten verfügbar | Kauf abschließen |
| `denied` | abgelehnt | melden, **nicht** ohne neue Anfrage erneut versuchen |
| `expired` | 10-Minuten-Fenster verstrichen | neue Anfrage, wenn der Nutzer weiter will |
| `canceled` | vorzeitig abgebrochen | neue Anfrage |
| `succeeded` | Zahlung durch | fertig |
| `failed` | endgültig fehlgeschlagen | `status_details.failed.code` lesen |

Zwei Dinge beenden das Polling vorzeitig:

* `requires_action` → `status_details.requires_action.next_action` mit
  `type`, `resolution`, `display_message`, `action_url`, `expires_at`.
* Timeout → Exit ungleich null mit `code: "POLLING_TIMEOUT"`. **Das ist kein
  Fehlschlag und kein Erfolg** — erneut `retrieve`, bevor irgendwem irgendwas
  gemeldet wird.

`next_action`-Typen — nach `type` und `resolution` verzweigen, nicht nach
`failure_code`:

| `type` | `resolution` | Was zu tun ist |
| --- | --- | --- |
| `three_d_secure` | `auto_resume` | Nutzer auf `action_url` schicken, **weiterpollen** — die Anfrage lebt weiter |
| `three_d_secure_retry` | `create_new_spend_request` | neue Anfrage |
| `ssn_verification`, `identity_verification` | `create_new_spend_request_after_completion` | Nutzer verifiziert sich, danach neue Anfrage |
| `select_payment_method` | `create_new_spend_request` | Zahlungsmethode abgelehnt, andere wählen lassen |
| `add_payment_method`, `update_payment_method` | s. Tabelle | Nutzer zu `action_url`, dann neue Anfrage |
| `re_authorize` | `create_new_spend_request` | Zahlung überschritt den freigegebenen Betrag |
| `contact_support` | — | Verifikationsversuche erschöpft, Link-Support |

Merksatz: **nur `auto_resume` erhält die bestehende Anfrage.** Alles andere heißt,
der Vorgang ist tot und muss neu gestellt werden.

## 6. Schritt 4: Kartendaten holen, ohne sie zu verbrennen

Standardmäßig gibt `retrieve` die Karte **nicht** zurück. Mit `--include card`
schon — und dann gehört sie in eine Datei, nicht auf stdout:

```bash
link-cli spend-request retrieve lsrq_abc123 \
  --include card --output-file /run/cowork/link-card.json --format json
```

Die CLI legt die Datei mit `0600` an und **überschreibt nichts** ohne `--force`.
stdout enthält dann nur geschwärzte Felder plus `card_output_file`.

```json
{
  "id": "lsrq_abc123",
  "status": "approved",
  "card": {
    "brand": "visa",
    "number": "4242424242424242",
    "cvc": "100",
    "exp_month": 6,
    "exp_year": 2029,
    "billing_address": { "name": "Jenny Rosen", "postal_code": "94015", "country": "US" },
    "valid_until": "2026-06-13T03:40:10Z"
  }
}
```

Die Karte ist **einmal** verwendbar und läuft **12 Stunden** nach Erstellung der
Ausgabeanfrage ab (`valid_until`).

Warum das wichtig ist: stdout eines Tool-Calls landet bei uns im Modellkontext,
im Transkript und im Replay-Log. Eine PAN, die dort einmal drin steht, ist
dauerhaft drin. Also niemals `--include card` ohne `--output-file`.

## 7. Schritt 5: das Formular ausfüllen, ohne dem Modell die Karte zu zeigen

browser-use kann genau das: `sensitive_data` injiziert Werte erst im Browser, das
Modell sieht nur Platzhalter, und die Werte werden aus LLM-Nachrichten, Logs und
serialisierter History herausgefiltert (`_filter_sensitive_data`, Ersetzung durch
`<secret>key</secret>`).

```python
card = json.loads(Path(card_file).read_text())["card"]
agent = Agent(
    task="Complete the checkout with the stored payment details.",
    llm=llm,
    sensitive_data={
        "https://*.press.stripe.com": {          # domainweise begrenzen
            "x_card_number": card["number"],
            "x_card_cvc":    card["cvc"],
            "x_card_exp":    f"{card['exp_month']:02d}/{str(card['exp_year'])[-2:]}",
            "x_postal":      card["billing_address"]["postal_code"],
        }
    },
    browser=Browser(allowed_domains=["press.stripe.com", "*.press.stripe.com"]),
)
```

Wir haben die Domain-Klammer schon: `domain_scope()` /
`allowed_domains` in `agent/src/cowork_agent/browser.py:756` bindet den Lauf an
den Host der Start-URL. Der Zahlvorgang muss dieselbe Klammer benutzen, und der
`merchant-url`-Host aus der Ausgabeanfrage muss **derselbe** sein wie der Host,
auf dem die Karte eingetippt wird. Diese Prüfung machen wir selbst; Link erzwingt
sie bei der Virtualkarte nicht.

Weiter: für die Zahlungsseite Vision abschalten. Ein Screenshot kann die
getippten Ziffern enthalten, und Screenshots werden nicht geschwärzt.

Danach das Ergebnis zurückmelden:

```bash
link-cli report --domain press.stripe.com --outcome success --spend-request-id lsrq_abc123
```

## 8. Wenn der Betrag im Checkout steigt

Klassiker: Steuer und Versand erscheinen erst nach Eingabe der Karte. Statt vorab
einen Puffer freigeben zu lassen:

```bash
link-cli spend-request update lsrq_abc123 --amount 7500   # neuer Gesamtbetrag, nicht die Differenz
link-cli spend-request request-approval lsrq_abc123        # Nutzer muss erneut freigeben
link-cli spend-request retrieve lsrq_abc123 --interval 2 --max-attempts 300
```

Vorbedingungen: `incremental_auth_enabled` in der Antwort, Anfrage bereits
freigegeben, Karte noch **nicht** benutzt. Ein Fehlschlag der Erhöhung macht die
vorhandenen Daten nie ungültig — im Zweifel mit dem alten Betrag weiter oder
abbrechen und neu anlegen. `--amount` ist das einzige änderbare Feld; die
Kartendaten bleiben gleich.

## 9. Grenzen, die Geld kosten

| Grenze | Wert |
| --- | --- |
| pro Anfrage | 500 USD |
| pro Tag | 500 USD |
| pro 30 Tage | 20.000 USD |
| gleichzeitig aktiv | 30 (`created` + `approved`) |
| gleichzeitig freigegeben | 10 |
| Erstellungsrate | 50/Stunde, 200/60 Tage |
| Freigabefenster | 10 Minuten |
| Gültigkeit der Karte | 12 Stunden ab Erstellung |

Die Limits gelten **pro Agenten-Integration**, nicht pro Nutzer. Bei 20+ aktiven
Nutzern ist das Tageslimit von 500 USD die harte Wand — Anhebung nur über
Stripe-Sales. Das ist der Punkt, den man vor einem Launch klärt, nicht danach.

Weitere harte Randbedingungen:

* **Agentenzahlungen sind nur für Verbraucher in den USA verfügbar.** Der
  Händler darf außerhalb der USA sitzen, unser Unternehmen auch — der *Nutzer*
  nicht. Für einen deutschen Nutzerstamm ist das heute ein Blocker. Link
  schreibt „coming soon globally", ohne Datum.
* Die Agenten-Seite von Agentic Commerce ist **Private Preview** mit Warteliste;
  der Confidential-OAuth-Client kommt über Sales. Der Device-Flow funktioniert
  ohne das, taugt aber nur für lokale Agenten, nicht für einen gehosteten Dienst.
* Einmalkarte heißt: **keine Abos, keine Nachbelastung, keine Rückerstattung auf
  dieselbe Karte im Selbstlauf.** Für wiederkehrende Zahlungen ist das der
  falsche Weg.
* Adress- und Versanddaten kommen aus `userinfo:read` bzw.
  `link-cli shipping-address list` — dafür muss der Scope mit angefragt sein.

## 10. Bedrohungen und was sie abstellt

| Risiko | Gegenmaßnahme |
| --- | --- |
| Prompt-Injection auf der Händlerseite lässt den Agenten teurer/woanders kaufen | Betrag, `merchant-name`, `merchant-url`, Line-Items kommen aus **unserem** Zustand; der Link-Freigabebildschirm zeigt sie dem Nutzer; unser eigenes `approval_request` zeigt sie ein zweites Mal |
| PAN im Transkript / Modellkontext / Log | `--output-file` statt stdout, `sensitive_data` in browser-use, Vision auf Zahlungsseiten aus |
| Karte auf einer Phishing-Seite eingetippt | `allowed_domains` auf den Host aus `merchant-url`, Abgleich Host(Checkout) == Host(Anfrage) vor dem Ausfüllen |
| Gestohlenes Access-Token | 1 Stunde Lebensdauer, nur in der Prozessumgebung, jede Ausgabe braucht trotzdem die Nutzerfreigabe |
| Gestohlenes Refresh-Token | serverseitig verschlüsselt, rotiert bei jeder Benutzung; `auth/revoke` beim Trennen |
| Agent stellt in Schleife Anfragen | unser Gate vor `spend-request create` + Ratelimits (50/h) |
| Doppelbuchung nach `POLLING_TIMEOUT` | Timeout nie als Ergebnis werten, immer erneut `retrieve` |

Der eigentliche Sicherheitsgewinn: Link gibt eine **Einmalkarte mit begrenztem
Betrag** heraus. Selbst wenn die PAN abfließt, ist der maximale Schaden der
freigegebene Betrag, und nach 12 Stunden ist sie tot. Das ist strukturell besser,
als die echte Karte des Nutzers in einem Passwortmanager liegen zu haben.

## 11. Umsetzung in CoWork

Vorgeschlagener Zuschnitt (Beads folgen, Wurzel: `cowork-w84`):

1. **Backend/OAuth** — Route `POST /link/oauth/start` + `GET /link/callback`,
   PKCE-Verifier und `state` serverseitig, Refresh-Token verschlüsselt nach
   Supabase. Analog `app/lib/services/mcp` / `oauth_bridge.py`.
2. **App** — Einstellungsseite „Link verknüpfen" neben den Secrets
   (`app/lib/pages/secrets_settings_page.dart`), Status + Trennen-Knopf.
   Nach Verknüpfung: `link-cli user-info retrieve` als Verbindungstest.
3. **Frame** — Access-Token auf dem Task-Frame mitschicken (wie `mcp_servers`),
   `docs/WIRE_CONTRACT.md` erweitern.
4. **Agent-Tool** `link_pay` — kein Freitext. Eingabe: Betrag, Währung,
   Händlername, Händler-URL, Kontext, Positionen. Es kapselt: unser
   `approval_request`, `spend-request create`, Polling, `retrieve --output-file`,
   Rückgabe **nur** eines Datei-Handles plus geschwärzter Metadaten an das Modell.
5. **Browser-Übergabe** — der Checkout-Lauf bekommt die Karte über
   `sensitive_data`, Domain-Klammer aus `merchant-url`, Vision aus.
6. **Abschluss** — `link-cli report` und Status ins Run-Ledger
   (`app/lib/services/cowork/cowork_run_ledger.dart`).
7. **Tests** — Muster liegt vor: `executor/tests/test_herenow_approval.py` fährt
   den Approve/Deny-Round-Trip über den echten Loopback. Dazu ein Stub für
   `link-cli` (JSON auf stdout) für die Zustandsmaschine aus §5, plus
   `--test`-Läufe gegen echtes Link.

Reihenfolge fürs Erste: 7 und 4 zuerst mit `link-cli auth login` (Device-Flow)
und `--test`. Damit steht die komplette Mechanik, bevor irgendwer bei Stripe
einen OAuth-Client freischalten muss.

## 12. Quellen

* [Agentic Commerce (Übersicht)](https://docs.stripe.com/agentic-commerce)
* [Link CLI](https://docs.stripe.com/agentic-commerce/link-cli)
* [Zahlungsdaten mittels Ausgabeanfragen abrufen](https://docs.stripe.com/agentic-commerce/link-cli/use-link-wallet-pay-online)
* [OAuth für die Link CLI](https://docs.stripe.com/agentic-commerce/link-cli/oauth)
* [Shared Payment Tokens](https://docs.stripe.com/agentic-commerce/concepts/shared-payment-tokens)
* [stripe/link-cli auf GitHub](https://github.com/stripe/link-cli)
* [link.com/agents](https://link.com/agents)
* [Stripe Blog: Giving agents the ability to pay](https://stripe.com/blog/giving-agents-the-ability-to-pay)
* [TechCrunch, 2026-04-30: Stripe updates Link](https://techcrunch.com/2026/04/30/stripe-link-digital-wallet-ai-agents-shopping/)
* [browser-use: sensitive data](https://github.com/browser-use/browser-use/blob/main/skills/open-source/references/examples.md)
