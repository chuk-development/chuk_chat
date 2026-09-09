/// The pairing invite the host prints — as a QR code and as one line of text.
///
/// One string carries everything a phone needs to reach a host it has never
/// seen: which pairing channel to claim, the §15 pairing code, and which relay
/// to dial. It is the *only* thing the user ever handles, which is the point —
/// no host URL, no port, no IP address anywhere in the product.
///
///     cowork://pair?c=<pairing_channel>&k=<code>&r=<relay base url>
///
///  * `c` — the host's **relay pairing channel**: a fresh id with at least 256
///    bits of entropy. Possession of it IS the bootstrap credential — the app
///    claims that channel against its signed-in account and the relay then
///    brokers exactly that one pairing. **Treat it as key material.** It is
///    never logged, never shown in an error, never put in an analytics event.
///  * `k` — the §15 digits, 6 to 8 of them. §15 defines the pairing code as
///    *channel id + digits*, so `c` and `k` together ARE the code: the string
///    the SAS and the commitment are bound to is `<c>-<k>`. That is why a typed
///    code needs nothing else — it carries its own channel.
///  * `r` — optional relay base URL, so a self-hosted backend can be pointed at
///    without a rebuild. Defaults to [kDefaultCoworkRelayBase].
///
/// The QR is a convenience and never the only way in. One parser takes all
/// three forms and treats them identically (bead cowork-b75, resolved): a
/// scanned QR, the whole `cowork://` line pasted — even with text around it —
/// and the bare pairing code typed by hand. Input is trimmed and inner
/// whitespace is dropped, because that is what a person produces.
library;

/// The relay every client dials unless an invite names another one.
const String kDefaultCoworkRelayBase = 'wss://api.chuk.chat';

/// The scheme and host of the pairing URI. `cowork://pair?…`.
const String kCoworkPairingUriScheme = 'cowork';
const String kCoworkPairingUriHost = 'pair';

/// A parsed pairing invite: what to claim, what to prove, where to dial.
class CoworkPairingInvite {
  const CoworkPairingInvite({
    required this.pairingChannel,
    required this.pairingCode,
    required this.relayBase,
  });

  /// The host's high-entropy pairing channel — key material, never logged. It
  /// is both what the relay claim names and the first half of [pairingCode].
  final String pairingChannel;

  /// The §15 pairing code, in the exact `<channel>-<digits>` shape the
  /// `CoworkPairing` joiner and the host initiator both derive their SAS from.
  final String pairingCode;

  /// The relay base URL (`wss://api.chuk.chat`), without a path.
  final Uri relayBase;

  /// The digits half of [pairingCode] — what the user sees printed as "the
  /// code". Safe to show; it is short-lived and single-use.
  String get codeDigits {
    final dash = pairingCode.lastIndexOf('-');
    return dash < 0 ? pairingCode : pairingCode.substring(dash + 1);
  }

  /// Re-renders the invite as the URI the host prints. The host owns the
  /// canonical writer; this exists so a round-trip is testable from one side.
  Uri toUri() => Uri(
    scheme: kCoworkPairingUriScheme,
    host: kCoworkPairingUriHost,
    queryParameters: <String, String>{
      'c': pairingChannel,
      'k': codeDigits,
      if (relayBase.toString() != kDefaultCoworkRelayBase)
        'r': relayBase.toString(),
    },
  );

  /// Parses a scanned QR payload, a pasted invite URI, or a typed pairing code.
  /// Returns null for anything malformed — a bad scan must degrade to "try
  /// again", never to an exception or a half-built connection.
  static CoworkPairingInvite? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final link = _extractLink(text);
    if (link != null) return _fromUri(link);
    return _fromBareCode(text);
  }

  /// Finds the invite link inside whatever was pasted. A person copying the
  /// host's banner takes a line or two of prose with them, and refusing that is
  /// a needless dead end.
  static String? _extractLink(String text) {
    final match = RegExp(
      '(?:$kCoworkPairingUriScheme://|https?://)[^\\s\'"<>]+',
      caseSensitive: false,
    ).firstMatch(text);
    return match?.group(0);
  }

  static CoworkPairingInvite? _fromUri(String text) {
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      return null;
    }
    // `cowork://pair?…` is the contract. An https:// link is accepted only when
    // it carries the same query, so a web fallback page can use one URL.
    if (uri.scheme.toLowerCase() == kCoworkPairingUriScheme) {
      final target = uri.host.isNotEmpty
          ? uri.host
          : uri.path.replaceAll('/', '');
      if (target.toLowerCase() != kCoworkPairingUriHost) return null;
    }
    final channel = uri.queryParameters['c']?.trim() ?? '';
    final code = uri.queryParameters['k']?.trim() ?? '';
    if (channel.isEmpty || code.isEmpty) return null;
    if (channel.contains('-')) return null; // the dash separates the two
    final relay = _relayBaseFrom(uri.queryParameters['r']);
    if (relay == null) return null;
    final pairingCode = _resolveCode(channel, code);
    if (pairingCode == null) return null;
    return CoworkPairingInvite(
      pairingChannel: channel,
      pairingCode: pairingCode,
      relayBase: relay,
    );
  }

  /// The typed fallback: the pairing code alone. §15 defines it as the channel
  /// id plus the digits, so the channel is everything before the LAST dash —
  /// exactly how `CoworkRelayClient.channelIdOf` reads it. A typed code and a
  /// scanned QR therefore resolve to the same channel and the same code.
  static CoworkPairingInvite? _fromBareCode(String text) {
    final code = text.replaceAll(RegExp(r'\s+'), '');
    final dash = code.lastIndexOf('-');
    if (dash <= 0 || dash >= code.length - 1) return null;
    return CoworkPairingInvite(
      pairingChannel: code.substring(0, dash),
      pairingCode: code,
      relayBase: Uri.parse(kDefaultCoworkRelayBase),
    );
  }

  /// `k` is the digits, so the code is `<c>-<k>`. A host that already prints
  /// the whole code in `k` is accepted too, as long as it is this channel's —
  /// one for another channel is a hand-edited link and is refused.
  static String? _resolveCode(String channel, String code) {
    if (code.startsWith('$channel-')) {
      return code.length > channel.length + 1 ? code : null;
    }
    if (code.contains('-')) return null;
    return '$channel-$code';
  }

  /// Normalises `r` into a `ws://` / `wss://` base with no path. Accepts an
  /// https/http URL and a bare host, because that is what a person types.
  /// Returns null when it is not a usable address; absent means the default.
  static Uri? _relayBaseFrom(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return Uri.parse(kDefaultCoworkRelayBase);
    final withScheme = text.contains('://') ? text : 'wss://$text';
    final Uri parsed;
    try {
      parsed = Uri.parse(withScheme);
    } on FormatException {
      return null;
    }
    if (parsed.host.isEmpty) return null;
    final scheme = switch (parsed.scheme.toLowerCase()) {
      'wss' || 'https' => 'wss',
      'ws' || 'http' => 'ws',
      _ => null,
    };
    if (scheme == null) return null;
    return Uri(
      scheme: scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoworkPairingInvite &&
      other.pairingChannel == pairingChannel &&
      other.pairingCode == pairingCode &&
      other.relayBase == relayBase;

  @override
  int get hashCode => Object.hash(pairingChannel, pairingCode, relayBase);

  /// Deliberately says nothing: the channel and the code are secrets, and a
  /// `toString` is exactly how a secret ends up in a log line.
  @override
  String toString() => 'CoworkPairingInvite(relay: $relayBase)';
}
