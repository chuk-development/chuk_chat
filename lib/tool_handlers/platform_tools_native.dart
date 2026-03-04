import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/approval_config.dart';
import 'package:chuk_chat/services/bash_sandbox.dart';
import 'package:chuk_chat/services/device_services.dart';
import 'package:chuk_chat/services/email_service.dart';
import 'package:chuk_chat/services/github_oauth.dart';
import 'package:chuk_chat/services/google_oauth.dart';
import 'package:chuk_chat/services/slack_oauth.dart';
import 'package:chuk_chat/services/spotify_oauth.dart';
import 'package:chuk_chat/utils/tool_helpers.dart';

/// Singleton service instances for native platforms.
final SpotifyOAuth _spotifyOAuth = SpotifyOAuth();
final BashSandbox _bashSandbox = BashSandbox();
final GitHubOAuth _gitHubOAuth = GitHubOAuth();
final SlackOAuth _slackOAuth = SlackOAuth();
final GoogleOAuth _googleOAuth = GoogleOAuth();
final EmailService _emailService = EmailService();
final DeviceServices _deviceServices = DeviceServices();
final ApprovalConfig _approvalConfig = ApprovalConfig();

/// Initialize platform services — loads saved tokens/configs.
Future<void> initPlatformServices() async {
  await Future.wait([
    _approvalConfig.load(),
    _gitHubOAuth.loadSavedToken(),
    _slackOAuth.isAuthenticated(), // loads tokens internally
    _googleOAuth.getAccessToken().then((_) {}), // loads tokens internally
    _emailService.loadSavedConfig(),
    _bashSandbox.loadSavedFolder(),
  ]);
}

/// Check if a platform service is connected.
bool isPlatformServiceConnected(String service) {
  switch (service) {
    case 'spotify':
      return _spotifyOAuth.hasToken;
    case 'bash':
      return _bashSandbox.isConfigured;
    case 'github':
      return _gitHubOAuth.isAuthenticated;
    case 'slack':
      return _slackOAuth.hasToken;
    case 'google':
      return _googleOAuth.isAuthenticated;
    case 'email':
      return _emailService.isConfigured;
    default:
      return false;
  }
}

// ============== Spotify ==============

Future<String> executeSpotify(Map<String, dynamic> args) async {
  final isAuth = await _spotifyOAuth.isAuthenticated();
  if (!isAuth) {
    return 'Spotify not authenticated. '
        'Please connect your Spotify account first.';
  }

  final token = await _spotifyOAuth.getAccessToken();
  if (token == null) {
    return 'Failed to get Spotify access token. Please reconnect.';
  }

  final action = args['action'] as String? ?? '';

  try {
    switch (action.toLowerCase()) {
      case 'play':
        return await _spotifyPlay(token, args);
      case 'pause':
        await _spotifyApi(token, '/me/player/pause', method: 'PUT');
        return 'Playback paused';
      case 'next':
        await _spotifyApi(token, '/me/player/next', method: 'POST');
        return 'Skipped to next track';
      case 'previous':
        await _spotifyApi(token, '/me/player/previous', method: 'POST');
        return 'Skipped to previous track';
      case 'volume':
        final volume = (args['volume'] as int? ?? 50).clamp(0, 100);
        await _spotifyApi(
          token,
          '/me/player/volume?volume_percent=$volume',
          method: 'PUT',
        );
        return 'Volume set to $volume%';
      case 'search':
        return await _spotifySearch(token, args);
      case 'now_playing':
      case 'nowplaying':
        return await _spotifyNowPlaying(token);
      case 'devices':
        return await _spotifyDevices(token);
      case 'shuffle':
        final stateArg = args['state'];
        final bool state;
        if (stateArg is bool) {
          state = stateArg;
        } else if (stateArg is String) {
          state =
              stateArg.toLowerCase() == 'on' ||
              stateArg.toLowerCase() == 'true';
        } else {
          state = true;
        }
        await _spotifyApi(
          token,
          '/me/player/shuffle?state=$state',
          method: 'PUT',
        );
        return 'Shuffle ${state ? "enabled" : "disabled"}';
      case 'repeat':
        final rState = args['state'] as String? ?? 'off';
        await _spotifyApi(
          token,
          '/me/player/repeat?state=$rState',
          method: 'PUT',
        );
        return 'Repeat mode: $rState';
      case 'create_playlist':
        return await _spotifyCreatePlaylist(token, args);
      case 'get_playlists':
      case 'get_my_playlists':
        return await _spotifyGetPlaylists(token);
      case 'add_to_queue':
        final uri = args['uri'] as String? ?? '';
        if (uri.isEmpty) return 'Error: uri required';
        await _spotifyApi(token, '/me/player/queue?uri=$uri', method: 'POST');
        return 'Added track to queue';
      case 'find_and_play':
        return await _spotifyFindAndPlay(token, args);
      case 'get_recently_liked':
      case 'recently_liked':
        return await _spotifyRecentlyLiked(token, args);
      default:
        return 'Unknown Spotify action: $action. '
            'Available: play, pause, next, previous, volume, search, '
            'now_playing, devices, shuffle, repeat, create_playlist, '
            'get_playlists, add_to_queue, find_and_play, '
            'get_recently_liked';
    }
  } catch (e) {
    return 'Spotify error: $e';
  }
}

Future<String> _spotifyApi(
  String token,
  String endpoint, {
  String method = 'GET',
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.parse('https://api.spotify.com/v1$endpoint');
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  late http.Response response;
  switch (method.toUpperCase()) {
    case 'GET':
      response = await http.get(uri, headers: headers);
    case 'POST':
      response = await http.post(
        uri,
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
      );
    case 'PUT':
      response = await http.put(
        uri,
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
      );
    case 'DELETE':
      response = await http.delete(uri, headers: headers);
    default:
      return 'Unsupported HTTP method: $method';
  }

  if (response.statusCode >= 200 && response.statusCode < 300) {
    return response.body.isEmpty ? 'Success' : response.body;
  } else {
    return 'Spotify API error ${response.statusCode}: '
        '${response.body}';
  }
}

Future<String> _spotifyPlay(String token, Map<String, dynamic> args) async {
  final uri = args['uri'] as String?;

  Map<String, dynamic>? body;
  if (uri != null) {
    if (uri.startsWith('spotify:track:')) {
      body = {
        'uris': [uri],
      };
    } else if (uri.startsWith('spotify:album:') ||
        uri.startsWith('spotify:playlist:') ||
        uri.startsWith('spotify:artist:')) {
      body = {'context_uri': uri};
    } else {
      body = {
        'uris': [uri],
      };
    }
  }

  await _spotifyApi(token, '/me/player/play', method: 'PUT', body: body);
  return uri == null ? 'Playback resumed' : 'Playing: $uri';
}

Future<String> _spotifySearch(String token, Map<String, dynamic> args) async {
  final query = args['query'] as String? ?? '';
  final type = args['type'] as String? ?? 'track';
  final limit = args['limit'] as int? ?? 5;

  if (query.isEmpty) return 'Error: No search query provided';

  final response = await _spotifyApi(
    token,
    '/search?q=${Uri.encodeComponent(query)}&type=$type&limit=$limit',
  );
  final data = jsonDecode(response);

  final buffer = StringBuffer('Search results for "$query":\n\n');
  final items = data['${type}s']?['items'] as List? ?? [];

  for (int i = 0; i < items.length; i++) {
    final item = items[i];
    buffer.writeln('${i + 1}. ${item['name']}');
    if (item['artists'] != null) {
      final artists = (item['artists'] as List)
          .map((a) => a['name'])
          .join(', ');
      buffer.writeln('   Artist: $artists');
    }
    buffer.writeln('   URI: ${item['uri']}');
    buffer.writeln();
  }

  return buffer.toString();
}

Future<String> _spotifyNowPlaying(String token) async {
  final response = await _spotifyApi(token, '/me/player/currently-playing');
  if (response == 'Success') {
    return 'Nothing is currently playing';
  }

  final data = jsonDecode(response);
  if (data['item'] == null) {
    return 'Nothing is currently playing';
  }

  final track = data['item'];
  final artists = (track['artists'] as List).map((a) => a['name']).join(', ');
  final isPlaying = data['is_playing'] as bool? ?? false;
  final progress = data['progress_ms'] as int? ?? 0;
  final duration = track['duration_ms'] as int? ?? 0;

  return 'Now Playing:\n'
      '${track['name']}\n'
      'Artist: $artists\n'
      'Album: ${track['album']['name']}\n'
      '${isPlaying ? 'Playing' : 'Paused'} '
      '${formatDuration(progress)} / ${formatDuration(duration)}\n'
      'URI: ${track['uri']}';
}

Future<String> _spotifyDevices(String token) async {
  final response = await _spotifyApi(token, '/me/player/devices');
  final data = jsonDecode(response);
  final devices = data['devices'] as List? ?? [];

  if (devices.isEmpty) {
    return 'No devices found. Open Spotify on a device.';
  }

  final buffer = StringBuffer('Available Spotify devices:\n\n');
  for (int i = 0; i < devices.length; i++) {
    final device = devices[i];
    final isActive = device['is_active'] as bool? ?? false;
    buffer.writeln(
      '${isActive ? "[Active]" : "[  ]"} '
      '${device['name']} (${device['type']})',
    );
    buffer.writeln('   ID: ${device['id']}');
    buffer.writeln('   Volume: ${device['volume_percent']}%');
    buffer.writeln();
  }

  return buffer.toString();
}

Future<String> _spotifyCreatePlaylist(
  String token,
  Map<String, dynamic> args,
) async {
  final name = args['name'] as String? ?? 'New Playlist';
  final description = args['description'] as String? ?? '';
  final isPublic = args['public'] as bool? ?? false;

  final userResponse = await _spotifyApi(token, '/me');
  final userData = jsonDecode(userResponse);
  final userId = userData['id'];

  final body = {'name': name, 'description': description, 'public': isPublic};

  final response = await _spotifyApi(
    token,
    '/users/$userId/playlists',
    method: 'POST',
    body: body,
  );
  final playlist = jsonDecode(response);

  return 'Playlist created: ${playlist['name']}\n'
      'URL: ${playlist['external_urls']['spotify']}\n'
      'ID: ${playlist['id']}';
}

Future<String> _spotifyGetPlaylists(String token) async {
  final response = await _spotifyApi(token, '/me/playlists?limit=50');
  final data = jsonDecode(response);
  final items = data['items'] as List? ?? [];

  if (items.isEmpty) return 'No playlists found';

  final buffer = StringBuffer('Your playlists:\n\n');
  for (int i = 0; i < items.length; i++) {
    final playlist = items[i];
    buffer.writeln('${i + 1}. ${playlist['name']}');
    buffer.writeln('   Tracks: ${playlist['tracks']?['total'] ?? 0}');
    buffer.writeln('   URI: ${playlist['uri']}');
    buffer.writeln();
  }

  return buffer.toString();
}

Future<String> _spotifyFindAndPlay(
  String token,
  Map<String, dynamic> args,
) async {
  final query = args['query'] as String? ?? '';
  if (query.isEmpty) return 'Error: query parameter required';

  final queryLower = query.toLowerCase();

  // Search user's playlists
  final playlistsResponse = await _spotifyApi(token, '/me/playlists?limit=50');
  final playlistsData = jsonDecode(playlistsResponse);
  final playlists = playlistsData['items'] as List? ?? [];

  for (final playlist in playlists) {
    final name = (playlist['name'] as String?)?.toLowerCase() ?? '';
    if (name.contains(queryLower)) {
      final uri = playlist['uri'] as String;
      await _spotifyApi(
        token,
        '/me/player/play',
        method: 'PUT',
        body: {'context_uri': uri},
      );
      return 'Playing your playlist: ${playlist['name']}';
    }
  }

  // Search public playlists as fallback
  final publicSearch = await _spotifyApi(
    token,
    '/search?q=${Uri.encodeComponent(query)}'
    '&type=playlist&limit=5',
  );
  final publicData = jsonDecode(publicSearch);
  final publicPlaylists = publicData['playlists']?['items'] as List? ?? [];

  if (publicPlaylists.isNotEmpty) {
    final playlist = publicPlaylists[0];
    if (playlist != null && playlist['uri'] != null) {
      final uri = playlist['uri'] as String;
      await _spotifyApi(
        token,
        '/me/player/play',
        method: 'PUT',
        body: {'context_uri': uri},
      );
      return 'Playing public playlist: ${playlist['name']}';
    }
  }

  return 'Could not find "$query" in your playlists.';
}

Future<String> _spotifyRecentlyLiked(
  String token,
  Map<String, dynamic> args,
) async {
  final limit = args['limit'] as int? ?? 20;
  final response = await _spotifyApi(token, '/me/tracks?limit=$limit');
  final data = jsonDecode(response);
  final items = data['items'] as List? ?? [];

  if (items.isEmpty) return 'No liked songs found';

  final buffer = StringBuffer('Your recently liked songs:\n\n');
  for (int i = 0; i < items.length; i++) {
    final item = items[i];
    final track = item['track'];

    buffer.writeln('${i + 1}. ${track['name']}');
    buffer.writeln('   Artist: ${track['artists']?[0]?['name'] ?? 'Unknown'}');
    buffer.writeln('   URI: ${track['uri']}');
    buffer.writeln();
  }

  return buffer.toString();
}

// ============== Bash ==============

Future<String> executeBash(Map<String, dynamic> args) async {
  final command = args['command'] as String?;
  if (command == null || command.isEmpty) {
    return 'Error: No command provided';
  }

  if (!_bashSandbox.isConfigured) {
    return 'Error: No sandbox folder configured. '
        'Please set a sandbox folder in Settings > Bash first.';
  }

  final result = await _bashSandbox.execute(command);
  if (result['success'] == true) {
    return result['output'] as String? ?? 'Command executed successfully';
  } else {
    return 'Error: ${result['error'] ?? 'Unknown error'}';
  }
}

// ============== GitHub ==============

Future<String> executeGitHub(Map<String, dynamic> args) async {
  if (!_gitHubOAuth.isAuthenticated) {
    return 'Error: GitHub not authenticated. '
        'Please connect GitHub in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'get_user':
        final result = await _gitHubOAuth.getUser();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final user = result['user'] as Map<String, dynamic>? ?? {};
        return 'GitHub User: ${user['login']}\n'
            'Name: ${user['name'] ?? 'N/A'}\n'
            'Repos: ${user['public_repos']}';

      case 'list_repos':
        final result = await _gitHubOAuth.listRepos();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final repos = result['repos'] as List? ?? [];
        if (repos.isEmpty) return 'No repositories found';
        return 'Repositories:\n${repos.take(20).map((r) => '- ${r['full_name']}${r['private'] == true ? ' (private)' : ''}').join('\n')}';

      case 'get_repo':
        final owner = args['owner'] as String?;
        final repo = args['repo'] as String?;
        if (owner == null || repo == null) {
          return 'Error: owner and repo required';
        }
        final result = await _gitHubOAuth.getRepo(owner, repo);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final data = result['repo'] as Map<String, dynamic>? ?? {};
        return 'Repository: ${data['full_name']}\n'
            'Description: ${data['description'] ?? 'N/A'}\n'
            'Stars: ${data['stargazers_count']}\n'
            'Forks: ${data['forks_count']}';

      case 'list_issues':
        final owner = args['owner'] as String?;
        final repo = args['repo'] as String?;
        if (owner == null || repo == null) {
          return 'Error: owner and repo required';
        }
        final state = args['state'] as String? ?? 'open';
        final result = await _gitHubOAuth.listIssues(owner, repo, state: state);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final issues = result['issues'] as List? ?? [];
        if (issues.isEmpty) return 'No $state issues found';
        return 'Issues ($state):\n${issues.take(20).map((i) => '#${i['number']}: ${i['title']}').join('\n')}';

      case 'create_issue':
        final owner = args['owner'] as String?;
        final repo = args['repo'] as String?;
        final title = args['title'] as String?;
        final body = args['body'] as String?;
        if (owner == null || repo == null || title == null) {
          return 'Error: owner, repo, and title required';
        }
        final labels = (args['labels'] as List?)?.cast<String>();
        final result = await _gitHubOAuth.createIssue(
          owner,
          repo,
          title: title,
          body: body,
          labels: labels,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final issue = result['issue'] as Map<String, dynamic>? ?? {};
        return 'Issue created: #${issue['number']} - '
            '${issue['title']}\n'
            'URL: ${issue['html_url']}';

      case 'list_pull_requests':
        final owner = args['owner'] as String?;
        final repo = args['repo'] as String?;
        if (owner == null || repo == null) {
          return 'Error: owner and repo required';
        }
        final state = args['state'] as String? ?? 'open';
        final result = await _gitHubOAuth.listPullRequests(
          owner,
          repo,
          state: state,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final prs = result['pull_requests'] as List? ?? [];
        if (prs.isEmpty) {
          return 'No $state pull requests found';
        }
        return 'Pull Requests ($state):\n${prs.take(20).map((p) => '#${p['number']}: ${p['title']}').join('\n')}';

      case 'add_comment':
        final owner = args['owner'] as String?;
        final repo = args['repo'] as String?;
        final issueNumber = args['issue_number'] as int?;
        final body = args['body'] as String?;
        if (owner == null ||
            repo == null ||
            issueNumber == null ||
            body == null) {
          return 'Error: owner, repo, issue_number, and body '
              'required';
        }
        final result = await _gitHubOAuth.addComment(
          owner,
          repo,
          issueNumber,
          body: body,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'Comment added to issue #$issueNumber';

      default:
        return 'Unknown GitHub action: $action. '
            'Available: get_user, list_repos, get_repo, '
            'list_issues, create_issue, list_pull_requests, '
            'add_comment';
    }
  } catch (e) {
    return 'GitHub error: $e';
  }
}

// ============== Slack ==============

Future<String> executeSlack(Map<String, dynamic> args) async {
  if (!_slackOAuth.hasToken) {
    return 'Error: Slack not authenticated. '
        'Please connect Slack in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'test_auth':
        final result = await _slackOAuth.testAuth();
        return 'Slack connected as: ${result['user']} '
            'in team ${result['team']}';

      case 'list_channels':
        final result = await _slackOAuth.listChannels();
        final channels = result['channels'] as List? ?? [];
        if (channels.isEmpty) return 'No channels found';
        return 'Channels:\n${channels.take(30).map((c) => '- #${(c as Map<String, dynamic>)['name']} (${c['id']})').join('\n')}';

      case 'find_channel':
        final name = args['channel_name'] as String?;
        if (name == null) return 'Error: channel_name required';
        final channel = await _slackOAuth.findChannel(name);
        if (channel == null) {
          return 'Channel #$name not found';
        }
        return 'Found channel: #${channel['name']} '
            '(ID: ${channel['id']})';

      case 'get_channel_history':
        final channelId = args['channel_id'] as String?;
        if (channelId == null) {
          return 'Error: channel_id required';
        }
        final limit = args['limit'] as int? ?? 20;
        final result = await _slackOAuth.getChannelHistory(
          channel: channelId,
          limit: limit,
        );
        final messages = result['messages'] as List? ?? [];
        if (messages.isEmpty) return 'No messages found';
        return 'Recent messages:\n${messages.map((m) => '- ${(m as Map<String, dynamic>)['user'] ?? 'bot'}: ${m['text']}').join('\n')}';

      case 'send_message':
        final channelId = args['channel_id'] as String?;
        final message = args['message'] as String?;
        final threadTs = args['thread_ts'] as String?;
        if (channelId == null || message == null) {
          return 'Error: channel_id and message required';
        }
        if (_approvalConfig.isApprovalRequired(ApprovalCategory.slack)) {
          return 'Error: Slack message sending requires approval. '
              'Approval handling not yet implemented in chat UI.';
        }
        final result = await _slackOAuth.sendMessage(
          channel: channelId,
          text: message,
          threadTs: threadTs,
        );
        return 'Message sent (ts: ${result['ts']})';

      case 'search_messages':
        final query = args['query'] as String?;
        if (query == null) return 'Error: query required';
        final result = await _slackOAuth.searchMessages(query: query);
        final searchMessages =
            result['messages'] as Map<String, dynamic>? ?? {};
        final matches = searchMessages['matches'] as List? ?? [];
        if (matches.isEmpty) {
          return 'No messages found matching "$query"';
        }
        return 'Search results for "$query":\n${matches.take(10).map((m) => '- ${(m as Map<String, dynamic>)['channel']?['name'] ?? 'DM'}: ${m['text']}').join('\n')}';

      case 'get_users':
        final result = await _slackOAuth.getUsers();
        final members = result['members'] as List? ?? [];
        if (members.isEmpty) return 'No users found';
        return 'Users:\n${members.take(30).map((u) => '- ${(u as Map<String, dynamic>)['real_name'] ?? u['name']} (@${u['name']})').join('\n')}';

      default:
        return 'Unknown Slack action: $action. '
            'Available: test_auth, list_channels, find_channel, '
            'get_channel_history, send_message, search_messages, '
            'get_users';
    }
  } catch (e) {
    return 'Slack error: $e';
  }
}

// ============== Google Calendar ==============

Future<String> executeGoogleCalendar(Map<String, dynamic> args) async {
  if (!_googleOAuth.isAuthenticated) {
    return 'Error: Google not authenticated. '
        'Please connect Google in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'list_calendars':
        final result = await _googleOAuth.listCalendars();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final calendars = result['calendars'] as List? ?? [];
        if (calendars.isEmpty) return 'No calendars found';
        return 'Calendars:\n${calendars.map((c) => '- ${c['summary']} (${c['id']})').join('\n')}';

      case 'list_events':
        final calendarId = args['calendar_id'] as String? ?? 'primary';
        final maxResults = args['max_results'] as int? ?? 10;
        final query = args['query'] as String?;
        final result = await _googleOAuth.listEvents(
          calendarId: calendarId,
          maxResults: maxResults,
          query: query,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final events = result['events'] as List? ?? [];
        if (events.isEmpty) return 'No upcoming events found';
        return 'Upcoming events:\n${events.map((e) => '- ${e['summary'] ?? 'No title'} (${e['start'] ?? 'TBD'})').join('\n')}';

      case 'create_event':
        final calendarId = args['calendar_id'] as String? ?? 'primary';
        final summary = args['summary'] as String?;
        final startStr = args['start'] as String?;
        final endStr = args['end'] as String?;
        if (summary == null || startStr == null || endStr == null) {
          return 'Error: summary, start, and end required';
        }
        final result = await _googleOAuth.createEvent(
          calendarId: calendarId,
          summary: summary,
          start: DateTime.parse(startStr),
          end: DateTime.parse(endStr),
          description: args['description'] as String?,
          location: args['location'] as String?,
          attendees: (args['attendees'] as List?)?.cast<String>(),
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final event = result['event'] as Map<String, dynamic>? ?? {};
        return 'Event created: ${event['summary']}\n'
            'Link: ${event['htmlLink']}';

      case 'update_event':
        final calendarId = args['calendar_id'] as String? ?? 'primary';
        final eventId = args['event_id'] as String?;
        if (eventId == null) return 'Error: event_id required';
        final startStr = args['start'] as String?;
        final endStr = args['end'] as String?;
        final result = await _googleOAuth.updateEvent(
          calendarId: calendarId,
          eventId: eventId,
          summary: args['summary'] as String?,
          start: startStr != null ? DateTime.parse(startStr) : null,
          end: endStr != null ? DateTime.parse(endStr) : null,
          description: args['description'] as String?,
          location: args['location'] as String?,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final event = result['event'] as Map<String, dynamic>? ?? {};
        return 'Event updated: ${event['summary']}';

      case 'delete_event':
        final calendarId = args['calendar_id'] as String? ?? 'primary';
        final eventId = args['event_id'] as String?;
        if (eventId == null) return 'Error: event_id required';
        final result = await _googleOAuth.deleteEvent(
          calendarId: calendarId,
          eventId: eventId,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'Event deleted';

      default:
        return 'Unknown Google Calendar action: $action. '
            'Available: list_calendars, list_events, '
            'create_event, update_event, delete_event';
    }
  } catch (e) {
    return 'Google Calendar error: $e';
  }
}

// ============== Gmail ==============

Future<String> executeGmail(Map<String, dynamic> args) async {
  if (!_googleOAuth.isAuthenticated) {
    return 'Error: Google not authenticated. '
        'Please connect Google in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'list_messages':
        final query = args['query'] as String?;
        final maxResults = args['max_results'] as int? ?? 10;
        final labelIds = (args['label_ids'] as List?)?.cast<String>();
        final result = await _googleOAuth.listMessages(
          query: query,
          maxResults: maxResults,
          labelIds: labelIds,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final messages = result['messages'] as List? ?? [];
        if (messages.isEmpty) return 'No messages found';
        return 'Messages:\n${messages.map((m) => '- ${m['subject'] ?? m['snippet'] ?? 'No preview'} (ID: ${m['id']})').join('\n')}';

      case 'read_message':
        final messageId = args['message_id'] as String?;
        if (messageId == null) {
          return 'Error: message_id required';
        }
        final result = await _googleOAuth.readMessage(messageId);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final message = result['message'] as Map<String, dynamic>? ?? {};
        return 'From: ${message['from'] ?? 'Unknown'}\n'
            'Subject: ${message['subject'] ?? 'No subject'}\n\n'
            '${message['body'] ?? message['snippet'] ?? 'No content'}';

      case 'send_email':
        final to = args['to'] as String?;
        final subject = args['subject'] as String?;
        final body = args['body'] as String?;
        if (to == null || subject == null || body == null) {
          return 'Error: to, subject, and body required';
        }
        final result = await _googleOAuth.sendEmail(
          to: to,
          subject: subject,
          body: body,
          cc: args['cc'] as String?,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'Email sent to $to';

      case 'get_labels':
        final result = await _googleOAuth.getLabels();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final labels = result['labels'] as List? ?? [];
        if (labels.isEmpty) return 'No labels found';
        return 'Labels:\n${labels.map((l) => '- ${l['name']} (${l['id']})').join('\n')}';

      default:
        return 'Unknown Gmail action: $action. '
            'Available: list_messages, read_message, '
            'send_email, get_labels';
    }
  } catch (e) {
    return 'Gmail error: $e';
  }
}

// ============== Email (IMAP/SMTP) ==============

Future<String> executeEmail(Map<String, dynamic> args) async {
  if (!_emailService.isConfigured) {
    return 'Error: Email not configured. '
        'Please set up IMAP/SMTP in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'list_mailboxes':
        final result = await _emailService.listMailboxes();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final mailboxes = result['mailboxes'] as List? ?? [];
        if (mailboxes.isEmpty) return 'No mailboxes found';
        return 'Mailboxes:\n${mailboxes.map((m) => '- ${m['name']}${m['isInbox'] == true ? ' (Inbox)' : ''}').join('\n')}';

      case 'list_emails':
        final mailbox = args['mailbox'] as String? ?? 'INBOX';
        final limit = args['limit'] as int? ?? 20;
        final offset = args['offset'] as int? ?? 0;
        final result = await _emailService.listEmails(
          mailbox,
          limit: limit,
          offset: offset,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final emails = result['emails'] as List? ?? [];
        if (emails.isEmpty) {
          return 'No emails found in $mailbox';
        }
        final total = result['total'] ?? emails.length;
        return 'Emails in $mailbox ($total total):\n${emails.map((e) => '- [${(e as Map<String, dynamic>)['isRead'] == true ? 'R' : 'U'}] ${e['subject'] ?? 'No subject'} from ${e['from']} (ID: ${e['sequenceId']})').join('\n')}';

      case 'search_emails':
        final mailbox = args['mailbox'] as String? ?? 'INBOX';
        DateTime? since;
        DateTime? before;
        if (args['since'] != null) {
          since = DateTime.tryParse(args['since'] as String);
        }
        if (args['before'] != null) {
          before = DateTime.tryParse(args['before'] as String);
        }
        final result = await _emailService.searchEmails(
          mailbox,
          from: args['from'] as String?,
          to: args['to'] as String?,
          subject: args['subject'] as String?,
          text: args['text'] as String?,
          since: since,
          before: before,
          unreadOnly: args['unread_only'] as bool? ?? false,
          limit: args['limit'] as int? ?? 20,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final emails = result['emails'] as List? ?? [];
        if (emails.isEmpty) {
          return 'No emails found matching search';
        }
        final total = result['total'] ?? emails.length;
        return 'Search results ($total found):\n${emails.map((e) => '- ${(e as Map<String, dynamic>)['subject'] ?? 'No subject'} from ${e['from']} (ID: ${e['sequenceId']})').join('\n')}';

      case 'read_email':
        final sequenceId = args['sequence_id'] as int?;
        if (sequenceId == null) {
          return 'Error: sequence_id required';
        }
        final mailbox = args['mailbox'] as String? ?? 'INBOX';
        final result = await _emailService.readEmail(mailbox, sequenceId);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final emailMsg = result['email'] as Map<String, dynamic>? ?? {};
        return 'From: ${emailMsg['from'] ?? 'Unknown'}\n'
            'Subject: ${emailMsg['subject'] ?? 'No subject'}\n'
            'Date: ${emailMsg['date'] ?? 'Unknown'}\n\n'
            '${emailMsg['textBody'] ?? emailMsg['htmlBody'] ?? 'No content'}';

      case 'send_email':
        final to = args['to'] as String?;
        final subject = args['subject'] as String?;
        final body = args['body'] as String?;
        if (to == null || subject == null || body == null) {
          return 'Error: to, subject, and body required';
        }
        final ccStr = args['cc'] as String?;
        final bccStr = args['bcc'] as String?;
        final result = await _emailService.sendEmail(
          to: to,
          subject: subject,
          body: body,
          cc: ccStr?.split(',').map((s) => s.trim()).toList(),
          bcc: bccStr?.split(',').map((s) => s.trim()).toList(),
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Email sent successfully';

      case 'unread_count':
        final mailbox = args['mailbox'] as String? ?? 'INBOX';
        final result = await _emailService.getUnreadCount(mailbox);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return '$mailbox: ${result['unread']} unread '
            'of ${result['total']} total';

      default:
        return 'Unknown email action: $action. '
            'Available: list_mailboxes, list_emails, '
            'search_emails, read_email, send_email, unread_count';
    }
  } catch (e) {
    return 'Email error: $e';
  }
}

// ============== Device ==============

Future<String> executeDevice(Map<String, dynamic> args) async {
  final action = args['action'] as String?;
  if (action == null) {
    return 'Error: No action specified. '
        'Use: get_location, create_calendar_event, set_alarm, '
        'set_timer, cancel_alarm, list_alarms, sms_draft, '
        'email_draft, platform_info, distance';
  }

  try {
    switch (action.toLowerCase()) {
      case 'get_location':
        final result = await _deviceServices.getCurrentLocation();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final heading = result['heading'] as double?;
        if (heading != null && heading >= 0) {
          const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
          final idx = ((heading + 22.5) / 45).floor() % 8;
          result['heading_direction'] = dirs[idx];
        }
        return 'DEVICE_LOCATION:${jsonEncode(result)}';

      case 'get_last_location':
        final result = await _deviceServices.getLastKnownLocation();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'DEVICE_LOCATION:${jsonEncode(result)}';

      case 'create_calendar_event':
        final title = args['title'] as String?;
        final startStr = args['start'] as String?;
        final endStr = args['end'] as String?;
        if (title == null || startStr == null || endStr == null) {
          return 'Error: title, start, and end are required';
        }
        final result = await _deviceServices.createCalendarEvent(
          title: title,
          startDate: DateTime.parse(startStr),
          endDate: DateTime.parse(endStr),
          description: args['description'] as String?,
          location: args['location'] as String?,
          allDay: args['all_day'] as bool? ?? false,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Calendar event created';

      case 'set_alarm':
        final title = args['title'] as String? ?? 'Alarm';
        final timeStr = args['time'] as String?;
        if (timeStr == null) {
          return 'Error: time is required '
              '(ISO datetime, e.g. 2025-12-31T08:00:00)';
        }
        final alarmTime = DateTime.parse(timeStr);
        final result = await _deviceServices.setAlarm(
          title: title,
          dateTime: alarmTime,
          description: args['description'] as String?,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Alarm set';

      case 'set_timer':
        final title =
            args['label'] as String? ?? args['title'] as String? ?? 'Timer';
        final seconds =
            args['seconds'] as int? ?? (args['minutes'] as int? ?? 0) * 60;
        if (seconds <= 0) {
          return 'Error: seconds or minutes required';
        }
        final result = await _deviceServices.setTimer(
          title: title,
          duration: Duration(seconds: seconds),
          description: args['description'] as String?,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Timer set';

      case 'cancel_alarm':
        final alarmId = args['alarm_id'] as int?;
        if (alarmId == null) return 'Error: alarm_id required';
        final result = _deviceServices.cancelAlarm(alarmId);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Alarm cancelled';

      case 'list_alarms':
        final result = _deviceServices.listAlarms();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final alarms = result['alarms'] as List? ?? [];
        if (alarms.isEmpty) return 'No active alarms';
        return 'Active alarms:\n${alarms.map((a) => '- [ID: ${(a as Map<String, dynamic>)['id']}] ${a['title']} at ${a['dateTime']}').join('\n')}';

      case 'sms_draft':
        final phone = args['phone'] as String?;
        final message = args['message'] as String?;
        if (phone == null || message == null) {
          return 'Error: phone and message required';
        }
        final result = await _deviceServices.createSmsDraft(
          phoneNumber: phone,
          body: message,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'SMS draft opened';

      case 'email_draft':
        final to = args['to'] as String?;
        if (to == null) {
          return 'Error: to (email address) required';
        }
        final ccStr = args['cc'] as String?;
        final bccStr = args['bcc'] as String?;
        final result = await _deviceServices.createEmailDraft(
          to: to,
          subject: args['subject'] as String?,
          body: args['body'] as String?,
          cc: ccStr?.split(',').map((s) => s.trim()).toList(),
          bcc: bccStr?.split(',').map((s) => s.trim()).toList(),
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return result['message'] as String? ?? 'Email draft opened';

      case 'platform_info':
        final caps = _deviceServices.getPlatformCapabilities();
        final calCaps = caps['calendar'] as Map<String, dynamic>? ?? {};
        final alarmCaps = caps['alarms'] as Map<String, dynamic>? ?? {};
        final smsCaps = caps['sms'] as Map<String, dynamic>? ?? {};
        final emailCaps = caps['email'] as Map<String, dynamic>? ?? {};
        final gpsCaps = caps['gps'] as Map<String, dynamic>? ?? {};
        final notifCaps = caps['notifications'] as Map<String, dynamic>? ?? {};
        return 'Platform: ${caps['platform']}\n'
            'Calendar events: ${calCaps['supported'] == true ? 'yes (${calCaps['method']})' : 'no'}\n'
            'Alarms/Timers: ${alarmCaps['supported'] == true ? 'yes' : 'no'}\n'
            'SMS drafts: ${smsCaps['supported'] == true ? 'yes' : 'no'}\n'
            'Email drafts: ${emailCaps['supported'] == true ? 'yes' : 'no'}\n'
            'Geolocation: ${gpsCaps['supported'] == true ? 'yes' : 'no'}\n'
            'Notifications: ${notifCaps['supported'] == true ? 'yes' : 'no'}';

      case 'distance':
        final fromLat = args['from_lat'] != null
            ? toDouble(args['from_lat'])
            : null;
        final fromLon = args['from_lon'] != null
            ? toDouble(args['from_lon'])
            : null;
        final toLat = args['to_lat'] != null ? toDouble(args['to_lat']) : null;
        final toLon = args['to_lon'] != null ? toDouble(args['to_lon']) : null;
        if (fromLat == null ||
            fromLon == null ||
            toLat == null ||
            toLon == null) {
          return 'Error: from_lat, from_lon, to_lat, to_lon '
              'required';
        }
        final meters = _deviceServices.calculateDistance(
          fromLat,
          fromLon,
          toLat,
          toLon,
        );
        final km = meters / 1000;
        return 'Distance: ${km.toStringAsFixed(2)} km '
            '(${meters.toStringAsFixed(0)} m)';

      default:
        return 'Unknown device action: $action. '
            'Available: get_location, create_calendar_event, '
            'set_alarm, set_timer, cancel_alarm, list_alarms, '
            'sms_draft, email_draft, platform_info, distance';
    }
  } catch (e) {
    return 'Device error: $e';
  }
}
