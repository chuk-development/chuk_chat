import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/phone_linkify.dart';

void main() {
  group('linkifyPhoneNumbers', () {
    test('links a grouped international number and keeps its display', () {
      final out = linkifyPhoneNumbers('Call +41 61 317 40 00 now.');
      expect(out, 'Call [+41 61 317 40 00](tel:+41613174000) now.');
    });

    test('keeps display grouping, normalises only the target', () {
      final out = linkifyPhoneNumbers('+1 (555) 123-4567');
      expect(out, '[+1 (555) 123-4567](tel:+15551234567)');
    });

    test('links a number wrapped in bold markers', () {
      final out = linkifyPhoneNumbers('**+41 61 317 40 00**');
      expect(out, '**[+41 61 317 40 00](tel:+41613174000)**');
    });

    test('leaves national numbers without a plus untouched', () {
      const input = 'Reception 061 317 40 00 open now';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('does not touch a number already inside a markdown link', () {
      const input = '[+41 61 317 40 00](tel:+41613174000)';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('does not touch a number inside an inline code span', () {
      const input = 'run `git tag +41 61 317 40 00`';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('does not touch a number inside a fenced code block', () {
      const input = '```\ndial +41 61 317 40 00\n```';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('rejects a digit run that is too long to dial', () {
      const input = 'ref +1234567890123456789';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('handles multiple numbers in one string', () {
      final out = linkifyPhoneNumbers('a +49 30 1234567 and +33 1 23 45 67 89');
      expect(
        out,
        'a [+49 30 1234567](tel:+49301234567) '
        'and [+33 1 23 45 67 89](tel:+33123456789)',
      );
    });


    test('leaves a phone value inside a <map> block untouched', () {
      const input =
          'here\n<map>{"places":[{"name":"X","phone":"+41 61 317 40 00"}]}'
          '</map>\ntail';
      expect(linkifyPhoneNumbers(input), input);
    });

    test('links a number in prose but not one inside an adjacent map block', () {
      final out = linkifyPhoneNumbers(
        'Call +49 30 1234567\n<map>{"phone":"+49 30 1234567"}</map>',
      );
      expect(out, contains('[+49 30 1234567](tel:+49301234567)'));
      expect(out, contains('<map>{"phone":"+49 30 1234567"}</map>'));
    });

    test('no international prefix short-circuits to the same string', () {
      const input = 'no numbers here at all';
      expect(linkifyPhoneNumbers(input), same(input));
    });
  });

  group('telUriForDisplay', () {
    test('strips separators to E.164 digits', () {
      expect(telUriForDisplay('+41 61 317 40 00'), 'tel:+41613174000');
    });

    test('returns null for a too-short run', () {
      expect(telUriForDisplay('+12 34'), isNull);
    });

    test('returns null for a too-long run', () {
      expect(telUriForDisplay('+1234567890123456'), isNull);
    });
  });
}
