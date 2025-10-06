import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';

class ProfileRecord {
  const ProfileRecord({
    required this.id,
    required this.email,
    required this.displayName,
    required this.notificationsEnabled,
    required this.weeklySummaryEnabled,
  });

  final String id;
  final String email;
  final String displayName;
  final bool notificationsEnabled;
  final bool weeklySummaryEnabled;

  ProfileRecord copyWith({
    String? email,
    String? displayName,
    bool? notificationsEnabled,
    bool? weeklySummaryEnabled,
  }) {
    return ProfileRecord(
      id: id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      weeklySummaryEnabled: weeklySummaryEnabled ?? this.weeklySummaryEnabled,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'display_name': displayName,
      'notifications_enabled': notificationsEnabled,
      'weekly_summary_enabled': weeklySummaryEnabled,
    };
  }

  static ProfileRecord fromMap(
    Map<String, dynamic> data, {
    required String userEmail,
    required String userId,
  }) {
    return ProfileRecord(
      id: userId,
      email: userEmail,
      displayName: (data['display_name'] as String?) ?? '',
      notificationsEnabled: (data['notifications_enabled'] as bool?) ?? true,
      weeklySummaryEnabled: (data['weekly_summary_enabled'] as bool?) ?? false,
    );
  }
}

class ProfileService {
  const ProfileService();

  SupabaseQueryBuilder get _table => SupabaseService.client.from('profiles');

  Future<ProfileRecord> loadOrCreateProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const ProfileServiceException('User is not signed in.');
    }

    final email = user.email ?? '';

    final existing = await _table.select().eq('id', user.id).maybeSingle();

    if (existing != null) {
      return ProfileRecord.fromMap(existing, userEmail: email, userId: user.id);
    }

    final newRecord = ProfileRecord(
      id: user.id,
      email: email,
      displayName:
          (user.userMetadata?['display_name'] as String?) ??
          email.split('@').first,
      notificationsEnabled: true,
      weeklySummaryEnabled: false,
    );
    await _table.upsert(newRecord.toMap());
    return newRecord;
  }

  Future<ProfileRecord> saveProfile(ProfileRecord record) async {
    await _table.upsert(record.toMap());
    return record;
  }
}

class ProfileServiceException implements Exception {
  const ProfileServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
