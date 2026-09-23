import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';

/// Whether the chat core runs the Agents way: the host runs every tool
/// (`AgentsToolCallHandler`), sends go over the paired relay
/// (`AgentsChatTransport`) and silence never ends a stream.
///
/// Follows `FEATURE_AGENTS`. The ONE switch for every Agents code path: the
/// chat core (`ToolCallHandler()`, `WebSocketChatService`, `StreamingManager`),
/// storage routing (`ChatOrigin`) and file blocks (`ContentBlock`) all read
/// this and nothing else, so a test selects one side for all of them at once.
bool get agentsChatCore => debugAgentsChatCoreOverride ?? kFeatureAgents;

/// Test seam for [agentsChatCore]. Tests run with `FEATURE_AGENTS` off; an
/// Agents test sets this to true (and back to null in tear-down). Null follows
/// the build.
@visibleForTesting
bool? debugAgentsChatCoreOverride;
