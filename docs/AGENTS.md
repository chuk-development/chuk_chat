# docs/AGENTS.md — where a fact goes

Rules for writing and placing documentation in this repository. The root
`CLAUDE.md` (and its symlink `AGENTS.md`) holds the standing orders; this file
holds the rules for the `docs/` tree.

## One home per fact

Every fact has one home: the tier whose job it is. Everywhere else, link to
that home. Do not copy it.

| Tier | Job | Does NOT belong there |
|---|---|---|
| `CLAUDE.md` (root) | Standing orders: rules an agent needs in every session. One to three lines each, with a link to the home of the detail. | Stories, worked examples, long procedures, anything already said in a linked doc. |
| `docs/ARCHITECTURE.md`, `docs/FILE_MAP.md` | The map: services, state, platform split, where each file lives. Read before a structural change. | Decision rationale (→ `docs/notes/`), status ("done", "planned"), bug stories. |
| `docs/GOTCHAS.md` | Review rules: traps this code base has fallen into, each as a rule plus the reason. | Incident narratives (one sentence of cause is enough), how-tos. |
| `docs/CONVENTIONS.md` | Code conventions (naming, tests, logging, formatting). | Workflow rules (tests, CodeRabbit, commit, push: those are in `CLAUDE.md`). |
| Topic references (`docs/CHAT_PAYLOAD_FORMAT.md`, `docs/MCP_CONNECTORS.md`, `docs/PERFORMANCE.md`, ...) | The current contract of one subsystem. | History of how it got there (→ `docs/notes/`). |
| `docs/notes/proposed/`, `implemented/`, `rejected/` | Decision records: why, what was given up, how to verify. See `docs/notes/README.md`. | Migration checklists and "should" once the decision shipped. |
| `docs/notes/archived/` | Frozen history: handovers, session prompts, status and overnight reports, reviews. | Anything current. Never edit; never cite as current authority. |
| `docs/COMMON_TASKS.md` (cookbook) | Step-by-step how-tos with a check at the end. | Design rationale (link the note). |
| `.agents/skills/<name>/SKILL.md` | Procedures an agent loads on demand (pre-push checks, CoT-leak trim, beads). | Standing orders (→ `CLAUDE.md`). |
| `tasks/lessons.md` | Corrections from the owner, as rules. | Session logs. |

New dated session files (`HANDOVER_*`, `PLAN_*`, `STATUS_*`, ...) go into
`docs/notes/`, never into the top of `docs/`.

## Word budgets

`scripts/doc_budgets.json` sets a word ceiling for `CLAUDE.md`,
`docs/CONVENTIONS.md`, `docs/GOTCHAS.md` and this file.
`test/repo_checks/doc_budget_test.dart` fails when a file goes over. When it fails:

1. **Move** content that belongs in another tier (table above). Leave a
   one-line link.
2. **Condense** content that belongs here but can be shorter.
3. **Raise** the ceiling only when the words really need the room. Put the
   reason in the commit message.

## References

Write repository paths in backticks, from the repository root
(`lib/services/encryption_service.dart`), or as relative Markdown links.
`dart run tool/verify_doc_refs.dart` checks both; `test/repo_checks/doc_refs_test.dart`
runs it in `flutter test`.

## Slop checklist

Look for these in every doc you touch:

- **Duplicated rules.** Search a distinctive phrase. Keep one home, link the
  rest.
- **History outside `docs/notes/`.** State the current fact; link the note
  that has the story.
- **Status annotations** in prose ("implemented!", "future: ...", "TODO
  later"). Status rots; the code and `bd` carry it.
- **Hand-written inventories** of tests, files or flags when the source or a
  generator is authoritative. Link the source.
- **Reasoning transcripts**: step-by-step narration of how a change was made,
  proofs of obvious branches, test walkthroughs. Keep the resulting rule;
  delete the path to it. See `.agents/skills/trim-cot-leakage/SKILL.md`.
- **The same rationale** next to several sibling functions. Say it once, at
  the owner.
- **Paragraph walls**: one paragraph with several rules and asides. Split it.
- **Emphasis inflation**: bold, CAPS or "CRITICAL" everywhere means nothing
  stands out. Keep emphasis for the clause that changes behaviour.
- **Spec-speak in `implemented/` notes**: "should", migration plans,
  acceptance checklists. An implemented note says what is.
