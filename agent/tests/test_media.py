"""``run_ffmpeg`` / ``run_ffprobe``: the host's ffmpeg on the sandbox's files.

The whole risk of this tool is the argument vector, so every hardening rule gets
its own test: ``..`` traversal, an absolute path outside the workspace, a symlink
that points out of the workspace (for an input *and* for an output), an option
that is not on the allowlist, ``-i`` smuggled in as an option, and an option
value that references a file or a protocol the way ffmpeg really does
(``movie=``, ``subtitles=``, ``concat:``, ``http://``).

The successful runs go through a fake runner that records the argv, so the test
proves the exact command that would have been executed. One test runs the real
binary, and is skipped when the machine has none — nothing is installed here.
"""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from cowork_agent import (
    MediaError,
    MediaResult,
    ToolRegistry,
    WorkspaceMount,
    make_run_ffmpeg_handler,
    make_run_ffprobe_handler,
    register_media_tools,
    render_tool_docs,
    resolve_in_workspace,
    validate_options,
)

SANDBOX_ROOT = "/workspace"


@pytest.fixture
def mount(tmp_path) -> WorkspaceMount:
    host = tmp_path / "workspace"
    host.mkdir()
    (host / "in.mp4").write_bytes(b"fake video bytes")
    return WorkspaceMount(sandbox_root=SANDBOX_ROOT, host_root=str(host))


class FakeRunner:
    """Records the argv and, on success, creates the file ffmpeg would have."""

    def __init__(self, *, exit_code: int = 0, stdout: str = "", stderr: str = "") -> None:
        self.calls: list[list[str]] = []
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr

    def __call__(self, argv, timeout: int) -> MediaResult:
        argv = list(argv)
        self.calls.append(argv)
        if self.exit_code == 0 and argv[0].endswith("ffmpeg"):
            from pathlib import Path

            Path(argv[-1]).write_bytes(b"encoded output")
        return MediaResult(
            exit_code=self.exit_code,
            stdout=self.stdout,
            stderr=self.stderr,
            timed_out=False,
        )


# -- path hardening -----------------------------------------------------------


def test_relative_traversal_is_blocked(mount):
    with pytest.raises(MediaError) as excinfo:
        resolve_in_workspace(mount, "../../etc/passwd", must_exist=False)
    assert "escapes the workspace" in str(excinfo.value)


def test_traversal_in_the_middle_is_blocked(mount):
    with pytest.raises(MediaError):
        resolve_in_workspace(mount, "clips/../../../etc/passwd", must_exist=False)


def test_absolute_path_outside_the_sandbox_root_is_blocked(mount):
    with pytest.raises(MediaError) as excinfo:
        resolve_in_workspace(mount, "/etc/passwd", must_exist=False)
    assert "outside the workspace" in str(excinfo.value)


def test_absolute_path_inside_the_sandbox_root_is_mapped_to_the_host(mount):
    resolved = resolve_in_workspace(mount, f"{SANDBOX_ROOT}/in.mp4", must_exist=True)
    assert resolved == mount.host_base() / "in.mp4"


def test_a_prefix_lookalike_root_is_not_the_root(mount):
    """`/workspace-evil` starts with `/workspace` as a string but is not inside
    it as a path."""
    with pytest.raises(MediaError):
        resolve_in_workspace(mount, "/workspace-evil/x.mp4", must_exist=False)


def test_symlinked_input_out_of_the_workspace_is_blocked(mount, tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("password", encoding="utf-8")
    (mount.host_base() / "link.mp4").symlink_to(secret)

    with pytest.raises(MediaError) as excinfo:
        resolve_in_workspace(mount, "link.mp4", must_exist=True)
    assert "through a link" in str(excinfo.value)


def test_symlinked_output_directory_out_of_the_workspace_is_blocked(mount, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (mount.host_base() / "out").symlink_to(outside, target_is_directory=True)

    with pytest.raises(MediaError) as excinfo:
        resolve_in_workspace(mount, "out/clip.mp4", must_exist=False)
    assert "through a link" in str(excinfo.value)


def test_symlinked_output_file_is_blocked(mount, tmp_path):
    target = tmp_path / "target.mp4"
    target.write_bytes(b"x")
    (mount.host_base() / "out.mp4").symlink_to(target)

    with pytest.raises(MediaError) as excinfo:
        resolve_in_workspace(mount, "out.mp4", must_exist=False)
    assert "symlink" in str(excinfo.value)


def test_missing_input_is_rejected(mount):
    with pytest.raises(MediaError):
        resolve_in_workspace(mount, "nope.mp4", must_exist=True)


def test_a_directory_is_not_an_input(mount):
    (mount.host_base() / "clips").mkdir()
    with pytest.raises(MediaError):
        resolve_in_workspace(mount, "clips", must_exist=True)


def test_null_byte_is_rejected(mount):
    with pytest.raises(MediaError):
        resolve_in_workspace(mount, "a\x00b.mp4", must_exist=False)


# -- option hardening ---------------------------------------------------------


def test_allowed_options_pass_through_unchanged():
    options = ["-c:v", "h264_nvenc", "-crf", "23", "-vf", "scale=1280:720", "-an"]
    assert validate_options(options) == options


@pytest.mark.parametrize(
    "options",
    [
        ["-nostdin"],
        ["--config"],
        ["-filter_complex", "amix"],
        ["-attach", "x"],
        ["-passlogfile", "x"],
    ],
)
def test_options_off_the_allowlist_are_rejected(options):
    with pytest.raises(MediaError) as excinfo:
        validate_options(options)
    assert "not allowed" in str(excinfo.value)


@pytest.mark.parametrize("option", ["-i", "-y", "-n"])
def test_the_tool_owns_inputs_and_overwrite(option):
    with pytest.raises(MediaError) as excinfo:
        validate_options([option, "x.mp4"])
    assert "set by the tool" in str(excinfo.value)


@pytest.mark.parametrize(
    "value",
    [
        "movie=/etc/passwd",
        "amovie=/etc/passwd",
        "subtitles=/etc/shadow",
        "ass=/tmp/x.ass",
        "drawtext=fontfile=/etc/passwd:text=hi",
        "concat:/etc/passwd|/etc/shadow",
        "http://evil.test/x.mp4",
        "file:/etc/passwd",
        "pipe:0",
    ],
)
def test_option_values_may_not_reference_a_file_or_protocol(value):
    with pytest.raises(MediaError) as excinfo:
        validate_options(["-vf", value])
    assert "refers to a file or a protocol" in str(excinfo.value)


@pytest.mark.parametrize("value", ["a\x00b", "a`id`b", "a$(id)b", "a\"b", "a\\b"])
def test_option_values_with_forbidden_characters_are_rejected(value):
    with pytest.raises(MediaError) as excinfo:
        validate_options(["-preset", value])
    assert "forbidden characters" in str(excinfo.value)


def test_a_value_option_needs_its_value():
    with pytest.raises(MediaError) as excinfo:
        validate_options(["-crf"])
    assert "needs a value" in str(excinfo.value)


def test_options_must_be_separate_tokens():
    with pytest.raises(MediaError) as excinfo:
        validate_options("-c:v h264 -crf 23")
    assert "separate tokens" in str(excinfo.value)


def test_too_many_option_tokens():
    with pytest.raises(MediaError):
        validate_options(["-an"] * 100)


# -- run_ffmpeg ---------------------------------------------------------------


def test_successful_run_builds_the_exact_argv(mount):
    runner = FakeRunner()
    handler = make_run_ffmpeg_handler(mount, runner=runner)

    result = handler(
        inputs=["in.mp4"],
        output="out/clip.webm",
        options=["-c:v", "libvpx-vp9", "-crf", "30"],
    )

    assert result["ok"] is True
    assert result["output"] == "out/clip.webm"
    assert result["bytes"] == len(b"encoded output")

    argv = runner.calls[0]
    base = str(mount.host_base())
    assert argv[0] == "ffmpeg"
    assert "-nostdin" in argv
    assert "-n" in argv and "-y" not in argv
    assert argv[argv.index("-i") + 1] == f"{base}/in.mp4"
    assert argv[-1] == f"{base}/out/clip.webm"
    assert "-c:v" in argv and "libvpx-vp9" in argv
    # The output directory was created inside the workspace.
    assert (mount.host_base() / "out").is_dir()


def test_several_inputs_each_get_their_own_i(mount):
    (mount.host_base() / "b.mp4").write_bytes(b"more")
    runner = FakeRunner()

    result = make_run_ffmpeg_handler(mount, runner=runner)(
        inputs=["in.mp4", "b.mp4"], output="joined.mp4"
    )

    assert result["ok"] is True
    assert runner.calls[0].count("-i") == 2


def test_bad_arguments_never_reach_the_runner(mount):
    runner = FakeRunner()
    handler = make_run_ffmpeg_handler(mount, runner=runner)

    assert handler(inputs=["../../etc/passwd"], output="x.mp4")["ok"] is False
    assert handler(inputs=["in.mp4"], output="/etc/cron.d/x")["ok"] is False
    assert handler(inputs=["in.mp4"], output="x.mp4", options=["-i", "y.mp4"])[
        "ok"
    ] is False
    assert handler(inputs=[], output="x.mp4")["ok"] is False
    assert runner.calls == []


def test_existing_output_needs_overwrite(mount):
    (mount.host_base() / "out.mp4").write_bytes(b"old")
    runner = FakeRunner()
    handler = make_run_ffmpeg_handler(mount, runner=runner)

    refused = handler(inputs=["in.mp4"], output="out.mp4")
    assert refused["ok"] is False
    assert "overwrite=true" in refused["error"]
    assert runner.calls == []

    allowed = handler(inputs=["in.mp4"], output="out.mp4", overwrite=True)
    assert allowed["ok"] is True
    assert "-y" in runner.calls[0]


def test_output_may_not_be_an_input(mount):
    runner = FakeRunner()
    result = make_run_ffmpeg_handler(mount, runner=runner)(
        inputs=["in.mp4"], output="in.mp4", overwrite=True
    )

    assert result["ok"] is False
    assert "also an input" in result["error"]
    assert runner.calls == []


def test_a_failing_run_reports_a_bounded_stderr(mount):
    runner = FakeRunner(exit_code=1, stderr="x" * 10_000)

    result = make_run_ffmpeg_handler(mount, runner=runner)(
        inputs=["in.mp4"], output="out.mp4"
    )

    assert result["ok"] is False
    assert result["exit_code"] == 1
    assert len(result["error"]) <= 4000


def test_a_timeout_is_reported(mount):
    def runner(argv, timeout):
        return MediaResult(exit_code=124, stdout="", stderr="", timed_out=True)

    result = make_run_ffmpeg_handler(mount, runner=runner)(
        inputs=["in.mp4"], output="out.mp4", timeout=5
    )

    assert result["ok"] is False
    assert result["timed_out"] is True


# -- run_ffprobe --------------------------------------------------------------


def test_ffprobe_reads_only(mount):
    info = {"format": {"duration": "12.5"}, "streams": []}
    runner = FakeRunner(stdout=json.dumps(info))

    result = make_run_ffprobe_handler(mount, runner=runner)(path="in.mp4")

    assert result["ok"] is True
    assert result["info"] == info
    argv = runner.calls[0]
    assert argv[0] == "ffprobe"
    assert argv[-1] == f"{mount.host_base()}/in.mp4"
    # No writing option anywhere in the vector.
    assert "-y" not in argv and "-i" not in argv


def test_ffprobe_is_bound_by_the_same_workspace_rules(mount):
    runner = FakeRunner()
    handler = make_run_ffprobe_handler(mount, runner=runner)

    assert handler(path="/etc/passwd")["ok"] is False
    assert handler(path="../../etc/passwd")["ok"] is False
    assert runner.calls == []


def test_ffprobe_without_json_is_a_clean_failure(mount):
    runner = FakeRunner(stdout="not json")
    result = make_run_ffprobe_handler(mount, runner=runner)(path="in.mp4")

    assert result["ok"] is False
    assert "no JSON" in result["error"]


# -- registration -------------------------------------------------------------


def test_no_mount_means_no_media_tools():
    registry = ToolRegistry()
    register_media_tools(registry, None)

    assert registry.names() == []
    assert "run_ffmpeg" not in render_tool_docs(registry)


def test_a_mount_whose_host_directory_is_gone_is_unavailable(tmp_path):
    mount = WorkspaceMount(
        sandbox_root=SANDBOX_ROOT, host_root=str(tmp_path / "missing")
    )
    registry = ToolRegistry()
    register_media_tools(registry, mount, require_binaries=False)

    assert registry.has("run_ffmpeg")
    assert registry.available("run_ffmpeg") is False
    assert "run_ffmpeg" not in render_tool_docs(registry)


def test_a_usable_mount_documents_both_tools(mount):
    registry = ToolRegistry()
    register_media_tools(
        registry, mount, runner=FakeRunner(), require_binaries=False
    )

    docs = render_tool_docs(registry)
    assert registry.available("run_ffmpeg") is True
    assert "run_ffmpeg" in docs
    assert "run_ffprobe" in docs


def test_binaries_are_probed_when_required(mount):
    registry = ToolRegistry()
    register_media_tools(
        registry, mount, ffmpeg_binary="definitely-not-a-binary-xyz"
    )

    assert registry.available("run_ffmpeg") is False


# -- the real binary, when there is one ---------------------------------------


@pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="no host ffmpeg; nothing is installed for a test",
)
def test_real_ffmpeg_round_trip(mount):
    # A one-second silent tone, made by ffmpeg itself, then re-encoded by the
    # tool and measured by the tool.
    source = mount.host_base() / "tone.wav"
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "1",
            str(source),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )

    encoded = make_run_ffmpeg_handler(mount)(
        inputs=["tone.wav"], output="tone.flac", options=["-c:a", "flac"]
    )
    assert encoded["ok"] is True, encoded
    assert encoded["bytes"] > 0

    probed = make_run_ffprobe_handler(mount)(path="tone.flac")
    assert probed["ok"] is True, probed
    assert probed["info"]["streams"][0]["codec_name"] == "flac"


@pytest.mark.skipif(
    shutil.which("ffmpeg") is None, reason="no host ffmpeg; nothing is installed"
)
def test_real_ffmpeg_cannot_be_talked_out_of_the_workspace(mount, tmp_path):
    outside = tmp_path / "escaped.wav"
    handler = make_run_ffmpeg_handler(mount)

    result = handler(inputs=["in.mp4"], output=str(outside))

    assert result["ok"] is False
    assert not outside.exists()
