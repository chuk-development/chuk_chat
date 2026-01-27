// lib/services/model_capabilities_service.dart

import 'package:chuk_chat/services/model_cache_service.dart';

/// Service for determining model capabilities like vision support.
/// Primarily uses API data (supports_vision field), with fallback to heuristics.
class ModelCapabilitiesService {
  const ModelCapabilitiesService._();

  // Fallback hardcoded list for when API data is unavailable
  static final Set<String> _fallbackImageModelIds = <String>{
    'openai/gpt-4o',
    'openai/gpt-4o-mini',
    'openai/gpt-4.1',
    'openai/gpt-4.1-mini',
    'openai/gpt-4.1-preview',
    'openai/gpt-4.1-turbo',
    'openai/gpt-4-turbo',
    'openai/gpt-4.1-small',
    'openai/gpt-4o-realtime-preview',
    'google/gemini-1.5-pro',
    'google/gemini-1.5-flash',
    'google/gemini-2.0-flash-thinking-exp',
    'google/gemini-2.0-flash',
    'google/gemini-2.0-flash-lite',
    'meta-llama/llama-3.2-90b-vision-instruct',
    'meta-llama/llama-3.2-11b-vision-instruct',
    'meta-llama/llama-3.2-8b-vision',
    'meta-llama/llama-3.2-11b-vision',
    'anthropic/claude-3-opus',
    'anthropic/claude-3-sonnet',
    'anthropic/claude-3-haiku',
    'anthropic/claude-3.5-sonnet',
    'anthropic/claude-3.5-haiku',
    'anthropic/claude-3.5-sonnet-thinking',
    'deepseek/deepseek-vl',
    'x-ai/grok-2',
    'qwen/qwen2.5-vl-72b-instruct',
    'qwen/qwen2.5-vl-7b-instruct',
    'qwen/qwen2-vl-7b-instruct',
    'zhipu/glaive-v-1',
    'ideogram/ideogram-1.0',
    'moonshotai/kimi-k2.5',
  }.map((id) => id.toLowerCase()).toSet();

  static const Set<String> _fallbackImageKeywords = <String>{
    'vision',
    'vl',
    'multimodal',
    'vision-instruct',
    'gpt-4o',
    'gpt-4.1',
    'gpt-4-turbo',
    'gpt4o',
    'gpt4-vision',
    'gemini-1.5',
    'gemini-2.0',
  };

  /// Returns `true` if the provided model id supports image input.
  ///
  /// Priority:
  /// 1. Check cached API data for supports_vision field
  /// 2. Fallback to hardcoded list
  /// 3. Fallback to keyword matching
  static Future<bool> supportsImageInput(String modelId) async {
    if (modelId.isEmpty) return false;

    // Try to get data from API cache first
    try {
      final cachedModels = await ModelCacheService.loadAvailableModels();
      for (final model in cachedModels) {
        if (model['id'] == modelId) {
          final supportsVision = model['supports_vision'];
          if (supportsVision is bool) {
            return supportsVision;
          }
          break;
        }
      }
    } catch (_) {
      // Continue to fallback if cache read fails
    }

    // Fallback to heuristics
    return _supportsImageInputFallback(modelId);
  }

  /// Synchronous fallback method using hardcoded lists
  static bool _supportsImageInputFallback(String modelId) {
    final String lowerId = modelId.toLowerCase();
    if (_fallbackImageModelIds.contains(lowerId)) {
      return true;
    }
    return _fallbackImageKeywords.any(lowerId.contains);
  }

  /// Synchronous version for cases where async is not possible
  /// Uses only hardcoded heuristics
  static bool supportsImageInputSync(String modelId) {
    if (modelId.isEmpty) return false;
    return _supportsImageInputFallback(modelId);
  }
}
