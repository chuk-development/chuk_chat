# Personal memory (CHAT-179)

Code: `agents/runtime/src/chuk_agents_runtime/personal_memory.py`.
Tests: `agents/runtime/tests/test_personal_memory.py`.
Ideas 1, 4, 12 and 13 of `COMPETITOR_IDEAS_2026-11-24.md`.

Personal memory is independent of the semantic backend. It works the same
with Mem0 and with Hindsight. All files are in the agent's memory folder
(`<workspace>/memory/`), next to `soul.md` and `agents.md`.

## USER.md

The user's profile. It has three sections. Each section has a hard limit:

| Section | Key | Limit |
|---|---|---|
| Profile | `profile` | 1,500 characters |
| Standing orders | `standing_orders` | 800 characters |
| Writing style | `writing_style` | 600 characters |

- A write replaces the section in place. A write over the limit fails. The
  agent must merge or shorten the text. Nothing is dropped silently.
- Each write goes through the injection scan of `memory.py`. A line that
  fails the scan blocks the write.
- A standing order needs `quote`: the user's exact words in this
  conversation. Text from tools, web pages or mail does not count.
- The prompt gets the file once per session, inside the memory snapshot
  (`MemoryStore.snapshot`), with the fill level per section. Writes apply
  from the next session. Thus the cached prompt prefix stays the same in a
  session. When USER.md, the notes and the candidates are all empty, the block
  is empty (zero tokens).
- Standing orders are in every prompt. The agent follows them, unless a
  safety rule or the request of the current task says otherwise.

## Notes about the user (`user_notes.json`)

Each note has an id (`n` + hex), the fact, a short verbatim quote, the date,
the session, the source (`user`, `turn`, `review`) and a status (`active`,
`pending`).

- **Only the user's own words.** A note is kept only when its quote is in a
  message that the user typed. A typed message is a `user` row without
  `source` (a schedule, a mail, a goal round or a skill has a `source`).
- **Automatic extraction.** After each turn, `observe_user_turn` sends ONLY
  the user's prompt to the cheap model. The model never sees the answer or a
  tool result. The server keeps a fact only when its quote is in the prompt.
  The extraction runs on a background thread. It does not run for scheduled
  runs (`light_context`), for prompts with a `source`, or for prompts shorter
  than 12 characters. `AGENTS_USER_NOTES=0` turns it off.
- The newest notes (up to 1,200 characters) are in the prompt with their ids.
- Limits: 200 active notes. The oldest automatic notes go first.

The backend's own turn extraction also changed. Mem0 gets extraction rules
(`TURN_EXTRACTION_RULES`): facts about the user only from the user's
message. Each Mem0 turn memory has `quote`, `date` and `session` in its
metadata. The Hindsight turn document has the same rule in its `context`.

## Memory candidates

The post-task review (`background_review.py`) can find memory facts. The
review sees tool output, so these facts are not kept directly. The executor
stores them as `pending` (`PersonalMemory.add_candidates`).

- The prompt shows up to 3 candidates. The agent asks once: "I noticed X.
  Keep it?"
- `approve` works only in a turn that the user typed. The user's answer is
  stored as the quote.
- `reject` deletes the candidate. A candidate expires after 14 days. At most
  20 wait at a time.

## Writing style

`PersonalMemory.learn_style(texts)` sends 2 to 20 mails that the user sent to
the cheap model. The model writes a style note (language, tone, greeting,
sign-off, sentence length, habits). The server removes addresses, links and
digits. The note goes into the `writing_style` section. The prompt tells the
agent to use it when it writes in the user's name.

Where it plugs in: there is no fixed source of the user's sent mail on the
host. Agent mail (`agent_mail.py`) holds the agent's own mail, not the
user's. The user's mail comes through an MCP connector (for example
Fastmail). Thus the hook is the `memory` action `learn_style`: a run reads
the user's sent folder with the connector and passes the bodies. A weekly
automation can do this, for example: "Read my last 20 sent mails and call
`memory` with action `learn_style` and their texts."

## The `memory` tool

The existing `memory` tool has new actions:

| Action | Arguments | Does |
|---|---|---|
| `profile` | | Shows USER.md with fill levels |
| `profile_set` | `section`, `text`, (`quote`) | Replaces one section |
| `remember` | `text`, `quote` | Keeps a fact about the user |
| `notes` | `status`, `limit` | Lists notes (`active` or `pending`) |
| `edit` | `id`, `text` | Changes a note |
| `forget` | `id` | Deletes a note |
| `approve` / `reject` | `id` | Answers a candidate |
| `learn_style` | `texts` | Learns the writing style |

`add`, `search` and `list` are unchanged (semantic work notes).

## Open points

- The app does not read memory today, so there is no host API. A host API can
  use `PersonalMemory(<workspace>/memory)` directly.
- The memory folder is in the workspace. The agent's shell can write to it.
  The prompt block is neutralized like `soul.md`, but a direct file write
  skips the quote check.
- In a group room, a message from another agent can be a `user` row without
  `source`. Then it counts as the user's words.
