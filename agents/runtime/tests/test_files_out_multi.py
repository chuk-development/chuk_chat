"""``send_file_to_user`` with ``paths``: up to four deliverables in one call.

Pinned: each file is its own sink call (one ``file`` event each), in order; a
failure of one file does not stop the rest; more than four is refused before
any byte moves; the old one-file ``path`` shape is unchanged; a JSON-text array
(a common model slip) is accepted.
"""

from __future__ import annotations

from chuk_agents_runtime import LocalEnvironment, SentFile, ToolRegistry
from chuk_agents_runtime.files_out import (
    MAX_FILES_PER_CALL,
    SEND_FILE_SCHEMA,
    make_send_file_handler,
    register_send_file,
)


class Sink:
    def __init__(self) -> None:
        self.received: list[SentFile] = []

    def __call__(self, sent: SentFile) -> None:
        self.received.append(sent)


def _files(tmp_path, count):
    out = []
    for i in range(count):
        path = tmp_path / f"f{i}.txt"
        path.write_text(f"file {i}", encoding="utf-8")
        out.append(str(path))
    return out


def test_schema_keeps_path_and_adds_paths():
    props = SEND_FILE_SCHEMA["properties"]
    assert "path" in props
    assert props["paths"]["maxItems"] == MAX_FILES_PER_CALL == 4
    assert "required" not in SEND_FILE_SCHEMA


def test_four_files_are_four_sink_calls_in_order(tmp_path):
    sink = Sink()
    paths = _files(tmp_path, 4)
    result = make_send_file_handler(LocalEnvironment(), sink)(paths=paths)

    assert result["ok"] is True
    assert result["sent"] == 4
    assert [s.name for s in sink.received] == ["f0.txt", "f1.txt", "f2.txt", "f3.txt"]
    assert all("data" not in f for f in result["files"])


def test_five_files_are_refused_before_any_byte_moves(tmp_path):
    sink = Sink()
    result = make_send_file_handler(LocalEnvironment(), sink)(
        paths=_files(tmp_path, 5)
    )
    assert result["ok"] is False
    assert "max 4" in result["error"]
    assert sink.received == []


def test_one_missing_file_does_not_stop_the_others(tmp_path):
    sink = Sink()
    paths = _files(tmp_path, 2)
    paths.insert(1, str(tmp_path / "missing.txt"))
    result = make_send_file_handler(LocalEnvironment(), sink)(paths=paths)

    assert result["ok"] is False
    assert result["sent"] == 2
    assert [f["ok"] for f in result["files"]] == [True, False, True]
    assert len(sink.received) == 2


def test_path_and_paths_merge_without_duplicates(tmp_path):
    sink = Sink()
    a, b = _files(tmp_path, 2)
    result = make_send_file_handler(LocalEnvironment(), sink)(path=a, paths=[a, b])
    assert result["sent"] == 2
    assert len(sink.received) == 2


def test_single_path_result_shape_is_unchanged(tmp_path):
    sink = Sink()
    (a,) = _files(tmp_path, 1)
    result = make_send_file_handler(LocalEnvironment(), sink)(a)
    assert result["ok"] is True
    assert result["name"] == "f0.txt"
    assert "files" not in result


def test_json_text_array_is_accepted_through_the_registry(tmp_path):
    sink = Sink()
    registry = ToolRegistry()
    register_send_file(registry, LocalEnvironment(), sink)
    a, b = _files(tmp_path, 2)
    result = registry.dispatch("send_file_to_user", {"paths": f'["{a}", "{b}"]'})
    assert result["sent"] == 2


def test_nothing_given_is_an_error(tmp_path):
    result = make_send_file_handler(LocalEnvironment(), Sink())()
    assert result["ok"] is False


def test_workspace_block_carries_the_link_rule():
    from chuk_agents_runtime.prompt import WORKSPACE_LINK_RULE, build_system_prompt

    with_ws = build_system_prompt(ToolRegistry(), workspace="/work")
    assert WORKSPACE_LINK_RULE in with_ws
    assert "<src/app.py#L24-L30>" in WORKSPACE_LINK_RULE
    # No workspace, no file links to make.
    assert WORKSPACE_LINK_RULE not in build_system_prompt(ToolRegistry())
