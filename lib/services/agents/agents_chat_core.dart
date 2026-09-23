import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';

/// Whether the chat core runs the Agents way: the host runs every tool
/// (`AgentsToolCallHandler`), sends go over the paired relay
/// (`AgentsChatTransport`) and silence never ends a stream.
///
/// Follows `FEATURE_AGENTS`. The three switch points — `ToolCallHandler()`,
/// `WebSocketChatService` and `StreamingManager` — read this and nothing else,
/// so a test can select one side for all three at once.
bool get agentsChatCore => debugAgentsChatCoreOverride ?? kFeatureAgents;

/// Test seam for [agentsChatCore]. Tests run with `FEATURE_AGENTS` off; an
/// Agents test sets this to true (and back to null in tear-down). Null follows
/// the build.
@visibleForTesting
bool? debugAgentsChatCoreOverride;
