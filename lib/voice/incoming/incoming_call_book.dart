// lib/voice/incoming/incoming_call_book.dart
//
// Which agent calls this device already knows, and where each one is. The
// host re-sends `voice_call_incoming` for every call that still rings on each
// controller (re)attach and on each token refresh, so the same frame can
// arrive many times: a known `call_id` is a no-op (docs/WIRE_CONTRACT.md, "The
// agent calls the user", "When the host sends it"). Pure: the clock is an
// argument.

import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';

import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_mapping.dart';

/// Where one known call is on this device.
enum IncomingCallStatus {
  /// The ring screen is up.
  ringing,

  /// Accept was pressed; the microphone permission is being settled before
  /// `accepted` goes out.
  accepting,

  /// The user took it here; the voice session belongs to it.
  accepted,

  /// The user refused it here, or the host says it was refused.
  declined,

  /// Nobody answered in time (the local ring ran out, or the host's echo).
  missed,

  /// Over after an accept, or stopped for another reason.
  ended,

  /// Another device of the user took it.
  answeredElsewhere,

  /// It arrived after its `expires_at`: never rang.
  expired;

  /// True for every status after which nothing rings or runs any more.
  bool get isFinal => this != ringing && this != accepting && this != accepted;
}

/// One known call.
class IncomingCallEntry {
  IncomingCallEntry(this.call, this.status, {this.params});

  final IncomingCall call;
  IncomingCallStatus status;

  /// The ring this device showed (null when it never rang). Kept for the
  /// missed-call notice when the host's `missed` echo ends the ring.
  CallKitParams? params;

  /// The ring was shown without callkit's own foreground service on accept
  /// (the microphone was not granted then); the service starts after the
  /// permission.
  bool serviceDeferred = false;

  /// The state frames this device already sent for the call.
  final Set<String> sent = <String>{};

  String get callId => call.callId;
}

/// What [IncomingCallBook.admit] decided about a frame.
enum IncomingAdmission {
  /// New and still ringing: show the ring.
  ring,

  /// Known `call_id`: do nothing (do not ring again, keep the timer).
  duplicate,

  /// New, but already over (or too short to show): remembered, never shown.
  expired,
}

class IncomingCallBook {
  IncomingCallBook({
    this.keepAfterExpiry = const Duration(minutes: 30),
    this.maxEntries = 200,
  });

  /// How long a finished call stays known after its `expires_at`. The host
  /// only re-sends calls that still ring, so a little past the expiry is
  /// enough; the margin covers a host clock that runs behind.
  final Duration keepAfterExpiry;

  /// At most this many calls are remembered; the oldest go first.
  final int maxEntries;

  final Map<String, IncomingCallEntry> _entries = <String, IncomingCallEntry>{};

  IncomingCallEntry? operator [](String callId) => _entries[callId];

  int get length => _entries.length;

  /// Records [call] as seen at [now] and says what to do with it.
  IncomingAdmission admit(IncomingCall call, DateTime now) {
    _prune(now);
    if (_entries.containsKey(call.callId)) return IncomingAdmission.duplicate;
    final CallKitParams? params = incomingCallkitParams(call, now);
    if (params == null) {
      _put(IncomingCallEntry(call, IncomingCallStatus.expired));
      return IncomingAdmission.expired;
    }
    _put(IncomingCallEntry(call, IncomingCallStatus.ringing, params: params));
    return IncomingAdmission.ring;
  }

  /// The ringing calls, oldest first.
  Iterable<IncomingCallEntry> get ringing => _entries.values.where(
    (IncomingCallEntry e) => e.status == IncomingCallStatus.ringing,
  );

  void _put(IncomingCallEntry entry) {
    _entries[entry.callId] = entry;
    while (_entries.length > maxEntries) {
      final String? oldestFinal = _entries.keys.cast<String?>().firstWhere(
        (String? id) => _entries[id]!.status.isFinal,
        orElse: () => null,
      );
      _entries.remove(oldestFinal ?? _entries.keys.first);
    }
  }

  void _prune(DateTime now) {
    final DateTime cutoff = now.toUtc().subtract(keepAfterExpiry);
    _entries.removeWhere(
      (String _, IncomingCallEntry e) =>
          e.status.isFinal && e.call.expiresAt.isBefore(cutoff),
    );
  }
}
