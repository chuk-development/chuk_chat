"""The task server — runs the real Executor under the Manager's supervisor.

Once pairing and token provisioning are done, this bridges the local relay's
simple ``{"type":"frame",...}`` envelopes to the ``chuk_agents_executor`` Executor,
which already owns the whole agent-loop-in-a-sandbox path behind encrypted
frames. Nothing here re-implements the loop:

- an incoming sealed **task** frame is wrapped in the Executor's ``run_task``
  relay envelope and pushed to it over a loopback link, and
- every ``event`` / ``response`` envelope the Executor streams back has its inner
  sealed frame unwrapped and re-emitted as a ``{"type":"frame",...}`` message to
  the app.

The Executor's own :class:`~chuk_agents_crypto.AgentsFrameOpener` opens the task
frames (default deny — only the paired app's device gets in) and its
:class:`~chuk_agents_crypto.AgentsFrameSealer` seals every result. Lifecycle is the
real :class:`~chuk_agents_executor.ExecutorSupervisor`.

The app's **Stop** rides this same bridge unchanged: a stop is just another
sealed frame, so :meth:`TaskServer.submit` forwards it exactly like a task and
the Executor — the only side that can read it — matches it to the run it names
(§7.1). Nothing here inspects, labels or routes on content; that is the point of
a blind bridge.
"""

from __future__ import annotations

import itertools
import threading
from typing import Any, Callable

from chuk_agents_crypto import AgentsFrameOpener, AgentsFrameSealer
from chuk_agents_manager import (
    RosterStore,
    RuntimeState,
    decode_frames,
    encode_frame,
    make_request,
)
from chuk_agents_sandbox import BaseEnvironment

from chuk_agents_executor import (
    METHOD_EVENT,
    METHOD_RUN_TASK,
    Executor,
    ExecutorSupervisor,
    ModelFactory,
    ModelSelect,
    loopback_pair,
)

# Called with the base64 of one sealed result frame, to send it to the app.
FrameSink = Callable[[str], None]


class TaskServer:
    """Bridges local-relay frame envelopes to a supervised Executor."""

    def __init__(
        self,
        *,
        roster: RosterStore,
        agent_id: str,
        opener: AgentsFrameOpener,
        sealer: AgentsFrameSealer,
        environment: BaseEnvironment,
        environment_factory: Callable[[str], BaseEnvironment] | None = None,
        model_factory: ModelFactory,
        model_select: ModelSelect | None = None,
        db_path: str,
        send_frame: FrameSink,
        send_routed_frame: Callable[[str, str | None], None] | None = None,
        system_prompt: str | None = None,
        workspace: str | None = None,
        max_iterations: int = 50,
        estop_path: str | None = None,
        on_room_frame=None,
        account_token_provider: Callable[[], str | None] | None = None,
        account_session_provider: Callable[[], Any] | None = None,
        browser_mcp: bool = False,
        on_run_finished: Callable[[dict], None] | None = None,
        on_approval_pending: Callable[[dict], None] | None = None,
        on_account_frame: Callable[[dict], None] | None = None,
        on_run_ack: Callable[[dict], None] | None = None,
        secrets=None,
        on_secret_request_pending: Callable[[dict], None] | None = None,
        automations=None,
        on_automation_frame: Callable[[dict], dict | None] | None = None,
        job_frame_sender: Callable[[dict], Any] | None = None,
        on_agent_frame: Callable[[dict], list | None] | None = None,
        skills_seed_root: str | None = None,
    ) -> None:
        self._roster = roster
        self._agent_id = agent_id
        self._send_frame = send_frame
        self._send_routed_frame = send_routed_frame
        self._routes: dict[str, str] = {}
        self._controller_ep, self._executor_ep = loopback_pair()

        def factory(agent):
            return Executor(
                name=agent.name,
                endpoint=self._executor_ep,
                opener=opener,
                sealer=sealer,
                environment=environment,
                # One sandbox per agent (§6, bead cowork-jo2): a session key is
                # an agent id, and every agent that is not this host's own gets
                # its own container and its own workspace from here.
                environment_factory=environment_factory,
                db_path=db_path,
                model_factory=model_factory,
                # Per-task model selection (§ model picker). ``None`` offline, so
                # the injected factory runs every task and no credits are spent.
                model_select=model_select,
                system_prompt=system_prompt,
                workspace=workspace or agent.workspace_dir or None,
                max_iterations=max_iterations,
                estop_path=estop_path,
                on_room_frame=on_room_frame,
                # The account bearer for ``appSession`` MCP connectors (§10): a
                # live accessor, so a token refreshed on the SupabaseSession
                # carries to the next task. ``None`` -> those connectors simply
                # fail to authenticate, never crash.
                account_token_provider=account_token_provider,
                account_session_provider=account_session_provider,
                # Give the agent the Playwright MCP + watchable browser when the
                # sandbox is the browser image (§9.1).
                browser_mcp=browser_mcp,
                # Run-ownership hooks (docs/WIRE_CONTRACT.md): the host notifies
                # on a run that ends with no app attached, reacts to a pending
                # approval, and re-provisions tokens from a second account frame.
                on_run_finished=on_run_finished,
                on_approval_pending=on_approval_pending,
                on_account_frame=on_account_frame,
                on_run_ack=on_run_ack,
                # The user's secret set (docs/WIRE_CONTRACT.md, "Secrets") and
                # the "run blocked on a key, no app attached" nudge.
                secrets=secrets,
                on_secret_request_pending=on_secret_request_pending,
                # Automations (docs/WIRE_CONTRACT.md, "Automations"): the host's
                # manager for the session-scoped tools, and the frame hook.
                automations=automations,
                on_automation_frame=on_automation_frame,
                # Background jobs (docs/WIRE_CONTRACT.md, "Interactive shell
                # and background commands"): the host's sender for a ``job``
                # frame when no run of the session is live.
                job_frame_sender=job_frame_sender,
                # Skills (docs/WIRE_CONTRACT.md, "Skills"): which of the
                # workspace's skills are the shipped seeds.
                skills_seed_root=skills_seed_root,
                # Coworker names (docs/WIRE_CONTRACT.md, "Coworker names"):
                # the host's store answers agent_create / agent_rename /
                # agent_list with the current list.
                on_agent_frame=on_agent_frame,
            )

        self._supervisor = ExecutorSupervisor(roster, factory)
        self._ids = itertools.count(1)
        self._submitted: list[str] = []
        self._stop = threading.Event()
        self._pump: threading.Thread | None = None
        self._rx = b""

    # -- lifecycle -------------------------------------------------------

    @property
    def request_ids(self) -> list[str]:
        """The relay request ids handed out so far (diagnostics/tests)."""
        return list(self._submitted)

    def start(self) -> RuntimeState:
        """Start the Executor (via the supervisor) and the result pump."""
        state = self._supervisor.start(self._agent_id)
        self._pump = threading.Thread(
            target=self._pump_loop, name="host-result-pump", daemon=True
        )
        self._pump.start()
        return state

    def submit(self, frame_b64: str, *, controller_device: str | None = None) -> str:
        """Hand one sealed app frame to the Executor. Returns its request id.

        A task and a Stop travel the same way, because this side cannot tell them
        apart: the frame is sealed for the Executor, and the host is blind by
        design (§14). It is the Executor that opens the frame and dispatches on
        the payload type, so the ``run_task`` method here is a carrier, not a
        claim about the content. Labelling frames would mean either opening them
        (breaking end-to-end encryption) or trusting a cleartext hint the relay
        could forge.
        """
        request_id = f"task-{next(self._ids)}"
        if controller_device is not None:
            self._routes[request_id] = controller_device
        envelope = make_request(METHOD_RUN_TASK, {"frame": frame_b64}, request_id)
        self._submitted.append(request_id)
        self._controller_ep.send(encode_frame(envelope))
        return request_id

    def rebind(self, opener: AgentsFrameOpener, sealer: AgentsFrameSealer) -> None:
        """Hand the Executor a fresh frame codec for a new app session. The
        Executor, its queue, the sandbox and a run in flight all stay as they
        are (docs/WIRE_CONTRACT.md: a run belongs to the host, not a socket)."""
        executor = self._supervisor.executor(self._agent_id)
        if executor is not None:
            executor.rebind_codec(opener, sealer)

    def stop(self) -> None:
        self._stop.set()
        self._supervisor.stop(self._agent_id)
        if self._pump is not None:
            self._pump.join(timeout=2.0)
            self._pump = None

    @property
    def supervisor(self) -> ExecutorSupervisor:
        return self._supervisor

    # -- result pump -----------------------------------------------------

    def _pump_loop(self) -> None:
        while not self._stop.is_set():
            data = self._controller_ep.recv(timeout=0.2)
            if data is None:
                continue
            self._rx += data
            frames, self._rx = decode_frames(self._rx)
            for frame in frames:
                inner = self._inner_frame(frame)
                if inner is not None:
                    request_id = (
                        (frame.get("params") or {}).get("requestId")
                        if frame.get("method") == METHOD_EVENT
                        else frame.get("requestId")
                    )
                    if self._send_routed_frame is not None:
                        self._send_routed_frame(inner, self._routes.get(request_id))
                    else:
                        self._send_frame(inner)
                    if frame.get("type") == "response":
                        self._routes.pop(request_id, None)

    @staticmethod
    def _inner_frame(frame: dict) -> str | None:
        """Pull the sealed-frame base64 out of an Executor event/response envelope."""
        if frame.get("type") == "response":
            return (frame.get("result") or {}).get("frame")
        if frame.get("method") == METHOD_EVENT:
            return (frame.get("params") or {}).get("frame")
        return None
