"""apply_patch: the Codex patch format, all-or-nothing (research item 33).

Ported from deepseek-harness ``packages/fs/fs-patch/src`` (apply.ts, parse.ts),
which itself adapts OpenAI Codex rust-v0.158.0 (apply-patch/src/parser.rs,
streaming_parser.rs, seek_sequence.rs, file_update.rs). Those portions are
Apache-2.0:

    Copyright 2025 OpenAI. Licensed under the Apache License, Version 2.0.

A patch is one envelope::

    *** Begin Patch
    *** Add File: path
    +line
    *** Update File: path
    *** Move to: new/path
    @@ optional context
     context line
    -removed line
    +added line
    *** Delete File: path
    *** End Patch

The matcher tries four passes per anchor: exact, right-strip, both-strip, and
Unicode-punctuation normalization (curly quotes, dashes, non-break spaces). All
operations are checked in memory first; nothing is written unless every one
applies. On any failure nothing changes and the error names the problems.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .environment import Environment
from .file_edit import EditGuard, load_text, path_exists, store_text, unified_diff
from .sandbox_io import TransferError, workspace_path

BEGIN = "*** Begin Patch"
END = "*** End Patch"
EOF_MARK = "*** End of File"
MOVE = "*** Move to: "
ADD = "*** Add File: "
DELETE = "*** Delete File: "
UPDATE = "*** Update File: "

_WHITE = re.compile(r"\s", re.UNICODE)


class PatchParseError(ValueError):
    def __init__(self, line_number: int, reason: str) -> None:
        super().__init__(f"Invalid patch at line {line_number}: {reason}")
        self.line_number = line_number
        self.reason = reason


# -- parse --------------------------------------------------------------------


@dataclass
class PatchHunk:
    line_number: int
    context: str | None = None
    old_lines: list[str] = field(default_factory=list)
    new_lines: list[str] = field(default_factory=list)
    is_eof: bool = False

    def empty(self) -> bool:
        return not self.old_lines and not self.new_lines


@dataclass
class AddOp:
    path: str
    line_number: int
    content: str = ""
    kind: str = "add"


@dataclass
class DeleteOp:
    path: str
    line_number: int
    kind: str = "delete"


@dataclass
class UpdateOp:
    path: str
    line_number: int
    move_to: str | None = None
    hunks: list[PatchHunk] = field(default_factory=list)
    kind: str = "update"


def _trim(value: str) -> str:
    return value.strip()


def _trim_end(value: str) -> str:
    return value.rstrip()


def _ensure_update(op, line_number: int) -> None:
    if not isinstance(op, UpdateOp):
        return
    last = op.hunks[-1] if op.hunks else None
    if last is None:
        raise PatchParseError(op.line_number, f"Update for '{op.path}' requires at least one hunk")
    if last.empty():
        raise PatchParseError(line_number, "Update hunk must contain context, added, or removed lines")


def _read_update(op: UpdateOp, text: str, number: int, is_last: bool) -> None:
    trimmed = _trim_end(text)
    previous = op.hunks[-1] if op.hunks else None
    marker = trimmed == "@@" or trimmed.startswith("@@ ")
    if previous is not None and previous.is_eof:
        if trimmed == "":
            return
        if not marker:
            raise PatchParseError(number, "Expected '@@' after '*** End of File'")
    if previous is None and op.move_to is None and trimmed.startswith(MOVE):
        op.move_to = trimmed[len(MOVE):]
        return
    if marker:
        if previous is not None and previous.empty():
            raise PatchParseError(number, "Update hunk must contain context, added, or removed lines")
        hunk = PatchHunk(line_number=number)
        if trimmed.startswith("@@ "):
            hunk.context = trimmed[3:]
        op.hunks.append(hunk)
        return
    if trimmed == EOF_MARK:
        if previous is not None:
            if previous.empty():
                raise PatchParseError(number, "Update hunk must contain context, added, or removed lines")
            previous.is_eof = True
        return
    prefix = text[0] if text else ""
    if text != "" and prefix not in (" ", "+", "-"):
        raise PatchParseError(number, "Expected a context (' '), added ('+'), removed ('-') line, or '@@'")
    hunk = previous if previous is not None else PatchHunk(line_number=number)
    if previous is None:
        op.hunks.append(hunk)
    content = text[1:]
    if prefix == "+":
        hunk.new_lines.append(content)
    elif prefix == "-":
        hunk.old_lines.append(content)
    else:
        hunk.old_lines.append(content)
        hunk.new_lines.append(content)


def parse_patch(patch: str) -> list:
    stripped = patch.strip()
    offset = len(patch) - len(patch.lstrip())
    offset_lines = patch[:offset].count("\n")
    raw = stripped.split("\n")
    lines = [(offset_lines + i + 1, re.sub(r"\r$", "", t)) for i, t in enumerate(raw)]
    if not lines:
        raise PatchParseError(1, f"Expected '{BEGIN}'")
    first_no, first_text = lines[0]
    last_no, last_text = lines[-1]
    # Optional literal heredoc wrapper.
    if first_text in ("<<EOF", "<<'EOF'", '<<"EOF"') and last_text.endswith("EOF") and len(lines) >= 4:
        lines = lines[1:-1]
    start_no, start_text = lines[0]
    end_no, end_text = lines[-1]
    if _trim(start_text) != BEGIN:
        raise PatchParseError(start_no, f"Expected '{BEGIN}'")
    if _trim(end_text) != END:
        raise PatchParseError(end_no, f"Expected '{END}'")

    operations: list = []
    ended = False
    last_tuple = lines[-1]
    for number, text in lines[1:]:
        op = operations[-1] if operations else None
        is_last = (number, text) == last_tuple
        header = _trim_end(text) if isinstance(op, UpdateOp) and not is_last else _trim(text)
        if ended and not is_last:
            if _trim(text) != "":
                raise PatchParseError(number, f"Unexpected content after '{END}'")
            continue
        if header == END:
            _ensure_update(op, number)
            ended = True
        elif header.startswith(ADD):
            _ensure_update(op, number)
            operations.append(AddOp(path=header[len(ADD):], line_number=number))
        elif header.startswith(DELETE):
            _ensure_update(op, number)
            operations.append(DeleteOp(path=header[len(DELETE):], line_number=number))
        elif header.startswith(UPDATE):
            _ensure_update(op, number)
            operations.append(UpdateOp(path=header[len(UPDATE):], line_number=number))
        elif not operations and header.startswith("*** Environment ID:"):
            raise PatchParseError(number, "Environment ID headers are unsupported")
        elif isinstance(op, AddOp) and text.startswith("+"):
            op.content += text[1:] + "\n"
        elif isinstance(op, UpdateOp):
            _read_update(op, text, number, is_last)
        else:
            raise PatchParseError(
                number,
                "Expected an Add File, Delete File, or Update File header; added content must start with +",
            )
    return operations


# -- apply --------------------------------------------------------------------


def _trim_ws(value: str, leading: bool) -> str:
    start, end = 0, len(value)
    if leading:
        while start < end and _WHITE.match(value[start]):
            start += 1
    while end > start and _WHITE.match(value[end - 1]):
        end -= 1
    return value[start:end]


def _normalize_punct(value: str) -> str:
    value = _trim_ws(value, True)
    value = re.sub(r"[‐-―−]", "-", value)
    value = re.sub(r"[‘-‛]", "'", value)
    value = re.sub(r"[“-‟]", '"', value)
    value = re.sub(r"[  -   　]", " ", value)
    return value


_MATCH_PASSES = (
    lambda v: v,
    lambda v: _trim_ws(v, False),
    lambda v: _trim_ws(v, True),
    _normalize_punct,
)


def _seek(lines: list[str], pattern: list[str], start: int, eof: bool) -> int | None:
    if not pattern:
        return start
    if len(pattern) > len(lines):
        return None
    last = len(lines) - len(pattern)
    first = last if eof else start
    for normalize in _MATCH_PASSES:
        expected = [normalize(p) for p in pattern]
        for index in range(first, last + 1):
            if all(normalize(lines[index + off]) == exp for off, exp in enumerate(expected)):
                return index
    return None


@dataclass
class HunkFailure:
    hunk_line: int
    stage: str
    pattern: list[str]


def apply_hunks(before: str, hunks: list[PatchHunk]):
    """``(after, None)`` or ``(None, HunkFailure)``. No partial text on failure."""
    original = before.split("\n")
    if original and original[-1] == "":
        original.pop()
    replacements: list[tuple[int, int, list[str]]] = []
    line_index = 0
    for hunk in hunks:
        if hunk.context is not None:
            found = _seek(original, [hunk.context], line_index, False)
            if found is None:
                return None, HunkFailure(hunk.line_number, "context", [hunk.context])
            line_index = found + 1
        if not hunk.old_lines:
            start = len(original) - 1 if (original and original[-1] == "") else len(original)
            replacements.append((start, 0, hunk.new_lines))
            continue
        pattern = hunk.old_lines
        new_lines = hunk.new_lines
        found = _seek(original, pattern, line_index, hunk.is_eof)
        if found is None and pattern and pattern[-1] == "":
            pattern = pattern[:-1]
            if new_lines and new_lines[-1] == "":
                new_lines = new_lines[:-1]
            found = _seek(original, pattern, line_index, hunk.is_eof)
        if found is None:
            return None, HunkFailure(hunk.line_number, "oldLines", list(hunk.old_lines))
        replacements.append((found, len(pattern), new_lines))
        line_index = found + len(pattern)

    replacements.sort(key=lambda r: r[0])
    lines = original
    for start, old_len, new_lines in reversed(replacements):
        lines = lines[:start] + list(new_lines) + lines[start + old_len:]
    if not lines or lines[-1] != "":
        lines.append("")
    return "\n".join(lines), None


# -- the tool -----------------------------------------------------------------


@dataclass
class _Planned:
    op: object
    path: str
    before: str | None
    after: str | None
    move_to: str | None = None


def apply_patch(env: Environment, guard: EditGuard, patch: str, floor: object | None = None) -> dict:
    if not isinstance(patch, str) or not patch.strip():
        return {"ok": False, "error": "patch must not be empty"}
    try:
        operations = parse_patch(patch)
    except PatchParseError as exc:
        return {"ok": False, "error": str(exc)}
    if not operations:
        return {"ok": False, "error": "the patch contained no file operations"}

    planned: list[_Planned] = []
    problems: list[str] = []
    for op in operations:
        path = op.path.strip()
        if floor is not None:
            verdict = floor.check_path_write(path)
            if verdict is None and getattr(op, "move_to", None):
                verdict = floor.check_path_write(op.move_to.strip())
            if verdict is not None:
                problems.append(f"{path}: {verdict.message()}")
                continue
        if op.kind == "add":
            if path_exists(env, path):
                problems.append(f"{path}: Add File, but the file already exists")
                continue
            planned.append(_Planned(op=op, path=path, before=None, after=op.content))
        elif op.kind == "delete":
            refused = guard.check_modify(path)
            if refused:
                problems.append(refused)
                continue
            try:
                before = load_text(env, path)
            except TransferError as exc:
                problems.append(f"{path}: {exc}")
                continue
            planned.append(_Planned(op=op, path=path, before=before, after=None))
        else:  # update
            refused = guard.check_modify(path)
            if refused:
                problems.append(refused)
                continue
            try:
                before = load_text(env, path)
            except TransferError as exc:
                problems.append(f"{path}: {exc}")
                continue
            after, failure = apply_hunks(before, op.hunks)
            if failure is not None:
                anchor = failure.pattern[0] if failure.pattern else ""
                problems.append(
                    f"{path}: could not place a hunk ({failure.stage}) near "
                    f"patch line {failure.hunk_line}: {anchor[:80]!r} not found"
                )
                continue
            move_to = op.move_to.strip() if op.move_to else None
            if move_to and path_exists(env, move_to):
                problems.append(f"{path}: Move to {move_to}, but that path already exists")
                continue
            planned.append(_Planned(op=op, path=path, before=before, after=after, move_to=move_to))

    if problems:
        head = f"Patch rejected before any change ({len(problems)} problems): "
        return {"ok": False, "error": head + "; ".join(problems[:20])}

    # All ops preflighted. Now write; a mid-way I/O error is reported but the
    # earlier ones already landed (there is no transaction over the FS).
    results: list[dict] = []
    diffs: list[dict] = []
    for item in planned:
        op = item.op
        if op.kind == "add":
            failed = store_text(env, item.path, item.after or "")
            if failed:
                return _write_failure(item.path, failed, results)
            guard.observe(item.path)
            results.append({"path": item.path, "op": "add"})
            diffs.append({"path": item.path, "diff": unified_diff(item.path, "", item.after or "")})
        elif op.kind == "delete":
            q = __import__("shlex").quote(workspace_path(env, item.path))
            out = env.run_bash(f"rm -f -- {q}", timeout=30, internal=True)
            if not out.ok:
                return _write_failure(item.path, (out.stderr or "delete failed").strip(), results)
            guard.seen.put(guard.key(item.path), None)
            results.append({"path": item.path, "op": "delete"})
            diffs.append({"path": item.path, "diff": unified_diff(item.path, item.before or "", "")})
        else:
            if item.move_to:
                failed = store_text(env, item.move_to, item.after or "")
                if failed:
                    return _write_failure(item.move_to, failed, results)
                q = __import__("shlex").quote(workspace_path(env, item.path))
                env.run_bash(f"rm -f -- {q}", timeout=30, internal=True)
                guard.seen.put(guard.key(item.path), None)
                guard.observe(item.move_to)
                results.append({"path": item.path, "op": "update", "moved_to": item.move_to})
                diffs.append({"path": item.move_to, "diff": unified_diff(item.move_to, item.before or "", item.after or "")})
            else:
                failed = store_text(env, item.path, item.after or "")
                if failed:
                    return _write_failure(item.path, failed, results)
                guard.observe(item.path)
                results.append({"path": item.path, "op": "update"})
                diffs.append({"path": item.path, "diff": unified_diff(item.path, item.before or "", item.after or "")})

    return {
        "ok": True,
        "applied": results,
        "message": f"Applied {len(results)} file operation(s).",
        "_ui": {"diffs": diffs},
    }


def _write_failure(path: str, error: str, done: list[dict]) -> dict:
    return {
        "ok": False,
        "error": f"writing {path} failed after {len(done)} operation(s) already applied: {error}",
        "applied": done,
    }
