# Weight-space programming on a local model (experiment, 2026-11-05)

Source: https://rikiyat.github.io/blog/weight-space-programming/ (GPT-6 Astra
edits network weights directly). Exp 8 there: Qwen3.5-0.8B looped in thinking
mode; Astra found one direction written by the MLPs of layers 15 and 19 and
subtracted it from 64 down_proj columns per layer (131 072 weights). MATH-500
went from 7.9 % to 48.1 %. Critics: almost all of the gain is the loop fix,
thinking off gives about the same (45.8 %), and on Gemma 3 270M (no loops) the
edit did nothing. The edit removes an obstacle; it does not add a skill.

Question here: can the same edit make Qwen3.5-4B better at Chalk 3D models
(`tools/chalk/`) from a photo?

## Setup

- Code: `tools/wsp/wsp.py` (`gen`, `acts`, `edit`). Data and runs:
  `_scratch/wsp/` (gitignored).
- Model: `Qwen/Qwen3.5-4B` from the local HF cache. bf16 (8.5 GB) does not fit
  on the RTX 3060 next to the desktop, and accelerate moves the tied
  embedding back to the GPU when you try CPU offload. So: NF4 4-bit for all
  but `down_proj`, `visual`, `lm_head`; `down_proj` stays bf16 so the edit is
  exact. About 11 tok/s (no `causal_conv1d` kernel installed), 1-4 min per
  answer.
- Input: system prompt `tools/chalk/PROMPT.md`, one Wikimedia photo (448 px),
  "Baue das Objekt auf dem Foto als 3D-Modell in Chalk". Thinking off.
  Sampling T=0.6, top-p 0.95, top-k 20, max 2500 tokens.
- Score: the Chalk engine (`cli.mjs`): error lines, lints, visible parts.
  `valid` = no error and at least 3 visible parts.
- 20 photos: 10 practice (direction), 10 held out (evaluation).
- Photo trap: Wikimedia search "car" returned the Carina nebula; the model
  correctly built a nebula. Check the photos before a run.

## Results

Baseline, 20 photos: valid 5 %, mean 21 error lines, truncated 5 %.
**No looping.** The errors are key confusion: `box`/`loft` given `top=`/
`bottom=`/`width=` (keys of `body`), `wing r=`, bad `on=` format.

Direction: token level, MLP output on tokens of error lines minus tokens of
clean lines (practice set). The difference peaks in layers 15-17 (0.62-0.64 of
the clean norm). But the top 64 columns hold only about 4 % of the projection
mass: the direction is spread over all 9216 neurons, unlike the loop direction
in the paper. Confound: error lines are often long point lists, so the
direction also measures "number list".

Held out, 10 photos, 1 sample each:

| Run | valid | errors/answer | truncated |
|---|---|---|---|
| Baseline | 10 % | 11.2 | 0 % |
| Edit, layers 16+17, 64 cols each, scale 1 | 10 % | 11.0 | 20 % |
| Random direction, same size (4 of 10 done) | 25 % | 32 | 75 % |

The edit changes nothing measurable. The random control breaks the model
(truncation), so mid layers are sensitive, and the found direction is at least
not harmful.

## What this means

- Weight edits like this fix a *behaviour* that a single direction carries
  (loops, refusal). Chalk syntax errors are missing knowledge, not such a
  behaviour. Same result as the paper's Gemma case.
- Cheaper levers for the 4B: the error feedback loop (`mini.py` style: send
  the engine errors back), a short key table per shape, or constrained
  decoding with a grammar of shape keys. A LoRA on a few hundred correct Chalk
  files would teach the syntax; that is training, not weight-space
  programming.
- If this is tried again with a stronger editor model: give it the weights of
  layers 14-20 plus `acts` output and 50 forward passes, and look first for a
  behaviour (truncation, ignoring the photo), not for knowledge.
- Noise: 1 sample per photo at T=0.6 is too few. Use `--n 3` or more before
  you believe a difference under about 30 %.

## Run it

```bash
python3 tools/wsp/wsp.py gen _scratch/wsp/base "$(cat _scratch/wsp/heldout.txt)"
python3 tools/wsp/wsp.py acts _scratch/wsp/base _scratch/wsp/dirs.pt --subjects _scratch/wsp/practice.txt
python3 tools/wsp/wsp.py edit _scratch/wsp/dirs.pt _scratch/wsp/e.json --layers 16,17 --k 64 [--random]
python3 tools/wsp/wsp.py gen _scratch/wsp/ed "$(cat _scratch/wsp/heldout.txt)" --edit _scratch/wsp/e.json
```

Photos: `python3 -I tools/chalk/refs.py "<subject>" _scratch/wsp/photos/<name> 2`.
