/// Web implementation of [AgentFileSaver].
///
/// The browser has no filesystem the app may write to, and `path_provider` has
/// no web implementation, so this says so instead of pretending the save worked.
library;

import 'package:chuk_chat/services/agents/agent_file_saver_base.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

class DownloadsAgentFileSaver implements AgentFileSaver {
  const DownloadsAgentFileSaver();

  @override
  Future<String> save(AgentsRelayFile file) async {
    throw UnsupportedError('Saving files is not supported in the browser yet.');
  }
}
