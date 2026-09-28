import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';

/// Whether this is the Agents build. Follows `FEATURE_AGENTS`.
///
/// It says what the build carries, not how one chat runs. The Agents build
/// holds both kinds of chat, and each chat takes its side by its id
/// (`ChatOrigin.isAgentsThread`, which is false for every chat outside this
/// build):
///
/// | | chuk_chat chat | Agents thread |
/// |---|---|---|
/// | send | hosted API | paired relay (`AgentsChatTransport`) |
/// | tools | client loop | host (`AgentsToolCallHandler`) |
/// | silence | idle timeout | log-only watch |
/// | cloud | `encrypted_chats` | `cowork_chats` |
///
/// The chat screen takes its side from the surface that mounts it
/// (`messengerMode` / `agentsThread`). This flag itself gates only what
/// belongs to the whole build: the relay and pairing, the session refresh,
/// the Agents storage bootstrap, settings and file blocks. Tests set
/// [debugAgentsChatCoreOverride] to get the Agents build.
bool get agentsChatCore => debugAgentsChatCoreOverride ?? kFeatureAgents;

/// Test seam for [agentsChatCore]. Tests run with `FEATURE_AGENTS` off; an
/// Agents test sets this to true (and back to null in tear-down). Null follows
/// the build.
@visibleForTesting
bool? debugAgentsChatCoreOverride;
