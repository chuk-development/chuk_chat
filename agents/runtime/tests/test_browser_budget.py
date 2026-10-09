"""Browser results stay small (live test 2026-10-09: an image job sent 30
``browser_evaluate`` results, 75k characters, on every one of 50 steps)."""

from __future__ import annotations

import json
from types import SimpleNamespace

from chuk_agents_runtime.context import ContextLadder, LadderConfig
from chuk_agents_runtime.mcp_client import (
    BROWSER_RESULT_CAP,
    _normalize_result,
    compact_browser_result,
)


def _result(text: str):
    return SimpleNamespace(content=[SimpleNamespace(type="text", text=text)], is_error=False)


def test_a_result_block_is_written_compact():
    rows = [{"u": f"https://shop.test/{i}.jpg", "w": 800, "a": "mug"} for i in range(3)]
    text = "### Result\n" + json.dumps(rows, indent=2) + "\n### Ran Playwright code\nawait x()"
    out = compact_browser_result(text)
    assert '"u":"https://shop.test/0.jpg"' in out and "\n  " not in out
    assert out.endswith("### Ran Playwright code\nawait x()")
    assert compact_browser_result("### Result\nnot json") == "### Result\nnot json"


def test_a_long_browser_result_is_cut_with_a_note():
    rows = [{"title": "x" * 80, "href": f"https://ebay.test/itm/{i}"} for i in range(400)]
    payload = _normalize_result("playwright", "browser_evaluate", _result("### Result\n" + json.dumps(rows)))
    assert len(payload["content"]) <= BROWSER_RESULT_CAP + 80
    assert payload["content"].endswith("return fewer fields or fewer rows]")
    # Other servers keep the general cap.
    other = _normalize_result("files", "read_table", _result("y" * 10_000))
    assert len(other["content"]) == 10_000


def _browser_round(i: int, chars: int = 3_000) -> list[dict]:
    return [
        {"role": "assistant", "tool_calls": [{"id": f"b{i}", "type": "function", "function": {
            "name": "mcp__playwright__browser_evaluate", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": f"b{i}", "name": "mcp__playwright__browser_evaluate",
         "content": f"rows {i} " + "z" * chars},
    ]


def _task(rounds: int) -> list[dict]:
    messages = [{"role": "system", "content": "s"}, {"role": "user", "content": "find mugs"}]
    for i in range(rounds):
        messages += _browser_round(i)
    return messages


def _sizes(out: list[dict]) -> list[int]:
    return [len(json.dumps(m["content"])) for m in out if m.get("role") == "tool"]


def test_older_browser_results_are_folded_in_blocks():
    ladder = ContextLadder(config=LadderConfig())
    # 7 results: 4 foldable, below one block of 5 -> nothing changes yet.
    assert ladder.prepare(_task(7), turn_start=1) == _task(7)
    # 8 results: 5 foldable -> the first 5 are short, the newest 3 whole.
    sizes = _sizes(ladder.prepare(_task(8), turn_start=1))
    assert all(size < 1_000 for size in sizes[:5])
    assert all(size > 3_000 for size in sizes[5:])


def test_the_fold_keeps_the_prefix_until_the_next_block():
    ladder = ContextLadder(config=LadderConfig())
    first = ladder.prepare(_task(8), turn_start=1)
    later = ladder.prepare(_task(12), turn_start=1)
    assert later[: len(first)] == first  # 9 foldable: still the same block of 5


def test_browser_folding_can_be_turned_off():
    out = ContextLadder(config=LadderConfig(browser_fold_tokens=0)).prepare(_task(8), turn_start=1)
    assert out == _task(8)
