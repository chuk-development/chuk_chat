# Lessons

## Never classify model output by its TEXT — classify by PROTOCOL/structure

**Date:** 2026-06-08

**Mistake:** To stop Kimi's chain-of-thought + draft HTML leaking into the
answer body, I first stripped fenced ```code``` blocks and matched on the
streamed text. User rejected this hard: "du kannst nicht nach Text filtern, das
ein Modell gibt — immer einen anderen Text. Es ist unmöglich danach zu filtern."

**Why it's wrong:** A model emits arbitrary, ever-changing text. Any
text-pattern heuristic (fenced code, key phrases, language) is brittle and
breaks on the next prompt.

**Rule for myself:** Decide what is "answer" vs "reasoning" vs "tool" using the
PROTOCOL only:
- "Did this round emit tool calls?" (known at round end) -> if yes, its content
  is working text -> fold into reasoning, never the answer.
- "Has a tool-call token appeared in the stream?" (`hasToolCallStartMarker`,
  structural delimiters incl. Kimi `<|tool_calls_section_begin|>`) -> suppress
  content from the answer body live.
- Fold content VERBATIM — never edit/strip the model's text.

If the only fix I can think of requires reading what the words say, stop — the
boundary I want is almost always available structurally (channel, delimiter,
round outcome).

## 2026-09-24 Antwortformate
- "Schoenerer Output" heisst: statisch bessere Darstellung der Modell-Antwort (Typografie, Layout, Markup), NICHT interaktive Widgets. Bei vagen UI-Wuenschen erst klaeren, ob statisch oder interaktiv gemeint ist.

## 2026-09-27 Marketing-Videos: jedes Video braucht eine eigene Aufgabe
- Fehler: Fuenf Launch-Videos gebaut, die sich gegenseitig kopieren. Vier
  starten mit Tippen in eine Box, drei nutzen denselben Boss-Burnout-Prompt,
  und keins zeigt einfach, was die App kann. Der Hook von 01 (Nachricht senden,
  nichts passiert, Logo setzt sich zusammen) hat keine Aussage.
- Regel: Vor dem Bauen einer Serie eine Tabelle "Video -> eine Aufgabe ->
  eigener Hook -> eigene Prompts" schreiben und auf Ueberschneidung pruefen.
  Kein Prompt, kein Hook, kein Endcard-Gimmick doppelt.
- Regel: Ein Feature-Video zeigt Ergebnisse (Chart, Karte, Bild, PDF), nicht
  das Absenden. Tippen ist nur dann der Hook, wenn das Tippen die Geschichte ist.
- Regel: Lesbarkeit an Einzelframes in voller Aufloesung pruefen, nicht an
  verkleinerten Kontaktbogen-Kacheln (Schaetzungen waren um Faktor 4 zu klein).
