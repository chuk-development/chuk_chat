// lib/services/client_request_ids.dart
//
// Request idempotency on `/v2/ws` (api_server CLAUDE.md, "/v2/ws",
// "Request idempotency"). Every chat frame carries a `client_request_id`:
// one id per PASS of a turn (each tool pass gets its own), and the same id
// on every re-send of that pass (a reconnect retry, a cache-miss retry, an
// outbox re-send after an app restart). The server runs a claimed id once:
// a re-send gets the stored answer (`duplicate`) or waits for the running
// one (`duplicate_in_flight`), so it is never billed twice.
//
// Ids of an outbox row are derived from the row id and the pass number, so
// a re-send after an app kill uses the same ids (docs/OFFLINE_SEND.md).

import 'package:uuid/uuid.dart';

abstract final class ClientRequestIds {
  static const Uuid _uuid = Uuid();

  /// The server's limit (`MAX_REQUEST_ID_LEN`).
  static const int maxLength = 64;

  /// Longest base, so that `<base>-p<pass>` stays within [maxLength] for
  /// any pass number the tool loop reaches.
  static const int maxBaseLength = 56;

  /// The same rule as the server's `valid_request_id`: 1 to 64 printable
  /// characters, no whitespace at either end.
  static bool isValid(String? id) {
    if (id == null || id.isEmpty || id.length > maxLength) return false;
    if (id.trim() != id) return false;
    for (final int unit in id.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    return true;
  }

  /// A new random id (34 characters).
  static String fresh() => 'c-${_uuid.v4().replaceAll('-', '')}';

  /// A new random base for one turn (pass `n` sends `<base>-p<n>`). When the
  /// turn's first pass never reached the server and the message goes into
  /// the outbox, the row keeps this base, so its re-send uses the same ids.
  static String freshBase() => fresh();

  /// The base of an outbox row's ids: `ob-<row id>`, with anything the
  /// server would refuse removed. Stable for the life of the row.
  static String outboxBase(String rowId) {
    final StringBuffer clean = StringBuffer();
    for (final int unit in rowId.codeUnits) {
      final bool ok =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5a) ||
          (unit >= 0x61 && unit <= 0x7a) ||
          unit == 0x2d ||
          unit == 0x5f;
      if (ok) clean.writeCharCode(unit);
    }
    final String base = 'ob-$clean';
    return base.length > maxBaseLength
        ? base.substring(0, maxBaseLength)
        : base;
  }

  /// The id of pass [passNumber] (1-based) of a turn: derived from [base]
  /// when the turn has one (an outbox row), else a fresh random id.
  static String forPass(String? base, int passNumber) {
    if (base == null || base.isEmpty) return fresh();
    final String id = '$base-p$passNumber';
    return isValid(id) ? id : fresh();
  }

  // ── Armed bases ─────────────────────────────────────────────────────
  //
  // The outbox sends a row through the chat screen's own send path (a
  // Retry of the bubble) or the headless turn. Both end in a send path that
  // does not know about outbox rows, so the row's base is armed for its
  // chat right before the send and taken by the send path at the start of
  // the turn.

  static final Map<String, String> _armed = <String, String>{};

  /// The next turn of [chatId] uses ids derived from [base].
  static void arm(String chatId, String base) {
    if (chatId.isEmpty || base.isEmpty) return;
    _armed[chatId] = base;
  }

  /// Takes the base armed for [chatId], if any. A base is used by one turn.
  static String? take(String? chatId) {
    if (chatId == null) return null;
    return _armed.remove(chatId);
  }

  /// Drops a base no turn took (the send did not start).
  static void disarm(String chatId) => _armed.remove(chatId);
}
