---
name: typst-authoring
description: How to build a PDF with typst_compile — the PDF is shown to the user automatically (never try to send it), a known-good skeleton, the Typst syntax traps that cause compile errors, and how to update or start a second doc. Use when writing Typst for a paper, report, invoice, CV, or math PDF.
allowed-tools: typst_compile
metadata:
  version: "1.0"
---

# Typst authoring

`typst_compile` turns a Typst document into a PDF. Use it for anything with a
real layout — a paper, report, invoice, CV, cover letter, or math-heavy text.
Typst is the modern LaTeX; the source is compiled in a server sandbox and the
PDF is saved as an artifact.

## Delivery: the PDF is already handed over

When `typst_compile` succeeds, the app **immediately shows the user a
downloadable artifact card** (Download + Open buttons) in the chat. Calling
the tool *is* the delivery. There is nothing left to do to give the user the
file.

So after a successful compile:

- **Do NOT call `send_file_to_user`.** The PDF is not a sandbox file — it lives
  as an artifact. `send_file_to_user` will fail with "path must be under
  /home/sandbox" and send you chasing a file that does not exist.
- **Do NOT use the sandbox** (`code_run`, `bash`, `sandbox_list`) to find,
  copy, or send the PDF. It is not there.
- **Do NOT** write the file anywhere or describe a path. Just tell the user in
  one line that the document is ready above, and stop.

The only thing that delivers a Typst PDF is `typst_compile` itself.

## Start from this skeleton

Begin every document with the setup rules, then write content:

```typst
#set page(paper: "a4", margin: 2cm)
#set text(font: "New Computer Modern", size: 10.5pt, lang: "de")
#set par(justify: true, leading: 0.6em)
#set heading(numbering: "1.1")

= Title

== Section

Body text goes here.
```

Set `lang` to the document language (`"de"`, `"en"`) so hyphenation and
quotes are correct. For a plain, professional look keep one serif font, black
text, no colours.

## Typst is NOT Markdown

This is the single biggest source of errors. The syntax differs:

| You want | Markdown (WRONG here) | Typst (correct) |
|----------|----------------------|-----------------|
| Bold | `**bold**` | `*bold*` |
| Italic | `*italic*` | `_italic_` |
| Heading | `# Title` | `= Title` |
| Sub-heading | `## Sub` | `== Sub` |
| Link | `[text](url)` | `#link("url")[text]` |
| Bullet list | `- item` | `- item` (same) |
| Numbered list | `1. item` | `+ item` |
| Inline code | `` `code` `` | `` `code` `` (same) |

## The "unclosed delimiter" error — how to avoid it

Every delimiter must be balanced: `*…*`, `_…_`, `[…]`, `(…)`, `$…$`, `` `…` ``.
An odd one out anywhere in a paragraph fails the whole compile. This is the
error you will hit most.

Rules that prevent it:

- **Keep emphasis spans short and clean.** Bold a term, not a long clause:
  `*Sleep Restriction Therapy*, kurz SRT` — not
  `*Sleep Restriction Therapy (SRT), bei der …*` wrapping punctuation and
  parentheses inside the `*…*`.
- **Escape literal special characters** in prose with a backslash:
  `\*` `\_` `\#` `\$` `\@` `\<` `\>`. A price is `5\$`, a size is `10\%` only if
  you mean a literal percent, an email handle is `\@name`.
- **A `#` starts a Typst expression.** A literal hash in text must be `\#`.
  `C\#`, not `C#`.
- **Match brackets in function calls.** `#figure(caption: [Fig. 1])[…]`,
  `#table(columns: 2, [a], [b])` — count the `(` `)` and `[` `]`.

## Math

- Inline: `$a^2 + b^2 = c^2$` (no surrounding spaces → inline).
- Block: `$ a^2 + b^2 = c^2 $` (spaces just inside the `$` → its own line).
- Text inside math needs quotes: `$ "Energie" = m c^2 $`, not
  `$ Energie = m c^2 $`.
- Multiply with a space or `dot`: `$m c^2$` or `$m dot c^2$`.

## Common building blocks

```typst
- bullet
+ numbered
/ Term: definition

#table(
  columns: (auto, 1fr),
  [*Spalte A*], [*Spalte B*],
  [Zeile 1], [Wert],
)

#figure(caption: [Beschreibung])[
  Inhalt der Abbildung
]

Ein Verweis.#footnote[Quelle: …]

#pagebreak()
```

## Layout: avoid orphan pages

Each compile result reports `PDF: N pages; last page ~X% filled`. If it says
the last page is an **orphan** (a small slice spilling over), retry with a
tighter layout so the content fits on N−1 pages — shrink margins
(`#set page(margin: 1.5cm)`), reduce font size (`#set text(size: 10pt)`),
tighten leading (`#set par(leading: 0.55em)`), or trim filler. Keep the same
`artifact_id` so the version updates in place.

## Updating a document

To change a document, call `typst_compile` again with the **same
`artifact_id`** and the **full corrected `source`** (Typst has no partial
edit — always send the whole document). The artifact updates in place and its
version bumps (v1 → v2). Typst artifacts can only be changed through
`typst_compile`, never `artifact_manager`.

## Starting a second, different document

A different document gets a **new, content-descriptive `artifact_id`** — e.g.
`quartalsbericht-q1-2026`, `lebenslauf-mueller`. Never reuse an unrelated id,
and never make the id describe the format (`pdf`, `report`, `dokument` are bad
ids). Each real document has its own id and its own version history.

## When a compile fails

The result returns the full compiler error and does NOT save the source. Read
the error, fix that exact spot in the source, and call `typst_compile` again
with the corrected `source` in the SAME turn. Never end the turn with
intention-only text like "I will fix it" — emit the retry.
