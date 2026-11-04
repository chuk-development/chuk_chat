// test/services/follow_up_parking_service_test.dart
//
// Follow-ups typed while a reply streams survive a kill: they are parked per
// chat and user, sealed at rest, and removed on sign-out.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/follow_up_parking_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';

void main() {
  final disk = <String, String>{};

  setUp(() {
    disk.clear();
    OutboxCipher.useFake(userId: 'u1');
    FollowUpParkingService.read = (k) async => disk[k];
    FollowUpParkingService.write = (k, v) async => disk[k] = v;
    FollowUpParkingService.delete = (k) async => disk.remove(k);
    FollowUpParkingService.keys = (prefix) async =>
        disk.keys.where((k) => k.startsWith(prefix)).toList();
  });

  tearDown(() {
    OutboxCipher.reset();
    FollowUpParkingService.resetSeams();
  });

  test('save + load round trip, sealed at rest', () async {
    await FollowUpParkingService.save('c1', ['one', 'two']);
    expect(disk.values.single, isNot(contains('one')));
    expect(await FollowUpParkingService.load('c1'), ['one', 'two']);
    expect(await FollowUpParkingService.load('c2'), isEmpty);
  });

  test('an empty list deletes the entry', () async {
    await FollowUpParkingService.save('c1', ['one']);
    await FollowUpParkingService.save('c1', []);
    expect(disk, isEmpty);
  });

  test('wipeUser removes only that user', () async {
    await FollowUpParkingService.save('c1', ['mine']);
    OutboxCipher.useFake(userId: 'u2');
    await FollowUpParkingService.save('c1', ['theirs']);
    await FollowUpParkingService.wipeUser('u1');
    expect(disk, hasLength(1));
    expect(await FollowUpParkingService.load('c1'), ['theirs']);
  });
}
