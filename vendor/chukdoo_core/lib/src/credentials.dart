import 'dart:convert';

/// Everything a paired device needs to read and write the account.
///
/// Treat the JSON form as a secret: it holds the data key (which decrypts
/// every entry) and the device token. chuk_chat may copy it to the user's
/// other installs; revoking the device in the app stops all of them.
class ChukdooCredentials {
  final String supabaseUrl;
  final String anonKey;
  final String userId;
  final String deviceId;
  final String deviceToken;

  /// The account's 32-byte data key, base64.
  final String dataKey;
  final String deviceName;
  final DateTime pairedAt;

  const ChukdooCredentials({
    required this.supabaseUrl,
    required this.anonKey,
    required this.userId,
    required this.deviceId,
    required this.deviceToken,
    required this.dataKey,
    required this.deviceName,
    required this.pairedAt,
  });

  List<int> get dataKeyBytes => base64Decode(dataKey);

  Map<String, dynamic> toJson() => {
        'v': 1,
        'supabase_url': supabaseUrl,
        'anon_key': anonKey,
        'user_id': userId,
        'device_id': deviceId,
        'device_token': deviceToken,
        'data_key': dataKey,
        'device_name': deviceName,
        'paired_at': pairedAt.toUtc().toIso8601String(),
      };

  factory ChukdooCredentials.fromJson(Map<String, dynamic> json) =>
      ChukdooCredentials(
        supabaseUrl: json['supabase_url'] as String,
        anonKey: json['anon_key'] as String,
        userId: json['user_id'] as String,
        deviceId: json['device_id'] as String,
        deviceToken: json['device_token'] as String,
        dataKey: json['data_key'] as String,
        deviceName: json['device_name'] as String? ?? '',
        pairedAt: DateTime.tryParse(json['paired_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
}
