// lib/platform_specific/chat/composer_menu_choices.dart
//
// The values the two composer menus hand back: what to attach, and which
// workspace to work in.

/// What the attach menu offers.
enum AttachChoice { camera, photos, files, workspace }

/// A row in the workspace menu: a workspace to switch to (null clears it),
/// or the way to make a new one.
class WorkspaceChoice {
  const WorkspaceChoice.pick(this.workspaceId) : create = false;
  const WorkspaceChoice.create() : workspaceId = null, create = true;

  final String? workspaceId;
  final bool create;
}
