// The lab logo in front of a model's name: which id gets which logo, and
// that every logo the map names ships and parses.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/model_logo.dart';

void main() {
  group('modelLogoAsset', () {
    test('maps each lab prefix to its logo', () {
      const expected = <String, String>{
        'deepseek/deepseek-v4-pro-0813': 'deepseek',
        'moonshotai/kimi-k3': 'moonshot',
        'qwen/qwen3.5-397b-a17b': 'qwen',
        'z-ai/glm-5.3-flash': 'zai',
        'minimax/minimax-m2.7': 'minimax',
        'mistralai/mistral-small-3.2': 'mistral',
        'openai/gpt-oss-120b': 'openai',
        'meta-llama/llama-4-maverick': 'meta',
        'google/gemma-4-31b-it': 'google',
        'xiaomi/mimo-v2-flash': 'xiaomi',
        'black-forest-labs/flux-2-pro': 'bfl',
      };
      expected.forEach((id, stem) {
        expect(modelLogoAsset(id), 'assets/model_logos/$stem.svg', reason: id);
      });
    });

    test('ignores the case of the prefix', () {
      expect(modelLogoAsset('DeepSeek/V4'), 'assets/model_logos/deepseek.svg');
    });

    test('a lab without a logo, or an id without a lab, has none', () {
      expect(modelLogoAsset('acme/foo-1'), isNull);
      expect(modelLogoAsset('deepseek'), isNull);
      expect(modelLogoAsset('/deepseek-v4'), isNull);
      expect(modelLogoAsset(''), isNull);
      // Only the prefix counts, not a lab name further along the id.
      expect(modelLogoAsset('thedrummer/cydonia-mistral'), isNull);
    });
  });

  group('the bundled logos', () {
    test('every logo the map names is a file in assets/model_logos', () {
      for (final stem in kModelLogoByLab.values.toSet()) {
        expect(
          File('assets/model_logos/$stem.svg').existsSync(),
          isTrue,
          reason: '$stem.svg is missing',
        );
      }
    });

    test('the folder is declared as an asset', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('- assets/model_logos/'),
      );
    });

    testWidgets('every logo parses', (tester) async {
      await tester.runAsync(() async {
        for (final stem in kModelLogoByLab.values.toSet()) {
          final String svg = File('assets/model_logos/$stem.svg')
              .readAsStringSync();
          final bytes = await SvgStringLoader(svg).loadBytes(null);
          expect(bytes.lengthInBytes, greaterThan(0), reason: stem);
        }
      });
    });
  });

  group('ModelLogo', () {
    Future<void> pumpLogo(WidgetTester tester, String id, Color color) {
      return tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ModelLogo(modelId: id, color: color),
          ),
        ),
      );
    }

    testWidgets('draws the logo at 14 in an 18 slot, in the given colour', (
      tester,
    ) async {
      const color = Color(0xFF123456);
      await pumpLogo(tester, 'qwen/qwen3.5-27b', color);

      expect(tester.getSize(find.byType(ModelLogo)), const Size(18, 18));
      final picture = find.byType(SvgPicture);
      expect(picture, findsOneWidget);
      expect(tester.getSize(picture), const Size(14, 14));
      expect(
        tester.widget<SvgPicture>(picture).colorFilter,
        const ColorFilter.mode(color, BlendMode.srcIn),
      );
    });

    testWidgets('an unknown lab keeps the empty 18 slot', (tester) async {
      await pumpLogo(tester, 'acme/foo-1', const Color(0xFF000000));

      expect(tester.getSize(find.byType(ModelLogo)), const Size(18, 18));
      expect(find.byType(SvgPicture), findsNothing);
    });
  });
}
