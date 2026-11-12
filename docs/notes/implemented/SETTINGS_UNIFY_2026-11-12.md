# Settings: one pattern for both halves (CHAT-29, 2026-11-12)

## Problem

The owner saw settings menus that did not match. On a desktop window, the
Chat settings opened in a centred modal. An agent's settings opened as a
page that covered the full window, and the rows stretched to 1400 px. The
rows in the details pane also opened full-window pages. The agent profile
page used its own labels, cards and fields.

## Rule

See `docs/DESIGN.md` §2, "One settings pattern". In short:

* Every settings menu is a `FloatingPageScaffold` page with a
  `FloatingAppBar`, a `SettingsListView` and the `Expressive*` rows.
* Phone: the page is pushed full screen.
* Desktop window: the page opens in the settings modal
  (`SettingsModalFrame`, the panel of the Chat settings). The modal has its
  own navigator, so the pages it opens stay in the panel. The page header
  ends in the close chip.
* Open a settings page only with `openSettingsSurface`
  (`lib/widgets/settings_surface.dart`).
* Confirm dialogs, pickers, editors of one item and viewers are not
  settings menus. They stay dialogs or sheets.

## Inventory

"Push" = `MaterialPageRoute` on the app navigator. FPS =
`FloatingPageScaffold`. SLV = `SettingsListView`. Expr = the `Expressive*`
kit.

| Surface | File | How it opened before | Container | Header | Rows | Verdict |
|---|---|---|---|---|---|---|
| Chat settings hub, phone | `pages/settings_page.dart` | push | FPS | `FloatingAppBar` | SLV + Expr | Reference. No change. |
| Chat settings, desktop | `pages/desktop_settings_modal.dart` | `showGeneralDialog`, rail + page | own `Material` panel | page header + a close chip laid over it; compact: own 48 px bar | rail + page | Changed: panel is `SettingsModalFrame`; close chip and compact back are in the page header. |
| Chat sub-pages (account, model, identity, connectors, theme, customization, tools, skills, GitHub, about, developer) | `pages/*.dart` | push / modal page | FPS | `FloatingAppBar` | SLV + Expr | No change. |
| Agents section: here.now, Embedding, API keys, Agent mail, Automations, Host skills | `pages/settings/*`, `secrets_settings_page.dart`, `agent_mailbox_page.dart`, `automations_page.dart`, `skills_settings_page.dart` | push / modal page | FPS | `FloatingAppBar` | SLV + Expr | No change. |
| Per-agent settings | `pages/mobile_agents_settings_page.dart` | phone: push; desktop: push, full window | FPS | `FloatingAppBar` | SLV + Expr | Changed: desktop opens it in the settings modal. |
| Details pane "Settings" | `pages/agents_desktop_layout.dart` | in the pane | pane | pane header | SLV + Expr | Content kept. Changed: its rows open their pages in the modal, not full window. |
| Agent profile | `pages/agent_profile_edit_page.dart` | push | FPS, `ListView` | `FloatingAppBar` | private `_SectionLabel`, own cards, raw `TextField`s, own info box | Changed: SLV, `ExpressiveSectionHeader`, `ExpressiveGroup`/`Card`/`Row`, `ExpressiveField`, `ExpressiveInfoCard`; opens with `openSettingsSurface`. |
| Agent model | `pages/agent_model_page.dart` | push | FPS | `FloatingAppBar` | SLV + Expr | Opener changed. |
| Permissions | `pages/mobile_agent_permissions_page.dart` | push | FPS | `FloatingAppBar` | SLV + Expr (`_ChoiceRow` radio rows in the approvals card) | Opener changed. |
| Host & activity | `pages/agent_host_activity_page.dart` | push (shell, phone menu) | FPS | `FloatingAppBar` | `AgentControlPanel`: SLV + Expr | Opener changed. |
| Logins | `pages/agents_login_vault_page.dart` | push | FPS | `FloatingAppBar` | SLV + Expr; entry editor in a sheet | Opener changed. The editor sheet stays. |
| Agent model from the shell | `ModelSelectorPage(chatId:)` in `messenger_shell.dart` | push | FPS | `FloatingAppBar` | own | Opener changed. |
| Watcher automations from the details pane | `widgets/agent_details_overview.dart` | push | FPS | `FloatingAppBar` | SLV + Expr | Opener changed. |
| Checkpoints | `widgets/agents_checkpoints_sheet.dart` | `expressiveSheet` | sheet | sheet title | list | Kept: a list of restore actions, not a settings menu. |
| Automation editor | `widgets/automation_editor_sheet.dart` | `expressiveSheet` | sheet | sheet title | form | Kept: an editor of one item. |
| Composer "More models" | `platform_specific/chat/chat_model_selection_mixin.dart` | push | FPS | `FloatingAppBar` | SLV + Expr | Not changed (file owned by another stream). Open point. |

## What changed in code

* New `lib/widgets/settings_surface.dart`: `SettingsModalFrame`,
  `SettingsSurfaceNavigator`, `SettingsSurfaceScope`, `showSettingsModal`,
  `openSettingsSurface`, `closeSettingsModals`.
* `FloatingAppBar` reads `SettingsSurfaceScope`: in a modal it adds the
  close chip; the first page of a compact modal gets a back chip.
* `messenger_shell.dart`: agent settings, its row targets, the agent model
  page and the phone menu's "Host & activity" open with
  `openSettingsSurface`. "Account & app settings" closes the agent modal
  before the Chat settings modal opens, so two panels never stack.

## Renders

`test_previews/settings_preview_test.dart` (not run by `flutter test`)
writes `_scratch/agents_ui/before|after/settings_*.png`.

## Open points

* `chat_model_selection_mixin.dart` still pushes the model page with a bare
  route. Change it to `openSettingsSurface` when that stream is free.
* `agent_approvals_section.dart` draws its radio choices with a private
  `_ChoiceRow`. The kit has no radio row yet.
* The details pane draws its own 56 px header for "Settings" next to
  `PaneHeader` for "Details".

## Follow-up: agent settings in the right pane (CHAT-54, 2026-11-12)

The owner's newer rule wins for agent settings: on a desktop window they
open in the right details pane next to the thread, not in the centred
modal. Entry points: the agent pill in the thread header (a second tap
closes the pane), "Settings" in the header's "…" menu, the roster row's
"Profile" (selects that agent first) and the pane's gear. The pane wraps
the settings in a `SettingsSurfaceNavigator`, so `openSettingsSurface`
pushes their sub-pages inside the pane. The Chat settings stay in the
centred modal; opening them closes the pane (`closeSettingsModals`). A
window too narrow for the pane (under 616 px wide) and a phone keep the
old way: modal or full page.
