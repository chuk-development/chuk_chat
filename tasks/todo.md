# Expressive settings rollout

The settings root (`settings_page.dart`) and Connectors (`mcp_connectors_page.dart`)
are the reference: `lib/widgets/expressive_settings.dart` — separate filled tiles,
26/6 radii, 3 px gap, press squeeze, no dividers, no outlines, headline section labels.

Every other settings-family screen carried the old look: one card cut by dividers,
all-caps 12 pt section labels, 20 px radii, flat leading icons — and each screen
carried its own private copy of those widgets.

## Step 1 — the missing primitives

- [x] `ExpressiveSwitchRow` — a row that carries a switch
- [x] `ExpressiveInfoCard` — the info paragraph, any tone
- [x] `ExpressiveCard` — a standalone block (sliders, previews, editors)
- [x] `ExpressiveField` — a filled field that holds a dropdown or a preview
- [x] `ExpressiveBadge` gained an icon, `ExpressiveSectionHeader` a trailing
      action and a colour override

## Step 2 — the screens

- [x] `customization_page.dart`
- [x] `about_page.dart` (incl. the licence list and one licence)
- [x] `theme_page.dart`
- [x] `download_settings_page.dart`
- [x] `tool_calling_settings_page.dart` (+ MCP tools removed, see below)
- [x] `skills_settings_page.dart`
- [x] `diagnostics_settings_page.dart`
- [x] `system_prompt_page.dart`
- [x] `account_settings_page.dart`
- [x] `sandbox_management_page.dart`
- [x] `github_connection_page.dart`
- [x] `connector_detail_page.dart`
- [x] `recover_chats_page.dart`
- [x] `usage_details_page.dart`
- [x] `pricing_page.dart` (headers, credits card, badges; the plan cards keep
      their gradient — they are the one place that is meant to stand out)
- [x] `model_selector_page.dart` (section header)

## Tool calling no longer lists MCP tools

A connector is a server you sign in to; it is managed on the Connectors screen.
`_visibleTools()` drops `ToolCategory.mcp`, so a server with forty tools no
longer buries the six switches this page is actually about.

## Not touched

Chat, sidebar, workspaces, media manager and the sign-in flow are product
surfaces, not settings lists. `workspace_mobile_detail_page.dart` keeps its own
`_InfoCard`: it is a large tappable knowledge card, not a settings row.

## Review

Thirteen private copies of `_SectionHeader` / `_GroupedCard` / `_FilledCard` /
`_SwitchRow` / `_NavRow` / `_SettingsRow` / `_LeadingIcon` / `_InfoCard` /
`_Badge` and their tone enums are gone; the shape now lives in one file.

Evidence: `flutter analyze` reports no issues in `lib/`, and `flutter test`
ends in `All tests passed!` — 1269 tests, 40 skipped.

The visual migration changes shape, spacing and labels only. **One behaviour
change is intended and is not covered by that sentence**: tool calling no
longer lists MCP tools (above). Three review findings outside the migration
are fixed as well — MCP icons no longer cache a failed download,
`mcp_icon_cache.dart` no longer imports `dart:io` (that broke the web build,
now proven by `flutter build web --release`), and the Connectors row in
Settings reads its two labels from the localisations instead of English
literals.

The working tree also carries earlier, unrelated work on this branch: the
settings root rewrite, the Connectors screen itself, the plan badge now
served from the cached `UserStatusService`, and the chat/sidebar changes.
Those are not part of this migration.
