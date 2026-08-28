import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The embedding model the host uses for semantic memory (Mem0).
///
/// Net-new and deliberately small: a static list of known options plus a
/// stored choice. The host has no capability yet to feed real options or to
/// act on the choice — that is a later phase — so this only remembers what the
/// user picked. The default matches the memory stack's live embedder,
/// `qwen3-embedding-8b`.
class EmbeddingModelService {
  const EmbeddingModelService._();

  static const String _prefsKey = 'embedding_model_v1';

  /// The embedder the memory stack runs by default (deepinfra → fireworks,
  /// 1024 dims). The safety net when nothing is stored.
  static const String defaultModelId = 'qwen3-embedding-8b';

  /// The options offered in the picker. Static for now; a host capability
  /// feeds the real list in a later phase.
  static const List<EmbeddingModelOption> options = <EmbeddingModelOption>[
    EmbeddingModelOption(
      id: 'qwen3-embedding-8b',
      name: 'Qwen3 Embedding 8B',
      dimensions: 1024,
    ),
    EmbeddingModelOption(
      id: 'qwen3-embedding-4b',
      name: 'Qwen3 Embedding 4B',
      dimensions: 1024,
    ),
    EmbeddingModelOption(
      id: 'bge-m3',
      name: 'BGE-M3',
      dimensions: 1024,
    ),
    EmbeddingModelOption(
      id: 'text-embedding-3-large',
      name: 'OpenAI text-embedding-3-large',
      dimensions: 3072,
    ),
  ];

  /// The stored choice, or [defaultModelId] when nothing is stored or the
  /// read fails.
  static Future<String> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [Embedding] Could not read the stored model: $e');
      }
    }
    return defaultModelId;
  }

  /// Persist [modelId]. Failures are swallowed.
  static Future<void> save(String modelId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, modelId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [Embedding] Could not store the model: $e');
      }
    }
  }

  /// The human name for [modelId], falling back to the id itself.
  static String nameFor(String modelId) {
    for (final option in options) {
      if (option.id == modelId) return option.name;
    }
    return modelId;
  }
}

/// One embedding-model choice: an id, a display name, and its vector size.
@immutable
class EmbeddingModelOption {
  const EmbeddingModelOption({
    required this.id,
    required this.name,
    required this.dimensions,
  });

  final String id;
  final String name;
  final int dimensions;
}
