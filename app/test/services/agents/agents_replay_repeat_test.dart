import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_replay_loader.dart';

/// Bead cowork-4rpt: the same message, twice.
///
/// The app paints an outgoing message the moment it is sent and the answer as
/// it streams. Neither row can carry the host's `mid`, because the host has
/// not stored them yet. On the next replay the host sends that same turn back
/// above the cursor, and a plain append put it on screen a second time.
Map<String, String> user(String text) => <String, String>{
  'sender': 'user',
  'text': text,
  'reasoning': '',
};

Map<String, String> ai(String text) => <String, String>{
  'sender': 'ai',
  'text': text,
  'reasoning': '',
};

List<String> texts(List<Map<String, String>> rows) =>
    rows.map((r) => '${r['sender']}:${r['text']}').toList();

void main() {
  test('a turn the app painted itself is not appended twice', () {
    final existing = <Map<String, String>>[
      user('erste frage'),
      ai('erste antwort'),
      user('Nimm das bitte im Browser'),
    ];
    final delta = <Map<String, String>>[
      user('Nimm das bitte im Browser'),
      ai('mache ich'),
    ];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(existing, delta)), [
      'user:erste frage',
      'ai:erste antwort',
      'user:Nimm das bitte im Browser',
      'ai:mache ich',
    ]);
  });

  test('several repeated turns collapse, not just the last', () {
    final existing = <Map<String, String>>[
      user('a'),
      ai('A'),
      user('b'),
      ai('B'),
    ];
    final delta = <Map<String, String>>[user('b'), ai('B'), user('c')];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(existing, delta)), [
      'user:a',
      'ai:A',
      'user:b',
      'ai:B',
      'user:c',
    ]);
  });

  test('the host copy replaces a local answer that was cut off', () {
    // The streamed row and the stored row are not byte-identical, so the tails
    // do not line up. The user row above them still names the turn.
    final existing = <Map<String, String>>[
      user('was kostet das'),
      ai('Der Preis ist'),
    ];
    final delta = <Map<String, String>>[
      user('was kostet das'),
      ai('Der Preis ist 129,90 EUR.'),
    ];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(existing, delta)), [
      'user:was kostet das',
      'ai:Der Preis ist 129,90 EUR.',
    ]);
  });

  test('a genuinely new turn is appended', () {
    final existing = <Map<String, String>>[user('a'), ai('A')];
    final delta = <Map<String, String>>[user('b'), ai('B')];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(existing, delta)), [
      'user:a',
      'ai:A',
      'user:b',
      'ai:B',
    ]);
  });

  test('a short delta never shrinks the thread', () {
    // 'ok' was said long ago and is said again. Dropping everything between
    // would lose real history, so the delta is appended instead.
    final existing = <Map<String, String>>[
      user('ok'),
      ai('A'),
      user('b'),
      ai('B'),
      user('c'),
      ai('C'),
    ];
    final delta = <Map<String, String>>[user('ok')];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged.length, 7);
    expect(texts(merged).last, 'user:ok');
  });

  test('an empty side is left alone', () {
    expect(
      texts(AgentsReplayLoader.appendWithoutRepeats(<Map<String, String>>[], [
        user('a'),
      ])),
      ['user:a'],
    );
    expect(
      texts(
        AgentsReplayLoader.appendWithoutRepeats([
          user('a'),
        ], <Map<String, String>>[]),
      ),
      ['user:a'],
    );
  });

  _pagingTests();
  _repairTests();

  test('whitespace does not make a turn look new', () {
    final existing = <Map<String, String>>[user('hallo ')];
    final delta = <Map<String, String>>[user('hallo'), ai('hi')];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(existing, delta)), [
      'user:hallo',
      'ai:hi',
    ]);
  });
}

// An OLDER replay page is merged the other way round: the page comes first and
// the cache follows, so the same helper drops the overlap from the cache side.
void _pagingTests() {
  test('an older page does not repeat what the cache already shows', () {
    final page = <Map<String, String>>[user('alt'), ai('ALT'), user('a')];
    final cached = <Map<String, String>>[user('a'), ai('A')];
    expect(texts(AgentsReplayLoader.appendWithoutRepeats(page, cached)), [
      'user:alt',
      'ai:ALT',
      'user:a',
      'ai:A',
    ]);
  });
}

// The one-time repair: a cache written before the repeat guard existed may
// already show a turn twice, and no later delta heals a duplicate in the
// middle. Dropping every cursor once forces a full replay, which replaces the
// cache with the host's transcript.
void _repairTests() {
  test('the first load after the update keeps no cursor', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      '${kReplayCursorPrefix}thread-1': 106,
      '${kReplayTimestampCursorPrefix}thread-1': true,
    });
    final loader = AgentsReplayLoader.instance..reset();
    await loader.load();
    expect(loader.cursorFor('thread-1'), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kReplayRepeatRepairKey), isTrue);
  });

  test('a later load reads the cursors as before', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
      '${kReplayCursorPrefix}thread-1': 106,
      '${kReplayTimestampCursorPrefix}thread-1': true,
    });
    final loader = AgentsReplayLoader.instance..reset();
    await loader.load();
    expect(loader.cursorFor('thread-1'), 106);
  });
}
