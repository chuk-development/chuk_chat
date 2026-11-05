---
name: trim-cot-leakage
description: Use when auditing or fixing code comments, doc comments or docs that read like a leaked reasoning transcript - session or bead citations nobody can resolve, change narration ("used to", "no longer", "now"), agent or review vantage ("session b5 landed", "the reviewer said"), self-justifying comments, control-flow narration, or hedges like "probably fine for now".
---

# Trim chain-of-thought leakage

Adapted from the deepseek-harness skill `dsh-trim-cot-leakage`.

Leaked reasoning is prose written from the vantage of the authoring session,
not of the repository: it cites things only that session could see, tells
the story of the change instead of the state, or argues with a reviewer who
has left. Agents in this repo write a lot of it into `lib/` comments and
docs (`/// landed by session b5`, `// Was: ...`, `// FIX (cowork-84):`).

This is guidance, not a script. Never trim inside `docs/notes/archived/`
(frozen) or `vendor/` / `third_party/` (not ours).

## The one test

For each suspect passage ask: **can a reader at HEAD, with no session
transcript, no chat log, no uncommitted draft, resolve every reference and
check every claim?**

- No: restate the facts that survive from the repository's vantage, then
  delete the rest.
- Yes: it is not leakage, however historical it sounds. On a current-state
  surface (reference doc, doc comment) a change story still belongs in
  `docs/notes/` (see the tier table in `docs/AGENTS.md`).

Never delete alone when the passage carries a fact. Restate the fact so it
stands at HEAD, then delete the transcript around it.

## Taxonomy

1. **Dead session citations** - "session b5", "agent 47", "coordinator 76",
   "(decision 7)", "P3", "W2", "round 4", "as discussed". If a committed
   owner exists, cite it by path (`docs/WIRE_CONTRACT.md`, "Reasoning").
   Otherwise delete the citation and keep its fact.
2. **Agent / commit vantage** - "this change adds", "the previous commit",
   "landed by", "in this PR". State the mechanism that ships.
3. **Change narration** - "used to", "no longer", "the old X", "now" as a
   contrast to a past state, "Was:", "Before:". State the present behaviour.
   A fixed regression becomes a present-tense counterfactual: "without X, Y
   happens", never "Y used to happen".
4. **Review choreography** - "CodeRabbit flagged", "the reviewer
   confirmed", "rejected in review". Keep the decision and the reason as a
   plain fact; drop who said it and when.
5. **Self-justification** - "this cast is safe because ...", "this is
   correct since ...". State the invariant that makes the code safe, or
   delete the comment if the code shows it.
6. **Derivation transcripts** - "first we X, then we Y", proofs of obvious
   branches, test walkthroughs. Delete; keep only a non-obvious contract.
7. **Hedges and planning residue** - "probably fine for now", "should be
   enough", "TODO later" with no owner. Make it a bead (`bd create`) and a
   `TODO(<bead-id>)`, or state the real bound; delete the hedge.
8. **Language slips** - German working notes (`// Hier noch ...`) in English
   comments. Translate or delete.

## What is not leakage

- **Bead and issue references** that resolve: `TODO(cowork-266)`,
  `bd show chuk_chat-lgq2`, `#1470`. Keep them.
- **Commit hashes and dates in `docs/notes/`** - that is the sanctioned home
  for change history.
- **Suppression reasons** - `// ignore: x - reason`, empty-catch reasons. Fix
  a false reason, never delete it.
- **Counterfactual regression pins** - "without the lock, two writers tear
  the row".
- **Measured bounds** - "(measured: 4x on real chats)" next to a constant.
  The word "measured" carries the evidence.
- **Runtime old/new** - "the old socket drains before the new one accepts" is
  lifecycle, not history.
- **Protocol versions** - `/v1/models_info`, payload `v3`, envelope `"v":"2"`
  are identifiers.

## Workflow

1. Get an explicit scope (files or a directory). Never sweep the whole tree
   unasked; other agents edit `lib/` in parallel.
2. Audit read-only first. Probes (they over-match; judge every hit):

   ```sh
   rg -n -i '\bsession [a-z0-9]{2}\b|\bagent [0-9a-f]{2}\b|landed by|coordinator' lib docs --glob '!docs/notes/archived/**'
   rg -n -i '\bused to\b|\bno longer\b|\bthe old\b|\bpreviously\b|//\s*(was|before):' lib
   rg -n -i '\bthis (pr|commit|change)\b|previous commit|in review|coderabbit (flagged|said)' lib docs --glob '!docs/notes/archived/**'
   rg -n -i 'probably|should be enough|for now|hopefully' lib
   ```

   Calibrate each probe on a known hit and a near miss before trusting a zero
   count. Then read the densest prose in scope (service headers, doc
   comments) without a pattern.
3. Before deleting, list the passage's facts. Check the traps: do not turn
   an obligation into a suggestion, a plan into a shipped feature, or drop
   the evidence ("measured") behind a number.
4. Fix: comments in place; user- or model-visible strings
   (`lib/l10n/`, prompts in `lib/services/tool_prompt_builder.dart`,
   `assets/skills/`) only with evidence that the wording change is wanted.
5. Verify: rerun the probes, expect only the keeps above; then
   `flutter analyze <touched files>` and `dart run tool/verify_doc_refs.dart`
   for doc edits.
