// With FEATURE_AGENTS off the app must refresh its session exactly as
// upstream chuk_chat does: gotrue's own auto refresh, no Agents scheduler,
// and no stash of an expiring session before Supabase starts.
//
// The merge had made all three unconditional. The Agents session handling
// exists for the refresh token the app shares with a paired host; a chuk_chat
// build has no host, so it only made that build differ from upstream at the
// one moment an access token runs out.
//
// `kFeatureAgents` is a compile-time constant, so a test cannot flip it and
// initialise Supabase both ways. It checks the gates in the source instead.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('gotrue auto refresh is off only in an Agents build', () {
    final s = source('lib/services/supabase_service.dart');
    expect(s, contains('autoRefreshToken: !kFeatureAgents'));
    expect(s, isNot(contains('autoRefreshToken: false')));
  });

  test('the Agents refresh scheduler starts only in an Agents build', () {
    final s = source('lib/services/supabase_service.dart');
    final starts = RegExp(r'SessionRefreshScheduler\.instance\.start\(\)')
        .allMatches(s)
        .toList();
    expect(starts, hasLength(1));
    expect(
      s,
      contains('if (kFeatureAgents) SessionRefreshScheduler.instance.start();'),
    );
  });

  test('an expiring session is set aside only in an Agents build', () {
    final s = source('lib/main.dart');
    expect(
      s,
      contains(
        'if (kFeatureAgents) await SessionStash.setAsideExpiredSession();',
      ),
    );
    expect(
      RegExp(
        r'^\s*await SessionStash\.setAsideExpiredSession\(\);',
        multiLine: true,
      ).hasMatch(s),
      isFalse,
    );
  });
}
