/// The heal channel: how a paired app finds a host whose account session died.
///
/// The host needs a valid account token to open the relay the normal way. When
/// GoTrue refuses its refresh token, it cannot, and no app could reach it to
/// hand it a new one. So the host parks on the relay's pairing door under a
/// channel derived from the channel key both paired sides hold. This app
/// derives the same value and claims it with its own account; the host then
/// becomes an ordinary executor again and is re-provisioned over the sealed
/// channel. No code, no QR, no new pairing.
///
/// The relay stays blind: the value is an HMAC of the channel id, so it tells
/// the relay nothing about the key, and whoever claims the socket still has to
/// pass the controller-session handshake before the host acts on anything.
///
/// Python twin: `agents/host/src/chuk_agents_host/host_credential.py`
/// (`derive_heal_channel`). Both sides assert the same test vector.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Domain label; must stay byte-identical to the host's.
const String kAgentsHealChannelLabel = 'cowork/host/heal-channel/v1/';

/// HMAC-SHA256(channelKey, label + channelId), url-safe base64, no padding:
/// 43 characters, which is what the relay requires of a pairing channel.
Future<String> deriveAgentsHealChannel(
  List<int> channelKey,
  String channelId,
) async {
  if (channelKey.length != 32) {
    throw ArgumentError.value(
      channelKey.length,
      'channelKey',
      'must be 32 bytes',
    );
  }
  if (channelId.isEmpty) {
    throw ArgumentError.value(channelId, 'channelId', 'must not be empty');
  }
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode('$kAgentsHealChannelLabel$channelId'),
    secretKey: SecretKey(List<int>.of(channelKey)),
  );
  return base64Url.encode(mac.bytes).replaceAll('=', '');
}
