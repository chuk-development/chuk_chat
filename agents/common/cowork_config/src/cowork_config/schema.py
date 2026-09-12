"""Every CoWork setting, in one place, with its meaning next to it.

CoWork grew without a configuration file. Each process read what it needed
straight from the environment, at the point of use, with its own spelling of
the precedence rule and its own default written inline. That gave about forty
``COWORK_*`` variables spread over ``host/``, ``executor/``, ``manager/``,
``agent/`` and ``sandbox/``. Nobody could list them, nothing validated them, a
typo was invisible, and the only way to learn what one did was to find the line
that read it.

This module is the replacement: one frozen dataclass per subject, composed into
:class:`CoworkConfig`. The dataclasses are frozen because a configuration that
changes under a running task is not a configuration, it is a race. Each field
declares its environment variable and its prose, so:

* the loader can apply one precedence rule to all of them
  (argument > environment > ``config.toml`` > default);
* the validator can name an unknown key, a wrong type or a bad enum value with
  its ``section.key`` path;
* the writer can round trip the whole thing back to a file;
* a process that has to start a shell script can export the settings back into
  the environment the script still reads.

**Nothing here breaks an existing deployment.** Every variable that is set
today still wins over the file, because the environment sits above the file in
the precedence order. ``docker-compose``, the systemd unit and the test suite
keep working unchanged.

Secrets
-------

No secret is ever a field of this schema. A key, a token or a password in a
TOML file is a key, a token or a password in a backup, in a bug report and in a
screenshot. A setting that needs one holds a **reference** instead: the field is
named ``*_key_ref`` or ``*_token_ref`` and its value is the name of an entry in
the encrypted vault the host already keeps. The process resolves the name at
use, never at load. ``tests/test_no_secrets.py`` enforces the naming rule, so a
new field that looks like a secret and is not a reference fails the build.

Version
-------

The file carries ``version = 1`` at its top. See :data:`CONFIG_VERSION` for the
upgrade path when that number has to change.
"""

from __future__ import annotations

from dataclasses import dataclass, field, fields

from .fields import FieldSpec, section_specs, setting

__all__ = [
    "ALL_FIELDS",
    "CONFIG_VERSION",
    "FIELDS_BY_ENV",
    "FIELDS_BY_PATH",
    "NOT_CONFIG",
    "SECTIONS",
    "AutomationConfig",
    "BrowserConfig",
    "CoworkConfig",
    "DocumentsConfig",
    "EmulatorConfig",
    "LimitsConfig",
    "MemoryConfig",
    "ModelConfig",
    "NotifyConfig",
    "PathsConfig",
    "RelayConfig",
    "SandboxConfig",
    "SkillsConfig",
    "VncConfig",
]

#: The version written at the top of every ``config.toml``.
#:
#: **Upgrade path.** The number changes only when a file written by an older
#: CoWork can no longer be read field-for-field: a key was renamed, a type
#: changed, or a value's meaning changed. Adding a key does not need it — an
#: absent key takes its default, which is exactly what the old file means.
#:
#: When it does change, add the migration to ``_MIGRATIONS`` in
#: :mod:`cowork_config.loader`: a function from the raw table of version ``n``
#: to the raw table of version ``n + 1``. The loader chains them, so a version
#: 1 file still loads after version 4 ships, and the next :func:`save_config`
#: writes the new number. A file whose version is **higher** than this one is
#: refused with a named error rather than half-read: a newer CoWork wrote it,
#: and guessing at a key this build has never seen is how an agent ends up
#: running with the wrong model.
CONFIG_VERSION = 1


@dataclass(frozen=True)
class PathsConfig:
    """Where CoWork keeps its own state on this machine."""

    home: str = setting(
        "~/.cowork",
        env="COWORK_HOME",
        doc=(
            "The host state directory: the agent workspaces, the logs, the "
            "account store, the encrypted vault and this configuration file "
            "itself. A leading ``~`` is expanded. The file's own location is "
            "settled before the file is read, so setting this key inside the "
            "file moves the state directory for everything else but not the "
            "file that said so; move the file with ``$COWORK_HOME`` or an "
            "explicit path."
        ),
    )


@dataclass(frozen=True)
class SandboxConfig:
    """The box the agent's commands run in."""

    kind: str = setting(
        "auto",
        env="COWORK_SANDBOX_KIND",
        choices=("auto", "local", "docker"),
        doc=(
            "Which backend runs the agent's commands. ``docker`` is the "
            "isolated one, ``local`` runs them on this machine with no box at "
            "all, and ``auto`` picks ``docker`` when its daemon answers and "
            "falls back to ``local``."
        ),
    )
    image: str = setting(
        "",
        env="COWORK_SANDBOX_IMAGE",
        doc=(
            "The container image every sandbox starts from. Empty means let "
            "the runtime choose: the browser image when it is built on this "
            "machine, else the base image. Set it to pin a private build."
        ),
    )
    image_digest: str = setting(
        "",
        env="COWORK_SANDBOX_IMAGE_DIGEST",
        doc=(
            "A ``sha256:...`` digest the image must have. A tag is a moving "
            "target; a digest is the exact bytes. When set, the runtime "
            "resolves ``image`` and refuses to start a container whose image "
            "digest is different. Empty means do not check."
        ),
    )
    runtime: str = setting(
        "",
        env="COWORK_RUNTIME",
        doc=(
            "The container runtime binary: ``docker``, ``podman`` or a path. "
            "Empty means detect one on PATH."
        ),
    )
    workspace: str = setting(
        "/workspace",
        env="COWORK_WORKSPACE",
        doc=(
            "Where the agent's working directory is mounted **inside** the "
            "container. The image sets it, and the agent reads it back to "
            "translate a host path into a container path. The local backend "
            "has no mount, so there the host directory is used as it is."
        ),
    )
    user: str = setting(
        "cowork",
        env="COWORK_USER",
        doc=(
            "The unprivileged account inside the image that commands run as. "
            "It has passwordless sudo in the base image."
        ),
    )
    uid: int = setting(
        0,
        env="COWORK_UID",
        doc=(
            "The host user id the container's account is remapped to, so a "
            "file the agent writes in the workspace belongs to the person who "
            "started CoWork and not to root. ``0`` means take the id of the "
            "process that starts the container."
        ),
    )
    gid: int = setting(
        0,
        env="COWORK_GID",
        doc="The host group id, with the same rule as ``uid``.",
    )
    test_image: str = setting(
        "debian:stable-slim",
        env="COWORK_TEST_IMAGE",
        doc=(
            "The image the container tests pull. Small on purpose; it is not "
            "the image a task runs in, and nothing outside the test suite "
            "reads it."
        ),
    )


@dataclass(frozen=True)
class BrowserConfig:
    """The browser the agent drives, and the display it paints on."""

    target: str = setting(
        "sandbox",
        env="COWORK_BROWSER_TARGET",
        choices=("sandbox", "user_browser"),
        doc=(
            "Which browser a task drives: the Chromium inside the sandbox, or "
            "the browser the user already has open, through the add-on."
        ),
    )
    headless: bool = setting(
        False,
        env="COWORK_BROWSER_HEADLESS",
        doc=(
            "Run the browser with no display. **Off by default.** The live "
            "view in the app shows the pixels of the display the browser "
            "paints on, and a headless Chromium paints on none: the user gets "
            "a black rectangle and no way to take over a login. A browser "
            "nobody can watch has to be asked for by name."
        ),
    )
    auto_open: bool = setting(
        True,
        env="COWORK_BROWSER_AUTO_OPEN",
        doc=(
            "Open the browser window as soon as a browser server is "
            "connected, instead of waiting for the agent's first navigation. "
            "Off restores the old lazy behaviour."
        ),
    )
    home_url: str = setting(
        "about:blank",
        env="COWORK_BROWSER_HOME",
        doc=(
            "Where the forced first navigation goes on a browser server that "
            "has no tab-listing call. ``about:blank`` is free and offline."
        ),
    )
    cdp_url: str = setting(
        "",
        env="COWORK_BROWSER_CDP_URL",
        doc=(
            "Attach to a browser somebody else runs, over the Chrome DevTools "
            "Protocol: the published port of the browser image, or the user's "
            "own Chrome started with ``--remote-debugging-port``. Empty means "
            "launch one."
        ),
    )
    executable: str = setting(
        "",
        env="COWORK_BROWSER_EXECUTABLE",
        doc=(
            "A specific Chromium or Chrome binary. Empty means search PATH "
            "and then the Playwright download directory. Inside the browser "
            "image the launcher falls back to "
            "``/usr/local/bin/chromium``."
        ),
    )
    profile: str = setting(
        "/workspace/.cowork/chrome-profile",
        env="COWORK_BROWSER_PROFILE",
        doc=(
            "The persistent Chromium profile directory. It lives in the "
            "workspace so a login survives a container restart, which is the "
            "whole point of a browser the user can take over."
        ),
    )
    display: str = setting(
        ":99",
        env="COWORK_BROWSER_DISPLAY",
        doc=(
            "The X display the browser paints on and the live view reads. "
            "Deliberately far from ``:0``: a number in this range is a "
            "virtual display, never the user's own session."
        ),
    )
    screen: str = setting(
        "1280x800x24",
        env="COWORK_BROWSER_SCREEN",
        doc="Geometry of the virtual display, as ``WIDTHxHEIGHTxDEPTH``.",
    )
    viewport: str = setting(
        "1280x800",
        env="COWORK_BROWSER_VIEWPORT",
        doc="The browser window size, as ``WIDTHxHEIGHT``.",
    )
    cursor_theme: str = setting(
        "DMZ-White",
        env="COWORK_BROWSER_CURSOR_THEME",
        doc=(
            "The X cursor theme. A light cursor on a page the user watches is "
            "the difference between seeing the pointer and losing it."
        ),
    )
    cursor_size: int = setting(
        64,
        env="COWORK_BROWSER_CURSOR_SIZE",
        doc=(
            "The cursor size in pixels. Large, because the live view is "
            "scaled down on a phone screen."
        ),
    )
    retired_hostname: str = setting(
        "",
        env="COWORK_BROWSER_RETIRED_HOSTNAME",
        doc=(
            "The hostname of the container that last owned the browser "
            "profile. The profile owner check uses it to tell a dead owner "
            "from a live one; a hostname mismatch alone is not proof of "
            "death. The executor sets it per container."
        ),
    )
    extension_mcp: str = setting(
        "",
        env="COWORK_EXTENSION_MCP",
        doc=(
            "Path to the ``cowork-extension-mcp`` server that drives the "
            "user's own browser. Empty means find it next to the repository, "
            "which is what a source checkout needs; a packaged install sets "
            "it."
        ),
    )


@dataclass(frozen=True)
class VncConfig:
    """The live view: x11vnc on the sandbox display, bridged over the channel."""

    port: int = setting(
        5900,
        env="COWORK_VNC_PORT",
        doc=(
            "The RFB port x11vnc binds **inside** the container. It is never "
            "published: the host reaches it with a ``docker exec`` stdio "
            "bridge, so the port stays on the container's loopback."
        ),
    )
    pass_file: str = setting(
        "/run/cowork-vnc.pass",
        env="COWORK_VNC_PASS_FILE",
        doc=(
            "The root-only file x11vnc re-reads on every client connect. "
            "Writing it rotates the per-view secret without restarting "
            "x11vnc. The secret itself is generated per view and passed in "
            "the environment; it is never a setting and never written here."
        ),
    )
    allow_no_password: bool = setting(
        False,
        env="COWORK_VNC_ALLOW_NOPW",
        doc=(
            "Let x11vnc start with no password. Off, and it must stay off "
            "outside a test: an unauthenticated RFB port is a screen anybody "
            "on the container network can watch and type into."
        ),
    )
    log_path: str = setting(
        "/tmp/x11vnc.log",
        env="COWORK_VNC_LOG",
        doc=(
            "Where x11vnc's output goes inside the container. It must not be "
            "the script's stdout: the daemon would hold the ``docker exec`` "
            "pipe open and the call would never see EOF."
        ),
    )
    xdamage: bool = setting(
        True,
        env="COWORK_VNC_XDAMAGE",
        doc=(
            "Use the X DAMAGE extension to find changed screen regions. On is "
            "much cheaper. Turn it off when a driver reports damage wrongly "
            "and the view shows stale tiles."
        ),
    )


@dataclass(frozen=True)
class DocumentsConfig:
    """``read_document``: any file to Markdown, offline first, vision second."""

    max_bytes: int = setting(
        20 * 1024 * 1024,
        env="COWORK_DOC_MAX_BYTES",
        doc=(
            "The largest file ``read_document`` will pull out of the sandbox. "
            "The bytes travel through the host process, so this is a memory "
            "bound as much as a policy."
        ),
    )
    markdown_cap: int = setting(
        60_000,
        env="COWORK_DOC_MARKDOWN_CAP",
        doc=(
            "How much of the converted Markdown reaches the model. The result "
            "goes straight into the prompt and stays there for every "
            "following turn, so it is bounded."
        ),
    )
    vision_model: str = setting(
        "qwen/qwen3.6-35b-a3b",
        env="COWORK_DOC_VISION_MODEL",
        doc=(
            "The model that reads a scan or a photograph. The offline "
            "converter has no OCR, so a document with no text layer is handed "
            "to this model instead."
        ),
    )
    vision_timeout_seconds: float = setting(
        180.0,
        env="COWORK_DOC_VISION_TIMEOUT_SECONDS",
        doc="How long one vision read may take before it is given up.",
    )
    vision_max_image_bytes: int = setting(
        20 * 1024 * 1024,
        env="COWORK_DOC_VISION_MAX_IMAGE_BYTES",
        doc=(
            "The per-image ceiling the backend enforces. Sending more is a "
            "wasted round trip, so the tool checks it first."
        ),
    )


@dataclass(frozen=True)
class ModelConfig:
    """Which model answers, and how hard it thinks."""

    default: str = setting(
        "deepseek/deepseek-v4-flash",
        env="COWORK_MODEL_DEFAULT",
        doc=(
            "The model a new session uses when the app names none. This is "
            "the setting a typo hurts most: a misspelt model id that fell "
            "back to a default silently is the reason this package validates "
            "instead of shrugging."
        ),
    )
    provider: str = setting(
        "",
        env="COWORK_MODEL_PROVIDER",
        doc=(
            "The provider slug new autonomous sessions route through. Empty "
            "means let the backend choose."
        ),
    )
    reasoning_effort: str = setting(
        "",
        env="COWORK_MODEL_REASONING_EFFORT",
        doc=(
            "The default reasoning effort for new autonomous sessions. Empty "
            "means the backend's own default."
        ),
    )
    api_key_ref: str = setting(
        "",
        env="COWORK_MODEL_API_KEY_REF",
        doc=(
            "The **name** of the vault entry holding the model API key, never "
            "a key. Empty means use the paired account's own token. See the "
            "secrets section of this module's docstring."
        ),
    )


@dataclass(frozen=True)
class MemoryConfig:
    """The agent's long-term memory: an embedder, a writer model and a store."""

    collection: str = setting(
        "cowork_memory",
        env="COWORK_MEM_COLLECTION",
        doc="The vector collection memories are written to and read from.",
    )
    user_id: str = setting(
        "default",
        env="COWORK_MEM_USER_ID",
        doc=(
            "The owner a memory is filed under. One machine, one person, so "
            "the default is a constant rather than an account id."
        ),
    )
    qdrant_dirname: str = setting(
        "qdrant",
        env="COWORK_MEM_QDRANT_DIRNAME",
        doc=(
            "The directory inside the workspace that holds the embedded "
            "vector store. It is local-path Qdrant, so exactly one process "
            "may hold it open at a time."
        ),
    )
    llm_model: str = setting(
        "cowork-memory-writer",
        env="COWORK_MEM_LLM_MODEL",
        doc=(
            "The model that decides what is worth remembering. It runs "
            "through the same backend as the agent, not a second provider."
        ),
    )
    embed_provider: str = setting(
        "proxy",
        env="COWORK_MEM_EMBED_PROVIDER",
        choices=("proxy", "fastembed"),
        doc=(
            "Where embeddings come from: ``proxy`` is the hosted embedding "
            "route, ``fastembed`` is a local model with no network at all. "
            "The local one is also the automatic fall back when there is no "
            "token to call the proxy with."
        ),
    )
    embed_base_url: str = setting(
        "https://api.chuk.chat/v1",
        env="COWORK_MEM_EMBED_BASE_URL",
        doc="The base URL of the hosted embedding route.",
    )
    embed_model: str = setting(
        "qwen3-embedding-8b",
        env="COWORK_MEM_EMBED_MODEL",
        doc="The hosted embedding model.",
    )
    embed_dims: int = setting(
        1024,
        env="COWORK_MEM_EMBED_DIMS",
        doc=(
            "The output dimension of the embedding model. It sizes the "
            "collection, so changing it after memories exist means a new "
            "collection, not a rewrite."
        ),
    )
    embed_api_key_ref: str = setting(
        "",
        env="COWORK_MEM_EMBED_API_KEY_REF",
        doc=(
            "The **name** of the vault entry holding the embedding API key, "
            "never a key. Empty means use the paired account's own token, "
            "which is what a normal install does."
        ),
    )
    fastembed_model: str = setting(
        "nomic-ai/nomic-embed-text-v1.5",
        env="COWORK_MEM_FASTEMBED_MODEL",
        doc="The local embedding model used when ``embed_provider`` is ``fastembed``.",
    )
    fastembed_dims: int = setting(
        768,
        env="COWORK_MEM_FASTEMBED_DIMS",
        doc=(
            "The output dimension of the local model. Set ``embed_dims`` to "
            "the same number when the local embedder is the active one."
        ),
    )


@dataclass(frozen=True)
class NotifyConfig:
    """Telling the user a run ended, when no app is attached."""

    desktop: bool = setting(
        True,
        env="COWORK_DESKTOP_NOTIFY",
        doc=(
            "Show a desktop notification on the machine CoWork runs on. Off "
            "on a headless host, and off in the test suite, which must not "
            "raise a toast on somebody's screen."
        ),
    )
    icon: str = setting(
        "",
        env="COWORK_NOTIFY_ICON",
        doc=(
            "The icon name or path the desktop notification shows. Empty "
            "means the built-in one."
        ),
    )
    ntfy_topic: str = setting(
        "",
        env="COWORK_NTFY_TOPIC",
        doc=(
            "An ntfy.sh topic to publish completions to. A keyless sink for a "
            "self-hoster with no push credentials. The text carries no answer "
            "content, only that a run ended."
        ),
    )
    webhook_url: str = setting(
        "",
        env="COWORK_WEBHOOK_URL",
        doc=(
            "A URL that receives the same keyless completion notice as a "
            "POST. Same rule: no answer content ever leaves in it."
        ),
    )


@dataclass(frozen=True)
class SkillsConfig:
    """The skills a fresh workspace is seeded with."""

    seed_dir: str = setting(
        "",
        env="COWORK_SEED_SKILLS",
        doc=(
            "The directory the shipped seed skills are copied from. Empty "
            "means walk up from the installed package until a ``skills/`` "
            "directory appears, which is what a source checkout wants. Set it "
            "for a packaged install, where no source tree is on disk. Seeding "
            "never overwrites a skill the agent already has."
        ),
    )


@dataclass(frozen=True)
class RelayConfig:
    """The blind relay between the phone and this machine."""

    url: str = setting(
        "wss://api.chuk.chat",
        env="COWORK_RELAY_URL",
        doc=(
            "The cloud relay base URL. It rides in the pairing QR code, so a "
            "self-hosted backend needs no rebuild of the app."
        ),
    )
    local: bool = setting(
        False,
        env="COWORK_RELAY_LOCAL",
        doc=(
            "Run the blind relay on this machine's loopback instead of "
            "dialling the cloud. Same-machine development only: a phone can "
            "never reach 127.0.0.1."
        ),
    )
    local_port: int = setting(
        8787,
        env="COWORK_RELAY_PORT",
        doc="The TCP port the loopback relay binds. Only read when ``local`` is on.",
    )


@dataclass(frozen=True)
class LimitsConfig:
    """The clocks that stop a run that would otherwise never end."""

    run_max_seconds: float = setting(
        7200.0,
        env="COWORK_RUN_MAX_SECONDS",
        doc=(
            "Wall clock guard on one run. A run that keeps going after the "
            "app detached has no other upper bound on the host. After this "
            "the executor fires the run's kill switch and the run closes with "
            "reason ``timeout``. ``0`` disables the guard."
        ),
    )
    run_ack_timeout_seconds: float = setting(
        15.0,
        env="COWORK_RUN_ACK_TIMEOUT_SECONDS",
        doc=(
            "How long a run that ended with an app attached may go without "
            "the app's acknowledgement before it is announced as finished "
            "while away."
        ),
    )
    approval_wait_seconds: float = setting(
        600.0,
        env="COWORK_APPROVAL_WAIT_SECONDS",
        doc=(
            "How long an approval prompt waits for the user before it gives "
            "up and denies. Long enough to walk to the phone and read it; "
            "bounded, so a run cannot hang forever on a question nobody will "
            "answer."
        ),
    )
    secret_request_timeout_seconds: float = setting(
        600.0,
        env="COWORK_SECRET_REQUEST_TIMEOUT_SECONDS",
        doc=(
            "How long a request for a credential waits before every open name "
            "is reported missing. Same window as an approval: walk to the "
            "phone, read the dialog, paste a key. This is a clock, not a "
            "credential; the value the user pastes never touches this file."
        ),
    )
    job_timeout_seconds: float = setting(
        86_400.0,
        env="COWORK_JOB_TIMEOUT_SECONDS",
        doc="The fallback cap on one background job started from the shell tools.",
    )


@dataclass(frozen=True)
class AutomationConfig:
    """Watchers: the agent waking itself when something it watched changed."""

    triggers_path: str = setting(
        ".cowork/automations/triggers.jsonl",
        env="COWORK_TRIGGERS_PATH",
        doc=(
            "The file a watcher appends a trigger line to. A relative path is "
            "resolved against the working directory, which the host sets to "
            "the workspace, so the default keeps every agent's triggers "
            "inside its own workspace."
        ),
    )


@dataclass(frozen=True)
class EmulatorConfig:
    """The local Android AVD, used to look at the phone app on this machine.

    Development tooling, not part of a run. It lives here because
    ``scripts/emulator.sh`` reads these names out of the environment and a
    second, undocumented set of defaults is exactly the drift this package
    exists to stop. A shell script cannot read TOML, so the script is fed
    through :func:`cowork_config.loader.export_environ`.
    """

    avd: str = setting(
        "cowork_x64",
        env="COWORK_AVD",
        doc="The name of the virtual device, created on first start.",
    )
    image: str = setting(
        "system-images;android-36;google_apis;x86_64",
        env="COWORK_AVD_IMAGE",
        doc=(
            "The system image the device is created from. x86_64, never "
            "arm64: the host is x86_64, so an arm64 image runs with no KVM "
            "and is too slow to use."
        ),
    )
    device: str = setting(
        "pixel_7_pro",
        env="COWORK_AVD_DEVICE",
        doc="The hardware profile, matching the physical phone.",
    )
    ram_mb: int = setting(
        4096,
        env="COWORK_AVD_RAM",
        doc="Memory given to the virtual device, in megabytes.",
    )
    data_gb: int = setting(
        8,
        env="COWORK_AVD_DATA",
        doc="Size of the device's data partition, in gigabytes.",
    )
    gpu: str = setting(
        "host",
        env="COWORK_AVD_GPU",
        doc=(
            "The rendering mode. ``host`` puts rendering on the real GPU over "
            "Vulkan, which is the difference between usable and unusable."
        ),
    )
    log_path: str = setting(
        "/tmp/cowork-emulator.log",
        env="COWORK_AVD_LOG",
        doc="Where the emulator's own output goes.",
    )
    extra_args: str = setting(
        "",
        env="COWORK_AVD_EXTRA",
        doc="Extra arguments appended to the emulator command line, unquoted.",
    )
    soft_keyboard: bool = setting(
        False,
        env="COWORK_AVD_SOFT_KEYBOARD",
        doc=(
            "Show the on-screen keyboard. Off, so typing goes through the "
            "host keyboard and a screenshot is not half keyboard."
        ),
    )


@dataclass(frozen=True)
class CoworkConfig:
    """Every setting of one CoWork installation.

    Build it with :func:`cowork_config.load_config`; it is frozen, so change it
    with :func:`cowork_config.set_value`, which returns a new one.
    """

    version: int = CONFIG_VERSION
    paths: PathsConfig = field(default_factory=PathsConfig)
    sandbox: SandboxConfig = field(default_factory=SandboxConfig)
    browser: BrowserConfig = field(default_factory=BrowserConfig)
    vnc: VncConfig = field(default_factory=VncConfig)
    documents: DocumentsConfig = field(default_factory=DocumentsConfig)
    model: ModelConfig = field(default_factory=ModelConfig)
    memory: MemoryConfig = field(default_factory=MemoryConfig)
    notify: NotifyConfig = field(default_factory=NotifyConfig)
    skills: SkillsConfig = field(default_factory=SkillsConfig)
    relay: RelayConfig = field(default_factory=RelayConfig)
    limits: LimitsConfig = field(default_factory=LimitsConfig)
    automation: AutomationConfig = field(default_factory=AutomationConfig)
    emulator: EmulatorConfig = field(default_factory=EmulatorConfig)


def _build_sections() -> dict[str, type]:
    found: dict[str, type] = {}
    for entry in fields(CoworkConfig):
        if entry.name == "version":
            continue
        found[entry.name] = entry.type if isinstance(entry.type, type) else _resolve(entry.type)
    return found


def _resolve(annotation: object) -> type:
    resolved = globals().get(str(annotation))
    if not isinstance(resolved, type):  # pragma: no cover - guarded by tests
        raise TypeError(f"cannot resolve section type {annotation!r}")
    return resolved


#: ``section name -> the dataclass that holds it``, in file order.
SECTIONS: dict[str, type] = _build_sections()

#: Every setting in the schema, in file order.
ALL_FIELDS: tuple[FieldSpec, ...] = tuple(
    spec
    for name, cls in SECTIONS.items()
    for spec in section_specs(name, cls)
)

#: ``"section.key" -> spec``.
FIELDS_BY_PATH: dict[str, FieldSpec] = {spec.path: spec for spec in ALL_FIELDS}

#: ``"COWORK_..." -> spec``. Two settings may never share a variable.
FIELDS_BY_ENV: dict[str, FieldSpec] = {}
for _spec in ALL_FIELDS:
    if _spec.env in FIELDS_BY_ENV:  # pragma: no cover - guarded by tests
        raise ValueError(
            f"{_spec.path} and {FIELDS_BY_ENV[_spec.env].path} both claim {_spec.env}"
        )
    FIELDS_BY_ENV[_spec.env] = _spec
del _spec

#: ``COWORK_*`` names that appear in the source tree and are deliberately **not**
#: settings, with the reason. ``tests/test_env_coverage.py`` reads this: a new
#: variable in the tree must be either a field above or an entry here, so the
#: schema cannot quietly fall behind the code.
NOT_CONFIG: dict[str, str] = {
    "COWORK_ACCOUNT_TOKEN": (
        "A secret. The paired account's bearer token; it belongs to the "
        "account store and the encrypted vault, never to a file a person "
        "edits. A setting that needs it uses a ``*_key_ref`` name instead."
    ),
    "COWORK_VNC_PASSWD": (
        "A secret, and a per-view one: the executor generates a fresh value "
        "for every live view and passes it to the container on that one call. "
        "It has no default and no persistent value to configure."
    ),
    "COWORK_MEM_EMBED_API_KEY": (
        "A secret. Replaced by the setting ``memory.embed_api_key_ref``, "
        "which names a vault entry instead of holding a key."
    ),
    "COWORK_AUTOMATION_ID": (
        "A per-process handle, not a setting. The host sets it on a watcher "
        "process so the process can name the watcher it is; there is no "
        "machine-wide value to configure."
    ),
    "COWORK_AGENT_PLATFORM_PLAN": (
        "Not a variable. It is part of the filename "
        "``docs/COWORK_AGENT_PLATFORM_PLAN.md`` in a docstring."
    ),
    "COWORK_CWD": (
        "Not a variable. It is part of the random shell marker "
        "``__COWORK_CWD_<hex>__:`` the local sandbox prints to find the "
        "working directory after a command."
    ),
    "COWORK_CWD_": "Not a variable. The same shell marker, matched one character longer.",
    "COWORK_RELAY": (
        "Not a variable. It is the Python constant ``TYPE_COWORK_RELAY``, the "
        "name of a frame type on the wire."
    ),
    "COWORK_ERROR": (
        "Not a variable. It is the Python constant ``TYPE_COWORK_ERROR``, the "
        "name of a frame type on the wire."
    ),
    "COWORK_VNC_REVISION": (
        "Not a variable. ``vnc-up.sh`` assigns it itself as a cache buster in "
        "the VNC desktop name; it is never read from the environment."
    ),
}
