/// Native implementation of [AgentFileSaver]: writes into the platform's
/// downloads directory, or the app's documents directory when there is none.
library;

import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path_provider/path_provider.dart';

import 'package:chuk_chat/services/agents/agent_file_saver_base.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

class DownloadsAgentFileSaver implements AgentFileSaver {
  const DownloadsAgentFileSaver();

  @override
  Future<String> save(AgentsRelayFile file) async {
    final bytes = file.bytes;
    if (bytes == null) {
      throw StateError('The file has no body to save.');
    }
    Directory? target;
    try {
      target = await getDownloadsDirectory();
    } on UnsupportedError {
      target = null;
    } on MissingPluginException {
      target = null;
    }
    target ??= await getApplicationDocumentsDirectory();
    final path =
        '${target.path}${Platform.pathSeparator}'
        '${sanitizeAgentFileName(file.name)}';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
}
