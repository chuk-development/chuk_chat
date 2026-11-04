import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';

/// Agents has no attachment frame yet. An image must not vanish without a
/// word: the text goes out, and the view is told to say so.
void main() {
  late Map<String, String> disk;

  setUp(() {
    disk = <String, String>{};
    AgentsTaskOutbox.resetForTest();
    AgentsTaskOutbox.read = (key) async => disk[key];
    AgentsTaskOutbox.write = (key, value) async => disk[key] = value;
    AgentsTaskOutbox.delete = (key) async => disk.remove(key);
    AgentsRelayLink.instance.reset();
  });

  tearDown(() {
    AgentsTaskOutbox.read = null;
    AgentsTaskOutbox.write = null;
    AgentsTaskOutbox.delete = null;
    AgentsRelayLink.instance.reset();
  });

  test('a send with images raises a notice and keeps the text', () async {
    final notices = <AgentsSendNotice>[];
    final StreamSubscription<AgentsSendNotice> sub = AgentsChatTransport
        .notices
        .listen(notices.add);
    addTearDown(sub.cancel);

    final events = await AgentsChatTransport.sendStreamingChat(
      accessToken: '',
      message: 'schau dir das an',
      modelId: 'm',
      providerSlug: 'p',
      images: const <String>['data:image/png;base64,AAAA'],
      chatId: 'thread-img',
      modelSelectionCaptured: true,
    ).toList();
    await Future<void>.delayed(Duration.zero);

    expect(notices, hasLength(1));
    expect(notices.single.kind, AgentsSendNoticeKind.imagesNotSupported);
    expect(notices.single.sessionKey, 'thread-img');
    expect(notices.single.count, 1);
    expect(events.whereType<DoneEvent>(), isNotEmpty);

    // No host: the TEXT is queued, verbatim.
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final queued = await AgentsTaskOutbox.pendingFor('thread-img');
    expect(queued.single.prompt, 'schau dir das an');
  });

  test('a send without images raises no notice', () async {
    final notices = <AgentsSendNotice>[];
    final StreamSubscription<AgentsSendNotice> sub = AgentsChatTransport
        .notices
        .listen(notices.add);
    addTearDown(sub.cancel);
    await AgentsChatTransport.sendStreamingChat(
      accessToken: '',
      message: 'nur text',
      modelId: 'm',
      providerSlug: 'p',
      chatId: 'thread-txt',
      modelSelectionCaptured: true,
    ).toList();
    await Future<void>.delayed(Duration.zero);
    expect(notices, isEmpty);
  });
}
