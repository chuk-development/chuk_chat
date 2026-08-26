// CoWork messenger — data model + mock roster.
//
// This is the *basic UI* layer: a Slack-like roster of AI coworker agents and
// their threads. Data here is mock/in-memory for now; the Python backend
// (manager/relay/executor) replaces this source later. See
// docs/COWORK_AGENT_PLATFORM_PLAN.md §1.

import 'package:flutter/material.dart';

/// Deterministic, name-derived palette (mirrors the workspace color ladder so
/// CoWork avatars sit in the same visual family as the rest of the app).
const List<Color> kCoworkAvatarColors = [
  Color(0xFF6366F1), // Indigo
  Color(0xFF8B5CF6), // Violet
  Color(0xFFEC4899), // Pink
  Color(0xFFEF4444), // Red
  Color(0xFFF97316), // Orange
  Color(0xFFEAB308), // Yellow
  Color(0xFF22C55E), // Green
  Color(0xFF14B8A6), // Teal
  Color(0xFF06B6D4), // Cyan
  Color(0xFF3B82F6), // Blue
  Color(0xFF8B5E3C), // Brown
  Color(0xFF64748B), // Slate
];

/// Stable color for a coworker, derived from its name.
Color coworkColorFor(String name) =>
    kCoworkAvatarColors[name.hashCode.abs() % kCoworkAvatarColors.length];

/// One coworker (a contact in the roster) — a single agent or a group.
class CoworkAgent {
  const CoworkAgent({
    required this.id,
    required this.name,
    this.preview = '',
    this.time = '',
    this.unread = 0,
    this.isGroup = false,
    this.members = const <String>[],
    this.seed,
    this.working = false,
    this.thread = const <CoworkTurn>[],
    this.isHost = false,
  });

  final String id;
  final String name;

  /// Last-line preview shown in the roster row.
  final String preview;

  /// Human time label shown in the roster row (mock strings for now).
  final String time;

  /// Unread count; 0 hides the badge.
  final int unread;

  /// A group chat with several agents rather than a single coworker.
  final bool isGroup;

  /// Member names for a group (used to draw the stacked avatar).
  final List<String> members;

  /// Optional color override; falls back to a name-derived color.
  final Color? seed;

  /// Whether the agent is mid-run (drives the "Working" badge).
  final bool working;

  /// The conversation so far.
  final List<CoworkTurn> thread;

  /// The live host connection — its thread is a real relay/executor run
  /// (pairing + streamed run), not the mock conversation.
  final bool isHost;

  Color get color => seed ?? coworkColorFor(name);

  CoworkAgent copyWith({
    String? preview,
    String? time,
    int? unread,
    bool? working,
    List<CoworkTurn>? thread,
  }) => CoworkAgent(
    id: id,
    name: name,
    preview: preview ?? this.preview,
    time: time ?? this.time,
    unread: unread ?? this.unread,
    isGroup: isGroup,
    members: members,
    seed: seed,
    working: working ?? this.working,
    thread: thread ?? this.thread,
  );
}

/// One message in a thread. `isUser` picks the bubble side; when the sender is
/// the agent, `text` is rendered by the shared MessageBubble.
class CoworkTurn {
  const CoworkTurn({
    required this.text,
    required this.isUser,
    this.working = false,
  });

  final String text;
  final bool isUser;

  /// Renders the "Working" header on an agent turn (a live run).
  final bool working;
}

/// Seed roster mirroring the reference design. The first entry is the real
/// host connection (live relay/executor); the rest are mock until the backend
/// drives the roster.
List<CoworkAgent> mockCoworkRoster() => <CoworkAgent>[
  const CoworkAgent(
    id: 'host',
    name: 'Your Host',
    preview: 'connect your machine to run tasks',
    time: '',
    isHost: true,
    seed: Color(0xFFA8C7FA),
  ),
  const CoworkAgent(
    id: 'chief',
    name: 'Chief',
    preview: 'booked the venue and sent the invite',
    time: 'Yesterday',
    thread: [
      CoworkTurn(text: 'Book the offsite venue and send the invite.', isUser: true),
      CoworkTurn(
        text: 'Done. Venue booked for the 14th, invite is out to the team.',
        isUser: false,
      ),
    ],
  ),
  const CoworkAgent(
    id: 'sales-outbound',
    name: 'Sales Outbound',
    preview: "checking what's connected",
    time: '6:19 PM',
    working: true,
    thread: [
      CoworkTurn(
        text:
            'Pull the accounts from Hex, Gmail, and Salesforce. Draft email '
            'and LinkedIn sequences in my voice.',
        isUser: true,
      ),
      CoworkTurn(
        text:
            "Checking what's connected. Hex, Gmail, and LinkedIn are already "
            "signed in. Salesforce isn't.",
        isUser: false,
      ),
      CoworkTurn(
        text: 'Sign in to Salesforce so I can see the accounts you own.',
        isUser: false,
        working: true,
      ),
    ],
  ),
  const CoworkAgent(
    id: 'inbox-manager',
    name: 'Inbox Manager',
    preview: 'sent. inbox at zero, 5 drafts waiting',
    time: '3:19 PM',
    thread: [
      CoworkTurn(text: 'Clear my inbox and draft the replies.', isUser: true),
      CoworkTurn(
        text: 'Inbox at zero. 5 drafts are waiting for your review.',
        isUser: false,
      ),
    ],
  ),
  const CoworkAgent(
    id: 'account-manager',
    name: 'Account Manager',
    preview: "invite's out to vicky, global set",
    time: '1:19 PM',
    thread: [
      CoworkTurn(text: 'Add Vicky to the global account.', isUser: true),
      CoworkTurn(text: "Invite's out to Vicky. Global access set.", isUser: false),
    ],
  ),
  const CoworkAgent(
    id: 'talent-scout',
    name: 'Talent Scout',
    preview: '3 intros drafted in your voice',
    time: '10:19 AM',
    unread: 2,
    thread: [
      CoworkTurn(text: 'Find three senior backend candidates.', isUser: true),
      CoworkTurn(text: '3 intros drafted in your voice, ready to send.', isUser: false),
    ],
  ),
  const CoworkAgent(
    id: 'expense-manager',
    name: 'Expense Manager',
    preview: 'report filed. 9 receipts, all matched',
    time: '2:19 PM',
    thread: [
      CoworkTurn(text: 'File last week\'s expenses.', isUser: true),
      CoworkTurn(text: 'Report filed. 9 receipts, all matched.', isUser: false),
    ],
  ),
  const CoworkAgent(
    id: 'offsite-crew',
    name: 'Offsite crew',
    preview: 'that leaves the pipeline clear',
    time: '12:19 PM',
    isGroup: true,
    members: ['Chief', 'Talent Scout', 'Expense Manager'],
    thread: [
      CoworkTurn(text: 'Plan the offsite as a crew.', isUser: true),
      CoworkTurn(text: 'Venue, travel and budget are lined up. That leaves the pipeline clear.', isUser: false),
    ],
  ),
];
