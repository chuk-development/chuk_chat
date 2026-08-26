// The brand logos bundled in the binary for catalogue connectors, and the
// asset-first resolution that prefers them over the runtime favicon service.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';

/// PNG magic bytes — every bundled asset must be a real PNG, never an HTML
/// error body or an empty file saved under a `.png` name.
const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

void main() {
  group('kBundledMcpIcons', () {
    // Every id that ships a logo must name a real catalogue entry — a
    // first-party connector or an offered one. A stray id would point
    // bundledIconAsset at an asset no entry ever asks for.
    test('every bundled id is a real catalogue entry', () {
      final catalogueIds = {
        for (final e in firstPartyConnectors()) e.id,
        for (final e in kMcpCatalogue) e.id,
      };
      for (final id in kBundledMcpIcons) {
        expect(
          catalogueIds,
          contains(id),
          reason: '$id is bundled but no catalogue entry uses it',
        );
      }
    });

    test('every bundled id has a real PNG on disk', () {
      for (final id in kBundledMcpIcons) {
        final file = File('assets/mcp_icons/$id.png');
        expect(file.existsSync(), isTrue, reason: 'missing asset for $id');
        final head = file.readAsBytesSync().take(8).toList();
        expect(head, _pngMagic, reason: '$id.png is not a PNG');
      }
    });

    // The reverse guard: no orphan file in the folder that the set forgot,
    // which would ship in the binary yet never render.
    test('every PNG in the folder is declared in the set', () {
      final dir = Directory('assets/mcp_icons');
      final onDisk = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .map((f) => f.uri.pathSegments.last.replaceAll('.png', ''))
          .toSet();
      expect(onDisk, equals(kBundledMcpIcons));
    });
  });

  group('bundledIconAsset', () {
    test('returns the asset path for a bundled id', () {
      expect(bundledIconAsset('notion'), 'assets/mcp_icons/notion.png');
      expect(bundledIconAsset('github'), 'assets/mcp_icons/github.png');
    });

    test('returns null for an id with no bundled logo', () {
      // Registry / Add-by-URL servers carry no bundled asset.
      expect(bundledIconAsset('some-registry-server'), isNull);
      expect(bundledIconAsset(''), isNull);
    });

    test('path matches the id, so the set and the files cannot drift', () {
      for (final id in kBundledMcpIcons) {
        expect(bundledIconAsset(id), 'assets/mcp_icons/$id.png');
      }
    });
  });

  group('McpConnectorIcon', () {
    testWidgets('renders the bundled asset when one is given', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: McpConnectorIcon(
              assetPath: 'assets/mcp_icons/notion.png',
              serverUrl: 'https://mcp.notion.com/mcp',
              name: 'Notion',
              size: 42,
            ),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image;
      expect(provider, isA<AssetImage>());
      expect(
        (provider as AssetImage).assetName,
        'assets/mcp_icons/notion.png',
      );
    });

    testWidgets('shows no asset Image when none is bundled', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: McpConnectorIcon(
              // No assetPath: a registry server. The network path is used,
              // which resolves asynchronously and shows the placeholder first.
              serverUrl: 'https://mcp.example.com/mcp',
              name: 'Example',
              size: 42,
            ),
          ),
        ),
      );
      // No synchronous Image.asset in the tree — only the initial placeholder.
      expect(find.byType(Image), findsNothing);
      expect(find.text('E'), findsOneWidget);
    });
  });
}
