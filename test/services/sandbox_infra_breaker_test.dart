import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/tool_handlers/sandbox_tools.dart';

void main() {
  group('isSandboxInfraError', () {
    test('true for the real 502 / HTTP 0 upstream failure shapes', () {
      // These are the exact strings the production debug export showed.
      expect(
        isSandboxInfraError(
          'Error: HTTP 0 — [http_502] Sandbox upstream unavailable',
        ),
        isTrue,
      );
      expect(isSandboxInfraError('Error: HTTP 502 — bad gateway'), isTrue);
      expect(isSandboxInfraError('Error: HTTP 503 — service unavailable'), isTrue);
      expect(isSandboxInfraError('Error: HTTP 504 — gateway timeout'), isTrue);
    });

    test('true on the upstream-unavailable phrasing regardless of status', () {
      expect(isSandboxInfraError('Sandbox upstream is down'), isTrue);
      expect(isSandboxInfraError('gateway: upstream unavailable'), isTrue);
    });

    test('false for user-level errors (bad path, not found, too large)', () {
      expect(
        isSandboxInfraError('Error: HTTP 400 — path must be under /home/sandbox'),
        isFalse,
      );
      expect(isSandboxInfraError('Error: HTTP 404 — not found'), isFalse);
      expect(isSandboxInfraError('Error: HTTP 413 — payload too large'), isFalse);
    });

    test('false for a successful result', () {
      expect(isSandboxInfraError('Wrote /home/sandbox/x.txt (10 bytes)'), isFalse);
      expect(isSandboxInfraError('exit_code: 0\n--- stdout ---\nok'), isFalse);
    });
  });

  group('isSandboxBackedTool', () {
    test('true for sandbox-service and fallback tools', () {
      for (final name in const [
        'code_run',
        'bash',
        'sandbox_list',
        'sandbox_read',
        'sandbox_write',
        'sandbox_reset',
        'send_file_to_user',
      ]) {
        expect(isSandboxBackedTool(name), isTrue, reason: name);
      }
    });

    test('false for unrelated tools', () {
      expect(isSandboxBackedTool('web_search'), isFalse);
      expect(isSandboxBackedTool('generate_image'), isFalse);
      expect(isSandboxBackedTool('typst_compile'), isFalse);
    });
  });

  group('per-turn circuit-breaker progression', () {
    // Mirrors the exact predicate the tool loop applies: a sandbox tool is
    // short-circuited once [threshold] consecutive infra failures accrue; any
    // non-infra outcome resets the count.
    const threshold = 2;

    test('short-circuits the 3rd sandbox call after 2 infra failures', () {
      var failures = 0;
      const infra = 'Error: HTTP 0 — [http_502] Sandbox upstream unavailable';

      bool step(String name, String result) {
        final gated = isSandboxBackedTool(name) && failures >= threshold;
        if (gated) return true; // handler returns terminal message, no execute
        if (isSandboxBackedTool(name)) {
          if (isSandboxInfraError(result)) {
            failures++;
          } else {
            failures = 0;
          }
        }
        return false;
      }

      expect(step('code_run', infra), isFalse); // 1st failure
      expect(step('sandbox_list', infra), isFalse); // 2nd failure -> at threshold
      expect(step('send_file_to_user', infra), isTrue); // short-circuited
      expect(step('bash', infra), isTrue); // still short-circuited this turn
    });

    test('a success resets the count, re-enabling sandbox calls', () {
      var failures = 0;
      const infra = 'Error: HTTP 502 — bad gateway';
      const ok = 'exit_code: 0\n--- stdout ---\nok';

      bool step(String name, String result) {
        final gated = isSandboxBackedTool(name) && failures >= threshold;
        if (gated) return true;
        if (isSandboxBackedTool(name)) {
          failures = isSandboxInfraError(result) ? failures + 1 : 0;
        }
        return false;
      }

      expect(step('code_run', infra), isFalse); // 1
      expect(step('code_run', ok), isFalse); // reset to 0
      expect(step('code_run', infra), isFalse); // 1 again
      expect(step('code_run', infra), isFalse); // 2 -> at threshold
      expect(step('code_run', infra), isTrue); // now short-circuited
    });

    test('a bad-path (non-infra) error does NOT advance the breaker', () {
      var failures = 0;
      const badPath = 'Error: HTTP 400 — path must be under /home/sandbox';

      if (isSandboxBackedTool('send_file_to_user') &&
          isSandboxInfraError(badPath)) {
        failures++;
      }
      expect(failures, 0);
    });
  });
}
