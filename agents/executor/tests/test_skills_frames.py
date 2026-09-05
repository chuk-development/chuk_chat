"""Skills over the wire (docs/WIRE_CONTRACT.md, "Skills"): the app lists the
host's skills with ``skills_list`` and switches one with ``skill_control``;
both are answered with one terminal ``skills_list`` frame. The executor
answers from ``<workspace>/skills`` and the ``skill_settings`` table of its
own state database — the same table ``build_runtime`` reads, so a switch the
app flips is a skill the next task does not get."""

from __future__ import annotations

from cowork_agent import MockModelClient, SkillSettingsStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.protocol import skill_control_payload, skills_list_request_payload

from wiring import paired_channel

DESCRIPTION = "Summarizes a YouTube video."


def _write_skill(root, name: str, description: str = DESCRIPTION, text: str | None = None):
    directory = root / name
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "SKILL.md").write_text(
        text
        if text is not None
        else f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\nDo the thing.\n"
    )


def _executor(tmp_path, channel, executor_ep, **kw) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="skills",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        workspace=str(workspace),
        **kw,
    )


def _roundtrip(tmp_path, payloads: list[dict], **kw) -> list[list[dict]]:
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep, **kw)
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        replies = []
        for payload in payloads:
            rid = controller.send_payload(payload)
            replies.append(controller.collect(rid, timeout=10.0))
        return replies
    finally:
        executor.stop()


def test_skills_list_names_every_skill_with_source_and_switch(tmp_path):
    seeds = tmp_path / "seed"
    _write_skill(seeds, "youtube-transcript")
    root = tmp_path / "ws" / "skills"
    _write_skill(root, "youtube-transcript")
    _write_skill(root, "deploy", "Deploys the app.")
    _write_skill(root, "broken", text="no frontmatter")
    SkillSettingsStore(tmp_path / "state.db").set_enabled("deploy", False)

    (events,) = _roundtrip(tmp_path, [skills_list_request_payload()], skills_seed_root=str(seeds))

    assert len(events) == 1
    reply = events[0]
    assert reply["type"] == "skills_list"
    assert [(s["name"], s["source"], s["enabled"]) for s in reply["skills"]] == [
        ("youtube-transcript", "builtin", True),
        ("deploy", "workspace", False),
    ]
    assert reply["skills"][0]["description"] == DESCRIPTION
    assert reply["skills"][0]["path"].endswith("youtube-transcript/SKILL.md")
    assert len(reply["errors"]) == 1 and "broken" in reply["errors"][0]


def test_skill_control_flips_the_switch_and_answers_with_the_list(tmp_path):
    root = tmp_path / "ws" / "skills"
    _write_skill(root, "deploy", "Deploys the app.")

    off, on, bad = _roundtrip(
        tmp_path,
        [
            skill_control_payload(name="deploy", action="disable"),
            skill_control_payload(name="deploy", action="enable"),
            skill_control_payload(name="nope", action="disable"),
        ],
    )
    assert off == [
        {
            "type": "skills_list",
            "skills": [
                {
                    "name": "deploy",
                    "description": "Deploys the app.",
                    "source": "workspace",
                    "enabled": False,
                    "path": str(root / "deploy" / "SKILL.md"),
                }
            ],
            "errors": [],
        }
    ]
    assert on[0]["skills"][0]["enabled"] is True
    assert bad[0]["errors"] == ["no skill named 'nope'"]
    assert bad[0]["skills"][0]["enabled"] is True
    # The switch is in the executor's own state database: the store the next
    # ``build_runtime`` reads.
    assert SkillSettingsStore(tmp_path / "state.db").disabled() == set()


def test_a_disabled_skill_is_stored_where_the_next_task_reads_it(tmp_path):
    root = tmp_path / "ws" / "skills"
    _write_skill(root, "deploy", "Deploys the app.")
    _roundtrip(tmp_path, [skill_control_payload(name="deploy", action="disable")])
    assert SkillSettingsStore(tmp_path / "state.db").disabled() == {"deploy"}


def test_an_empty_workspace_lists_nothing_but_still_answers(tmp_path):
    (events,) = _roundtrip(tmp_path, [skills_list_request_payload()])
    assert events == [{"type": "skills_list", "skills": [], "errors": []}]
