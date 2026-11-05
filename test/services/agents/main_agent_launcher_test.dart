import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_thread_composer.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';

void main() {
  setUp(() {
    MainAgentLauncher.instance.reset();
    AgentsThreadComposer.reset();
  });

  test('openWithPrompt parks the text; take hands it out once', () {
    final MainAgentLauncher launcher = MainAgentLauncher.instance;
    final List<String?> seen = <String?>[];
    void listen() => seen.add(launcher.requests.value);
    launcher.requests.addListener(listen);
    addTearDown(() => launcher.requests.removeListener(listen));

    launcher.openWithPrompt('log 10 push-ups');
    expect(launcher.take(), 'log 10 push-ups');
    expect(launcher.requests.value, isNull);
    expect(launcher.take(), isNull);
    expect(seen, <String?>['log 10 push-ups', null]);
  });

  test('a prefill is taken once, and only for its own chat', () {
    int fired = 0;
    void count() => fired++;
    AgentsThreadComposer.prefillChanges.addListener(count);
    addTearDown(() => AgentsThreadComposer.prefillChanges.removeListener(count));

    AgentsThreadComposer.prefill('chat-a', 'hello');
    expect(fired, 1);
    expect(AgentsThreadComposer.takePrefill('chat-b'), isNull);
    expect(AgentsThreadComposer.takePrefill(null), isNull);
    expect(AgentsThreadComposer.takePrefill('chat-a'), 'hello');
    expect(AgentsThreadComposer.takePrefill('chat-a'), isNull);
  });

  test('a newer prefill replaces an untaken one', () {
    AgentsThreadComposer.prefill('chat-a', 'first');
    AgentsThreadComposer.prefill('chat-b', 'second');
    AgentsThreadComposer.prefill('', 'nowhere');
    expect(AgentsThreadComposer.takePrefill('chat-a'), isNull);
    expect(AgentsThreadComposer.takePrefill('chat-b'), 'second');
  });

  test('an empty prompt is a request for the focus, not nothing', () {
    MainAgentLauncher.instance.openWithPrompt('');
    expect(MainAgentLauncher.instance.take(), '');
    AgentsThreadComposer.prefill('chat-a', '');
    expect(AgentsThreadComposer.takePrefill('chat-a'), '');
  });
}
