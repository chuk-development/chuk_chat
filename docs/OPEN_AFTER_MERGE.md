# Open after the merge (2026-09-18)

What is started and not finished. The merge itself lives in the scratch clone
`/home/user/git/agents-merge`, branch `agents-integration`, mid-merge and
untouched. Nothing is pushed. `docs/MERGE_INTO_CHUK_CHAT.md` holds the runbook,
the execution log and the measured gate.

## Decisions only the owner can make

**1. The client-side tool loop.** `tool_call_handler.dart` is 1998 upstream lines
against a 321-line Agents stub, because tools run on the host. 21 test failures
in five upstream files describe the loop that is gone. Either it comes back
behind a flag, or those files go. A chuk_chat user with no host paired currently
gets no client-side tool loop at all. Bead is open.

**2. The host typing bubble and the rest of the MERGE NOTE.** `chat_ui_mobile.dart`
was rebuilt on upstream's shared mixin family, which dropped messenger-mode
rendering and the host typing bubble, the reply preview, the multi-message
composer outbox, this screen's reactions toggle, `MessageDecodeCache` and the
payment dialog. `agents_thread_view_test` fails on the key `host-run-typing`:
the test is right, the code is missing. Decide per item whether it returns on
upstream's decomposition or stays only in `agents_thread_view`.

## P1 beads — must be closed before stage 7

**3. Chats are written to the wrong table.** The facade reads chuk_chat chats
from `encrypted_chats` and writes them through `AgentsChatStore.replaceThread`,
whose cloud step targets `cowork_chats`. Local memory and the SQLite cache hide
it, so it looks fine in testing; the cloud copy of an edited chat lands in the
Agents table and the user's other devices never see the edit. Fix: route by id
shape in the facade.

**4. Offline messages enqueue in one queue and drain from another.**
`OfflineSendCoordinator.enqueue` routes to `AgentsTaskOutbox`, while
`OfflineRetryManager` and `OfflineSendExecutor` drain `OfflineQueueService`. For
a chuk_chat user with no host paired, a message typed offline is never sent.

**5. The beads database has to move.** `.beads/config.yaml` and
`.beads/metadata.json` were restored to chuk_chat, so every `cowork-*` id is
unreachable from the merged checkout until the `cowork` Dolt database is
imported into `chuk_chat` at the Dolt level. That is not a file edit. 241 ids,
including every one the docs quote. `.beads/interactions.jsonl` already holds
the union of both id spaces and they do not overlap.

## Mechanical, no decision needed

**6. About 15 test expectations** describe the Agents-only tree and now meet the
merged one. `messenger_shell_test` looks for the text "Chuk Chat" (the wordmark
is upstream's SVG again); `settings_page_test` asserts the hub lists only the
Agents areas and now finds upstream's rows too. The merged behaviour is the
intended one, so the tests move.

**7. About 25 pixel baselines** have to be re-taken and read once by a human:
`every_screen_layout_test` (15), `document_chart_golden_test` (4),
`mobile_preview_test` (4), `model_selector_design_test` (2).

**8. `executor/test_regenerate.py::test_four_retries_replay_the_question_once`**
fails on the branch with no upstream code present. Pre-existing, needs its own
fix.

## Then

**9. Stage 7, the push to master.** Commands are in section 9 of
`docs/MERGE_INTO_CHUK_CHAT.md`. It is the point of no return; everything before
it dies with `rm -rf` on the clone. After it: delete the `agents` branch, work on
master, `FEATURE_AGENTS` decides what ships.

**10. The image workflow cannot run yet.** `.github/workflows/images.yml` is
committed, but GitHub only offers `workflow_dispatch` for workflows on the
default branch, so `agents-base` and `agents-browser` reach ghcr.io only once
the merge lands (or through a separate small pull request).

**11. Wire the config into its consumers.** `agents/common/chuk_agents_config`
is built and tested but nothing reads it yet; the packages still read
`AGENTS_*` / `COWORK_*` directly. After that: `cowork config get|set|edit`, and
`install.sh` writing tag and digest into `[sandbox]`.

## State of the gate

analyze 24 issues / 1 error (the deliberate one) · Python 1897 passed, 1 failed ·
Flutter 2885 passed, 64 failed. Upstream's suite alone is 1553 passed, 0 failed,
so none of the 64 is inherited.
