"""Speed test for Agents turns.

Four parts, one per question:

- :mod:`.snapshot` makes a consistent copy of the live state database. Every
  other part works on a copy, never on the live file.
- :mod:`.runs` reads the ``runs`` table of a copy and says where the wall clock
  went (p50/p95 per session and per provider/model). It also parses the
  backend's ``model call`` log lines.
- :mod:`.offline` replays the prepare pipeline (store -> system prompt upgrade ->
  context ladder) for one session, with no model call, and times each step.
- :mod:`.live` sends real prompts to a scratch session. It spends credits, so it
  runs only behind an explicit flag.
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
