import 'package:shared_preferences/shared_preferences.dart';

/// Categories of actions that may require approval
enum ApprovalCategory {
  bash, // Shell commands
  email, // IMAP/SMTP email
  gmail, // Gmail via Google OAuth
  slack, // Slack messages
  nextcloud, // Nextcloud file operations
  github, // GitHub actions
  calendar, // Calendar modifications
}

/// Specific actions within each category that can require approval
class ApprovalAction {
  final ApprovalCategory category;
  final String action;
  final String description;
  final String riskLevel; // 'low', 'medium', 'high', 'critical'
  final String riskDescription;

  const ApprovalAction({
    required this.category,
    required this.action,
    required this.description,
    required this.riskLevel,
    required this.riskDescription,
  });
}

/// Universal Approval Configuration
///
/// Manages which actions require user approval before execution.
/// Can be extended with new tools and actions.
class ApprovalConfig {
  static final ApprovalConfig _instance = ApprovalConfig._internal();
  factory ApprovalConfig() => _instance;
  ApprovalConfig._internal();

  // Category-level approval settings
  final Map<ApprovalCategory, bool> _categoryApproval = {
    ApprovalCategory.bash: true,
    ApprovalCategory.email: true,
    ApprovalCategory.gmail: true,
    ApprovalCategory.slack: true,
    ApprovalCategory.nextcloud: true,
    ApprovalCategory.github: false,
    ApprovalCategory.calendar: false,
  };

  // All actions that can require approval
  static const List<ApprovalAction> allActions = [
    // Bash actions
    ApprovalAction(
      category: ApprovalCategory.bash,
      action: 'dangerous_command',
      description: 'Commands with sudo, pipes, redirects, or shell expansion',
      riskLevel: 'high',
      riskDescription:
          'Could execute harmful system commands, modify files outside '
          'sandbox, or expose sensitive data.',
    ),
    ApprovalAction(
      category: ApprovalCategory.bash,
      action: 'file_delete',
      description: 'Deleting files with rm command',
      riskLevel: 'medium',
      riskDescription: 'Could permanently delete important files.',
    ),

    // Email (IMAP/SMTP) actions
    ApprovalAction(
      category: ApprovalCategory.email,
      action: 'send_email',
      description: 'Sending emails via SMTP',
      riskLevel: 'high',
      riskDescription:
          'AI could send emails on your behalf without your knowledge. '
          'Emails cannot be recalled once sent.',
    ),
    ApprovalAction(
      category: ApprovalCategory.email,
      action: 'delete_email',
      description: 'Deleting emails from mailbox',
      riskLevel: 'medium',
      riskDescription: 'Could permanently delete important emails.',
    ),

    // Gmail actions
    ApprovalAction(
      category: ApprovalCategory.gmail,
      action: 'send_email',
      description: 'Sending emails via Gmail API',
      riskLevel: 'high',
      riskDescription:
          'AI could send emails from your Gmail account. '
          'Emails cannot be recalled once sent.',
    ),

    // Slack actions
    ApprovalAction(
      category: ApprovalCategory.slack,
      action: 'send_message',
      description: 'Sending messages to Slack channels',
      riskLevel: 'medium',
      riskDescription:
          'AI could post messages visible to your team or organization.',
    ),

    // Nextcloud actions
    ApprovalAction(
      category: ApprovalCategory.nextcloud,
      action: 'delete_file',
      description: 'Deleting files from Nextcloud',
      riskLevel: 'medium',
      riskDescription:
          'Could permanently delete files from your cloud storage.',
    ),
    ApprovalAction(
      category: ApprovalCategory.nextcloud,
      action: 'upload_file',
      description: 'Uploading files to Nextcloud',
      riskLevel: 'low',
      riskDescription: 'Could upload content to your cloud storage.',
    ),

    // GitHub actions
    ApprovalAction(
      category: ApprovalCategory.github,
      action: 'create_issue',
      description: 'Creating issues on repositories',
      riskLevel: 'low',
      riskDescription: 'Could create visible issues on public repositories.',
    ),
    ApprovalAction(
      category: ApprovalCategory.github,
      action: 'add_comment',
      description: 'Adding comments to issues/PRs',
      riskLevel: 'low',
      riskDescription:
          'Could post comments visible to repository collaborators.',
    ),

    // Calendar actions
    ApprovalAction(
      category: ApprovalCategory.calendar,
      action: 'create_event',
      description: 'Creating calendar events',
      riskLevel: 'low',
      riskDescription: 'Could add events to your calendar.',
    ),
    ApprovalAction(
      category: ApprovalCategory.calendar,
      action: 'delete_event',
      description: 'Deleting calendar events',
      riskLevel: 'medium',
      riskDescription: 'Could delete important events from your calendar.',
    ),
  ];

  /// Load settings from SharedPreferences
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final category in ApprovalCategory.values) {
      final key = 'approval_${category.name}';
      if (prefs.containsKey(key)) {
        _categoryApproval[category] = prefs.getBool(key) ?? true;
      }
    }
  }

  /// Save a category setting
  Future<void> setCategoryApproval(
    ApprovalCategory category,
    bool required,
  ) async {
    _categoryApproval[category] = required;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('approval_${category.name}', required);
  }

  /// Check if approval is required for a category
  bool isApprovalRequired(ApprovalCategory category) {
    return _categoryApproval[category] ?? true;
  }

  /// Check if approval is required for a specific action
  bool isActionApprovalRequired(ApprovalCategory category, String action) {
    if (!isApprovalRequired(category)) return false;
    return allActions.any((a) => a.category == category && a.action == action);
  }

  /// Get actions for a specific category
  static List<ApprovalAction> getActionsForCategory(ApprovalCategory category) {
    return allActions.where((a) => a.category == category).toList();
  }

  /// Get risk description for disabling approval in a category
  static String getRiskWarning(ApprovalCategory category) {
    final actions = getActionsForCategory(category);
    if (actions.isEmpty) return 'No known risks.';

    final highRisk = actions.where(
      (a) => a.riskLevel == 'high' || a.riskLevel == 'critical',
    );
    if (highRisk.isNotEmpty) {
      return 'HIGH RISK: '
          '${highRisk.map((a) => a.riskDescription).join(' ')}';
    }

    final mediumRisk = actions.where((a) => a.riskLevel == 'medium');
    if (mediumRisk.isNotEmpty) {
      return 'MEDIUM RISK: '
          '${mediumRisk.map((a) => a.riskDescription).join(' ')}';
    }

    return 'Low risk: ${actions.first.riskDescription}';
  }

  /// Get a human-readable category name
  static String getCategoryDisplayName(ApprovalCategory category) {
    switch (category) {
      case ApprovalCategory.bash:
        return 'Bash Commands';
      case ApprovalCategory.email:
        return 'Email (IMAP/SMTP)';
      case ApprovalCategory.gmail:
        return 'Gmail';
      case ApprovalCategory.slack:
        return 'Slack Messages';
      case ApprovalCategory.nextcloud:
        return 'Nextcloud Files';
      case ApprovalCategory.github:
        return 'GitHub Actions';
      case ApprovalCategory.calendar:
        return 'Calendar Events';
    }
  }
}

/// Extension to easily get approval status from anywhere
extension ApprovalCategoryExtension on ApprovalCategory {
  bool get requiresApproval => ApprovalConfig().isApprovalRequired(this);
  String get displayName => ApprovalConfig.getCategoryDisplayName(this);
  String get riskWarning => ApprovalConfig.getRiskWarning(this);
  List<ApprovalAction> get actions =>
      ApprovalConfig.getActionsForCategory(this);
}
