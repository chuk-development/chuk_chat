// lib/services/model_capabilities_service.dart

/// Lightweight heuristics for determining feature support for a given model id.
/// The API does not yet expose explicit capability metadata, so we fall back to
/// a curated allow-list and keyword matching for common multimodal models.
class ModelCapabilitiesService {
  const ModelCapabilitiesService._();

  static final Set<String> _imageModelIds = <String>{
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
  }.map((id) => id.toLowerCase()).toSet();

  static const Set<String> _imageKeywords = <String>{
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

  /// Returns `true` if the provided model id is known (or inferred) to accept
  /// image uploads as part of the prompt.
  static bool supportsImageInput(String modelId) {
    if (modelId.isEmpty) return false;
    final String lowerId = modelId.toLowerCase();
    if (_imageModelIds.contains(lowerId)) {
      return true;
    }
    return _imageKeywords.any(lowerId.contains);
  }
}
