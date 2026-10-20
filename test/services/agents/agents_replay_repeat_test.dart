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
  test('a cached role: assistant tail overlaps a sender: ai delta beyond '
      'the repeat window', () {
    // The cache hands rows back in the stored shape (`role`), the replay in
    // the wire shape (`sender`). The overlap starts further back than
    // repeatWindow, so only the linear-time tail match can find it, and that
    // match hashes rows: the hash must read both shapes.
    final int n = AgentsReplayLoader.repeatWindow + 5;
    Map<String, String> cached(int i) => <String, String>{
      'role': i.isEven ? 'user' : 'assistant',
      'text': 'turn $i',
    };
    Map<String, String> wire(int i) =>
        i.isEven ? user('turn $i') : ai('turn $i');
    final existing = <Map<String, String>>[
      for (int i = 0; i < 10; i++)
        <String, String>{'role': 'user', 'text': 'old $i'},
      for (int i = 0; i < n; i++) cached(i),
    ];
    final delta = <Map<String, String>>[
      for (int i = 0; i < n; i++) wire(i),
      ai('new answer'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged, hasLength(10 + n + 1));
    expect(merged.where((r) => r['text'] == 'turn 0'), hasLength(1));
    // The host's copy wins.
    expect(merged[10]['sender'], 'user');
    expect(merged.last['text'], 'new answer');
  });

  test('a repeated question with a different answer is appended, not '
      'written over', () {
    // The cache holds an older turn "ok" -> "A". A new turn asks "ok" again
    // and gets "B". Aligning on the user row must not replace "A".
    final existing = <Map<String, String>>[
      user('erste frage'),
      ai('erste antwort'),
      <String, String>{'role': 'user', 'text': 'ok'},
      <String, String>{'role': 'assistant', 'text': 'Antwort A'},
    ];
    final delta = <Map<String, String>>[user('ok'), ai('Antwort B')];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged.map((r) => r['text']), [
      'erste frage',
      'erste antwort',
      'ok',
      'Antwort A',
      'ok',
      'Antwort B',
    ]);
  });

  test('a cut-off streamed answer is still replaced by the full one', () {
    final existing = <Map<String, String>>[
      user('frage'),
      <String, String>{'role': 'assistant', 'text': 'Die Antwort ist'},
    ];
    final delta = <Map<String, String>>[
      user('frage'),
      ai('Die Antwort ist vollstaendig.'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged.map((r) => r['text']), [
      'frage',
      'Die Antwort ist vollstaendig.',
    ]);
  });

  test('a replaced local voice row keeps its voice metadata', () {
    final existing = <Map<String, String>>[
      user('erste frage'),
      ai('erste antwort'),
      <String, String>{
        'role': 'user',
        'text': 'Wie wird das Wetter?',
        'inputMode': 'voice',
        'voiceDurationMs': '4200',
      },
    ];
    final delta = <Map<String, String>>[
      user('Wie wird das Wetter?'),
      ai('Sonnig.'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged, hasLength(4));
    expect(merged[2]['sender'], 'user', reason: 'the host row replaced it');
    expect(merged[2]['inputMode'], 'voice');
    expect(merged[2]['voiceDurationMs'], '4200');
    expect(merged[3].containsKey('inputMode'), isFalse);
    expect(delta[0].containsKey('inputMode'), isFalse, reason: 'no mutation');
  });

  test('the streamed case keeps the voice metadata too', () {
    final existing = <Map<String, String>>[
      user('erste frage'),
      <String, String>{
        'role': 'user',
        'text': 'Lies die Mail vor',
        'inputMode': 'voice',
        'voiceDurationMs': '1800',
      },
      ai('Die Mail sa'), // cut off while streaming
    ];
    final delta = <Map<String, String>>[
      user('Lies die Mail vor'),
      ai('Die Mail sagt: alles gut.'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(texts(merged), [
      'user:erste frage',
      'user:Lies die Mail vor',
      'ai:Die Mail sagt: alles gut.',
    ]);
    expect(merged[1]['inputMode'], 'voice');
    expect(merged[1]['voiceDurationMs'], '1800');
  });

  test('a host row keeps its own metadata value', () {
    final existing = <Map<String, String>>[
      <String, String>{'role': 'user', 'text': 'hallo', 'inputMode': 'voice'},
    ];
    final delta = <Map<String, String>>[
      <String, String>{'sender': 'user', 'text': 'hallo', 'inputMode': 'text'},
      ai('hi'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged.first['inputMode'], 'text');
  });

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
      texts(
        AgentsReplayLoader.appendWithoutRepeats(<Map<String, String>>[], [
          user('a'),
        ]),
      ),
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
    expect(prefs.getBool(kReplayFileRepairKey), isTrue);
  });

  // Bead chuk_chat-zhhd: an install that already ran the repeat repair still
  // drops its cursors once, so a file the relay refused (its row now below
  // the cursor) comes back in a full replay.
  test('the file repair drops the cursors once more', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
      '${kReplayCursorPrefix}thread-1': 1436,
      '${kReplayTimestampCursorPrefix}thread-1': true,
      '${kReplayRunMetaCursorPrefix}thread-1': true,
    });
    final loader = AgentsReplayLoader.instance..reset();
    await loader.load();
    expect(loader.cursorFor('thread-1'), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kReplayFileRepairKey), isTrue);

    // The next start reads the cursor again: the repair runs once.
    await prefs.setInt('${kReplayCursorPrefix}thread-1', 1436);
    final again = AgentsReplayLoader.instance..reset();
    await again.load();
    expect(again.cursorFor('thread-1'), 1436);
  });

  test('a later load reads the cursors as before', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kReplayRepeatRepairKey: true,
      kReplayFileRepairKey: true,
      '${kReplayCursorPrefix}thread-1': 106,
      '${kReplayTimestampCursorPrefix}thread-1': true,
      '${kReplayRunMetaCursorPrefix}thread-1': true,
    });
    final loader = AgentsReplayLoader.instance..reset();
    await loader.load();
    expect(loader.cursorFor('thread-1'), 106);
  });
  test('repeated identical turns from the cache are not kept twice', () {
    // The cache hands its rows back in the stored shape: `role`, no
    // `sender` (bead chuk_chat-kl8x). The overlap check must read both, or
    // it never matches and the fallback aligns on a later "ok".
    Map<String, String> cached(String role, String text) => <String, String>{
      'role': role,
      'text': text,
    };
    final existing = <Map<String, String>>[
      cached('user', 'ok'),
      cached('assistant', 'ok'),
      cached('user', 'ok'),
      cached('assistant', 'ok'),
    ];
    final delta = <Map<String, String>>[
      user('ok'),
      ai('ok'),
      user('ok'),
      ai('ok'),
      user('ok'),
      ai('ok'),
    ];
    final merged = AgentsReplayLoader.appendWithoutRepeats(existing, delta);
    expect(merged, hasLength(6));
    expect(texts(merged), [
      'user:ok',
      'ai:ok',
      'user:ok',
      'ai:ok',
      'user:ok',
      'ai:ok',
    ]);
  });
}
