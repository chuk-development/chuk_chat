import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tool_registry.dart';
import 'package:chuk_chat/tool_handlers/image_tools.dart';

void main() {
  group('normalizeImageModel', () {
    test('defaults to krea for a missing or blank key', () {
      expect(normalizeImageModel(null), 'krea');
      expect(normalizeImageModel('  '), 'krea');
      expect(defaultImageModel, 'krea');
    });

    test('maps legacy keys onto the current lineup', () {
      expect(normalizeImageModel('quality'), 'krea');
      expect(normalizeImageModel('flux'), 'krea');
      expect(normalizeImageModel('FLUX'), 'krea');
      expect(normalizeImageModel('ideogram'), 'seedream');
      expect(normalizeImageModel('k3'), 'edit');
    });

    test('keeps current and unknown keys', () {
      for (final key in imageModelDisplayNames.keys) {
        expect(normalizeImageModel(key), key);
      }
      expect(normalizeImageModel('nope'), 'nope');
    });
  });

  test('every alias target is a known model', () {
    for (final target in legacyImageModelAliases.values) {
      expect(imageModelDisplayNames, contains(target));
    }
  });

  test('generate_image schema enum matches the client model table', () {
    final tool = builtinTools.firstWhere((t) => t.name == 'generate_image');
    final props = tool.parameters['properties'] as Map<String, dynamic>;
    final model = props['model'] as Map<String, dynamic>;
    expect(
      (model['enum'] as List).toSet(),
      imageModelDisplayNames.keys.toSet(),
    );
    expect(props.containsKey('megapixels'), isFalse);
    expect(props.containsKey('tier'), isFalse);
  });

  group('executeGenerateImage validation', () {
    test('rejects an unknown model', () async {
      final result = await executeGenerateImage(
        serverHttpUrl: null,
        accessToken: null,
        args: const {'model': 'nope', 'prompt': 'cat'},
      );
      expect(result, startsWith('Error: unknown image model "nope"'));
    });

    test('k3 alias routes to edit and needs image_url', () async {
      final result = await executeGenerateImage(
        serverHttpUrl: null,
        accessToken: null,
        args: const {'model': 'k3', 'prompt': 'a cat'},
      );
      expect(result, contains('"image_url" parameter required'));
    });

    test('text-to-image models do not need image_url', () async {
      for (final model in ['krea', 'turbo', 'hunyuan', 'seedream']) {
        final result = await executeGenerateImage(
          serverHttpUrl: null,
          accessToken: null,
          args: {'model': model, 'prompt': 'cat'},
        );
        expect(result, 'Error: Not connected to server', reason: model);
      }
    });

    test('edit needs image_url', () async {
      final result = await executeGenerateImage(
        serverHttpUrl: null,
        accessToken: null,
        args: const {'model': 'edit', 'prompt': 'make it blue'},
      );
      expect(result, contains('"image_url" parameter required'));
    });

    test('legacy key passes validation and reaches the request', () async {
      final result = await executeGenerateImage(
        serverHttpUrl: null,
        accessToken: null,
        args: const {'model': 'flux', 'prompt': 'cat'},
      );
      expect(result, 'Error: Not connected to server');
    });
  });
}
