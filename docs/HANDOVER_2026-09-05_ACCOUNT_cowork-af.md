# Handover — account page, credits, coworker names (session cowork-af, 2026-09-05)

Beads `cowork-4ih` (credits in the footer, Account settings 1:1 chuk) and
`cowork-817` (rename a coworker, create one with a name, chuk's input).
Both are claimed, both are CODE-COMPLETE and COMMITTED; the live proof after
an app rebuild and a host restart is the only thing left.

## Commits

| hash | what |
|---|---|
| `b21dd18` | Dart: chuk account page + services restored from the manifest, `credit_display.dart` original again, footer pill = chuk's `_buildFooterRow` (profile name + `BalanceBadge`), rename/create dialog, `agent_create` / `agent_rename` / `agent_list` on the controller, roster merge. Also carried f5's browser-presence hunks and 18's skills frames (named in the body). |
| `39b8fcf` | Dart: `requestAgentList` waits on the provision gate like a replay (Host #6 finding: the request reached the host before the account token and was dropped, and nothing asked again). relay_client_test 52. |
| `13f3ee4` | Python: `cowork_host/coworker_names.py` (store + frame handler), executor `on_agent_frame`, protocol helpers, host/serve wiring, 6 tests. Committed from a private index (`GIT_INDEX_FILE`) so the foreign uncommitted hunks in `executor.py` / `host.py` / `serve.py` (`account_session_provider`, `skills_seed_root`) stayed out. |

## 4ih — what the user sees

- Sidebar footer pill (`widgets/agent_roster_view.dart`, `_footerRow`): the
  profile display name (chuk's `_loadProfile` / `_displayNameFor`, verbatim),
  then the credit pill (`BalanceBadge` inside the accent @0.20 container,
  chuk's exact styles), then the gear. The badge and the profile fetch are
  gated on `SupabaseService.isInitialized` (`_hosted`): a widget test has no
  session and gets chuk's pill minus the badge. The badge reads chuk's hosted
  account API through `ApiConfigService` (api.chuk.chat) and the Supabase
  `user_billing` realtime channel — the same code as chuk, nothing CoWork-own.
- Settings → Account opens chuk's `AccountSettingsPage` (780 lines verbatim):
  profile name/e-mail, change password, reset/recover (`recover_chats_page`),
  key version, delete account. There is deliberately no second sign-out on
  it: chuk keeps sign-out in the settings modal footer, so does CoWork
  (`widget_test` asserts one `Icons.logout`).
- Manifest: the ten files are listed under "Account settings + credits" in
  `tools/chat_ui_manifest.txt`. They were tracked already (the verbatim import
  commit f22a189 had them); the working tree had deleted/stubbed them. DO NOT
  run `scripts/import_chat_ui.sh` wholesale — it would overwrite 9e's
  `supabase_service.dart` deviation (`autoRefreshToken:false`) and 5c's
  `chat_scroll_mixin.dart`; copy single files with the script's two `sed`
  rules instead.

## 817 — what the user sees

- Row menu (`_AgentTile`, `PopupMenuButton`): Rename · Hide · Delete. Rename
  opens `showCoworkerNameDialog` — chuk's `_renameChatDialog` shape
  (`AlertDialog`, one autofocused `TextField` with label/hint, Cancel + submit;
  Enter submits). The controller lives in the dialog's own `State` (chuk
  disposes it right after `showDialog`, which trips "used after dispose"
  during the route's exit animation under a widget test).
- New coworker (rail row, top-right, phone list) opens the same dialog with a
  suggested adjective-noun name pre-filled; the old `AgentOnboardingSheet`
  (role/brief/schedule form) and its test are deleted. Role and brief are
  still fields on `CoworkAgent`, just no longer asked at creation.
- Persistence: `CoworkShellHost._renameAgent` / `_openOnboarding` update the
  `LocalAgentRosterSource` first, then send `agent_rename` / `agent_create`
  through `CoworkRelayController`. `_onPaired` sends an `agent_list` request;
  the answer (`CoworkRelayAgentList` on `CoworkRelayLink.instance.inbound`)
  goes through `AgentRosterSource.applyHostNames`: known id → renamed,
  unknown id → added with its one permanent thread, `host: true` entry →
  renames the `host:<peerDeviceId>` row, ids deleted in this session are
  skipped (`_deletedAgentIds`; delete is not on the wire yet — bead if it
  matters). A list never removes anything.
- Host: `coworker_names` table in `roster.db`, own connection
  (`check_same_thread=False` + lock, the executor's serve thread answers the
  frames). The running agent's `RosterStore` row is never touched — its
  `name` is the workspace directory. `host_agent_id()` is
  `host:cowork-host` (`HOST_DEVICE_ID`), which is the `peerDeviceId` the app
  pairs with, so a host-agent rename lands on the right roster row.
- Contract: `docs/WIRE_CONTRACT.md` "Coworker names".

## Tests (all green at commit time)

`agent_roster_view_test` 28 (rename dialog ×3, `renameAgent`, `applyHostNames`
×2), `messenger_shell_test` 55 (create dialog, cancel, rename → host,
`agent_list` merge with a deleted id), `widget_test` 3; `host/tests/
test_coworker_names.py` 4, `executor/tests/test_automations.py` +2; scoped
`flutter analyze` 0 errors; ruff clean. Host suite: `test_local_run` 14/14
alone and with `test_automations_e2e`; in the FULL host run the same 14 fail
("controller received no frames") — an order effect from an earlier test
file, present before and after this session's change; bisect was running at
handover (relay+serve group first).

## Open — the live proof (needs "Bildschirm frei")

1. Host restart with 13f3ee4 and an app rebuild with 39b8fcf (the running host predates `agent_list`: the app
   will get `error: unknown payload type 'agent_list'` on pair until then —
   harmless, the roster just keeps the device id).
2. App rebuild (c6 holds the instance).
3. Check: footer shows the profile name + credits (compare with chuk_chat
   running on the same account); Settings → Account is chuk's page; row menu
   → Rename → name changes; New coworker → dialog → name; restart the app →
   names come back from the host. Screenshots → `docs/screenshots/af/`
   (gnome-screenshot + convert crop, see 5c's handover), then `SendUserFile`.
4. `bd close cowork-4ih cowork-817`.

## Traps

- Adding a subclass to the sealed `CoworkRelayInbound` breaks three
  exhaustive switches (`cowork_thread_view` `_onInbound`, `cowork_replay_loader`
  `_handle`, `websocket_chat_service`). Add the `case` in the same step or the
  tree stops compiling for everyone (it did, for ~10 minutes, together with
  18's `CoworkRelaySkillsList`).
- `serve.TaskServer` is a wrapper with an explicit kwargs list: a new
  `Executor` kwarg must be added there too, or the host logs "could not start
  task server: TypeError" and every local-run test sees no frames.
- A commit from a private index (`GIT_INDEX_FILE`) leaves the SHARED index's
  entries for those paths at the old HEAD content: a later pathspec-less
  commit by anyone would silently revert the hunks. After such a commit,
  refresh those paths (`git reset -q -- <paths>` is safe only when the index
  entry equals `HEAD~1:<path>`, i.e. nobody staged there; checked per path).
