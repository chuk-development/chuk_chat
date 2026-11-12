// Agent avatar check (not shipped, docs/AGENT_AVATAR.md): the real
// AgentAvatar widgets in round and square frames at 32/50/64 px, in every
// state, rendered by the running engine and written as PNGs to
// $AVATAR_SHOT_DIR (default _scratch/avatar_check), then the app exits.
// Run: xvfb-run -a flutter run --profile -d linux -t tool/agent_avatar_shot.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart';

final GlobalKey _shot = GlobalKey();

const List<String> _ids = <String>[
  'main',
  'inbox',
  'research',
  'design',
  'watcher',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Two agents pick the round figure in their profile; the rest keep the
  // square default.
  await AgentProfileStore.instance.load();
  for (final String id in <String>['research', 'watcher']) {
    await AgentProfileStore.instance.update(id, round: true);
  }
  runApp(const _Sheet());
  Timer(const Duration(seconds: 2), () async {
    final String dir =
        Platform.environment['AVATAR_SHOT_DIR'] ?? '_scratch/avatar_check';
    Directory(dir).createSync(recursive: true);
    for (final double ratio in <double>[1, 2]) {
      final RenderRepaintBoundary rb =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ui.Image img = await rb.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/frames_${ratio.toInt()}x.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    }
    print('SHOT written to $dir');
    exit(0);
  });
}

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) {
    Widget framed(AgentsAgent a, double size, AgentAvatarState st, bool round) {
      final Widget av = Container(
        width: size,
        height: size,
        color: const Color(0xFFE6E0F0),
        child: AgentAvatar(
          agent: a,
          size: size,
          state: st,
          showPresence: false,
        ),
      );
      return Padding(
        padding: const EdgeInsets.all(4),
        child: round
            ? ClipOval(child: av)
            : ClipRRect(
                borderRadius: BorderRadius.circular(size * 0.22),
                child: av,
              ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F3EC),
        body: SingleChildScrollView(
          child: RepaintBoundary(
            key: _shot,
            child: Container(
              color: const Color(0xFFF7F3EC),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final AgentAvatarState st in AgentAvatarState.values)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        SizedBox(
                          width: 50,
                          child: Text(
                            st.name,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        for (final String id in _ids)
                          for (final bool round in <bool>[true, false])
                            for (final double size in <double>[64, 50, 32])
                              framed(
                                AgentsAgent(
                                  id: id,
                                  name: id,
                                  threads: const <AgentsThreadInfo>[],
                                ),
                                size,
                                st,
                                round,
                              ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
