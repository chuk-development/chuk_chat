import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/tool_executor.dart';

/// A tool result's failure flag drives the icon the user sees AND whether the
/// model is told the call succeeded. The old rule was `startsWith('Error:')`,
/// which around a hundred real failure strings do not match — they rendered
/// with a green check and were fed to the model as data.
void main() {
  group('tool failures are recognised', () {
    const failures = <String>[
      // the reported ones
      'Error getting route: ClientException with SocketException',
      'Error searching places: timeout',
      'Error geocoding: bad input',
      'Error generating QR code: too long',
      'Error parsing "1 + ": unexpected end',
      'Error: route lookup failed (503)',
      // "<Thing> error:" — the most common shape across handlers
      'Spotify error: 401',
      'GitHub error: rate limited',
      'Weather error: Invalid server response',
      'Web search error: upstream refused',
      'Image generation error: content filtered',
      'Crypto data error: no such coin',
      'Notes error: decrypt failed',
      'Nextcloud error: 404',
      'Calculation error: division by zero',
      'Nextcloud API error (503): upstream down',
      // other real prefixes
      'Failed to get Spotify access token. Please reconnect.',
      'Unknown Nextcloud action: frobnicate. Valid actions are …',
      'Unknown operation: frobnicate',
      'Unsupported HTTP method: TRACE',
      'Spotify not authenticated. Please connect your Spotify account first.',
      'Google token expired and could not be refreshed.',
    ];

    for (final failure in failures) {
      test('"${failure.split(':').first}" counts as a failure', () {
        expect(ToolExecutor.looksLikeToolFailure(failure), isTrue);
      });
    }
  });

  group('successful results are not mistaken for failures', () {
    const successes = <String>[
      'Search results for "magellan": …',
      '18.5 °C, light rain in Kiel',
      'Route: 42 km, about 38 minutes',
      'The error rate dropped to 0.2% after the fix.',
      'Saved note "einkaufen".',
      'Errors in your logs are usually harmless.',
      '{"temperature": 18.5}',
      '',
    ];

    for (final success in successes) {
      test('"${success.length > 28 ? '${success.substring(0, 28)}…' : success}"'
          ' is not a failure', () {
        expect(ToolExecutor.looksLikeToolFailure(success), isFalse);
      });
    }

    test('a sentence merely containing "error:" later is not a failure', () {
      expect(
        ToolExecutor.looksLikeToolFailure(
          'The log line reads error: disk full, which explains the crash.',
        ),
        isFalse,
      );
    });
  });

  group('retryable stream failures are chosen by code, not by wording', () {
    test('the server sends one sentence for several failure classes', () {
      // All four of these arrive as "AI service temporarily unavailable.
      // Please try again." — only `code` tells them apart.
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.upstreamNetwork),
        isTrue,
      );
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.upstreamNoStream),
        isTrue,
      );
      expect(
        StreamErrorCodes.retryable.contains(
          StreamErrorCodes.upstreamFirstByteTimeout,
        ),
        isTrue,
      );
    });

    test('a flat provider rejection is NOT retried', () {
      // Retrying a 400/413 fails identically and costs tokens.
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.upstreamStatus),
        isFalse,
      );
    });

    test('locally raised transport failures are retried', () {
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.connectionLost),
        isTrue,
      );
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.idleTimeout),
        isTrue,
      );
      expect(
        StreamErrorCodes.retryable.contains(StreamErrorCodes.streamFailure),
        isTrue,
      );
    });

    test('an unknown code is not assumed retryable', () {
      expect(StreamErrorCodes.retryable.contains('something_new'), isFalse);
    });

    test('ErrorEvent carries the code through', () {
      const event = ErrorEvent('boom', code: StreamErrorCodes.upstreamNetwork);
      expect(event.code, StreamErrorCodes.upstreamNetwork);
      expect(const ErrorEvent('boom').code, isNull);
    });
  });
}
