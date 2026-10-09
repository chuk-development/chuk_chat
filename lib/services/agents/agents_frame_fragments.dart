import 'dart:convert';
import 'dart:typed_data';

/// The in-frame type of one part of a payload that was too large for one
/// relay frame (docs/WIRE_CONTRACT.md, "Fragments", bead chuk_chat-zhhd).
const String kAgentsFragmentType = 'fragment';

/// Receiver limits. They match the host's `MAX_FRAGMENT_COUNT` and
/// `MAX_FRAGMENT_TOTAL_BYTES` (`chuk_agents_executor.protocol`): 128 parts of
/// 256 KiB. The largest payload the host sends (an 8 MiB file in base64) is
/// about 11 MiB, which is 43 parts.
const int kAgentsMaxFragmentCount = 128;
const int kAgentsMaxFragmentTotalBytes = kAgentsMaxFragmentCount * 256 * 1024;

/// Incomplete payloads kept at one time. The oldest goes first.
const int kAgentsMaxPendingFragments = 4;

/// Joins `fragment` payloads back into the payload the host split.
///
/// The cloud relay refuses a frame over 1 MiB. The host therefore splits a
/// large payload (a `file` of more than about 600 KB, live or replayed) into
/// parts, seals each part as its own frame and sends them in order:
///
/// ```json
/// {"type": "fragment", "fragment_id": "<hex>", "index": 0, "count": 3,
///  "total_bytes": 1048576, "data": "<base64 of the slice>"}
/// ```
///
/// [add] returns a payload that is not a fragment unchanged, `null` while a
/// split payload is incomplete, and the whole decoded payload when its last
/// part arrives. Bad parts are dropped; they never throw. Parts may arrive in
/// any order.
class AgentsFragmentAssembler {
  AgentsFragmentAssembler({this.maxPending = kAgentsMaxPendingFragments});

  final int maxPending;

  // fragment_id -> parts, oldest first (a LinkedHashMap keeps insert order).
  final Map<String, _PendingPayload> _pending = <String, _PendingPayload>{};

  /// The number of incomplete payloads held now. For tests.
  int get pendingCount => _pending.length;

  /// Drops every incomplete payload, for example when the link is new: the
  /// host sends the parts of one payload together, so parts from an old
  /// socket never complete.
  void clear() => _pending.clear();

  Map<String, dynamic>? add(Map<String, dynamic> payload) {
    if (payload['type'] != kAgentsFragmentType) return payload;
    final id = payload['fragment_id'];
    final index = payload['index'];
    final count = payload['count'];
    final total = payload['total_bytes'];
    final data = payload['data'];
    if (id is! String ||
        id.isEmpty ||
        index is! int ||
        count is! int ||
        total is! int ||
        data is! String ||
        count < 1 ||
        count > kAgentsMaxFragmentCount ||
        index < 0 ||
        index >= count ||
        total <= 0 ||
        total > kAgentsMaxFragmentTotalBytes) {
      return null;
    }
    final Uint8List part;
    try {
      part = base64.decode(data);
    } on FormatException {
      return null;
    }
    var entry = _pending[id];
    if (entry == null) {
      while (_pending.length >= maxPending) {
        _pending.remove(_pending.keys.first);
      }
      entry = _PendingPayload(count, total);
      _pending[id] = entry;
    }
    if (entry.count != count || entry.total != total) {
      _pending.remove(id);
      return null;
    }
    entry.parts[index] = part;
    var held = 0;
    for (final p in entry.parts.values) {
      held += p.length;
    }
    if (held > total) {
      _pending.remove(id);
      return null;
    }
    if (entry.parts.length < count) return null;
    _pending.remove(id);
    if (held != total) return null;
    final joined = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      joined.add(entry.parts[i]!);
    }
    try {
      final decoded = jsonDecode(utf8.decode(joined.takeBytes()));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['type'] == kAgentsFragmentType) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }
}

class _PendingPayload {
  _PendingPayload(this.count, this.total);

  final int count;
  final int total;
  final Map<int, Uint8List> parts = <int, Uint8List>{};
}
