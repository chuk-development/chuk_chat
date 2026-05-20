import 'package:flutter/material.dart';

class DemoChat {
  final String id;
  final String title;
  final String preview;
  final DateTime time;
  final int unread;
  final String? emoji;
  final Color accent;
  final bool pinned;

  const DemoChat({
    required this.id,
    required this.title,
    required this.preview,
    required this.time,
    this.unread = 0,
    this.emoji,
    this.accent = const Color(0xFF7C3AED),
    this.pinned = false,
  });
}

class DemoProject {
  final String id;
  final String name;
  final Color color;
  final int chatCount;
  const DemoProject(this.id, this.name, this.color, this.chatCount);
}

class DemoData {
  static List<DemoChat> chats() {
    final now = DateTime.now();
    DateTime t(int hOff) => now.subtract(Duration(hours: hOff));
    DateTime d(int dOff) => now.subtract(Duration(days: dOff));
    return [
      DemoChat(
        id: '1',
        title: 'Flutter sidebar redesign',
        preview: 'Let\'s look at glassmorphism and dense layouts...',
        time: t(0),
        unread: 2,
        emoji: '🎨',
        accent: const Color(0xFF7C3AED),
        pinned: true,
      ),
      DemoChat(
        id: '2',
        title: 'Supabase RLS policies',
        preview: 'Row level security for chat_messages table',
        time: t(1),
        emoji: '🔒',
        accent: const Color(0xFF10B981),
        pinned: true,
      ),
      DemoChat(
        id: '3',
        title: 'Trip planning — Kyoto',
        preview: 'Day 4: Fushimi Inari then Gion...',
        time: t(3),
        unread: 5,
        emoji: '🗾',
        accent: const Color(0xFFEF4444),
      ),
      DemoChat(
        id: '4',
        title: 'Code review: chat_ui_mobile',
        preview: 'Looks good, one nit on the scroll controller',
        time: t(6),
        emoji: '👀',
        accent: const Color(0xFF3B82F6),
      ),
      DemoChat(
        id: '5',
        title: 'Recipe ideas for dinner',
        preview: 'Pasta puttanesca or Thai green curry?',
        time: d(1),
        emoji: '🍝',
        accent: const Color(0xFFF59E0B),
      ),
      DemoChat(
        id: '6',
        title: 'Math: gradient descent',
        preview: 'Why does the learning rate matter so much...',
        time: d(1),
        emoji: '∑',
        accent: const Color(0xFF8B5CF6),
      ),
      DemoChat(
        id: '7',
        title: 'Resume bullet rewrite',
        preview: 'Senior engineer at ACME, shipped...',
        time: d(2),
        emoji: '📄',
        accent: const Color(0xFF06B6D4),
      ),
      DemoChat(
        id: '8',
        title: 'Bug: avatar cache invalidation',
        preview: 'Old images persist after profile update',
        time: d(3),
        emoji: '🐞',
        accent: const Color(0xFFE11D48),
      ),
      DemoChat(
        id: '9',
        title: 'Startup pitch deck v3',
        preview: 'Cut slide 7 and merge 9 into 8',
        time: d(4),
        emoji: '🚀',
        accent: const Color(0xFFF43F5E),
      ),
      DemoChat(
        id: '10',
        title: 'Reading list — sci-fi',
        preview: 'Children of Time, Project Hail Mary, ...',
        time: d(5),
        emoji: '📚',
        accent: const Color(0xFF22C55E),
      ),
      DemoChat(
        id: '11',
        title: 'Workout split — push/pull/legs',
        preview: 'Tuesday: chest + triceps',
        time: d(6),
        emoji: '💪',
        accent: const Color(0xFFEAB308),
      ),
      DemoChat(
        id: '12',
        title: 'Dart 3 pattern matching',
        preview: 'Sealed classes and exhaustive switch',
        time: d(8),
        emoji: '🎯',
        accent: const Color(0xFF14B8A6),
      ),
    ];
  }

  static List<DemoProject> projects() => const [
        DemoProject('p1', 'Chuk Chat', Color(0xFF7C3AED), 14),
        DemoProject('p2', 'Personal', Color(0xFF10B981), 7),
        DemoProject('p3', 'Research', Color(0xFFF59E0B), 3),
      ];

  static String relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${diff.inDays ~/ 7}w';
  }

  static String groupOf(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inHours < 24) return 'Today';
    if (diff.inDays < 2) return 'Yesterday';
    if (diff.inDays < 7) return 'This week';
    return 'Earlier';
  }
}

class SidebarCallbacks {
  final ValueChanged<String> onChatTap;
  final VoidCallback onNewChat;
  final VoidCallback onSettings;
  final VoidCallback onMedia;
  final VoidCallback onWorkspaces;
  final ValueChanged<String> onSearch;
  const SidebarCallbacks({
    required this.onChatTap,
    required this.onNewChat,
    required this.onSettings,
    required this.onMedia,
    required this.onWorkspaces,
    required this.onSearch,
  });
}
