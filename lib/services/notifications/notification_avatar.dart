/// The agent's avatar as a small PNG file, for notification icons and for
/// the host (docs/agents/NOTIFICATIONS.md, rule 3 and "Avatar on the host").
///
/// The PNG is the same face the app draws ([paintShareTargetIcon] in badge
/// mode): a round badge with the user's photo, or the generated figure. It is
/// cached per agent id in `<app support>/notification_avatars/`. A sidecar
/// file holds a fingerprint of what the picture shows (name, photo, colour,
/// figure). When the fingerprint changes, the PNG is painted again.
///
/// The background isolate of a push cannot paint (it has no profile store
/// and no raster work is safe there). It only reads the cached file with
/// [AgentNotificationAvatar.cachedPath]. The app paints the files ahead of
/// time ([AgentNotificationAvatar.ensure]) when the roster or a profile
/// changes.
library;

import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/share/share_target_icon.dart';

/// Paints the avatar of [agentId] at [size] pixels as PNG bytes.
typedef AvatarPngPainter = Future<Uint8List?> Function(
  String agentId,
  String name,
  double size,
);

class AgentNotificationAvatar {
  AgentNotificationAvatar({
    AvatarPngPainter? paintPng,
    Future<Directory> Function()? supportDir,
    AgentProfileStore? profiles,
  }) : _painter = paintPng,
       _baseDir = supportDir ?? getApplicationSupportDirectory,
       _store = profiles;

  static final AgentNotificationAvatar instance = AgentNotificationAvatar();

  /// The edge of the PNG in pixels.
  static const double size = 192;

  /// The host accepts no bigger PNG (`agent_avatar_set`).
  static const int maxPngBytes = 128 * 1024;

  /// Smaller edges to try when a photo makes the PNG too big.
  static const List<double> _fallbackSizes = <double>[160, 128, 96];

  final AvatarPngPainter? _painter;
  final Future<Directory> Function() _baseDir;
  final AgentProfileStore? _store;

  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  AgentProfileStore get _profiles => _store ?? AgentProfileStore.instance;

  /// What the picture shows. A change means "paint again".
  static String fingerprintOf(String name, AgentProfile profile) => <Object?>[
    'v1',
    name.trim(),
    profile.photoPath,
    profile.colorValue,
    profile.round,
    profile.shape?.name,
  ].join('|');

  /// A file name safe on every platform.
  static String safeId(String agentId) =>
      agentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<Directory?> _dir() async {
    if (kIsWeb) return null;
    final Directory base = await _baseDir();
    final Directory dir = Directory(p.join(base.path, 'notification_avatars'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// The cached PNG of [agentId], or null when none is there. No painting:
  /// safe in the background isolate.
  Future<String?> cachedPath(String agentId) async {
    if (agentId.isEmpty) return null;
    try {
      final Directory? dir = await _dir();
      if (dir == null) return null;
      final File file = File(p.join(dir.path, '${safeId(agentId)}.png'));
      return file.existsSync() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// The PNG of [agentId], painted when it is missing or out of date.
  /// Returns the file path, or null when painting fails.
  Future<String?> ensure(String agentId, {required String name}) {
    if (agentId.isEmpty) return Future<String?>.value(null);
    final Future<String?>? running = _inFlight[agentId];
    if (running != null) return running;
    // A block body: `remove` returns this very future, and `whenComplete`
    // would wait for a returned future, so an arrow body waits for itself.
    final Future<String?> job = _ensure(agentId, name).whenComplete(() {
      _inFlight.remove(agentId);
    });
    _inFlight[agentId] = job;
    return job;
  }

  /// The PNG bytes of [agentId] (painted when needed), or null.
  Future<Uint8List?> pngBytes(String agentId, {required String name}) async {
    final String? path = await ensure(agentId, name: name);
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// The fingerprint the cached PNG of [agentId] was painted for.
  Future<String?> cachedFingerprint(String agentId) async {
    try {
      final Directory? dir = await _dir();
      if (dir == null) return null;
      final File key = File(p.join(dir.path, '${safeId(agentId)}.key'));
      return key.existsSync() ? await key.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  /// Deletes the cached PNG of [agentId] (the agent was deleted).
  Future<void> forget(String agentId) async {
    try {
      final Directory? dir = await _dir();
      if (dir == null) return;
      for (final String ext in <String>['png', 'key']) {
        final File file = File(p.join(dir.path, '${safeId(agentId)}.$ext'));
        if (file.existsSync()) await file.delete();
      }
    } catch (_) {
      // A file we cannot delete only costs disk space.
    }
  }

  Future<String?> _ensure(String agentId, String name) async {
    try {
      final Directory? dir = await _dir();
      if (dir == null) return null;
      final String id = safeId(agentId);
      final File png = File(p.join(dir.path, '$id.png'));
      final File key = File(p.join(dir.path, '$id.key'));
      final String want = fingerprintOf(name, _profiles.profileOf(agentId));
      if (png.existsSync() && key.existsSync()) {
        if (await key.readAsString() == want) return png.path;
      }
      final Uint8List? bytes = await _paintWithinLimit(agentId, name);
      if (bytes == null) return null;
      // Write to a temp file and rename it, so a reader never sees half a
      // PNG (the push isolate can read at any time).
      final File tmp = File(p.join(dir.path, '$id.png.tmp'));
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(png.path);
      await key.writeAsString(want, flush: true);
      return png.path;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AgentNotificationAvatar] paint failed: $error');
      }
      return null;
    }
  }

  Future<Uint8List?> _paintWithinLimit(String agentId, String name) async {
    for (final double edge in <double>[size, ..._fallbackSizes]) {
      final Uint8List? bytes = await _paint(agentId, name, edge);
      if (bytes == null) return null;
      if (bytes.length <= maxPngBytes) return bytes;
    }
    return null;
  }

  Future<Uint8List?> _paint(String agentId, String name, double edge) {
    final AvatarPngPainter? painter = _painter;
    if (painter != null) return painter(agentId, name, edge);
    return paintShareTargetIcon(
      agentId: agentId,
      name: name,
      store: _profiles,
      size: edge,
      badge: true,
    );
  }
}
