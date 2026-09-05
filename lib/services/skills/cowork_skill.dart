import 'package:flutter/foundation.dart' show immutable;

/// One skill as the host lists it (docs/WIRE_CONTRACT.md, "Skills").
///
/// The host is the truth: the app never compiles a skill in, never reads a
/// SKILL.md itself. It shows what the host has and flips one switch per skill;
/// the Python agent then gets exactly the enabled ones.
@immutable
class CoworkSkill {
  const CoworkSkill({
    required this.name,
    required this.description,
    required this.source,
    required this.enabled,
    this.path,
  });

  /// The `name` of the SKILL.md frontmatter, unique on the host.
  final String name;

  /// The level-1 text the model reads on every round (300 chars max).
  final String description;

  /// `builtin` for a skill shipped with the repository (the host's seed set),
  /// `workspace` for one the agent or the user put into the workspace.
  final String source;

  /// The user's switch. Off keeps the file on disk but out of the prompt.
  final bool enabled;

  /// Where the host read it from. Informative only.
  final String? path;

  bool get isBuiltin => source == kSourceBuiltin;

  static const String kSourceBuiltin = 'builtin';
  static const String kSourceWorkspace = 'workspace';

  /// Reads one `skills_list` entry. Null when it has no usable name.
  static CoworkSkill? fromPayload(Map<String, dynamic> payload) {
    final name = payload['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final description = payload['description'];
    final source = payload['source'];
    final enabled = payload['enabled'];
    final path = payload['path'];
    return CoworkSkill(
      name: name.trim(),
      description: description is String ? description : '',
      source: source == kSourceBuiltin ? kSourceBuiltin : kSourceWorkspace,
      enabled: enabled is bool ? enabled : true,
      path: path is String && path.isNotEmpty ? path : null,
    );
  }

  CoworkSkill copyWith({bool? enabled}) => CoworkSkill(
        name: name,
        description: description,
        source: source,
        enabled: enabled ?? this.enabled,
        path: path,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoworkSkill &&
          other.name == name &&
          other.description == description &&
          other.source == source &&
          other.enabled == enabled &&
          other.path == path;

  @override
  int get hashCode => Object.hash(name, description, source, enabled, path);

  @override
  String toString() =>
      'CoworkSkill($name, $source, ${enabled ? 'on' : 'off'})';
}

/// The two frames the app sends about skills. Kept apart from
/// `CoworkRelayController` so the existing test doubles keep compiling; the
/// real relay client implements both, and the source checks `is
/// CoworkSkillsControl` before it sends.
abstract interface class CoworkSkillsControl {
  /// `skill_control`: switch one skill on (`enable`) or off (`disable`). The
  /// host answers with a fresh `skills_list`.
  Future<void> sendSkillControl({required String name, required String action});

  /// `skills_list`: ask for every skill of the host. The host answers with a
  /// `skills_list` frame.
  Future<void> requestSkillsList();
}
