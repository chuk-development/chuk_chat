// lib/platform_config.dart
// Platform configuration using compile-time constants
//
// This file uses const bool flags that can be set at compile time via --dart-define
// to enable aggressive tree-shaking. The Dart compiler can completely remove
// unused branches when these are compile-time constants.

// These can be overridden at build time with:
// flutter build linux --dart-define=PLATFORM_MOBILE=false
// flutter build apk --dart-define=PLATFORM_DESKTOP=false

const bool kPlatformMobile = bool.fromEnvironment(
  'PLATFORM_MOBILE',
  defaultValue: false,
);
const bool kPlatformDesktop = bool.fromEnvironment(
  'PLATFORM_DESKTOP',
  defaultValue: false,
);

// Auto-detect if not explicitly set
const bool kAutoDetectPlatform = !kPlatformMobile && !kPlatformDesktop;

// ============================================================================
// FEATURE FLAGS
// ============================================================================
// These flags control experimental/in-progress features.
// Set to true to enable, false to disable (hide from UI).
//
// Build with features enabled:
// flutter build apk --dart-define=FEATURE_VOICE_MODE=true --dart-define=FEATURE_WORKSPACES=true
//
// Build with defaults (workspaces enabled, others off):
// flutter build apk

/// Voice mode - audio recording and transcription
const bool kFeatureVoiceMode = bool.fromEnvironment(
  'FEATURE_VOICE_MODE',
  defaultValue: false,
);

/// Workspaces — custom AI personas with system prompts, files, and memory
/// settings. Off: the feature earned its place in nobody's day, so it is
/// hidden rather than removed. Nothing is deleted in Supabase — flipping the
/// flag back brings every workspace back with it.
const bool kFeatureWorkspaces = bool.fromEnvironment(
  'FEATURE_WORKSPACES',
  defaultValue: false,
);

/// Artifacts - editable code/markdown/HTML/technical drawing panels alongside chat
const bool kFeatureArtifacts = bool.fromEnvironment(
  'FEATURE_ARTIFACTS',
  defaultValue: true,
);

/// Image Generation - AI image creation via Z-Image Turbo
/// Always enabled - no feature flag needed (Image Generation is production-ready)
const bool kFeatureImageGen = true;

/// Media Manager - View and manage stored media (images) in Supabase
const bool kFeatureMediaManager = true;

/// Server-backed integration tools (GitHub, Slack, Google, Email,
/// Nextcloud). OAuth credentials are managed by the API server; tokens are
/// stored locally on the client.
const bool kFeatureServerTools = bool.fromEnvironment(
  'FEATURE_SERVER_TOOLS',
  defaultValue: false,
);

/// Remote MCP connectors: sign in to a server in the browser and its tools
/// join the tool list. Native only — the sign-in needs a loopback port,
/// which a web page cannot open.
const bool kFeatureMcp = bool.fromEnvironment(
  'FEATURE_MCP',
  defaultValue: true,
);

/// Artifact hosting: the `create_artifact` / `update_artifact` tools publish a
/// self-contained HTML page to the artifacts host and return a public,
/// unguessable URL. Backed by the artifacts service (see ARTIFACTS_BASE_URL).
const bool kFeatureArtifactHosting = bool.fromEnvironment(
  'FEATURE_ARTIFACT_HOSTING',
  defaultValue: true,
);

/// Desktop system tray integration (Linux, Windows, macOS).
/// Disabled by default; enable via --dart-define=FEATURE_SYSTEM_TRAY=true.
const bool kFeatureSystemTray = bool.fromEnvironment(
  'FEATURE_SYSTEM_TRAY',
  defaultValue: false,
);

/// Linux secure storage backend for encryption keys.
/// When disabled, Linux falls back to SharedPreferences instead of keyring.
const bool kFeatureLinuxKeyring = bool.fromEnvironment(
  'FEATURE_LINUX_KEYRING',
  defaultValue: false,
);

/// Direct payment integration via Stripe (web + mobile + desktop).
/// Defaults to true for direct distribution.
/// MUST be set false for Google Play Store builds to comply with Google's billing policy.
const bool kFeaturePaymentsDirect = bool.fromEnvironment(
  'FEATURE_PAYMENTS_DIRECT',
  defaultValue: true,
);

// ============================================================================
// AGENTS-ONLY FEATURE FLAGS
// ============================================================================
// Appended by scripts/import_chat_ui.sh after the verbatim copy of chuk_chat's
// platform_config.dart. These flags do not exist upstream; keep them here so a
// re-sync never drops them.

/// Agents mode — a phone-driven agent that runs on the user's laptop with real
/// system/CLI access, sandboxed execution and a persistent tray daemon. It is a
/// build flag, not a switch in the app: with it on, `main.dart` shows the
/// Agents `MessengerShell`; with it off, upstream's `RootWrapper`, exactly as
/// chuk_chat ships it. There is no in-app switcher between the two.
/// Disabled by default; enable via --dart-define=FEATURE_AGENTS=true.
/// See docs/AGENTS_BUILD_PLAN.md.
const bool kFeatureAgents = bool.fromEnvironment(
  'FEATURE_AGENTS',
  defaultValue: false,
);

/// Agents Demo — laptop-native agent tools (`run_command`, `read_file`,
/// `write_file`, `list_directory`) that let the running app's agent loop act
/// on the local machine. Every path and command cwd is jailed under a
/// configurable root (default the user's home), reads of obvious secret paths
/// are denied, and `run_command` is killed after a timeout. These tools touch
/// the real filesystem, so they stay OFF by default and register only on a
/// build that opts in.
///
/// Disabled by default; enable via --dart-define=FEATURE_AGENTS_DEMO=true.
/// When off, none of the four tools register and a normal build is unchanged.
const bool kFeatureAgentsDemo = bool.fromEnvironment(
  'FEATURE_AGENTS_DEMO',
  defaultValue: false,
);

/// Agent Skills — named procedures the AI loads on demand via the `skill`
/// tool, following the open spec at https://agentskills.io/specification.
/// Only `name` + description sit in the prompt; the body is disclosed on
/// activation. Skills are authored in `assets/skills/` and compiled in — none
/// are fetched at runtime.
///
/// Disabled by default; enable via --dart-define=FEATURE_SKILLS=true.
/// When off, the `skill` tool is never registered and the prompt is
/// byte-identical to a build without this feature.
const bool kFeatureSkills = bool.fromEnvironment(
  'FEATURE_SKILLS',
  defaultValue: false,
);

/// Spotify playback tool. Disabled by default — API server no longer
/// exposes Spotify OAuth endpoints. Set `--dart-define=FEATURE_SPOTIFY=true`
/// only when the backend route is re-enabled.
const bool kFeatureSpotify = bool.fromEnvironment(
  'FEATURE_SPOTIFY',
  defaultValue: false,
);

/// WHOOP health/fitness tool. Disabled by default — integration removed
/// alongside Spotify. Set `--dart-define=FEATURE_WHOOP=true` to re-enable.
const bool kFeatureWhoop = bool.fromEnvironment(
  'FEATURE_WHOOP',
  defaultValue: false,
);
