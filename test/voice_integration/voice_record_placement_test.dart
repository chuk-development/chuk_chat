import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_chat_widgets.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_record_placement.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

DateTime _t(int minute) => DateTime.utc(2026, 9, 29, 10, minute);

VoiceCallRecord _record(int minute) => VoiceCallRecord(
  chatId: 'chat-1',
  mode: VoiceCallMode.chat,
  startedAt: _t(minute),
  endedAt: _t(minute + 1),
  turns: <VoiceTurn>[
    VoiceTurn(role: 'user', text: 'hi', at: _t(minute), isFinal: true),
  ],
);

void main() {
  group('placeRecordsByTime', () {
    List<Object> timeline(
      List<DateTime?> times,
      List<int> recordMinutes,
    ) {
      final VoiceRecordPlacement<int> placement = placeRecordsByTime<int>(
        messageTimes: times,
        records: recordMinutes,
        timeOf: _t,
      );
      // Records as 'r<minute>', messages as their index.
      return flattenPlacement<Object>(
        times.length,
        VoiceRecordPlacement<Object>(
          beforeIndex: <int, List<Object>>{
            for (final MapEntry<int, List<int>> e
                in placement.beforeIndex.entries)
              e.key: <Object>[for (final int m in e.value) 'r$m'],
          },
          trailing: <Object>[for (final int m in placement.trailing) 'r$m'],
        ),
      );
    }

    test('a call lands before the first message sent after it started', () {
      expect(timeline(<DateTime?>[_t(0), _t(10), _t(20)], <int>[15]), <Object>[
        0,
        1,
        'r15',
        2,
      ]);
    });

    test('a call after every message goes to the end', () {
      expect(timeline(<DateTime?>[_t(0), _t(10)], <int>[30]), <Object>[
        0,
        1,
        'r30',
      ]);
    });

    test('a call before every message goes first', () {
      expect(timeline(<DateTime?>[_t(10), _t(20)], <int>[5]), <Object>[
        'r5',
        0,
        1,
      ]);
    });

    test('several calls keep time order, unsorted input or not', () {
      expect(
        timeline(<DateTime?>[_t(0), _t(10), _t(20)], <int>[25, 5, 12, 6]),
        <Object>[0, 'r5', 'r6', 1, 'r12', 2, 'r25'],
      );
    });

    test('an undated row goes with the dated row after it', () {
      // A question without a stamp and its stamped answer stay together.
      expect(
        timeline(<DateTime?>[_t(0), null, null, _t(20)], <int>[15]),
        <Object>[0, 'r15', 1, 2, 3],
      );
    });

    test('rows after the last dated one stay undated; a later call ends '
        'the list', () {
      expect(
        timeline(<DateTime?>[_t(0), null, null], <int>[15]),
        <Object>[0, 1, 2, 'r15'],
      );
      expect(timeline(<DateTime?>[null, null], <int>[15]), <Object>[
        0,
        1,
        'r15',
      ]);
    });

    test('a call at the same moment as a message goes after it', () {
      expect(timeline(<DateTime?>[_t(10)], <int>[10]), <Object>[0, 'r10']);
    });

    test('no records, no placement', () {
      final VoiceRecordPlacement<int> placement = placeRecordsByTime<int>(
        messageTimes: <DateTime?>[_t(0)],
        records: const <int>[],
        timeOf: _t,
      );
      expect(placement.isEmpty, isTrue);
    });
  });

  group('placeVoiceRecords on chat rows', () {
    test('reads sentAt, then startedAt, of each row', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        <String, String>{
          'sender': 'user',
          'text': 'a',
          'sentAt': _t(0).toIso8601String(),
        },
        <String, String>{
          'sender': 'ai',
          'text': 'b',
          'startedAt': _t(1).toIso8601String(),
        },
        <String, String>{'sender': 'user', 'text': 'no stamp'},
        <String, String>{
          'sender': 'user',
          'text': 'c',
          'sentAt': _t(30).toIso8601String(),
        },
      ];
      final VoiceCallRecord early = _record(20);
      final VoiceCallRecord late = _record(40);
      final VoiceRecordPlacement<VoiceCallRecord> placement =
          placeVoiceRecords(rows, <VoiceCallRecord>[late, early]);
      // Row 2 has no stamp: it goes with row 3, so the call sits above it.
      expect(placement.before(2), <VoiceCallRecord>[early]);
      expect(placement.before(3), isEmpty);
      expect(placement.trailing, <VoiceCallRecord>[late]);
      expect(placement.before(0), isEmpty);
    });

    test('the message list itself is not touched', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        <String, String>{
          'sender': 'user',
          'text': 'a',
          'sentAt': _t(0).toIso8601String(),
        },
      ];
      placeVoiceRecords(rows, <VoiceCallRecord>[_record(5)]);
      expect(rows, hasLength(1));
      expect(rows.single.keys, containsAll(<String>['sender', 'text']));
    });
  });
}
