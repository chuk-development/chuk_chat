from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from cowork_executor.browser_profile import retired_browser_hostname


@pytest.fixture
def inventory(tmp_path, monkeypatch):
    profile = tmp_path / ".cowork" / "chrome-profile"
    profile.mkdir(parents=True)
    lock = profile / "SingletonLock"
    lock.symlink_to("retired-host-104")
    containers = [{
        "Id": "current-container", "State": {"Running": True},
        "Config": {"Hostname": "current-host", "Labels": {"cowork.managed": "true"}},
        "Mounts": [{"Source": str(tmp_path), "Destination": "/workspace"}],
    }]
    calls = []
    def run(args, **kwargs):
        calls.append(args)
        return SimpleNamespace(stdout=("\n".join(c["Id"] for c in containers) if args[1] == "ps" else json.dumps(containers)))
    monkeypatch.setattr("cowork_executor.browser_profile.subprocess.run", run)
    return tmp_path, containers, lock, calls


def test_attests_only_retired_owner_with_unique_verified_workspace(inventory):
    workspace, _, _, calls = inventory
    assert retired_browser_hostname("docker", "current-container", str(workspace)) == "retired-host"
    assert calls[0] == ["docker", "ps", "-aq", "--no-trunc"]


@pytest.mark.parametrize("running", [True, False])
def test_existing_owner_is_not_retired_even_if_stopped(inventory, running):
    workspace, containers, _, _ = inventory
    containers.append({"Id": "old-id", "State": {"Running": running}, "Config": {"Hostname": "retired-host"}})
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None


def test_other_running_mount_owner_blocks_attestation(inventory):
    workspace, containers, _, _ = inventory
    containers.append({"Id": "other", "State": {"Running": True}, "Config": {"Hostname": "other"}, "Mounts": [{"Source": str(workspace.parent)}]})
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None


def test_current_container_requires_matching_workspace_and_managed_label(inventory):
    workspace, containers, _, _ = inventory
    containers[0]["Config"]["Labels"] = {}
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None


def test_custom_profile_is_not_attested(inventory):
    workspace, containers, _, _ = inventory
    containers[0]["Config"]["Env"] = ["COWORK_BROWSER_PROFILE=/elsewhere"]
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None


def test_inventory_failure_fails_closed(inventory, monkeypatch):
    workspace, _, _, _ = inventory
    def fail(*args, **kwargs):
        raise OSError("docker unavailable")
    monkeypatch.setattr("cowork_executor.browser_profile.subprocess.run", fail)
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None


def test_no_profile_lock_avoids_docker_inventory(inventory):
    workspace, _, lock, calls = inventory
    lock.unlink()
    assert retired_browser_hostname("docker", "current-container", str(workspace)) is None
    assert not calls
