"""The executor's half of the automation guards (docs/WIRE_CONTRACT.md,
"Automation guards"): the run's origin reaches the bound backend, a failed
run hands its error and the transient test to the host, and a schedule that
fires into a new chat runs in its owner's mode."""

from __future__ import annotations

from types import SimpleNamespace

from chuk_agents_executor.executor import Executor


class _Bound:
    def __init__(self, origin=None, run=None):
        self.origin = origin
        self.run = run

    def with_origin(self, origin):
        return _Bound(origin, self.run)

    def for_run(self, run_id, automation_id):
        return _Bound(self.origin, (run_id, automation_id))


class _Manager:
    def __init__(self, outcome=None):
        self.calls = []
        self.outcome = outcome

    def bound(self, key):
        return _Bound()

    def finish_run(self, run_id, automation_id, *, ok=True, error=None, transient=False):
        self.calls.append((run_id, automation_id, ok, error, transient))
        return self.outcome


def _run(**kw):
    base = dict(run_id="r1", automation_id="a1", origin="automation", automation_finished=False, cost=None)
    base.update(kw)
    return SimpleNamespace(**base)


def test_the_backend_carries_the_run_origin():
    fake = SimpleNamespace(_automations=_Manager())
    backend = Executor._automation_backend(fake, _run(), "s")
    assert backend.origin == "automation" and backend.run == ("r1", "a1")
    user = Executor._automation_backend(fake, _run(origin="app", automation_id=None), "s")
    assert user.origin == "app" and user.run is None


def test_a_failed_run_hands_error_and_transient_to_the_host():
    class ConnectError(Exception):
        pass

    manager = _Manager({"changed": False, "reported": False, "retry_at": 123.0})
    fake = SimpleNamespace(_automations=manager)
    out = Executor._finish_automation(fake, _run(), ok=False, error="loop failed", exc=ConnectError("x"))
    assert manager.calls == [("r1", "a1", False, "loop failed", True)]
    assert out == {"changed": False, "retry_at": 123.0}
    # After the model answered (the run has a cost) a failure is not transient.
    manager2 = _Manager({"changed": False, "repeated_error": True})
    fake2 = SimpleNamespace(_automations=manager2)
    out2 = Executor._finish_automation(
        fake2, _run(cost={"input_tokens": 5}), ok=False, error="e", exc=ConnectError("x")
    )
    assert manager2.calls[0][4] is False and out2 == {"changed": False, "repeated_error": True}


def test_an_old_host_hook_without_error_still_works():
    class Old:
        def __init__(self):
            self.calls = []

        def finish_run(self, run_id, automation_id, *, ok=True):
            self.calls.append(ok)
            return None

    old = Old()
    assert Executor._finish_automation(SimpleNamespace(_automations=old), _run(), ok=False, error="e") is None
    assert old.calls == [False]
