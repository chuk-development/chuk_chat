import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:meta/meta.dart';
import 'package:openui_core/src/prompt/prompt.dart';

/// Metadata for one OpenUI component: name, prop schema, and LLM description.
///
/// Marked `@experimental` per D12.
@experimental
class ComponentDefinition {
  /// Creates a [ComponentDefinition].
  const ComponentDefinition({
    required this.name,
    required this.schema,
    this.description,
    this.internal = false,
  });

  /// Builds a [ComponentDefinition] from a JSON-style map.
  factory ComponentDefinition.fromMap(Map<String, Object?> map) =>
      ComponentDefinition(
        name: map['name']! as String,
        schema: _schemaFrom(map['schema'])!,
        description: map['description'] as String?,
        internal: map['internal'] as bool? ?? false,
      );

  /// The TYPE-token name used in source (e.g. `'Stack'`, `'Card'`).
  final String name;

  /// Prop schema for coercion, prompt generation, and reactive markers.
  final Schema schema;

  /// Optional LLM-facing description for generated prompts.
  final String? description;

  /// When `true`, excluded from generated prompts.
  final bool internal;

  /// Returns this definition as a JSON-style map.
  Map<String, Object?> toMap() => {
    'name': name,
    'schema': schema.value,
    'description': description,
    'internal': internal,
  };
}

/// Metadata for one OpenUI tool: name, description, and input/output schemas.
///
/// Marked `@experimental` per D12.
@experimental
class ToolDefinition {
  /// Creates a [ToolDefinition].
  const ToolDefinition({
    required this.name,
    required this.description,
    this.input,
    this.output,
  });

  /// Builds a [ToolDefinition] from a JSON-style map.
  factory ToolDefinition.fromMap(Map<String, Object?> map) => ToolDefinition(
    name: map['name']! as String,
    description: map['description']! as String,
    input: _schemaFrom(map['input']),
    output: _schemaFrom(map['output']),
  );

  /// Tool name as it appears in source and prompts.
  final String name;

  /// Human-facing description for generated prompts.
  final String description;

  /// JSON schema describing tool input.
  final Schema? input;

  /// JSON schema describing tool output, or `null` when not applicable.
  final Schema? output;

  /// Returns this definition as a JSON-style map.
  Map<String, Object?> toMap() => {
    'name': name,
    'description': description,
    'input': input?.value,
    'output': output?.value,
  };
}

/// Registry of component and tool definitions for prompts and schema lookup.
///
/// Marked `@experimental` per D12.
@experimental
class LibraryDefinition {
  /// Creates a [LibraryDefinition].
  const LibraryDefinition({
    this.components = const [],
    this.tools = const [],
    this.libraryPrompt,
  });

  /// Deserializes a [LibraryDefinition] from JSON.
  factory LibraryDefinition.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, Object?>;
    return LibraryDefinition(
      components: [
        for (final c in (map['components'] as List<Object?>? ?? const []))
          ComponentDefinition.fromMap(c! as Map<String, Object?>),
      ],
      tools: [
        for (final t in (map['tools'] as List<Object?>? ?? const []))
          ToolDefinition.fromMap(t! as Map<String, Object?>),
      ],
      libraryPrompt: map['libraryPrompt'] as String?,
    );
  }

  /// Serializes this library to a JSON string.
  String toJson() => jsonEncode({
    'components': [for (final c in components) c.toMap()],
    'tools': [for (final t in tools) t.toMap()],
    'libraryPrompt': libraryPrompt,
  });

  /// Registered component definitions.
  final List<ComponentDefinition> components;

  /// Registered tool definitions.
  final List<ToolDefinition> tools;

  /// Optional guidance appended to generated prompts.
  final String? libraryPrompt;

  /// Returns the component with [name], or `null` when not registered.
  ComponentDefinition? component(String name) =>
      components.reversed.firstWhereOrNull((c) => c.name == name);

  /// Returns the tool with [name], or `null` when not registered.
  ToolDefinition? tool(String name) =>
      tools.reversed.firstWhereOrNull((t) => t.name == name);

  /// Returns a new library with additional definitions layered on top.
  ///
  /// Last-write-wins on duplicate names.
  LibraryDefinition extend({
    List<ComponentDefinition> components = const [],
    List<ToolDefinition> tools = const [],
  }) => LibraryDefinition(
    components: [...this.components, ...components],
    tools: [...this.tools, ...tools],
    libraryPrompt: libraryPrompt,
  );

  /// Generates a system prompt from all non-internal registered components.
  String prompt({
    String? preamble,
    List<String> examples = const [],
    List<String> additionalRules = const [],
  }) {
    final filtered = components.where((c) => !c.internal).toList();
    return generatePrompt(
      LibraryDefinition(
        components: filtered,
        tools: tools,
        libraryPrompt: libraryPrompt,
      ),
      preamble: preamble,
      examples: examples,
      additionalRules: additionalRules,
    );
  }
}

/// Decodes a schema map, or returns `null` when [value] is `null`.
///
/// Throws a [StateError] when [value] is not a map.
Schema? _schemaFrom(Object? value) {
  if (value == null) return null;
  if (value is Map) return Schema.fromMap(Map<String, dynamic>.from(value));
  throw StateError('Expected Map for Schema, got $value');
}
