# Handover: User wurde aus der Agents-App ausgeloggt (Bead cowork-2n1)

Session: cowork-9e, 2026-09-05. Status (Entscheidung Koordinator cowork-76): Code + Tests fertig (91/91, analyze clean), Live-DoD (Screenshots vorher/nachher, Neustart-nach-Ablauf-Beweis) ist Nachlauf nach 'Bildschirm frei' und dem naechsten gebuendelten App-Neubau durch 5c. Bead cowork-2n1 bleibt bis dahin offen. Nichts committet.

## Befund (belegt)

Zeitachse (echte Uhr, CEST):

| Zeit | Ereignis | Beleg |
|---|---|---|
| bis 03:21:27 | Alter Host-Prozess 2303591 (pre-c91: Host refresht das GETEILTE Token-Paar selbst) laeuft | ps, Aussage 47, Commit-Text 6eab6b2 |
| 03:21:27 | Neuer Host 3901507 mit c91 (6eab6b2) startet, hat noch kein Token | ps, .hostlive |
| 03:22:31 | App 3913977 startet, laedt Session S0 von Platte (Access-Token noch gueltig), provisioniert Host ("token provisioned") | flutter-hot run.log, .hostlive |
| ~03:23 | Send-Pfad ruft `SupabaseService.refreshSession()` ("supabase.auth: INFO: Refresh session"). Kein Fehler-Print, KEIN neuer Token-Frame an den Host -> gotrue-Stillpfad "refresh_token_already_used, Session noch gueltig" | run.log (kein "Session refresh auth error"), .hostlive (nur ein Frame nach provisioned) |
| ~03:18 | Access-Token hatte 7,8 min Restlaufzeit (Probe-Abbruch bei 47) -> S0 laeuft ~03:26 ab | Aussage 47 |
| ~03:26 | gotrue Auto-Tick refresht ab 90 s vor Ablauf, GoTrue lehnt ab (Token verbraucht), nach Ablauf greift die Ausnahme nicht mehr -> `_removeSession()` + `signedOut(sessionExpired)` -> AuthGate zeigt LoginPage | gotrue-2.27.1 `_doRefresh`, `_autoRefreshTokenTick` |
| 03:26:43 | User loggt sich per Passwort neu ein (neue session_id, `last_sign_in_at` = 03:26:43) | shared_preferences.json |

Wer den Refresh-Token vor 03:23 verbraucht hat, ist nicht mehr beweisbar (Log
des alten Hosts ueberschrieben, kein GoTrue-Serverlog). Ausgeschlossen: 47's
Probe (Rotationsschutz war vor dem ersten Lauf drin, kein /token), 5c's
App-Instanzen (nie parallel). Kandidaten: der alte Host pre-c91 (genau das
Verhalten, das c91 abgestellt hat) oder die unbekannte Instanz 3872829.

Kernmechanik, unabhaengig vom Verbraucher: **gotrue-dart loescht bei jedem
nicht-retrybaren Fehler eines /token-Calls die lokale Session und feuert
`signedOut(sessionExpired)`** (`_doRefresh`). Einzige Ausnahme: Code
`refresh_token_already_used` bei noch gueltigem Access-Token. Jeder vermeidbare
/token-Call ist also eine Logout-Chance, sobald irgendwer sonst den
Refresh-Token verbraucht hat. Und GoTrue's Reuse-Detection kann bei so einem
Call die ganze Session-Familie (Host + App) beenden.

## Fix (App-Seite, Dateien von cowork-9e)

| Datei | Aenderung |
|---|---|
| `app/lib/services/account_session.dart` | `SupabaseAccountSession.refresh()`: Netz-Refresh nur bei <= 60 s Restlaufzeit (`refreshHeadroom`), sonst aktuelle Session ohne Netz. Nach abgelehntem Refresh: Restore per `setSession(refresh, accessToken:)` (geht ueber /user, verbraucht nichts), solange der Access-Token gueltig ist. Kollaboratoren injizierbar. |
| `app/lib/services/session_recovery.dart` (neu) | `SessionStash.setAsideExpiredSession()`: vor `Supabase.initialize` eine ablaufende persistierte Session beiseite legen (crash-sicher unter `agents.session_stash_v1`). `SessionRecovery.run()`: Relay reconnect ohne Code -> stale Paar provisionieren -> Host flusht `account_session_rotated` (adoptieren) oder fragt `reprovision_request` (dann eigenen Token ausgeben, aber NIE nach gemeldeter Rotation) -> Fallback eigener Token bei unerreichbarem/stummem Host -> null nur, wenn alles tot ist. |
| `app/lib/services/session_refresh_scheduler.dart` (neu) | Ersetzt gotrue's Auto-Refresh: 30-s-Tick, Refresh bei <= 60 s; bei `hostAttached == false` erst `reconnectHost` (10 s), dann eigener Refresh; laeuft durch gotrue, also feuert `tokenRefreshed` -> Relay-Client re-provisioniert (c91 bleibt). Resume-Hook fuer Laptop-Aufwachen. |
| `app/lib/services/supabase_service.dart` | `autoRefreshToken: false` + `SessionRefreshScheduler.instance.start()` (6 Zeilen; Manifest-Kommentar in `tools/chat_ui_manifest.txt`). |
| `app/lib/widgets/auth_gate.dart` | StatefulWidget: Startup-Stash und `signedOut(sessionExpired)` starten die Recovery (Wartescreen "Reconnecting to your host"), LoginPage erst, wenn nichts mehr zu retten ist. `userInitiated` geht direkt zur LoginPage. Test-Seams fuer Stream/Session/Recover/Shell/Login. |
| `app/lib/main.dart` | 6 Zeilen: Import + `await SessionStash.setAsideExpiredSession();` vor `SupabaseService.initialize()`. |
| `app/lib/services/agents/agents_relay_client.dart` (47, eingebaut) | `_adoptRotatedSession` nutzt `setSession(refresh, accessToken: access)` -> /user statt /token, ein abgelehntes Host-Paar loescht die eigene Session nicht mehr. |

| `app/lib/services/agents/agents_relay_client.dart` (9e, nach 84) | Scheduler-Hooks: Ctor-Param `scheduler` (Default `SessionRefreshScheduler.instance`), `_publishAttachment` in `_set` (paired -> `hostAttached=true` + `reconnectHost=_reattach`; closed/error mit Trust -> `false`), `_reattach` = reconnect mit gespeichertem Trust + `provisionAccount(current)`, `dispose` zieht nur die eigenen Hooks zurueck. |

Tests (alle gruen, ein Lauf, 91/91): `test/services/account_session_test.dart` (12), `test/services/session_recovery_test.dart` (16), `test/services/session_refresh_scheduler_test.dart` (8), `test/widgets/auth_gate_test.dart` (7), `test/services/agents/agents_relay_client_test.dart` (48, davon 2 neu fuer die Hooks). `flutter analyze`: 0 Befunde in diesen Dateien.

## Alle Pfade, die gotrue `signedOut` ausloesen koennen, und ihr Abfang

| # | Pfad | Ausloeser | Vorher | Jetzt |
|---|---|---|---|---|
| 1 | `_autoRefreshTokenTick` -> `/token` mit verbrauchtem Token, Access-Token abgelaufen | gotrue-Timer | Logout (der Vorfall) | Timer AUS (`autoRefreshToken: false`). Scheduler refresht erst bei <= 60 s und laesst bei getrenntem Host erst den Relay-Client reattachen/adoptieren (Hooks eingebaut). Schlaegt der Refresh fehl: Restore solange Access-Token gueltig; ist er abgelaufen -> `signedOut(sessionExpired)` -> AuthGate-Recovery ueber den Host -> LoginPage nur, wenn Host + eigener Token tot. |
| 2 | `recoverSession` beim Start mit abgelaufener persistierter Session | App-Start nach > 1 h Abwesenheit, Host hat detached rotiert | Logout beim Start, plus Familien-Kill durch Reuse-Detection | Session wird VOR `Supabase.initialize` beiseite gelegt (Stash), gotrue sieht sie nicht; AuthGate-Recovery holt das Host-Paar; kein blinder /token. |
| 3 | `refreshSession()` explizit (Send-Pfad, 401-Handler in chuk-Code, `SupabaseAccountSession.refresh`) | App-Code | Logout bei abgelehntem Refresh | Host-Anfragen: Refresh nur bei <= 60 s + Restore. chuk-verbatim-Aufrufer (`SupabaseService.refreshSession`) bleiben unveraendert; ihr Refresh ist bei gueltigem Access-Token per `already_used`-Ausnahme still, bei abgelaufenem greift Pfad 1/Recovery. |
| 4 | `setSession(refreshToken)` in `_adoptRotatedSession` | Host meldet rotiertes Paar | Logout, wenn GoTrue das Host-Paar ablehnt | `setSession(refresh, accessToken:)` -> /user, nichts verbraucht, nichts geloescht (47 eingebaut). |
| 5 | `_answerReprovisionRequest` mit reason token_expired/refresh_failed -> `source.refresh()` | Host-Frame | erzwungener /token | Pfad 3: nur bei <= 60 s, sonst aktuelle Session; Host wartet per `mark_reprovisioned` auf den naechsten Refresh der App. |
| 6 | `signOut()` userInitiated (Settings, Shell-Button, chat_ui_mobile) | User | LoginPage | unveraendert, gewollt; AuthGate prueft `signOutReason`. |
| 7 | `recoverSession` mit kaputter persistierter Session (`sessionMissing`) | korrupte Prefs | LoginPage | unveraendert (nichts zu retten). |
| 8 | Broadcast-Channel `SIGNED_OUT` | nur Web | n/a auf Desktop/Mobile | unveraendert. |
| 9 | `EncryptionService.clearKey()` | nur in `AuthService.signOut()` | kein Logout-Ausloeser (Schluessel, nicht Session) | unveraendert; "Encryption key is not available" ist Bead cowork-6v5 (5c). |

## Offen

- Relay-Client-Hooks: EINGEBAUT (siehe Tabelle). P8-Review F4 (f7): `_onSocketDone` cancelt `_sub` und nullt `_socket`, `_reattach` hat einen Guard bei laufendem Dial; `reconnectHost` nach Host-Drop wirft damit nicht mehr (relay_client 51/51). F5 (f7): der Rotated-Fallback ohne userId ackt nicht mehr; die Recovery ist davon unberuehrt, ihr `current()` liefert den Stash mit userId. Restluecke: `_reattach` haengt am gespeicherten Trust des Clients; ein Client ohne erfolgreiche Pairing (Trust null) meldet nichts, dann refresht der Scheduler direkt (Regel 3).
- Live-Beweis in der laufenden App (Neustart nach Ablauf mit detached Host) und Screenshots vorher/nachher: Bildschirm war gesperrt/schwarz; `gnome-screenshot -f` liefert nur Schwarz, bis "Bildschirm frei".
- Host-Seite (Python, nicht 9e): Host flusht die rotierte Session heute nur beim Provision-Frame (`_flush_pending_session_rotation` in der Provision und in `_on_reprovision`). Die Recovery provisioniert deshalb das stale Paar; der Host ersetzt sein Session-Objekt damit kurzzeitig, bekommt aber per Ack sofort das adoptierte Paar zurueck. Sauberer waere ein Flush direkt beim Controller-Attach (reconnect-confirm), dann braucht die Recovery kein stale Provision. Vorschlag fuer die Python-Committer-Rolle.
