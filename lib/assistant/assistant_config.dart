import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/utils/io_helper.dart';

/// The model the assistant surface runs on. Hard-wired on purpose: the overlay
/// is a fixed-cost, latency-critical surface, not the chat model picker.
const String kAssistantModelId = 'z-ai/glm-5.3-flash';

/// Provider pin that goes with [kAssistantModelId].
const String kAssistantProviderSlug = 'fireworks/serverless';

/// Reasoning level for the assistant turn.
///
/// It is **not** `none`. GLM 5.3 is a thinking-only model and both routes
/// reject a disable directive outright:
///
/// - OpenRouter: `400 Reasoning is mandatory for this endpoint and cannot be
///   disabled.` (model-level `reasoning.mandatory: true`)
/// - Fireworks direct: `400 GLM-5.3 is a thinking-only model; disabling
///   thinking (reasoning_effort='none') is not supported.`
///
/// `low` is the cheapest level the model accepts. The API server drops a
/// `none` for this model anyway (`chat/reasoning.py`), so sending one would
/// silently land on the provider default (`max`) instead — slower, not faster.
/// Switch to a model with `reasoning_mandatory: false` (for example
/// `deepseek/deepseek-v4-flash-0731`) if reasoning must be off entirely.
const String kAssistantReasoningEffort = 'low';

/// Upper bound on tool rounds in one turn, so a confused model cannot loop.
const int kAssistantMaxToolRounds = 6;

/// Answer budget. Spoken answers are short by design.
const int kAssistantMaxTokens = 700;

/// Where the assistant surface can run at all.
///
/// The native channel, the ASSIST intent and the accessibility service are
/// Android-only. Everything that touches [AssistantBridge] must be behind this.
abstract final class AssistantPlatform {
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }
}

/// User-owned assistant preferences. Everything model-related is a constant
/// above; only the things a user actually decides live here.
@immutable
class AssistantSettings {
  const AssistantSettings({this.language = defaultLanguage});

  /// ISO-639-1 code sent to the transcription endpoint and used to localize
  /// the search tools. Empty means "let the recognizer decide".
  static const String defaultLanguage = 'de';

  final String language;

  AssistantSettings copyWith({String? language}) =>
      AssistantSettings(language: language ?? this.language);
}

/// Persistence for [AssistantSettings].
abstract final class AssistantSettingsStore {
  static const String _keyLanguage = 'assistant_language';

  static Future<AssistantSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AssistantSettings(
      language:
          prefs.getString(_keyLanguage) ?? AssistantSettings.defaultLanguage,
    );
  }

  static Future<void> save(AssistantSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLanguage, settings.language.trim());
  }
}
