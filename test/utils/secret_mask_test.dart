import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/secret_mask.dart';

void main() {
  group('findSecrets finds', () {
    final Map<String, String> positives = <String, String>{
      'openai': 'sk-proj-AbC123dEf456GhI789jKl012MnO345',
      'anthropic': 'sk-ant-api03-AbC123dEf456GhI789jKl012MnO345pQr',
      'github': 'ghp_1234567890abcdefghijABCDEFGHIJ123456',
      'github_pat': 'github_pat_11ABCDEFG0123456789_abcdefghijklmnop',
      'gitlab': 'glpat-' 'AbC123dEf456GhI789jK',
      'npm': 'npm_1234567890abcdefghijABCDEFGHIJ123456',
      'huggingface': 'hf_1234567890abcdefghijABCDEFGHIJ',
      'aws': 'AKIAIOSFODNN7EXAMPLE',
      'google': 'AIzaSyA1234567890abcdefghijklmnopqrstuv',
      'slack': 'xoxb-' '1234567890-abcdefghij',
      'slack app': 'xoxa-' '2-1234567890-abcdefghij',
      'slack refresh': 'xoxe-' '1-My0xLTEyMzQ1Njc4OTAtYWJj',
      'slack rotated': 'xoxe.' 'xoxp-1-Mi0yLTEyMzQ1Njc4OTA',
      'stripe live': 'sk_live_' '51H8abcDEF1234567890ghijKLmn',
      'stripe test': 'sk_test_' '51H8abcDEF1234567890ghijKLmn',
      'stripe restricted': 'rk_live_' '51H8abcDEF1234567890ghijKL',
      'jwt': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
    };
    positives.forEach((String name, String key) {
      test(name, () {
        final List<SecretMatch> m = findSecrets('my key is $key, keep it');
        expect(m, hasLength(1));
        expect(m.single.value, key);
      });
    });

    test('sk-ant is reported once, as anthropic', () {
      final List<SecretMatch> m = findSecrets(
        'sk-ant-api03-AbC123dEf456GhI789jKl012MnO345pQr',
      );
      expect(m.single.kind, 'anthropic');
    });

    test('two keys in one text, in order', () {
      final List<SecretMatch> m = findSecrets(
        'a AKIAIOSFODNN7EXAMPLE and hf_1234567890abcdefghijABCDEFGHIJ end',
      );
      expect(m.map((e) => e.kind), <String>['aws', 'huggingface']);
    });
  });

  group('findSecrets ignores', () {
    for (final String text in <String>[
      'use sk-learn for that',
      'sk-this-is-just-a-long-hyphenated-phrase',
      'the task-AbC123dEf456GhI789jKl012MnO345 id',
      'ghp_short1',
      'AKIA1234',
      'npm_install',
      'eyJhbGc.eyJzdWI.sig',
      'plain text with no keys at all, nothing to see here',
    ]) {
      test(text, () => expect(findSecrets(text), isEmpty));
    }
  });

  test('maskSecret keeps 8 characters and caps the dots', () {
    expect(maskSecret('AKIAIOSFODNN7EXAMPLE'), 'AKIAIOSF••••••••••••');
    final String long = 'x' * 8 + 'y' * 200;
    expect(maskSecret(long), '${'x' * 8}${'•' * kSecretMaxMaskChars}');
  });

  test('maskSecretsIn and containsSecret', () {
    const String text = 'key AKIAIOSFODNN7EXAMPLE here';
    expect(containsSecret(text), isTrue);
    expect(maskSecretsIn(text), 'key AKIAIOSF•••••••••••• here');
    expect(containsSecret('hello'), isFalse);
  });
}
