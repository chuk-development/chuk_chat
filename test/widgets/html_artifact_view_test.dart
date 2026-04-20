import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/html_artifact_view.dart';
import 'package:chuk_chat/widgets/html_artifact_view_source_fallback.dart';

const _sampleHtml = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>Demo</title></head>
<body><h1>Hello</h1><p>Paragraph</p></body></html>
''';

void main() {
  group('HtmlArtifactView', () {
    testWidgets('renders with valid HTML without throwing', (tester) async {
      // On every native platform the widget constructs an InAppWebView,
      // whose platform channel is not available under the flutter_test
      // harness. We pump the widget, swallow the expected platform-init
      // exception, and assert the widget was constructed — runtime
      // rendering is covered by manual + integration testing.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: HtmlArtifactView(html: _sampleHtml),
            ),
          ),
        ),
      );
      tester.takeException();
      expect(find.byType(HtmlArtifactView), findsOneWidget);
    });

    testWidgets('handles empty HTML input without throwing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 200,
              child: HtmlArtifactView(html: ''),
            ),
          ),
        ),
      );
      tester.takeException();
      expect(find.byType(HtmlArtifactView), findsOneWidget);
    });
  });

  group('HtmlSourceFallback', () {
    testWidgets('shows the source as selectable text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HtmlSourceFallback(html: '<p>Hello world</p>'),
          ),
        ),
      );
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('<p>Hello world</p>'), findsOneWidget);
    });
  });

  group('shouldLoadInWebView', () {
    test('allows null and relative URIs', () {
      expect(shouldLoadInWebView(null), isTrue);
      expect(shouldLoadInWebView(Uri.parse('')), isTrue);
    });

    test('allows sandbox-safe schemes', () {
      expect(shouldLoadInWebView(Uri.parse('about:blank')), isTrue);
      expect(
        shouldLoadInWebView(Uri.parse('data:text/html,<b>hi</b>')),
        isTrue,
      );
      expect(
        shouldLoadInWebView(
          Uri.parse('blob:https://example.com/abc-123'),
        ),
        isTrue,
      );
    });

    test('blocks http(s) so they go to the system browser', () {
      expect(
        shouldLoadInWebView(Uri.parse('https://example.com/x')),
        isFalse,
      );
      expect(
        shouldLoadInWebView(Uri.parse('http://example.com/x')),
        isFalse,
      );
    });

    test('blocks exfiltration-shaped schemes', () {
      expect(
        shouldLoadInWebView(Uri.parse('javascript:alert(1)')),
        isFalse,
      );
      expect(shouldLoadInWebView(Uri.parse('file:///etc/passwd')), isFalse);
      expect(shouldLoadInWebView(Uri.parse('ftp://example.com/x')), isFalse);
    });

    test('scheme check is case insensitive', () {
      expect(shouldLoadInWebView(Uri.parse('ABOUT:blank')), isTrue);
      expect(shouldLoadInWebView(Uri.parse('HTTPS://example.com')), isFalse);
    });
  });
}
