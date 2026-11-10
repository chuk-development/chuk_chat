"""Sandbox escalation on ``run_command`` / ``python`` (docs/WIRE_CONTRACT.md,
"Sandbox escalation", DeepSeek research item 28)."""

from __future__ import annotations

from chuk_agents_runtime.action_policy import ActionDecision
from chuk_agents_runtime.environment import ProcessResult
from chuk_agents_runtime.escalation import SANDBOX_ESCALATION, parse_escalation
from chuk_agents_runtime.tools import make_run_command_handler, make_run_python_handler


class _Box:
    """A box that withholds ``network`` and records how each call ran."""

    def __init__(self, withheld=("network",), exit_code=6):
        self._withheld = tuple(withheld)
        self.exit_code = exit_code
        self.plain: list[str] = []
        self.escalated: list[tuple[str, tuple]] = []

    def withheld_permissions(self):
        return self._withheld

    def run_bash(self, cmd, *, timeout=120, internal=False, env=None):
        self.plain.append(cmd)
        return ProcessResult(stdout="", stderr="curl: (6) could not resolve", exit_code=self.exit_code)

    def run_escalated(self, cmd, *, grant, timeout=120, env=None):
        self.escalated.append((cmd, tuple(grant)))
        return ProcessResult(stdout="ok", stderr="", exit_code=0)


class _Gate:
    def __init__(self, answer):
        self.answer = answer
        self.asked = []

    def __call__(self, request):
        self.asked.append(request)
        return self.answer


def test_pairing_rules():
    assert parse_escalation(["network"], None).error.startswith("invalid escalation: sandbox_permissions requires")
    assert "only valid together" in parse_escalation(None, "why").error
    assert "non-empty" in parse_escalation(["network"], "  ").error
    assert "unknown sandbox permission" in parse_escalation(["root"], "x").error
    ok = parse_escalation(["sudo", "network", "network"], "Install jq.")
    assert ok.requested == ("network", "sudo") and ok.error is None
    assert parse_escalation(None, None).requested == ()


def test_a_denied_command_carries_the_hint():
    box, gate = _Box(), _Gate(True)
    run = make_run_command_handler(box, escalation_ask=gate)
    out = run(command="curl https://example.com", description="Fetch a page")
    assert out["sandbox"]["withheld"] == ["network"]
    assert "sandbox_permissions" in out["sandbox"]["hint"]
    assert list(out)[-1] == "exit_code"
    assert gate.asked == []


def test_no_hint_without_an_approval_channel_or_on_success():
    run = make_run_command_handler(_Box(), escalation_ask=None)
    assert "sandbox" not in run(command="curl x", description="Fetch")
    run = make_run_command_handler(_Box(exit_code=0), escalation_ask=_Gate(True))
    assert "sandbox" not in run(command="true", description="Do nothing")


def test_an_approved_escalation_runs_once_in_the_wider_box():
    box, gate = _Box(withheld=("network", "sudo")), _Gate(ActionDecision(approved=True, scope="once"))
    run = make_run_command_handler(box, escalation_ask=gate)
    out = run(
        command="curl https://example.com",
        description="Fetch a page",
        sandbox_permissions=["network", "sudo"],
        justification="The task needs the page from the internet.",
    )
    assert box.escalated == [("curl https://example.com", ("network", "sudo"))]
    assert out["escalated"] == ["network", "sudo"] and out["exit_code"] == 0
    [card] = gate.asked
    assert card.action_class == SANDBOX_ESCALATION
    assert card.options == ("once", "deny")
    assert card.details["justification"] == "The task needs the page from the internet."
    assert card.details["kind"] == SANDBOX_ESCALATION
    assert "internet access" in card.summary
    # The next plain call runs in the agent's own box again.
    run(command="curl x", description="Fetch")
    assert box.plain == ["curl x"]


def test_a_rejected_escalation_does_not_run():
    box, gate = _Box(), _Gate(False)
    run = make_run_command_handler(box, escalation_ask=gate)
    out = run(command="curl x", description="Fetch", sandbox_permissions=["network"], justification="Need it.")
    assert out["declined"] is True
    assert "the user rejected escalating this command to network" in out["error"]
    assert "stop and explain" in out["error"]
    assert box.plain == [] and box.escalated == []


def test_unattended_or_invalid_never_runs():
    box = _Box()
    run = make_run_command_handler(box, escalation_ask=None)
    out = run(command="curl x", description="Fetch", sandbox_permissions=["network"], justification="Need it.")
    assert out["ok"] is False and "no approval channel" in out["error"]
    out = run(command="curl x", description="Fetch", sandbox_permissions=["network"])
    assert "requires a justification" in out["error"]
    assert box.plain == [] and box.escalated == []


def test_a_permission_that_is_not_withheld_needs_no_card():
    box, gate = _Box(withheld=()), _Gate(True)
    run = make_run_command_handler(box, escalation_ask=gate)
    out = run(command="ls", description="List", sandbox_permissions=["network"], justification="Need it.")
    assert gate.asked == [] and box.plain == ["ls"]
    assert "ignored" in out["note"]


def test_python_escalates_the_same_way():
    box, gate = _Box(), _Gate(True)
    run = make_run_python_handler(box, escalation_ask=gate)
    out = run(code="print(1)", description="Print one", sandbox_permissions=["network"], justification="Need it.")
    assert out["escalated"] == ["network"] and len(box.escalated) == 1
    assert gate.asked[0].tool == "python"
    denied = make_run_python_handler(_Box(), escalation_ask=_Gate(False))(
        code="print(1)", description="Print", sandbox_permissions=["network"], justification="Need it."
    )
    assert "escalating this script" in denied["error"]
    failed = make_run_python_handler(_Box(), escalation_ask=_Gate(True))(code="x", description="Fail")
    assert failed["sandbox"]["withheld"] == ["network"]
