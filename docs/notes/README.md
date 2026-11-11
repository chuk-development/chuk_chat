# docs/notes — decision records and session history

A note records one decision or one work session: why it was done, what was
given up, and how to verify it. Reference docs (the ones in the Docs Index of
`CLAUDE.md`) describe the current system; notes do not.

## Folders

| Folder | Holds | Can change? |
|---|---|---|
| `proposed/` | A design that is not built yet. | Yes. Edit it while the decision is open. |
| `implemented/` | A decision that shipped. Write it in present tense: what the code does, not what it "should" do. | Yes, keep it true when the code changes. |
| `rejected/` | A design that was decided against, with the reason. | Only to add a later reason. |
| `archived/` | Frozen history: handovers, session prompts, status reports, overnight logs, reviews. | **No.** Archived notes are never current authority and are not edited. |

When a proposed note ships, `git mv` it to `implemented/` and rewrite the
"should" parts as present-tense facts. When an implemented note stops being
true, move it to `archived/` and put the current facts in the reference doc
that owns them.

## File names

`yyyy-mm-dd-<kind>-<topic>.md`, all lower case, words joined by `-`. The date
is the day the note was written. `<kind>` is optional for new notes
(`plan`, `handover`, `review`, `proposal`, `status`, `session`, `prompt`,
`overnight`). Example: `2026-09-09-plan-cloud-pairing-transport.md`.

Do not put new dated session files (`HANDOVER_*`, `PLAN_*`, `STATUS_*`, ...)
at the top of `docs/`. They go here.

## Links

Link a note with its repository path, for example
`docs/notes/implemented/2026-09-09-plan-cloud-pairing-transport.md`.
`dart run tool/verify_doc_refs.dart` checks that such paths exist; it skips
the contents of `archived/`, because frozen notes can point at files that are
gone.
