import 'dart:convert';

import 'package:chuk_chat/services/approval_config.dart';
import 'package:chuk_chat/services/bash_sandbox.dart';
import 'package:chuk_chat/services/device_services.dart';
import 'package:chuk_chat/services/github_oauth.dart';
import 'package:chuk_chat/services/google_oauth.dart';
import 'package:chuk_chat/services/slack_oauth.dart';
import 'package:chuk_chat/utils/tool_helpers.dart';

/// Singleton service instances for native platforms.
final BashSandbox _bashSandbox = BashSandbox();
final GitHubOAuth _gitHubOAuth = GitHubOAuth();
final SlackOAuth _slackOAuth = SlackOAuth();
final GoogleOAuth _googleOAuth = GoogleOAuth();
final DeviceServices _deviceServices = DeviceServices();
final ApprovalConfig _approvalConfig = ApprovalConfig();

/// Initialize platform services — loads saved tokens/configs.
Future<void> initPlatformServices() async {
  await Future.wait(<Future<void>>[
    _approvalConfig.load(),
    _gitHubOAuth.loadSavedToken(),
    _slackOAuth.isAuthenticated(), // loads tokens internally
    _googleOAuth.getAccessToken().then((_) {}), // loads tokens internally
    _bashSandbox.loadSavedFolder(),
  ]);
}

/// Check if a platform service is connected.
bool isPlatformServiceConnected(String service) {
  switch (service) {
    case 'bash':
      return _bashSandbox.isConfigured;
    case 'github':
      return _gitHubOAuth.isAuthenticated;
    case 'slack':
      return _slackOAuth.hasToken;
    case 'google':
      return _googleOAuth.isAuthenticated;
    default:
      return false;
  }
}

// ============== Service connection management ==============

/// Categories that support OAuth connect/disconnect.
final Set<String> connectableServices = {
  'github',
  'slack',
  'google',
};

/// Start the OAuth flow for a service. Returns true on success.
Future<bool> connectPlatformService(String service) async {
  switch (service) {
    case 'github':
      await _gitHubOAuth.startAuth();
      return _gitHubOAuth.completeAuth();
    case 'slack':
      await _slackOAuth.startAuth();
      return _slackOAuth.completeAuth();
    case 'google':
      await _googleOAuth.startAuth();
      return _googleOAuth.completeAuth();
    default:
      return false;
  }
}

/// Disconnect a service by clearing its stored tokens.
Future<void> disconnectPlatformService(String service) async {
  switch (service) {
    case 'github':
      await _gitHubOAuth.logout();
    case 'slack':
      await _slackOAuth.logout();
    case 'google':
      await _googleOAuth.logout();
  }
}

// ============== Bash ==============

/// Folder the local bash tool is confined to, null while unset.
String? get bashSandboxFolder => _bashSandbox.sandboxFolder;

/// Confine the local bash tool to [path]. Throws [StateError] if the folder
/// is gone by the time it is picked.
Future<void> setBashSandboxFolder(String path) =>
    _bashSandbox.setSandboxFolder(path);

/// Forget the sandbox folder; bash commands are refused until a new one is set.
Future<void> clearBashSandboxFolder() => _bashSandbox.clearSandboxFolder();

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

// ============== Standalone wrappers for top-level tools ==============
// These delegate to DeviceServices so the AI can discover them by name
// without going through the generic "device" tool + action parameter.

Future<String> executeCalendar(Map<String, dynamic> args) async {
  return executeDevice({...args, 'action': 'create_calendar_event'});
}

Future<String> executeReminder(Map<String, dynamic> args) async {
  // A reminder is an alarm at a specific time
  final action = args['action'] as String? ?? 'set_alarm';
  switch (action) {
    case 'set_timer':
      return executeDevice({...args, 'action': 'set_timer'});
    case 'cancel':
      return executeDevice({...args, 'action': 'cancel_alarm'});
    case 'list':
      return executeDevice({...args, 'action': 'list_alarms'});
    default:
      // Default: set_alarm
      // Allow "time" or "start" for convenience
      final time = args['time'] ?? args['start'];
      return executeDevice({
        ...args,
        ...?(time == null ? null : <String, dynamic>{'time': time}),
        'action': 'set_alarm',
      });
  }
}

Future<String> executeDraftEmail(Map<String, dynamic> args) async {
  return executeDevice({...args, 'action': 'email_draft'});
}
