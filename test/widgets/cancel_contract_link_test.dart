import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/l10n/strings_es.dart';
import 'package:chuk_chat/l10n/strings_fr.dart';
import 'package:chuk_chat/l10n/strings_pt.dart';
import 'package:chuk_chat/widgets/cancel_contract_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const locales = {
    'en': stringsEn,
    'de': stringsDe,
    'es': stringsEs,
    'fr': stringsFr,
    'pt': stringsPt,
  };

  group('cancelContractUrl (§ 312k BGB)', () {
    test('German opens the German form', () {
      expect(cancelContractUrl('de'), 'https://chuk.chat/de/kuendigen/');
    });

    test('every other language opens the English form', () {
      for (final code in ['en', 'es', 'fr', 'pt']) {
        expect(
          cancelContractUrl(code),
          'https://chuk.chat/en/cancel-contract/',
        );
      }
    });
  });

  group('withdrawContractUrl (Art. 11a Directive 2011/83/EU)', () {
    test('points at the withdrawal part of the form', () {
      expect(
        withdrawContractUrl('de'),
        'https://chuk.chat/de/kuendigen/#widerruf',
      );
      expect(
        withdrawContractUrl('en'),
        'https://chuk.chat/en/cancel-contract/#withdraw',
      );
      expect(
        withdrawContractUrl('fr'),
        'https://chuk.chat/en/cancel-contract/#withdraw',
      );
    });
  });

  group('legalPageUrl', () {
    test('German consent links go to the German pages', () {
      expect(
        legalPageUrl('de', 'cancellation'),
        'https://chuk.chat/de/cancellation/',
      );
      expect(legalPageUrl('de', 'terms'), 'https://chuk.chat/de/terms/');
    });

    test('other languages go to the English pages', () {
      expect(legalPageUrl('fr', 'terms'), 'https://chuk.chat/en/terms/');
      expect(
        legalPageUrl('en', 'cancellation'),
        'https://chuk.chat/en/cancellation/',
      );
    });
  });

  group('order and cancellation strings', () {
    test('every language has the new keys', () {
      for (final entry in locales.entries) {
        for (final key in [
          'subscribeNow',
          'viewSubscription',
          'consentTermsSuffix',
          'cancelContractHere',
          'cancelContractHereSubtitle',
          'withdrawContract',
          'withdrawContractSubtitle',
          'linkOpenFailed',
          'immediateAccessAck',
          'onceServiceBegins',
        ]) {
          expect(
            entry.value[key],
            isNotNull,
            reason: '${entry.key} is missing $key',
          );
        }
      }
    });

    test('the order button says that the order costs money (§ 312j)', () {
      expect(stringsDe['subscribeNow'], 'Zahlungspflichtig abonnieren');
      expect(stringsEn['subscribeNow'], 'Subscribe and pay');
    });

    test('consent does not claim the right of withdrawal ends', () {
      // § 356 Abs. 4 BGB: for a digital service the right does not end when
      // the service begins. The consumer pays for the service used instead.
      final de =
          '${stringsDe['immediateAccessAck']}${stringsDe['rightOfWithdrawal']}'
          '${stringsDe['onceServiceBegins']}${stringsDe['termsOfService']}'
          '${stringsDe['consentTermsSuffix']}';
      expect(de, contains('Ich verlange ausdrücklich'));
      expect(de, contains('Wertersatz'));
      expect(de, isNot(contains('verliere')));
      expect(de, endsWith('Nutzungsbedingungen zu.'));
      expect(stringsEn['immediateAccessAck'], isNot(contains('lose')));
    });

    test('the German cancellation label is the § 312k wording', () {
      expect(stringsDe['cancelContractHere'], 'Verträge hier kündigen');
      expect(stringsDe['withdrawContract'], 'Vertrag hier widerrufen');
      expect(stringsEn['withdrawContract'], 'Withdraw from contract here');
    });
  });
}
