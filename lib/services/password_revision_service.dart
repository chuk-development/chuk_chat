import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/supabase_service.dart';

/// Keeps track of a password revision marker so that other sessions can detect
/// password updates and force a logout.
class PasswordRevisionService {
  const PasswordRevisionService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _metadataRevisionKey = 'password_revision';
  static const String _storageRevisionPrefix = 'password_revision_';
  static final _uuid = Uuid();

  static String? _lastCachedUserId;

  /// Returns true when the cached revision does not match the remote one.
  /// When this happens the caller should sign the user out locally.
  ///
  /// This method is designed to be safe - it will return false (no mismatch)
  /// if there are any storage errors, to prevent false-positive logouts.
  static Future<bool> hasRevisionMismatch(User user) async {
    try {
      final remote = _readRemoteRevision(user);
      final storageKey = _storageKey(user.id);
      _lastCachedUserId = user.id;

      if (remote == null || remote.isEmpty) {
        try {
          await _storage.delete(key: storageKey);
        } catch (_) {
          // Ignore storage errors during cleanup
        }
        return false;
      }

      String? local;
      try {
        local = await _storage.read(key: storageKey);
      } catch (e) {
        // If we can't read local storage, don't force logout
        // This prevents random logouts due to storage issues
        return false;
      }

      if (local == null) {
        try {
          await _storage.write(key: storageKey, value: remote);
        } catch (_) {
          // Ignore write errors - we'll try again next time
        }
        return false;
      }

      return local != remote;
    } catch (e) {
      // Any unexpected error should not cause a logout
      return false;
    }
  }

  /// Ensures that a user has a password revision marker, creating one if
  /// necessary and caching it locally.
  ///
  /// Returns the updated user if the metadata had to be patched.
  static Future<User?> ensureRevisionSeeded(User user) async {
    final remote = _readRemoteRevision(user);
    if (remote != null && remote.isNotEmpty) {
      await _cacheRevision(user.id, remote);
      return null;
    }
    return _updateRemoteRevision(user);
  }

  /// Bumps the password revision to a fresh UUID so that other sessions can
  /// detect the change and sign out.
  ///
  /// Returns the updated user instance if Supabase returns one.
  static Future<User?> bumpRevision(User user) async {
    return _updateRemoteRevision(user);
  }

  /// Updates the cached revision to match the remote value.
  static Future<void> cacheRemoteRevision(User user) async {
    final remote = _readRemoteRevision(user);
    _lastCachedUserId = user.id;
    if (remote == null || remote.isEmpty) {
      await _storage.delete(key: _storageKey(user.id));
      return;
    }
    await _cacheRevision(user.id, remote);
  }

  /// Clears any stored revision for the last known user (or the provided [userId]).
  static Future<void> clearCachedRevision({String? userId}) async {
    final targetId = userId ?? _lastCachedUserId;
    if (targetId == null) {
      return;
    }
    await _storage.delete(key: _storageKey(targetId));
    if (userId == null || userId == _lastCachedUserId) {
      _lastCachedUserId = null;
    }
  }

  static Future<User?> _updateRemoteRevision(User user) async {
    final revision = _uuid.v4();
    final existingMetadata = Map<String, dynamic>.from(user.userMetadata ?? {});
    existingMetadata[_metadataRevisionKey] = revision;

    final response = await SupabaseService.auth.updateUser(
      UserAttributes(data: existingMetadata),
    );
    final updatedUser = response.user ?? user;
    await _cacheRevision(updatedUser.id, revision);
    _lastCachedUserId = updatedUser.id;
    return response.user;
  }

  static String? _readRemoteRevision(User user) {
    final value = user.userMetadata?[_metadataRevisionKey];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  static Future<void> _cacheRevision(String userId, String revision) async {
    await _storage.write(key: _storageKey(userId), value: revision);
  }

  static String _storageKey(String userId) => '$_storageRevisionPrefix$userId';
}
