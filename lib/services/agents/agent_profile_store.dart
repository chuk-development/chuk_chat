/// The display profile of a coworker: its picture, its accent colour, its role
/// line and its standing brief, as the user set them in this app.
///
/// ## Why this is a store of its own
///
/// The roster ([AgentRosterSource]) is deliberately not persisted: the durable
/// roster lives on the host, and the wire carries only ids and NAMES
/// (`agent_create` / `agent_rename` / `agent_list`, see docs/WIRE_CONTRACT.md).
/// A picture, a colour, a role line and a brief have no wire frame, so the host
/// can neither store nor return them. They are display data this app owns, and
/// this store is where they live — one JSON blob in `SharedPreferences`, keyed
/// by agent id.
///
/// So: editing a coworker's NAME goes through the roster and reaches the host;
/// everything in here stays on this device until a frame exists for it. The
/// profile page says as much next to the fields it writes.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// The picture is copied into the app's own support directory. Both imports are
// conditional so a web build still compiles: on web the stubs report "no file
// system" and [setPhotoFromFile] returns null.
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

/// One coworker's display profile. Every field is optional: an agent with no
/// entry renders exactly as it did before this store existed.
/// The silhouette a coworker's face is cut from. `expressive` is the automatic
/// one: it derives a shape from the agent id, which is what a coworker gets
/// until the user picks. The rest are the shapes of the expressive family,
/// named so the user can choose one on purpose.
///
/// Values are persisted by name, and an unknown name reads back as null (=
/// automatic), so an older build simply falls back instead of breaking.
enum AgentAvatarShape {
  round,
  oval,
  roundedSquare,
  square,
  expressive,
  cookie,
  clover,
  flower,
  diamond,
  gem,
  triangle,
  burst,
}

@immutable
class AgentProfile {
  const AgentProfile({
    this.photoPath,
    this.colorValue,
    this.role,
    this.brief,
    this.shape,
  });

  /// Null keeps the original stable expressive silhouette.
  final AgentAvatarShape? shape;

  /// Absolute path of the picture copied into the app's support directory.
  /// Null means "use the generated blob face".
  final String? photoPath;

  /// ARGB value of the accent the user picked for this coworker. Null means
  /// "derive the colour from the agent id", which is what the roster did before.
  final int? colorValue;

  /// A short role line ("researcher", "release manager"). Display only.
  final String? role;

  /// The standing job the user wrote for this coworker. Display only until the
  /// host serves a brief.
  final String? brief;

  bool get isEmpty =>
      photoPath == null &&
      colorValue == null &&
      role == null &&
      brief == null &&
      shape == null;

  /// Merges the given fields. A `clear*` flag wins over a value, so an emptied
  /// text field really removes what was stored instead of merging the old value
  /// back in.
  AgentProfile copyWith({
    String? photoPath,
    int? colorValue,
    String? role,
    String? brief,
    AgentAvatarShape? shape,
    bool clearPhoto = false,
    bool clearColor = false,
    bool clearRole = false,
    bool clearBrief = false,
    bool clearShape = false,
  }) => AgentProfile(
    photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
    colorValue: clearColor ? null : (colorValue ?? this.colorValue),
    role: clearRole ? null : (role ?? this.role),
    brief: clearBrief ? null : (brief ?? this.brief),
    shape: clearShape ? null : (shape ?? this.shape),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (photoPath != null) 'photo': photoPath,
    if (colorValue != null) 'color': colorValue,
    if (role != null) 'role': role,
    if (brief != null) 'brief': brief,
    if (shape != null) 'shape': shape!.name,
  };

  static AgentProfile fromJson(Map<String, dynamic> json) => AgentProfile(
    photoPath: json['photo'] as String?,
    colorValue: json['color'] is int
        ? json['color'] as int
        : int.tryParse('${json['color']}'),
    role: json['role'] as String?,
    brief: json['brief'] as String?,
    shape: _readShape(json['shape']),
  );

  static AgentAvatarShape? _readShape(Object? value) {
    for (final shape in AgentAvatarShape.values) {
      if (shape.name == value) return shape;
    }
    return null;
  }
}

class AgentProfileStore extends ChangeNotifier {
  AgentProfileStore();

  static final AgentProfileStore instance = AgentProfileStore();

  static const String _prefsKey = 'cowork_agent_profiles_v1';

  final Map<String, AgentProfile> _profiles = <String, AgentProfile>{};
  bool _loaded = false;

  bool get loaded => _loaded;

  /// The stored profile for [agentId], or an empty one. Never null, so callers
  /// read `profileOf(id).role` without a null dance.
  AgentProfile profileOf(String agentId) =>
      _profiles[agentId] ?? const AgentProfile();

  /// Reads the store from disk. Safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final MapEntry<dynamic, dynamic> entry in decoded.entries) {
            final dynamic value = entry.value;
            if (value is Map) {
              _profiles['${entry.key}'] = AgentProfile.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          }
        }
      }
    } catch (error) {
      debugPrint('⚠️ [AgentProfileStore] load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Writes one or more fields of [agentId]'s profile and persists the store.
  Future<void> update(
    String agentId, {
    String? photoPath,
    int? colorValue,
    String? role,
    String? brief,
    AgentAvatarShape? shape,
    bool clearPhoto = false,
    bool clearColor = false,
    bool clearRole = false,
    bool clearBrief = false,
    bool clearShape = false,
  }) async {
    final AgentProfile next = profileOf(agentId).copyWith(
      photoPath: photoPath,
      colorValue: colorValue,
      role: role,
      brief: brief,
      shape: shape,
      clearPhoto: clearPhoto,
      clearColor: clearColor,
      clearRole: clearRole,
      clearBrief: clearBrief,
      clearShape: clearShape,
    );
    if (next.isEmpty) {
      _profiles.remove(agentId);
    } else {
      _profiles[agentId] = next;
    }
    notifyListeners();
    await _persist();
  }

  /// Forgets everything stored for [agentId] — called when the coworker is
  /// deleted, so a later agent with the same id cannot inherit a stale face.
  Future<void> forget(String agentId) async {
    if (_profiles.remove(agentId) == null) return;
    notifyListeners();
    await _persist();
  }

  /// Copies [sourcePath] into the app's support directory and stores it as
  /// [agentId]'s picture. Returns the stored path, or null when the copy fails
  /// (a web build has no file system for this).
  Future<String?> setPhotoFromFile(String agentId, String sourcePath) async {
    if (kIsWeb) return null;
    try {
      final Directory dir = await getApplicationSupportDirectory();
      final Directory faces = Directory(p.join(dir.path, 'agent_faces'));
      if (!faces.existsSync()) await faces.create(recursive: true);
      final String ext = p.extension(sourcePath).isEmpty
          ? '.png'
          : p.extension(sourcePath);
      final String safeId = agentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final String target = p.join(
        faces.path,
        '$safeId-${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      // Read + write rather than File.copy: the web stub has no copy, and this
      // path is the same on every platform that does have a file system.
      final Uint8List bytes = await File(sourcePath).readAsBytes();
      await File(target).writeAsBytes(bytes, flush: true);
      // Drop the previous picture so the directory does not grow forever.
      final String? old = profileOf(agentId).photoPath;
      if (old != null && old != target) {
        try {
          final File oldFile = File(old);
          if (oldFile.existsSync()) await oldFile.delete();
        } catch (_) {
          // A picture we cannot delete is not worth failing the update over.
        }
      }
      await update(agentId, photoPath: target);
      return target;
    } catch (error) {
      debugPrint('⚠️ [AgentProfileStore] setPhotoFromFile failed: $error');
      return null;
    }
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_profiles.isEmpty) {
        await prefs.remove(_prefsKey);
        return;
      }
      final Map<String, dynamic> out = <String, dynamic>{
        for (final MapEntry<String, AgentProfile> e in _profiles.entries)
          e.key: e.value.toJson(),
      };
      await prefs.setString(_prefsKey, jsonEncode(out));
    } catch (error) {
      debugPrint('⚠️ [AgentProfileStore] persist failed: $error');
    }
  }
}
