# pseudomap · chuk_chat

611 Dateien · 2765 Typen/Funktionen · 15134 Member · 1251/1720 öffentliche Symbole mit Zweckzeile · Stand 2026-09-30

Diese Datei ist `.pseudomap/MAP.md` — Stufe 1: was es gibt und wo es liegt.

Vor dem Schreiben neuer Funktionen hier nachsehen, ob die Sache schon existiert. Tut sie es, wird sie wiederverwendet statt neu geschrieben.

- Lange Parameterlisten sind hier gekürzt (`…)`). Volle Signaturen mit Zeilennummern stehen in `.pseudomap/detail/<ordner>.md`, Pfad mit `__` statt `/` — `lib/services` liegt in `.pseudomap/detail/lib__services.md`.
- Suche über alles: `pseudomap find <begriff>`.
- Neu bauen: `pseudomap build` (läuft nach jedem Edit automatisch).

## lib
### constants.dart  (563 Z.)
- const: kDefaultBgColor kDefaultAccentColor kDefaultIconFgColor kDefaultThemeMode kDefaultDynamicColorEnabled kDefaultShowReasoningTokens kDefaultShowModelInfo kDefaultShowTps kDefaultUiLocale kDefaultToolCallingEnabled kDefaultToolDiscoveryMode kDefaultShowToolCalls kDefaultIncludeToolResultsInHistory kDefaultChatFontSize kMinChatFontSize kMaxChatFontSize kDefaultUiScale kMinUiScale kMaxUiScale kChatFontFamilySystem kChatFontFamilyArimo kChatFontFamilyMerriweather kChatFontFamilyJetBrainsMono kDefaultChatFontFamily kSupportedChatFontFamilies +25
- `double contrastFactor(double contrast)`  — Maps the [kMinContrast]..[kMaxContrast] slider value to the multiplier
- `ThemeData buildAppTheme({ required Color accent, required Color iconFg, required Color bg, required Brightness brightnes …)`
- `Color _shiftHue(Color c, double degrees)`

### env_loader.dart  (158 Z.)
- `class EnvLoader`  — Loads environment variables from .env file at runtime.

### main.dart  (786 Z.)
- `void _installLogDeduper()`  — Collapse consecutive identical debug log lines into a single line with a
- `Future<void> main()`
- `class AgentsApp extends StatefulWidget`
- `class _AgentsAppState extends State<AgentsApp>`
- `class _OnboardingFirstLaunchGate extends StatefulWidget`  — Starts the interactive onboarding tour if the signed-in user has never
- `class _OnboardingFirstLaunchGateState extends State<_OnboardingFirstLaunchGate>`

### model_selector_page.dart  (1988 Z.)
- `class PricingDetails`
- `class ModelProviderInfo`
- `class CustomModelInfo`
- `enum _ModelListFilter`  — Which slice of the catalogue the model list shows.
- `class ModelSelectorPage extends StatefulWidget`
- `class _ModelSelectorPageState extends State<ModelSelectorPage> with ApiAvailabilityPolling<ModelSelectorPage>`
- `class ModelSelectionRow extends StatefulWidget`
- `class _ModelSelectionRowState extends State<ModelSelectionRow>`
- `class _NameRow extends StatelessWidget`
- `class _ProviderPill extends StatelessWidget`
- `class _AuthRequiredException implements Exception`
- `class _ModeRowData`  — One mode's data for the picker panel.
- `class _ModePickerPanel extends StatelessWidget`  — The panel at the top of the model screen that assigns a model, a provider
- `class _ListFilterBar extends StatelessWidget`  — A three-way pill toggle above the model list: All / Active / Inactive.
- `class _StatChip extends StatelessWidget`

### platform_config.dart  (185 Z.)
- const: kPlatformMobile kPlatformDesktop kAutoDetectPlatform kFeatureVoiceMode kFeatureVoiceCall kFeatureWorkspaces kFeatureArtifacts kFeatureImageGen kFeatureMediaManager kFeatureServerTools kFeatureMcp kFeatureArtifactHosting kFeatureSystemTray kFeatureLinuxKeyring kFeaturePaymentsDirect kFeatureAgents kFeatureAgentsDemo kFeatureSkills kFeatureSpotify kFeatureWhoop

### supabase_config.dart  (121 Z.)
- `class SupabaseConfig`

### web_env.dart  (5 Z.)
- const: webSupabaseUrl webSupabaseAnonKey

## lib/assistant
### assistant_bridge.dart  (327 Z.)
- `class AssistantBridge`  — Untyped wrappers around the native assistant channel.

### assistant_cards.dart  (382 Z.)
- `class AssistantCardView extends StatelessWidget`  — Renders one [AssistantCard]. Every colour comes from the running theme, so
- `class _CardHeader extends StatelessWidget`
- `class _PlacesCardView extends StatelessWidget`
- `class _PlaceRow extends StatelessWidget`
- `class _RatingChip extends StatelessWidget`
- `class _LinksCardView extends StatelessWidget`
- `class _ActionCardView extends StatelessWidget`
- `class _FactsCardView extends StatelessWidget`

### assistant_config.dart  (84 Z.)
- const: kAssistantModelId kAssistantProviderSlug kAssistantReasoningEffort kAssistantMaxToolRounds kAssistantMaxTokens
- `abstract final class AssistantPlatform`  — Where the assistant surface can run at all.
- `@immutable class AssistantSettings`  — User-owned assistant preferences. Everything model-related is a constant
- `abstract final class AssistantSettingsStore`  — Persistence for [AssistantSettings].

### assistant_microphone.dart  (284 Z.)
- `class AssistantMicrophone`  — Continuous microphone capture with energy-based endpointing.
- `Uint8List pcmToWav( Uint8List pcm, { required int sampleRate, required int channels, })`  — Wraps raw 16-bit little-endian PCM in a 44-byte RIFF header.
- `void _writeAscii(ByteData buffer, int offset, String value)`

### assistant_overlay.dart  (674 Z.)
- const: assistantOverlayRouteName
- `Route<void> buildAssistantOverlayRoute()`  — Transparent, instant route for the assistant surface.
- `class AssistantOverlayPage extends StatefulWidget`
- `class _AssistantOverlayPageState extends State<AssistantOverlayPage>`
- `@immutable class AssistantToolBadge`  — One tool call, as the surface shows it.
- `class AssistantOverlayView extends StatelessWidget`  — Presentation separated from transport so the layout can be checked offline.
- `class AssistantToolRow extends StatelessWidget`  — One line per tool call, so the user sees what the assistant really does.
- `class AssistantSurface extends StatelessWidget`  — One floating, blurred panel. The surface colour is the user's, only the
- `class AssistantAction extends StatelessWidget`  — Label and icon as one centred group with a 48 dp minimum target.
- `class AssistantWaveform extends StatefulWidget`  — Microphone level as a symmetric bar field.
- `class _AssistantWaveformState extends State<AssistantWaveform> with SingleTickerProviderStateMixin`
- `class _WavePainter extends CustomPainter`

### assistant_result.dart  (141 Z.)
- `sealed class AssistantCard`  — A visual result the assistant surface renders next to (or instead of) the
- `@immutable class AssistantPlace`  — One place from the Brave Local proxy.
- `class AssistantPlacesCard extends AssistantCard`  — A list of places — restaurants, shops, anything from a local lookup.
- `@immutable class AssistantLink`  — One web result.
- `class AssistantLinksCard extends AssistantCard`  — Ranked web results from the Brave Search proxy.
- `class AssistantActionCard extends AssistantCard`  — A device action that happened: a timer was set, maps opened, an app
- `class AssistantFactsCard extends AssistantCard`  — Anything with a heading and a block of prepared text — weather, a summary,
- `@immutable class AssistantToolOutcome`  — What one tool call produced: the JSON the model reads back, and the card

### assistant_session.dart  (510 Z.)
- `enum AssistantPhase`  — Where one assistant turn currently stands.
- `class AssistantSession extends ChangeNotifier`  — The whole assistant turn: endpointed microphone, transcription through the
- `@immutable class _AssistantPass`

### assistant_tools.dart  (874 Z.)
- const: assistantTools assistantToolsByName assistantToolSchemas
- `class AssistantToolRuntime`  — Everything a tool handler may use besides its own arguments.
- `typedef AssistantToolHandler = Future<AssistantToolOutcome> Function( Map<String, dynamic> args, AssistantToolRuntime ru`
- `class AssistantTool`  — One function the model may call, in the OpenAI tool schema.
- `Map<String, dynamic> _object( Map<String, dynamic> properties, { List<String> required = const <String>[], })`
- `Map<String, dynamic> _string(String description, {List<String>? values})`
- `Map<String, dynamic> _integer(String description)`
- `Map<String, dynamic> _number(String description)`
- `double? _toDouble(Object? value)`  — Models send numbers as a number or as a string, so accept both.
- `int _toInt(Object? value)`
- `String _text(Map<String, dynamic> args, String key)`
- `String _clip(String text, int max)`
- `AssistantToolOutcome _plain(Object? value)`
- `Future<AssistantToolOutcome> _webSearch( Map<String, dynamic> args, AssistantToolRuntime runtime, )`
- `Future<AssistantToolOutcome> _places( Map<String, dynamic> args, AssistantToolRuntime runtime, { required bool restauran …)`
- `String _formatDuration(int seconds)`
- `class AssistantToolRun`  — Result of one tool call: the JSON string the model reads back, plus the
- `Future<void> runAssistantTool({ required AssistantToolRun run, required Map<String, dynamic> args, required AssistantToo …)`  — Runs one tool call and always produces a JSON string — the `tool` message

## lib/constants
### file_constants.dart  (185 Z.)
- `class FileConstants`  — Shared constants for file handling across the application.

## lib/core
### model_selection_events.dart  (32 Z.)
- `class ModelSelectionEventBus`  — Event bus for model selection changes to decouple services from UI widgets.

## lib/demo
### app_palette.dart  (63 Z.)
- `class AppPalette`

### demo_data.dart  (182 Z.)
- `class DemoChat`
- `class DemoProject`
- `class DemoData`
- `class SidebarCallbacks`

### shared_widgets.dart  (645 Z.)
- `class SbBrand extends StatelessWidget`  — Brand row: optional logo square + name. Trailing widget on the right.
- `class SbNewChatPill extends StatelessWidget`  — Accent pill "New chat" button — used in top-right or as full-width.
- `class SbSearch extends StatelessWidget`  — Generic search field with bordered surface.
- `class SbSectionLabel extends StatelessWidget`  — Uppercase section header (PINNED, RECENT, etc.).
- `class SbChatRow extends StatelessWidget`  — Full-width flat chat row with selection tint, pin icon, unread dot, time.
- `class SbPinnedRow extends StatelessWidget`  — Compact pinned row variant (smaller padding/font, used inside Pinned bento).
- `class SbFooter extends StatelessWidget`  — Account footer (avatar + name + email + settings icon).
- `class SbNavItem extends StatelessWidget`  — Sidebar nav row (icon + label, vertically stacked). Like original top stack.
- `class SbBento extends StatelessWidget`  — Generic rounded surface "bento" card.
- `class SbPinnedBento extends StatelessWidget`  — Accent-tinted pinned bento card with header + rows.
- `class SbQuickTile extends StatelessWidget`  — Bento quick tile (icon + title + subtitle).
- `class SbHairline extends StatelessWidget`  — Hairline divider matching app palette.
- `class ChatSplit`  — Splits chats into pinned + rest. Convenience for variants.

### sidebar_demo_main.dart  (589 Z.)
- const: kSidebarWidth
- `void main()`
- `class SidebarDemoApp extends StatefulWidget`
- `class _SidebarDemoAppState extends State<SidebarDemoApp>`
- `enum FrameMode`
- `class DemoHome extends StatefulWidget`
- `class _DemoHomeState extends State<DemoHome>`

## lib/demo/variants
### variant_1_minimal.dart  (83 Z.)
- `class VariantMinimal extends StatelessWidget`

### variant_2_glass.dart  (126 Z.)
- `class VariantGlass extends StatelessWidget`

### variant_3_dense.dart  (114 Z.)
- `class VariantDense extends StatelessWidget`

### variant_4_playful.dart  (160 Z.)
- `class VariantPlayful extends StatelessWidget`

### variant_5_bento.dart  (112 Z.)
- `class VariantBento extends StatelessWidget`

### variant_6_final.dart  (142 Z.)
- `class VariantFinal extends StatelessWidget`
- `class _SearchTrigger extends StatelessWidget`  — Subtle search icon button. No layout shift, no inline bar.

## lib/l10n
### app_localizations.dart  (809 Z.)
- `class AppLocalizations`  — Holds all translated UI strings for the current locale.
- `class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations>`

### strings_de.dart  (784 Z.)
- const: stringsDe

### strings_en.dart  (773 Z.)
- const: stringsEn

### strings_es.dart  (615 Z.)
- const: stringsEs

### strings_fr.dart  (622 Z.)
- const: stringsFr

### strings_pt.dart  (608 Z.)
- const: stringsPt

## lib/models
### agents_agent.dart  (130 Z.)
- `enum AgentActivity`  — What a coworker is doing, as far as the app can actually tell.
- `@immutable class AgentsThreadInfo`  — One conversation with one agent. An agent can have many (§4).
- `@immutable class AgentsAgent`  — One coworker.

### agents_room.dart  (157 Z.)
- `@immutable class AgentsRoomMember`  — One coworker in a room: the agent id the app tracks and the handle it is
- `@immutable class AgentsRoom`  — A group room the app knows about: an id, a name, and its members in order.
- `@immutable class AgentsRoomDraft`  — What the create-room form produces: a name and the chosen members. It is not
- `@immutable class AgentsRoomTurn`  — One agent turn in a room exchange, as the app shows it. Mirrors the manager's
- `enum AgentsRoomStop`  — Why a room exchange ended, as the host reported it. The strings match the

### app_shell_config.dart  (147 Z.)
- `class AppShellConfig`  — Bundles all theme, display, image-generation, and AI-context settings

### artifact.dart  (202 Z.)
- `enum ArtifactType`
- `extension ArtifactTypeX on ArtifactType`
- `class ArtifactDocument`
- `class ArtifactVersionSnapshot`
- `class ArtifactEdit`

### chat_message.dart  (277 Z.)
- `enum ChatMessageStatus`  — Delivery status of a chat message in the local queue/UI.
- `ChatMessageStatus? _statusFromString(String? raw)`
- `int? parseFlexibleInt(dynamic value)`  — Parse an int that may arrive as an int, a num, or a String — the UI map
- `String? _statusToString(ChatMessageStatus? status)`
- `class ChatMessage`  — Represents a single message in a chat.

### chat_model.dart  (122 Z.)
- `class ModelItem`
- `class AttachedFile`

### chat_reply.dart  (36 Z.)
- `class ChatReply`  — Reply context travels as ordinary quoted user text, so host history, offline

### chat_stream_event.dart  (194 Z.)
- `sealed class ChatStreamEvent`  — Events that can be received from chat streaming services.
- `class NativeToolCall`  — A native OpenAI-format tool call assembled from the provider stream.
- `class ToolCallsEvent extends ChatStreamEvent`  — Event carrying one or more native tool calls the model requested this turn.
- `class ContentEvent extends ChatStreamEvent`  — Event containing message content text.
- `class FinalContentEvent extends ChatStreamEvent`  — Authoritative completed answer. Replaces streamed provisional content;
- `class ReasoningEvent extends ChatStreamEvent`  — Event containing reasoning/thinking process text.
- `class UsageEvent extends ChatStreamEvent`  — Event containing token usage information.
- `class MetaEvent extends ChatStreamEvent`  — Event containing metadata about the response.
- `class TpsEvent extends ChatStreamEvent`  — Event containing tokens per second (TPS) metric.
- `class ErrorEvent extends ChatStreamEvent`  — Event indicating an error occurred.
- `class HeartbeatEvent extends ChatStreamEvent`  — Proof of life: the host says the run behind this stream is still running.
- `class DoneEvent extends ChatStreamEvent`  — Event indicating the stream has completed.
- `typedef StreamErrorCallback = void Function(String error, {String? code})`  — Signature for stream error callbacks.
- `abstract final class StreamErrorCodes`  — Failure classes carried on [ErrorEvent.code].

### client_tool.dart  (70 Z.)
- `class ClientTool`  — Represents a tool that can be executed client-side.
- `enum ToolType`  — Type of tool.
- `enum ToolCategory`  — Tool categories for grouping and enabling/disabling.

### content_block.dart  (173 Z.)
- `enum ContentBlockType`  — The type of a content block within an AI response.
- `class SandboxArtifactPayload`  — Payload for a [ContentBlockType.sandboxArtifact] block.
- `class ContentBlock`  — An ordered block of content within an AI response.

### queued_message.dart  (103 Z.)
- `class QueuedMessage`  — A message persisted in the offline queue, waiting for connectivity so it

### skill.dart  (276 Z.)
- `enum SkillSource`  — Where a [Skill] came from. Determines its trust level.
- `class SkillResource`  — A file bundled alongside a skill (Level 3): a `references/`, `scripts/` or
- `class Skill`
- `bool _resourceListEquals(List<SkillResource> a, List<SkillResource> b)`
- `bool _listEquals(List<String> a, List<String> b)`
- `bool _mapEquals(Map<String, String> a, Map<String, String> b)`

### stored_chat.dart  (202 Z.)
- `class StoredChat`  — Represents a stored chat with metadata.

### stream_phase.dart  (39 Z.)
- `enum StreamPhase`  — The phases of one assistant turn, in the order they occur.

### tool_call.dart  (94 Z.)
- `class ToolCall`  — Represents a single tool call made by the AI during a conversation.
- `enum ToolCallStatus`  — Status of a tool call in its lifecycle.
- `bool finalizeStaleToolCalls(List<ToolCall> toolCalls)`  — Utility to finalize any stale (running/pending) tool calls.

### workspace_model.dart  (464 Z.)
- `class Workspace`  — Represents a workspace that combines AI persona, system prompts, files,
- `class WorkspaceFile`  — Represents a file attached to a workspace

## lib/pages
### about_page.dart  (597 Z.)
- `class AboutPage extends StatefulWidget`
- `class _AboutPageState extends State<AboutPage>`
- `class _ThemedLicensePage extends StatefulWidget`
- `class _ThemedLicensePageState extends State<_ThemedLicensePage>`
- `class _LicenseTile extends StatelessWidget`
- `class _LicenseHeader extends StatelessWidget`
- `class _LicensePackage`
- `class _LicenseDetailPage extends StatelessWidget`
- `String? _inferLicenseName(String text)`

### account_settings_page.dart  (739 Z.)
- `class AccountSettingsPage extends StatefulWidget`
- `class _AccountSettingsPageState extends State<AccountSettingsPage>`
- `class _FieldLabel extends StatelessWidget`

### agent_profile_edit_page.dart  (613 Z.)
- `class AgentProfileEditPage extends StatefulWidget`
- `class _AgentProfileEditPageState extends State<AgentProfileEditPage>`
- `class _FacePreview extends StatelessWidget`  — The face as it will look, with the colour the user is trying out.
- `class _SectionLabel extends StatelessWidget`
- `class _ColorRow extends StatelessWidget`  — The colour palette, plus a "back to the derived colour" target.
- `class _ShapeRow extends StatelessWidget`  — The silhouettes a coworker can be given, drawn as themselves.

### agent_profile_page.dart  (663 Z.)
- `class AgentProfilePage extends StatelessWidget`
- `class _StatePill extends StatelessWidget`  — The live-state pill under the name: what the coworker is doing right now.
- `class _ActionRow extends StatelessWidget`  — The row of round targets under the header.
- `class _Action extends StatelessWidget`
- `class _InfoCard extends StatelessWidget`  — One labelled card in the profile body.

### agents_desktop_layout.dart  (639 Z.)
- part of 'messenger_shell.dart'
- `mixin _AgentsDesktopLayout on State<MessengerShell>, AgentsShellHost`  — The Agents desktop layout: chuk_chat's desktop with coworkers in it.

### agents_install_page.dart  (360 Z.)
- `typedef AgentsCodePageOpener = Future<AgentsPairingInvite?> Function( BuildContext context, )`  — Opens the code page and hands back what the user scanned or typed.
- `class AgentsInstallPage extends StatefulWidget`
- `class _AgentsInstallPageState extends State<AgentsInstallPage>`
- `class _CommandBox extends StatelessWidget`  — The command, in a flat card, selectable. A long line wraps instead of

### agents_pairing_page.dart  (310 Z.)
- `typedef AgentsQrViewBuilder = Widget Function( BuildContext context, { required ValueChanged<String> onCode, required Va`  — Builds the live camera view. Injected so a widget test can drive the screen
- `bool agentsCameraIsDefault()`  — True on the platforms where opening a camera is the right default.
- `class AgentsPairingPage extends StatefulWidget`
- `class _AgentsPairingPageState extends State<AgentsPairingPage>`

### agents_shell_state.dart  (1166 Z.)
- part of 'messenger_shell.dart'
- `Future<AgentsRelayController> _buildRelayController( AgentsPairingStore store, AccountSessionSource sessionSource, )`  — Builds the default production relay controller: a real [AgentsRelayClient]
- `mixin AgentsShellHost on State<MessengerShell>`  — Everything the shell OWNS, as opposed to how it lays it out.
- `@visibleForTesting DateTime? newestMessageTime(List<ChatMessage>? messages)`  — The newest timestamp among [messages] (`sentAt`, else `startedAt`), or

### assistant_settings_page.dart  (410 Z.)
- `class AssistantSettingsPage extends StatefulWidget`  — One job: make Chuk Chat the assistant of this phone.
- `class _Grant`  — One freedom the assistant needs, and what it buys.
- `class _AssistantSettingsPageState extends State<AssistantSettingsPage> with WidgetsBindingObserver`
- `class _HowTo extends StatelessWidget`
- `class _Step extends StatelessWidget`
- `class _AllSet extends StatelessWidget`

### automations_page.dart  (193 Z.)
- `class AutomationsPage extends StatefulWidget`  — Every automation of the host, grouped by the coworker that owns it, with
- `class _AutomationsPageState extends State<AutomationsPage>`

### coming_soon_page.dart  (95 Z.)
- `class ComingSoonPage extends StatelessWidget`

### connector_detail_page.dart  (245 Z.)
- `class ConnectorDetailPage extends StatefulWidget`  — Full-screen detail page for a single tool, showing enable/disable,
- `class _ConnectorDetailPageState extends State<ConnectorDetailPage>`

### customization_page.dart  (803 Z.)
- `class CustomizationPage extends StatefulWidget`
- `class _CustomizationPageState extends State<CustomizationPage>`
- `class _CardLabel extends StatelessWidget`  — Title and explanation at the top of a card that is not a row.

### desktop_media_modal.dart  (128 Z.)
- const: _kRadius
- `Future<void> showDesktopMediaModal(BuildContext context)`  — Opens the media library over the current page.
- `class DesktopMediaModal extends StatelessWidget`  — The panel itself: a header row, then the library.

### desktop_settings_modal.dart  (886 Z.)
- `Future<void> showDesktopSettingsModal( BuildContext context, { required AppShellConfig config, String? initialSectionId …)`  — Opens the desktop settings modal over the current chat UI.
- `class _SettingsDest`  — A settings destination: either a page shown in the right pane, or an
- `class _SettingsGroup`
- `class DesktopSettingsModal extends StatefulWidget`
- `class _DesktopSettingsModalState extends State<DesktopSettingsModal>`

### diagnostics_settings_page.dart  (381 Z.)
- `class DeveloperOptionsPage extends StatefulWidget`
- `class _DeveloperOptionsPageState extends State<DeveloperOptionsPage>`

### download_settings_page.dart  (136 Z.)
- `class DownloadSettingsPage extends StatefulWidget`
- `class _DownloadSettingsPageState extends State<DownloadSettingsPage>`

### forgot_password_page.dart  (208 Z.)
- `class ForgotPasswordPage extends StatefulWidget`  — Page for requesting a password reset code, then verifying it and setting
- `class _ForgotPasswordPageState extends State<ForgotPasswordPage>`

### fullscreen_map_page.dart  (1145 Z.)
- `class FullscreenMapPage extends StatefulWidget`
- `class _FullscreenMapPageState extends State<FullscreenMapPage>`
- `class _RouteGeometry`

### github_connection_page.dart  (470 Z.)
- `class GitHubConnectionPage extends StatefulWidget`
- `class _GitHubConnectionPageState extends State<GitHubConnectionPage>`

### login_page.dart  (578 Z.)
- `class LoginPage extends StatefulWidget`
- `class _LoginPageState extends State<LoginPage>`

### mcp_connectors_page.dart  (1108 Z.)
- `class McpConnectorsPage extends StatefulWidget`
- `class _McpConnectorsPageState extends State<McpConnectorsPage>`
- `class McpConnectorDetailPage extends StatefulWidget`  — One connector: connect or disconnect it, and see what it can do.
- `class _McpConnectorDetailPageState extends State<McpConnectorDetailPage>`
- `Future<Map<String, String>?> showMcpCredentialDialog( BuildContext context, List<McpCredentialField> fields, String name …)`  — Collect a reader's own credentials for an [McpAuth.apiKey] server. Returns
- `class McpConnectorIcon extends StatefulWidget`  — A connector logo. The bundled brand logo first (shipped in the binary for
- `class _McpConnectorIconState extends State<McpConnectorIcon>`
- `Future<T> _withProgress<T>( BuildContext context, Future<T> Function() work, { McpConnectCanceler? canceler, })`
- `class _AddByUrlDialog extends StatefulWidget`  — The "Add a connector" dialog. It owns its text controller, so the
- `class _AddByUrlDialogState extends State<_AddByUrlDialog>`

### media_manager_page.dart  (1513 Z.)
- const: kMediaFilterBarHeight
- `enum _MediaFilter`
- `class MediaManagerPage extends StatefulWidget`
- `class _MediaManagerPageState extends State<MediaManagerPage>`
- `class _ThumbGate`  — What one thumbnail knows about itself.
- `class _ThumbState`
- `class _ImageTile extends StatefulWidget`  — One image in the grid: the picture, what it costs to keep, and — on hover
- `class _ImageTileState extends State<_ImageTile>`
- `class _ThumbError extends StatelessWidget`  — What a tile shows instead of a picture, with the reason and a way back.
- `class _Glass extends StatelessWidget`  — A dark round pad behind a glyph drawn on top of a picture.
- `class _TileAction extends StatelessWidget`  — One hover action on a tile.
- `class _MediaFilterBar extends StatelessWidget`  — Images / Artifacts, as one segmented track with the count in the label.
- `class _ArtifactTile extends StatelessWidget`

### messenger_shell.dart  (1115 Z.)
- part 'agents_shell_state.dart' · part 'agents_desktop_layout.dart'
- `class MessengerShell extends StatefulWidget`  — The messenger: coworkers down the left, the selected thread in the middle,
- `class _MessengerShellState extends State<MessengerShell> with AgentsShellHost, _AgentsDesktopLayout, SingleTickerProvide …)`

### mobile_agents_settings_page.dart  (398 Z.)
- `class MobileAgentsSettingsPage extends StatefulWidget`  — The mobile contact page: everyday choices first, technical details second.
- `class _MobileAgentsSettingsPageState extends State<MobileAgentsSettingsPage>`

### otp_verification_page.dart  (291 Z.)
- `class OtpVerificationPage extends StatefulWidget`  — Reusable page for entering a 6-digit email verification code.
- `class _OtpVerificationPageState extends State<OtpVerificationPage>`

### pricing_page.dart  (679 Z.)
- const: _supabase _apiBaseUrl
- `Future<void> _launchExternalUrl(String url)`
- `Future<String> _getAccessToken()`
- `Future<void> startCheckout()`
- `Future<void> openBillingPortal()`
- `Future<void> syncSubscription()`
- `Future<Map<String, dynamic>> getUserStatus()`  — Always a live read — used before opening Stripe checkout, where a stale
- `class PricingPage extends StatefulWidget`
- `class _PricingPageState extends State<PricingPage> with WidgetsBindingObserver`
- `class _PlanCard extends StatelessWidget`

### recover_chats_page.dart  (400 Z.)
- `class RecoverChatsPage extends StatefulWidget`  — Page for recovering or deleting chats encrypted with old passwords.
- `class _RecoverChatsPageState extends State<RecoverChatsPage>`

### secrets_settings_page.dart  (282 Z.)
- `class SecretsSettingsPage extends StatefulWidget`
- `class _SecretsSettingsPageState extends State<SecretsSettingsPage>`
- `class _SecretDialog extends StatefulWidget`  — Name + value entry. With [fixedName] only the value is asked (change).
- `class _SecretDialogState extends State<_SecretDialog>`

### set_new_password_page.dart  (269 Z.)
- `class SetNewPasswordPage extends StatefulWidget`  — Page shown after a user clicks a password reset link.
- `class _SetNewPasswordPageState extends State<SetNewPasswordPage>`

### settings_page.dart  (1127 Z.)
- `class SettingsPage extends StatefulWidget`
- `class _SettingsPageState extends State<SettingsPage>`
- `class _PlanInfo`
- `class _AccountRow extends StatefulWidget`
- `class _AccountRowState extends State<_AccountRow>`
- `class _PlanBadge extends StatelessWidget`
- `class _SettingsRow extends StatelessWidget`
- `class _DevTile extends StatelessWidget`
- `enum BadgeTone`
- `class _Badge extends StatelessWidget`
- `class _MiniChip extends StatelessWidget`
- `class DottedBorderBox extends StatelessWidget`  — Paints a dashed rounded-rectangle border around [child].
- `class _DashedRectPainter extends CustomPainter`

### skills_settings_page.dart  (733 Z.)
- `class SkillsSettingsPage extends StatefulWidget`  — Lists built-in skills and lets the user author their own.
- `class _SkillsSettingsPageState extends State<SkillsSettingsPage>`
- `class SkillEditorPage extends StatefulWidget`  — Edits one skill's SKILL.md source.
- `class _SkillEditorPageState extends State<SkillEditorPage>`
- `class _SkillsEmptyState extends StatelessWidget`  — Shown when the user has authored no skills of their own. A quiet centred
- `class _NoSkillMatches extends StatelessWidget`  — What a section shows when the query matched nothing in it.
- `class _SkillRow extends StatelessWidget`
- `class AgentsSkillsSettingsPage extends StatefulWidget`  — The host's skills, one switch each (docs/WIRE_CONTRACT.md, "Skills").
- `class _AgentsSkillsSettingsPageState extends State<AgentsSkillsSettingsPage>`

### system_prompt_page.dart  (878 Z.)
- `class SystemPromptPage extends StatefulWidget`
- `class _SystemPromptPageState extends State<SystemPromptPage>`
- `class _MaterialTextField extends StatelessWidget`

### theme_page.dart  (1160 Z.)
- `class ThemePage extends StatefulWidget`
- `class _ThemePageState extends State<ThemePage>`
- `class _ColorCard extends StatelessWidget`
- `class _ColorPickerDialog extends StatefulWidget`
- `class _ColorPickerDialogState extends State<_ColorPickerDialog>`
- `class _GradientSlider extends StatelessWidget`
- `class _Swatch extends StatelessWidget`
- `class _PresetPicker extends StatelessWidget`
- `class _PresetDots extends StatelessWidget`
- `class _FontCard extends StatelessWidget`

### tool_calling_settings_page.dart  (759 Z.)
- `class ToolCallingSettingsPage extends StatefulWidget`
- `class _ToolCallingSettingsPageState extends State<ToolCallingSettingsPage>`
- `class _ToolRow extends StatelessWidget`  — One tool: the switch turns it off, the tile itself opens its detail.
- `class _CategoryLabel extends StatelessWidget`  — A light category label under the single "Tools" section header. Smaller and

### usage_details_page.dart  (1340 Z.)
- const: _kMonthNames
- `class UsageDetailsPage extends StatefulWidget`
- `class _UsageDetailsPageState extends State<UsageDetailsPage>`
- `enum _UsageScopeType`
- `class _UsageScopeOption`
- `class _UsageSlice`
- `class _ModelSliceSummary`
- `class _MutableModelSliceSummary`
- `class _StatGrid extends StatelessWidget`  — Label/value pairs on baseline-aligned rows. Replaces the boxed metric
- `class _StreakTile extends StatelessWidget`  — One of the two streak read-outs: a big number over a quiet label.
- `class _TokenActivityHeatmap extends StatelessWidget`  — A GitHub-contribution-style grid: one column per ISO week (oldest at the
- `int _heatmapLevel(int value, int maxValue)`  — Quartile of [value] against [maxValue]: 0 (none) then 1–4 (light→dark).
- `Color _heatmapCellColor(BuildContext context, int level)`  — Cell colour for a heat level, from theme tokens so both themes read well:

### workspace_detail_page.dart  (1031 Z.)
- `class WorkspaceDetailPage extends StatelessWidget`
- `class _WorkspaceDetailDesktop extends StatefulWidget`
- `class _WorkspaceDetailPageState extends State<_WorkspaceDetailDesktop> with SingleTickerProviderStateMixin, WorkspaceAct …)`
- `class _ContextUsageBar extends StatelessWidget`
- `class _ChatSelectorDialog extends StatefulWidget`
- `class _ChatSelectorDialogState extends State<_ChatSelectorDialog>`

### workspace_files_page.dart  (778 Z.)
- `class WorkspaceFilesPage extends StatefulWidget`
- `class _WorkspaceFilesPageState extends State<WorkspaceFilesPage> with WorkspaceActionsMixin<WorkspaceFilesPage>`
- `class _SheetTile extends StatelessWidget`
- `class _FileTile extends StatelessWidget`
- `class _UploadProgress extends StatelessWidget`
- `class _DocumentDraft`
- `class _NewDocumentPage extends StatefulWidget`
- `class _NewDocumentPageState extends State<_NewDocumentPage>`

### workspace_instructions_page.dart  (225 Z.)
- `class WorkspaceInstructionsPage extends StatefulWidget`
- `class _WorkspaceInstructionsPageState extends State<WorkspaceInstructionsPage>`

### workspace_management_page.dart  (758 Z.)
- `class WorkspaceManagementPage extends StatefulWidget`  — Mobile-friendly workspace management page
- `class _WorkspaceManagementPageState extends State<WorkspaceManagementPage> with SingleTickerProviderStateMixin, Workspac …)`
- `class _ChatSelectorSheet extends StatelessWidget`  — Bottom sheet for selecting a chat to add to workspace

### workspace_mobile_detail_page.dart  (567 Z.)
- `class WorkspaceMobileDetailPage extends StatefulWidget`
- `class _WorkspaceMobileDetailPageState extends State<WorkspaceMobileDetailPage>`
- `class _PrivacyChip extends StatelessWidget`
- `class _InfoCard extends StatelessWidget`
- `String _formatDate(DateTime date, BuildContext context)`
- `class _ChatRow extends StatelessWidget`

### workspaces_page.dart  (859 Z.)
- `enum ProjectSortMode`  — Sort options for workspace list
- `class WorkspacesPage extends StatefulWidget`
- `class _WorkspacesPageState extends State<WorkspacesPage>`
- `class _SortButton extends StatelessWidget`
- `class _ProjectRow extends StatelessWidget`
- `class _CreateProjectDialog extends StatefulWidget`
- `class _CreateProjectDialogState extends State<_CreateProjectDialog>`

## lib/pages/settings
### embedding_settings_page.dart  (95 Z.)
- `class EmbeddingSettingsPage extends StatefulWidget`  — Picks the embedding model the host uses for semantic memory.
- `class _EmbeddingSettingsPageState extends State<EmbeddingSettingsPage>`

### herenow_settings_page.dart  (153 Z.)
- `class HereNowSettingsPage extends StatefulWidget`  — The here.now publishing connector: let a coworker put a file or a folder on
- `class _HereNowSettingsPageState extends State<HereNowSettingsPage>`

## lib/platform_specific
### root_wrapper.dart  (5 Z.)
- reicht weiter: 'root_wrapper_stub.dart' if (dart.library.io) 'root_wrapper_io.dart'

### root_wrapper_desktop.dart  (796 Z.)
- `class RootWrapperDesktop extends StatefulWidget`
- `class _RootWrapperDesktopState extends State<RootWrapperDesktop>`

### root_wrapper_io.dart  (76 Z.)
- `class RootWrapper extends StatelessWidget`

### root_wrapper_mobile.dart  (819 Z.)
- `class RootWrapperMobile extends StatefulWidget`
- `class _RootWrapperMobileState extends State<RootWrapperMobile> with WidgetsBindingObserver, SingleTickerProviderStateMix …)`

### root_wrapper_stub.dart  (19 Z.)
- `class RootWrapper extends StatelessWidget`  — Web wrapper - renders desktop UI since web is a desktop-like environment

### sidebar_desktop.dart  (591 Z.)
- `class SidebarDesktop extends StatefulWidget`
- `class _SidebarDesktopState extends State<SidebarDesktop> with SidebarStateCommon<SidebarDesktop>`

### sidebar_mobile.dart  (699 Z.)
- `class SidebarMobile extends StatefulWidget`
- `class _SidebarMobileState extends State<SidebarMobile> with SidebarStateCommon<SidebarMobile>`
- `List<String> _filterChatsIsolate(Map<String, dynamic> params)`

## lib/platform_specific/chat
### chat_api_service.dart  (400 Z.)
- `class ChatApiService`  — A service for handling chat-related API interactions,
- `class TranscriptionResult`
- `class TranscriptionException implements Exception`

### chat_debug_snapshot.dart  (56 Z.)
- `abstract class ChatDebugSnapshot`  — What the "copy debug chat" action reads out of a running chat screen.
- `Map<String, String> chatDebugContext( ChatDebugSnapshot? state, { required String platform, })`  — The context block that rides along with a copied debug chat.

### chat_message_edit_mixin.dart  (346 Z.)
- `mixin ChatMessageEditMixin<W extends StatefulWidget> on State<W>, ChatScrollMixin<W>`

### chat_metrics_observer.dart  (15 Z.)
- `class ChatMetricsObserver with WidgetsBindingObserver`  — Calls back on every view-metrics change — the soft keyboard opening or

### chat_model_selection_mixin.dart  (335 Z.)
- `mixin ChatModelSelectionMixin<W extends StatefulWidget> on State<W>, ModelProviderResolutionMixin<W>`

### chat_scroll_mixin.dart  (538 Z.)
- const: _kTranscriptCenterKey
- `mixin ChatScrollMixin<T extends StatefulWidget> on State<T>`  — Shared message-list scroll behaviour for the desktop and mobile chat UIs.
- `class _TranscriptScrollController extends ScrollController`  — A [ScrollController] whose initial offset is read when a position is

### chat_ui_desktop.dart  (2706 Z.)
- part 'desktop_send_logic.dart'
- `class ChukChatUIDesktop extends StatefulWidget`
- `class ChukChatUIDesktopState extends State<ChukChatUIDesktop> with SingleTickerProviderStateMixin, ChatScrollMixin, Mode …)`

### chat_ui_helpers.dart  (1418 Z.)
- const: _kRowTimeCacheCap _rowTimeCache _rowLocalDayCache
- `class MessageRenderData`  — Data class holding pre-parsed render information for a single chat message.
- `class MessageRenderCache`  — Owns decoded message payloads for one visible chat and builds render data.
- `class _MessageRenderMaps`  — The four decode maps behind a [MessageRenderCache].
- `class ChatContinuationRequest`  — Immutable input for resuming the latest interrupted assistant message.
- `class ChatUiHelpers`  — Static utility functions shared between the desktop and mobile chat UIs.
- `DateTime? messageRowTime(Map<String, String> raw)`  — Message grouping — the one place that decides which rows form a run.
- `DateTime? _rowTimeFor(String stamp)`
- `int? _rowLocalDay(Map<String, String> raw)`  — The local calendar day of a row's stamp as `yyyymmdd`, or null when the
- `bool messageOpensDay(Map<String, String>? previous, Map<String, String> row)`  — Whether a day divider is drawn above [row]. An undated row gets none — an
- `bool messageStartsRun(List<Map<String, String>> messages, int index)`  — Whether the row at [index] opens a new run: it is the first row, the sender
- `bool messageEndsRun(List<Map<String, String>> messages, int index)`  — Whether the row at [index] closes its run: the last row, or the next row

### chat_ui_mobile.dart  (4177 Z.)
- `enum _AttachChoice`  — What the plus menu can start.
- `class _WorkspaceChoice`  — A row in the workspace menu: a workspace to switch to (null clears it),
- `@visibleForTesting String queuedMessagesForComposer(String pending, List<String> followUps)`  — The text a cancelled queue puts back into the composer: the pending
- `class ChukChatUIMobile extends StatefulWidget`
- `class ChukChatUIMobileState extends State<ChukChatUIMobile> with ChatScrollMixin, ModelProviderResolutionMixin, ChatMode …)`  — Serialize a [ChatMessageStatus] into the wire-format string used inside

### composer_menu.dart  (59 Z.)
- `PopupMenuItem<T> composerMenuRow<T>({ required T value, required Color iconFg, required IconData icon, required String l …)`  — One row of a composer menu — same metrics as the mode menu.
- `Future<T?> showAnchoredComposerMenu<T>({ required BuildContext anchorContext, required List<PopupMenuEntry<T>> items, })`  — Open a menu anchored to a composer button. It leaves the focus and

### composer_menu_choices.dart  (18 Z.)
- `enum AttachChoice`  — What the attach menu offers.
- `class WorkspaceChoice`  — A row in the workspace menu: a workspace to switch to (null clears it),

### composer_metrics.dart  (18 Z.)
- `class ComposerMetrics`  — The numbers that make the mobile composer's action row read as one family.

### desktop_send_logic.dart  (2573 Z.)
- part of 'chat_ui_desktop.dart'
- `extension DesktopSendLogic on ChukChatUIDesktopState`  — Extension on [ChukChatUIDesktopState] containing the large send/streaming

### model_provider_resolution_mixin.dart  (186 Z.)
- `mixin ModelProviderResolutionMixin<T extends StatefulWidget> on State<T>`  — Shared model → provider-slug resolution for the desktop and mobile chat UIs.

### regen_variant_seed.dart  (150 Z.)
- `mixin RegenVariantSeedMixin<W extends StatefulWidget> on State<W>`

## lib/platform_specific/chat/handlers
### audio_recording_handler.dart  (567 Z.)
- `enum AudioRecordingChange`
- `class AudioRecordingHandler`  — Handles microphone recording + transcription.
- `class TranscriptionResult`  — Result of audio transcription.

### chat_persistence_handler.dart  (467 Z.)
- `@visibleForTesting bool keepsMoreThanPatch(String? stored, String? patch)`  — Handles chat persistence and storage
- `class ChatPersistenceHandler`
- `class _PendingBackgroundUpdate`

### desktop_clipboard_handler.dart  (265 Z.)
- `class DesktopClipboardHandler`  — Handles desktop-specific clipboard operations and context menus.

### desktop_file_handler.dart  (444 Z.)
- `class ValidatedFile`  — Temporary container for validated files before upload.
- `class DesktopFileHandler`  — Handles desktop-specific file attachment processing including:

### file_attachment_handler.dart  (438 Z.)
- `class FileAttachmentHandler`  — Handles file and image attachments

### message_actions_handler.dart  (195 Z.)
- `class MessageActionsHandler`  — Handles message-related actions (copy, edit, resend)

### mobile_workspace_handler.dart  (153 Z.)
- `class MobileWorkspaceHandler`  — Handles mobile-specific workspace selection UI and workspace–chat linking.

### scanned_pdf_pages.dart  (89 Z.)
- `Future<void> replaceWithScannedPages({ required List<String> dataUrls, required String fileId, required String fileName …)`  — Replaces a scanned PDF in [attachedFiles] with its rendered pages.
- `void discardScannedPages(List<String> paths)`  — Deletes pages that were uploaded before the replacement failed, so a

### streaming_message_handler.dart  (1660 Z.)
- `class StreamingMessageHandler`  — Handles message streaming and sending
- `class _StreamingSnapshot`

## lib/platform_specific/chat/voice
### chat_voice_binding.dart  (474 Z.)
- const: debugOnVoiceCallStart
- `VoiceCallMode voiceCallModeFor(String chatId)`  — Whether this build shows the voice call at all: the build flag and a
- `String? storedChatTitle(String chatId)`  — The stored title of [chatId], or null.
- `List<Map<String, String>> storedChatRows(String chatId)`  — The stored messages of [chatId] as chat rows, for a call started from a
- `class ChatVoiceBinding`
- `class ChatVoiceSessions extends ChangeNotifier`  — The chat screens that can hold a call, so a header drawn outside a
- `String? voiceThreadKeyFor(AgentsAgent agent)`  — The thread a call with [agent] runs in: the one open on the Agents
- `Future<void> startAgentVoiceCall( AgentsAgent agent, { Duration waitForThread = Duration.zero, })`  — Starts a call with [agent] from a page that is not its thread (the
- `Future<void> startAgentsThreadVoiceCall({ required String threadKey, String? agentName, Duration waitForThread = Duratio …)`  — Starts a call for an Agents thread from a page that is not the thread.
- `typedef VoiceCallStartProbe = ({ String chatId, VoiceCallMode mode, String? agentName, String? callId, String? callReaso`  — What a start from this file hands to `VoiceCallController.start`, for a

### chat_voice_call_button.dart  (263 Z.)
- `enum ChatVoiceCallStyle`  — Which surface the target sits on.
- `class ChatVoiceCallButton extends StatelessWidget`

### voice_call_context.dart  (117 Z.)
- const: kVoiceTaskMarker kVoiceContextMaxMessages kVoiceContextMaxChars kVoiceContextMaxLineChars kVoiceResultMaxChars _kThinkingPlaceholder _visualTag _whitespace
- `String buildVoiceCallContext( List<Map<String, String>> messages, { int maxMessages = kVoiceContextMaxMessages, int maxC …)`  — The call context: the last [maxMessages] text messages of a chat as plain
- `String? _contextLine(Map<String, String> message, int maxLineChars)`
- `String _cut(String text, int max)`
- `String? voiceTaskMessageText(String task)`  — The text a spoken task is sent with: the marker, then the task on one
- `String voiceResultText(String text)`  — Cuts a task result to what the worker gets back.
- `bool looksLikeFailedTurn(String text)`  — The texts the chat pipeline finalizes a turn with when the turn did not

### voice_chat_widgets.dart  (102 Z.)
- const: kVoiceRecordGap
- `VoiceRecordPlacement<VoiceCallRecord> placeVoiceRecords( List<Map<String, String>> messages, List<VoiceCallRecord> recor …)`  — Places [records] against [messages] by the rows' own clocks
- `Widget withVoiceRecords({ required Widget item, required int index, required int messageCount, required VoiceRecordPlace …)`  — [item] (message row [index] of [messageCount]) with the call cards that
- `Widget _card(VoiceCallRecord record)`
- `class VoiceCallPanelSlot extends StatelessWidget`  — The live call panel of [chatId] with its gap to the composer under it.

### voice_record_placement.dart  (88 Z.)
- `class VoiceRecordPlacement<T>`  — The records of a chat, placed against its message rows.
- `VoiceRecordPlacement<T> placeRecordsByTime<T>({ required List<DateTime?> messageTimes, required List<T> records, require …)`  — Merges [records] into a message list by time.
- `List<Object> flattenPlacement<T extends Object>( int messageCount, VoiceRecordPlacement<T> placement, )`  — One entry of the merged timeline: a message index or a record. Used by

### voice_task_delegates.dart  (143 Z.)
- const: kVoiceTaskChatClosed kVoiceTaskCallEnded
- `typedef VoiceTaskSender = Future<VoiceTurnOutcome> Function(String text)`  — Sends one task text into the chat and completes when its turn ended.
- `abstract class VoiceTurnDelegate implements VoiceTaskDelegate`  — The shared body of both delegates.
- `class ChatVoiceDelegate extends VoiceTurnDelegate`  — A normal chat: the task goes through chuk_chat's send pipeline with its
- `class AgentsVoiceDelegate extends VoiceTurnDelegate`  — An Agents thread: the task goes through the thread's send path to the

### voice_turn_queue.dart  (262 Z.)
- const: kVoiceTaskOffline
- `class VoiceTurnOutcome`  — How one voice task ended in the chat.
- `typedef VoiceTurnStarted = void Function(String chatId, int placeholderIndex)`  — Called by the chat screen once the turn is under way: the chat it went to
- `typedef VoiceTurnSend = Future<void> Function(String text, VoiceTurnStarted onStarted)`  — Sends [text] as a user message through the chat screen's send path. Calls
- `class VoiceTurnQueue`
- `class _Pending`

## lib/platform_specific/chat/widgets
### chat_message_list_item.dart  (198 Z.)
- `class ChatMessageListItem extends StatelessWidget`  — One message row shared by the desktop and mobile chat lists.

### mobile_chat_widgets.dart  (213 Z.)
- `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive …)`  — Build a tiny icon button widget
- `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color …)`  — Build a tiny action button widget (for send, etc.)
- `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, requir …)`  — Build attachment sheet option (for bottom sheet)
- `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCal …)`  — Build keyboard listener for text field (handles Enter/Shift+Enter)

## lib/platform_specific/mobile
### mobile_agent_list.dart  (1430 Z.)
- const: _kBarReach
- `String accountMonogram(String? label)`  — The account monogram: "alex.smith@…" → "A", "Alex Smith" → "AS".
- `class MobileAgentList extends StatefulWidget`
- `class _MobileAgentListState extends State<MobileAgentList>`
- `Widget _buildBarRow({ Key? key, required Widget leading, required Widget middle, Widget? trailing, })`  — One row of chuk's floating bar: a chip, the middle, and optionally a chip
- `class _BarChip extends StatelessWidget`  — A chip of the inbox bar when it carries the app switch: chuk's floating
- `class _SearchField extends StatelessWidget`  — The roster's search input: one rounded, filled field that carries its own
- `class MobileAgentRow extends StatelessWidget`
- `class MobileRoomRow extends StatelessWidget`  — One ROOM, in the inbox's own row grammar.
- `class _RoleTag extends StatelessWidget`  — The small grey tag next to the name (the coworker's role).
- `class _MenuRow extends StatelessWidget`
- `class _EmptyState extends StatelessWidget`
- `String mobileTimeLabel(DateTime? when, {required DateTime now})`  — The time column of an inbox row, like a messenger: a clock time today,
- `class _UnreadBadge extends StatelessWidget`  — The number of new threads on a coworker, in that coworker's colour.

### mobile_agent_sheet.dart  (211 Z.)
- `class MobileAgentSheet extends StatelessWidget`

### mobile_chat_chrome.dart  (498 Z.)
- const: kMobileChromeChip kMobileChromeRow kMobileChromePillRadius _kReach _kPillFaceSize _kPillStatusFontSize
- `class MobileChatChrome extends StatelessWidget`
- `class _ChromeChip extends StatelessWidget`  — One round chip of the bar: chuk's floating chip — the chrome surface, a
- `class _AgentPill extends StatelessWidget`  — The coworker pill: chuk's title pill with the face, the name and the live

### mobile_chat_screen.dart  (220 Z.)
- `typedef MobileChatBodyBuilder = Widget Function(BuildContext context, double topInset)`  — Builds the chat body. [topInset] is the space the body must leave at the
- `class MobileChatScreen extends StatefulWidget`
- `class _MobileChatScreenState extends State<MobileChatScreen> with TickerProviderStateMixin`

### mobile_chips.dart  (63 Z.)
- `List<BoxShadow> mobileChipShadow(ThemeData theme)`  — The soft shadow under a chip or pill. Lighter in dark mode, where a hard
- `class MobileBarFade extends StatelessWidget`  — The fade behind a floating bar: solid at the top, transparent at the

### mobile_container_transform.dart  (178 Z.)
- `@immutable class ContainerTransformSource`  — One tapped roster row, as the container transform needs it: where the row
- `class MobileContainerTransform extends StatelessWidget`  — The container transform: [closed] grows into [open] over [progress].

### mobile_home.dart  (273 Z.)
- `class MobileHome extends StatefulWidget`
- `class _MobileHomeState extends State<MobileHome>`
- `class FadeThroughTabs extends StatefulWidget`  — An [IndexedStack] that fades through instead of cutting.
- `class _FadeThroughTabsState extends State<FadeThroughTabs> with SingleTickerProviderStateMixin`

### mobile_layout.dart  (96 Z.)
- `class MobileLayout`

### mobile_media_page.dart  (225 Z.)
- `class MobileMediaPage extends StatefulWidget`
- `class _MobileMediaPageState extends State<MobileMediaPage>`
- `class _Thumbnail extends StatelessWidget`
- `class _Empty extends StatelessWidget`

### mobile_nav_bar.dart  (171 Z.)
- `@immutable class MobileNavDestination`  — One destination of [MobileNavBar].
- `class MobileNavBar extends StatelessWidget`
- `class _NavTarget extends StatelessWidget`

## lib/services
### account_session.dart  (198 Z.)
- `class AccountSession`  — Immutable snapshot of the account's authenticated session.
- `abstract interface class AccountSessionSource`  — Reads the current [AccountSession] and refreshes it on demand.
- `class SupabaseAccountSession implements AccountSessionSource`  — [AccountSessionSource] backed by the live Supabase session.

### api_config_base.dart  (130 Z.)
- const: apiConfigEnvApiUrl apiConfigEnvApiHost apiConfigEnvApiPort apiConfigDefaultPort apiConfigDefaultProtocol apiConfigDefaultProductionUrl apiConfigLocalUrl apiConfigProductionUrl artifactsConfigEnvUrl artifactsConfigDefaultProductionUrl
- `String? getConfiguredUrl()`  — Resolves an explicitly configured URL from environment variables, or null.
- `String getApiBaseUrl()`  — Gets the appropriate API base URL based on the current environment.
- `String getArtifactsBaseUrl()`  — Gets the artifacts hosting base URL.
- `String getEnvironment()`  — Whether the current build is pointing at a local development server.
- `bool getIsConfigured()`  — Checks whether the API was explicitly configured via environment variables,
- `String getConfigurationDescription(String platformName)`  — Gets a human-readable description of the current configuration.

### api_config_service.dart  (5 Z.)
- reicht weiter: 'api_config_service_stub.dart' if (dart.library.io) 'api_config_service_io.dart'

### api_config_service_io.dart  (35 Z.)
- `class ApiConfigService`  — Service for managing API configuration across different environments and platforms.

### api_config_service_stub.dart  (27 Z.)
- `class ApiConfigService`  — Service for managing API configuration across different environments and platforms.

### api_status_service.dart  (59 Z.)
- `class ApiStatusService`  — Utility helpers for checking the availability of the primary API.

### app_initialization_service.dart  (467 Z.)
- `class AppInitializationService`  — Callback for initialization events

### app_lifecycle_service.dart  (165 Z.)
- `class AppLifecycleService extends ChangeNotifier`  — Callback when app state changes

### app_mode_service.dart  (108 Z.)
- `enum AppMode`  — The two halves, in the order the switch shows them: Chat on the left,
- `class AppModeService extends ValueNotifier<AppMode>`  — The current [AppMode], with its persistence.

### app_theme_service.dart  (870 Z.)
- `typedef ThemeChangedCallback = void Function()`  — Callback type for theme changes
- `class AppThemeService extends ChangeNotifier`  — Service for managing application theme state, persistence, and Supabase sync

### approval_config.dart  (140 Z.)
- `enum ApprovalCategory`  — Categories of actions that may require approval
- `class ApprovalAction`  — Specific actions within each category that can require approval
- `class ApprovalConfig`  — Universal Approval Configuration

### artifact_context_service.dart  (12 Z.)
- `class ArtifactContextService`

### artifact_diff_engine.dart  (134 Z.)
- `class ArtifactDiffEngine`

### artifact_storage_service.dart  (3209 Z.)
- `typedef ArtifactRowRef = ({ String rowId, String handle, String chatId, String title, String? language, DateTime updated`  — What the service knows about one `artifacts` row without its content:
- `class ArtifactStorageService`

### artifact_tag_processor.dart  (142 Z.)
- `class ArtifactTagProcessor`  — Processes inline `<artifact>` tags emitted by the assistant. For each tag:

### auth_service.dart  (205 Z.)
- `class AuthService`
- `class AuthServiceException implements Exception`

### auth_trace.dart  (84 Z.)
- `class AuthTrace`  — Why the app last stopped being signed in.
- `void unawaited(Future<void> future)`  — Local `unawaited`, so this file pulls in nothing but what it uses.

### bash_sandbox.dart  (457 Z.)
- `typedef ApprovalCallback = Future<bool> Function(String command, String reason)`  — Callback type for approval dialogs
- `class BashSandbox`  — Sandboxed Bash Command Executor

### chat_cache_search_text.dart  (41 Z.)
- `String? buildChatSearchText(String payload)`  — Build the searchable text of a chat payload: message text only.

### chat_dirty_store.dart  (197 Z.)
- `class ChatDirtyStore`

### chat_history_builder.dart  (295 Z.)
- `class ChatHistoryBuilder`

### chat_mode_service.dart  (568 Z.)
- `enum ChatMode`
- `@immutable class ModeConfig`  — One mode's independent settings: which model, on which provider, at which
- `class ChatModeService`

### chat_model_selection_service.dart  (118 Z.)
- `@immutable class ChatModelSelection`
- `class ChatModelSelectionService extends ChangeNotifier`  — A model AND provider belong to one account/chat, never just to a model ID.

### chat_payload_codec.dart  (561 Z.)
- const: kChatPayloadVersion kChatPayloadVersionV2 _jsonFields _refKey _refToolCalls _refRoundThinking _versionPrefix _canonicalStringKeys
- `class DecodedChatPayload`  — A decoded chat payload: message maps in the v2 shape (the input of
- `String encodeChatPayload( List<Map<String, dynamic>> messages, { String? customName, })`  — Encode [messages] (each one `ChatMessage.toJson()`) as a v3 payload.
- `DecodedChatPayload decodeChatPayload(String json)`  — Decode a payload of any version (v1, v2, v3).
- `int? peekChatPayloadVersion(String json)`  — The version of a payload JSON, read from its start without parsing the
- `String toChatPayloadV3(String json)`  — Re-encode a payload JSON of any version as v3. A v3 input is returned as
- `String? toChatPayloadV3Verified(String json)`  — [json] (any version) as v3, proven: null when the v3 JSON would not
- `String chatPayloadFingerprint(DecodedChatPayload p)`  — A fingerprint of the decoded messages and custom name: equal for two
- `({String v3, String fingerprint})? convertChatPayloadToV3WithFingerprint( String json, )`  — [json] (any version) as a proven v3 JSON plus the fingerprint of its
- `String chatPayloadJsonFingerprint(String json)`  — The fingerprint of a payload JSON of any version. For isolates.
- `bool chatPayloadsEquivalent(DecodedChatPayload a, DecodedChatPayload b)`  — Whether [a] and [b] decode to the same messages and custom name.
- `Map<String, dynamic> _canonicalMessage(Map<String, dynamic> m)`  — The message map as `ChatMessage.fromJson` followed by `toJson` would
- `Map<String, dynamic> encodeMessageV3(Map<String, dynamic> m)`  — One message (v2 shape) to its v3 form. Never changes [m].
- `Map<String, dynamic> _plainV2(Map<String, dynamic> m)`  — [m] as it is, with only a stray `_ref` key removed.
- `Object? _structured(String s)`  — The parsed value of [s] when it is a list or a map that encodes back to
- `List<dynamic>? _dedupToolCalls(List<dynamic> toolCalls, List<dynamic> blocks)`  — [blocks] with every tool call that equals an entry of [toolCalls] (same
- `List<dynamic>? _referenceRoundThinking( List<dynamic> toolCalls, List<dynamic> blocks, String? reasoning, )`  — [toolCalls] with each `roundThinking` that repeats reasoning text of the
- `Map<String, dynamic> decodeMessageV3(Map<dynamic, dynamic> m)`  — One v3 message to the v2 shape.
- `List<dynamic> _resolveRoundThinking( List<dynamic> toolCalls, List<dynamic> blocks, String? reasoning, )`
- `bool _isThinkingRef(Object? value)`
- `Map<dynamic, dynamic> _withThinking( Map<dynamic, dynamic> call, Object? ref, List<dynamic> blocks, String? reasoning, S …)`
- `List<dynamic> _resolveToolCalls(List<dynamic> blocks, List<dynamic> toolCalls)`
- `Map<String, dynamic> _normalizeV1(Map<String, dynamic> msg)`  — A v1 message with its field names normalised; all fields are kept.

### chat_payload_migration_service.dart  (1247 Z.)
- `String bumpTimestampByOneMicrosecond(String timestamp)`  — `updated_at` + 1 µs, as Postgres wants it. Works on the web too, where a
- `@immutable class ChatMaintenanceProgress`  — Progress of a run, for the two bars of the maintenance screen.
- `@immutable class ChatMaintenancePlan`  — What needs rewriting for one account.
- `enum ChatStartupCheck`  — What a normal start has to wait for, from local state only.
- `enum ChatMaintenanceOutcome`  — How a run ended.
- `class ChatMaintenanceFailure implements Exception`  — A run that failed. [restored] tells whether the cache backup was put back.
- `abstract class ChatMigrationCloud`  — The cloud half, behind an interface so tests run it without Supabase.
- `class SupabaseChatMigrationCloud implements ChatMigrationCloud`  — [ChatMigrationCloud] over Supabase and [EncryptionService].
- `class ChatPayloadMigrationService`
- `enum _CloudResult`
- `class _MigrationState`  — Persisted progress of one account on this device (`kv_cache`, which a
- `class ChatMaintenanceController extends ChangeNotifier`  — Drives the maintenance screen: plans, runs, and holds the app until the
- `enum ChatMaintenancePhase`

### chat_preload_service.dart  (403 Z.)
- `class ChatPreloadService`  — Service for background preloading all chat messages.

### chat_reaction_service.dart  (91 Z.)
- `class ChatReactionService extends ChangeNotifier`  — Personal, device-local reactions. They are never sent as model feedback.

### chat_runtime.dart  (189 Z.)
- `@immutable class StreamingLive`  — Immutable snapshot of the assistant placeholder's live streaming body,
- `class ChatRuntime`  — Per-chat in-memory live state.

### chat_runtime_registry.dart  (95 Z.)
- `class ChatRuntimeRegistry`  — Singleton registry of per-chat [ChatRuntime]s.

### chat_storage_crud.dart  (1644 Z.)
- `class ChatStorageCrud`  — Handles CRUD operations for chat storage: save, update, delete, load.

### chat_storage_mutations.dart  (295 Z.)
- const: _kTitlesEncodeInBackgroundAt
- `class ChatStorageMutations`  — Handles chat mutations: star, rename, re-encrypt, export
- `String _encodeTitles(List<Map<String, Object>> data)`
- `Future<void> saveTitlesToCache(String userId, List<StoredChat> chats)`

### chat_storage_service.dart  (360 Z.)
- reicht weiter: 'package:chuk_chat/models/chat_message.dart' · 'package:chuk_chat/models/stored_chat.dart' · 'package:chuk_chat/services/chat_storage_state.dart' show initChatStorageCache
- `class ChatStorageService`  — Facade class providing backward-compatible API for chat storage.

### chat_storage_sidebar.dart  (558 Z.)
- const: _kSidebarApplyChunkSize _kSidebarIsolateParseThresholdChars
- `List<Map<String, Object?>> _parseSidebarTitleCache(String raw)`  — Parse cached sidebar title JSON into a typed list.
- `class ChatStorageSidebar`  — Handles sidebar-specific chat loading and title caching.

### chat_storage_state.dart  (311 Z.)
- const: sharedPrefsInstance _legacyPrefsCleanupScheduled _kLegacyPrefsCleanupDelay
- `Future<void> initChatStorageCache()`  — Pre-initialize SharedPreferences at app startup for instant cache access
- `void _scheduleLegacyPrefsCleanup()`  — Move the two big blobs that used to live in SharedPreferences into the
- `String chatTitlesCacheKey(String userId)`  — kv_cache key holding the sidebar title list for [userId].
- `class ChatStorageState`  — Central state management for chat storage.

### chat_storage_sync.dart  (482 Z.)
- const: _backgroundEncodeMinChars
- `class DeserializeResult`  — Internal class for deserialize results from isolate
- `DeserializeResult deserializePayloadIsolate(String json)`  — Top-level function for background JSON deserialization
- `class ChatPayload`  — Internal class for chat payload
- `Future<ChatPayload> deserializePayloadAsync(String json)`  — Deserialize chat payload in background isolate to avoid UI blocking
- `List<ChatPayload?> _deserializeBatchIsolate(List<String> jsonPayloads)`  — Top-level function for batch deserialization in a single isolate.
- `Future<List<ChatPayload?>> deserializePayloadBatchAsync( List<String> jsonPayloads, )`  — Batch deserialize multiple payloads in a single isolate (much faster
- `String chatTitleFromMessages(List<ChatMessage> messages)`  — The title a chat gets when nobody named it: its first user message,
- `String _encodeChatPayloadIsolate(_EncodeArgs args)`
- `class _EncodeArgs`
- `Future<String> encodeChatPayloadAsync( List<ChatMessage> messages, String? customName, )`  — The v3 payload JSON of [messages], encoded off the UI isolate when the
- `Future<String> toChatPayloadV3Async(String json)`  — [json] (a payload of any version) as a v3 payload JSON. A v3 input is
- `class ChatStorageSync`  — Handles chat synchronization from cloud to local state.

### chat_sync_service.dart  (424 Z.)
- `class ChatSyncService`  — Service for syncing chats between local state and Supabase.

### chat_titles_prefs_cleanup.dart  (86 Z.)
- `class ChatTitlesPrefsCleanup`

### current_user.dart  (49 Z.)
- `abstract final class CurrentUser`  — Who is signed in, for the static caches that are keyed on it.

### customization_preferences_service.dart  (249 Z.)
- `class CustomizationPreferences`
- `String _sanitizeFontFamily(String? id)`
- `class CustomizationPreferencesService`
- `class CustomizationPreferencesServiceException implements Exception`

### developer_options_service.dart  (206 Z.)
- `class DeveloperOptionsService`  — Cross-device developer options toggle.

### device_services.dart  (728 Z.)
- `class DeviceServices`  — Singleton service providing access to native device features.

### diagnostics_log_service.dart  (5 Z.)
- reicht weiter: 'diagnostics_log_service_stub.dart' if (dart.library.io) 'diagnostics_log_service_io.dart'

### diagnostics_log_service_io.dart  (566 Z.)
- `class DiagnosticsLogService`  — Opt-in diagnostics logger that also works in release builds.

### diagnostics_log_service_stub.dart  (53 Z.)
- `class DiagnosticsLogService`

### download_preferences_service.dart  (72 Z.)
- `class DownloadPreferencesService`  — User preferences for how downloaded files are saved across the app.

### encrypted_meta.dart  (135 Z.)
- const: kEncryptedPlaceholder kEncryptedMetaVersion
- `class EncryptedMeta`

### encryption_service.dart  (1237 Z.)
- const: kPlainEnvelopeVersion kCompressedEnvelopeVersion
- `String _cleartextToString(List<int> cleartext, Object? version)`  — The text of a decrypted envelope of [version].
- `void _checkEnvelopeVersion(Object? version)`
- `Future<String> sealChatPayload({ required String json, required List<int> keyBytes, required int keyVersion, bool allowB …)`  — Seal a chat payload JSON: compress it into a frame, encrypt the frame
- `Future<String> openEnvelopeText(String encrypted, List<int> keyBytes)`  — Decrypt an envelope of either version to its text. Pure, see
- `String? envelopeVersionOf(String encrypted)`  — The envelope version of [encrypted] without decrypting it, or null when
- `class _SealParams`  — Parameters for sealing a chat payload in the background.
- `typedef ChatEnvelopeV3 = ({ String envelope, String payloadJson, String fingerprint, })`  — The result of [convertChatEnvelopeToV3]: the new envelope, the v3
- `Future<ChatEnvelopeV3?> convertChatEnvelopeToV3({ required String encrypted, required List<int> keyBytes, required int k …)`  — Convert the chat payload envelope [encrypted] (any version) to a v3
- `Future<String> chatEnvelopeFingerprint( String encrypted, List<int> keyBytes, )`  — Decrypt a chat envelope and return the fingerprint of its messages.
- `class _FingerprintParams`
- `Future<String> _fingerprintInBackground(_FingerprintParams params)`
- `class _ConvertParams`
- `Future<ChatEnvelopeV3?> _convertChatEnvelopeInBackground( _ConvertParams params, )`
- `Future<String> _sealChatPayloadInBackground(_SealParams params)`
- `class _EncryptionParams`  — Parameters for background encryption
- `class _DecryptionParams`  — Parameters for background decryption
- `class _BatchDecryptionParams`  — Parameters for batch background decryption
- `Future<String> _encryptBytesInBackground(_EncryptionParams params)`  — Top-level function for background encryption
- `Future<Uint8List> _decryptBytesInBackground(_DecryptionParams params)`  — Top-level function for background decryption
- `Future<String> _decryptStringInBackground(_DecryptionParams params)`  — Top-level function for background string decryption (for chat text)
- `Future<List<String?>> _decryptBatchInBackground( _BatchDecryptionParams params, )`  — Top-level function for batch background decryption
- `class _KeyDerivationParams`  — Parameters for PBKDF2 key derivation in background isolate
- `Future<List<int>> _deriveKeyInBackground(_KeyDerivationParams params)`  — Top-level function for background PBKDF2 key derivation
- `class EncryptionService`

### executor_provisioning.dart  (111 Z.)
- `class ExecutorHandle`  — Identifies one executor the app can hand its session to.
- `abstract interface class ExecutorTransport`  — The encrypted connect channel the app uses to reach an executor.
- `class UnimplementedExecutorTransport implements ExecutorTransport`  — Placeholder transport used until the encrypted relay is built. It throws so
- `class ExecutorProvisioning`  — Hands an executor the account authentication so it can spend the account's

### file_conversion_service.dart  (425 Z.)
- `class FileConversionService`  — Service for converting files to markdown using the /v1/ai/convert-file endpoint.

### file_save_service.dart  (142 Z.)
- `class SaveResult`  — Outcome of a save attempt. Callers use this to drive snackbars or follow-up
- `enum SaveOutcome`
- `class FileSaveService`  — Centralised file-save entry point. Every download in the app should funnel

### github_connection_service.dart  (251 Z.)
- `class GitHubConnectionStatus`
- `class GitHubConnectInit`
- `enum GitHubConnectPollState`  — Poll result from /connect/poll. ``success`` means the token is
- `class GitHubConnectPollResult`
- `class GitHubConnectionException implements Exception`
- `class GitHubConnectionService`

### github_oauth.dart  (465 Z.)
- `class GitHubOAuth`  — GitHub OAuth Service - Supports both OAuth App and Personal Access Token

### google_oauth.dart  (807 Z.)
- `class GoogleOAuth`  — Google OAuth Service - Backend-assisted flow for Gmail & Calendar APIs

### image_compression_service.dart  (243 Z.)
- `Future<Uint8List> _compressImageInBackground(_CompressionParams params)`  — Top-level function for background image compression
- `class _CompressionParams`  — Parameters for background image compression
- `class ImageCompressionService`  — Service for compressing images with no size limit

### image_storage_service.dart  (476 Z.)
- `class StoredImage`  — Represents a stored image with metadata
- `class ChatUsingImage`  — Represents a chat that uses a specific image
- `String _utf8DecodeInBackground(Uint8List bytes)`  — Top-level function for UTF-8 decoding in background isolate
- `class ImageStorageService`  — Service for storing and retrieving encrypted images in Supabase Storage

### key_version_service.dart  (146 Z.)
- `class PreviousKeyInfo`  — Represents a previous encryption key's metadata.
- `class KeyVersionService`  — Manages encryption key versions for password reset recovery.

### local_chat_cache_native.dart  (1124 Z.)
- `class LocalChatCacheService`
- `typedef _EncodedPayload = ({Object stored, String? searchText})`  — A payload as the table stores it, with its search text.
- `List<_EncodedPayload> _encodePayloads(List<String> payloads)`
- `List<Map<String, dynamic>> _parseJsonCacheInIsolate(String raw)`  — Parse JSON cache data in a background isolate (for migration reads).

### local_chat_cache_rows.dart  (66 Z.)
- `Map<String, dynamic> buildPlaintextCacheRow({ required String id, required String payload, required String createdAt, re …)`  — Builds a plaintext cache row.
- `Map<String, dynamic>? sanitizeCacheRow(Map<String, dynamic> row)`  — Normalises a row read back from storage, or returns null when it is not

### local_chat_cache_service.dart  (5 Z.)
- reicht weiter: 'local_chat_cache_web.dart' if (dart.library.io) 'local_chat_cache_native.dart'

### local_chat_cache_web.dart  (346 Z.)
- `class LocalChatCacheService`

### message_composition_service.dart  (412 Z.)
- `class MessageCompositionResult`  — Result of message composition preparation
- `class MessageCompositionService`  — Service for composing and validating chat messages before sending
- `class _MessageContent`  — Internal class for message content
- `class _TokenLimits`  — Internal class for token limits

### model_cache_service.dart  (228 Z.)
- `class ModelCacheService`

### model_capabilities_service.dart  (209 Z.)
- `class ModelCapabilitiesService`  — Service for determining model capabilities like vision and reasoning.

### model_prefetch_service.dart  (113 Z.)
- `class ModelPrefetchService`

### multiplex_connection.dart  (1054 Z.)
- const: _uuid
- `class MultiplexException implements Exception`  — Error surfaced by [MultiplexConnection.tool] (and the chat stream's
- `String _newReqId()`  — Generate a fresh request id. ≤ 32 hex chars — comfortably under the
- `class MultiplexConnection`  — Multiplexed WebSocket client.

### multiplex_session.dart  (527 Z.)
- const: _idleCloseDelay _staleReconnectThreshold
- `class MultiplexSession`
- `class _ActiveChatStream`  — Per-chatId book-keeping for the single in-flight chat stream

### multiplex_tool_proxy.dart  (76 Z.)
- `class MultiplexToolOutcome`  — Result of [tryToolViaMultiplex]. Either holds a decoded body (when
- `Future<MultiplexToolOutcome> tryToolViaMultiplex({ required String tool, required Map<String, dynamic> payload, })`  — Attempt to send a tool call over the multiplex socket. Designed so

### network_status_service.dart  (203 Z.)
- `class NetworkStatusService`  — Provides utilities for checking general internet reachability.
- `class _ConnectivityProbe`

### notification_service.dart  (46 Z.)
- `class NotificationService`

### notification_service_io.dart  (250 Z.)
- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)

### notification_service_stub.dart  (38 Z.)
- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)

### oauth_loopback_server.dart  (158 Z.)
- `class OAuthResultPageTheme`  — Colours of the small page the browser shows after the redirect.
- `class OAuthLoopbackServer`  — Loopback HTTP server for the desktop OAuth redirect.

### offline_queue_service.dart  (9 Z.)
- reicht weiter: 'offline_queue_service_web.dart' if (dart.library.io) 'offline_queue_service_native.dart'

### offline_queue_service_native.dart  (249 Z.)
- `class OfflineQueueService`  — Persistent offline send queue. Used by [OfflineRetryManager] to replay

### offline_queue_service_web.dart  (171 Z.)
- `class OfflineQueueService`  — SharedPreferences-backed persistent queue used on web where SQLite is not

### offline_retry_manager.dart  (372 Z.)
- `class SendExecutorResult`  — Outcome of a send executor call.
- `typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg)`  — Performs the actual send for one queued message. Returns success or a
- `typedef OutboxFlush = Future<int> Function()`  — Agents: sends everything queued for the thread it was registered for, and
- `typedef HostReconnect = Future<void> Function()`  — Agents: gets the transport to try the host again, from scratch.
- `enum OfflineRetryEventType`  — Lifecycle event for retry attempts. Mostly useful for diagnostics + UI
- `class OfflineRetryEvent`
- `class OfflineRetryManager`  — Watches connectivity and drains the offline queue when the device returns
- `class _RetryableError implements Exception`

### offline_send_coordinator.dart  (153 Z.)
- `class OfflineSendPayload`
- `class OfflineSendCoordinator`  — Convenience wrapper around [OfflineQueueService] + [OfflineRetryManager].

### offline_send_executor.dart  (173 Z.)
- `class OfflineSendExecutor`

### onboarding_tour_controller.dart  (1204 Z.)
- `enum _Step`  — Step in the interactive tour state machine.
- `class TourNavigatorObserver extends NavigatorObserver`  — Navigator observer the controller installs on the root navigator. It
- `class OnboardingTourController`  — Singleton controller for the interactive onboarding tour.
- `enum _BodyKind`  — Marker for which copy block the banner should show.
- `class _TourModalCard extends StatelessWidget`  — Welcome / finale full-screen card with a scrim.
- `class _TourBannerOverlay extends StatefulWidget`  — Overlay shown for pointer + page-banner steps. Reads the target slot's
- `class _TourBannerOverlayState extends State<_TourBannerOverlay> with SingleTickerProviderStateMixin`
- `class _PulsingRing extends StatefulWidget`  — Animated pulsing ring rendered at the target position. Never receives
- `class _PulsingRingState extends State<_PulsingRing> with SingleTickerProviderStateMixin`

### password_change_service.dart  (227 Z.)
- `class PasswordChangeService`
- `class PasswordChangeException implements Exception`

### password_reset_service.dart  (269 Z.)
- `class RecoveryException implements Exception`  — Exception thrown by password reset recovery operations.
- `class PasswordResetService`  — Service for recovering or deleting chats encrypted with old keys

### password_revision_service.dart  (171 Z.)
- `class PasswordRevisionService`  — Keeps track of a password revision marker so that other sessions can detect

### payload_compression.dart  (146 Z.)
- const: _frameMarker _headerLength _bzip2MinBytes
- `class PayloadCodec`  — Codec ids of the frame. Never reuse a number: stored data carries it.
- `bool isPayloadFrame(List<int> bytes)`  — Whether [bytes] is a compressed payload frame.
- `Uint8List compressPayloadStrong(String text, {bool allowBzip2 = true})`  — The strongest frame for [text]: bzip2 or deflate level 9, whichever is
- `Uint8List compressPayloadFast(String text)`  — A fast deflate frame for [text] (the local cache).
- `Uint8List decompressPayloadFrame(List<int> frame)`  — The uncompressed bytes of a frame. Throws [FormatException] for an
- `String decodeStoredPayload(List<int> bytes)`  — The text of a stored payload in any of its forms: a frame, a gzip blob
- `Uint8List _deflate(List<int> raw, int level)`
- `Uint8List _frame(int codec, List<int> raw, List<int> data)`
- `bool _sameBytes(List<int> a, List<int> b)`

### pdf_attachment_service.dart  (38 Z.)
- `class PdfAttachmentService`

### per_model_system_prompt_service.dart  (555 Z.)
- const: _kModelPromptSeparator
- `enum ModelPromptMode`  — How a per-model system prompt combines with the base (global + workspace)
- `ModelPromptMode _modeFromString(String? raw)`
- `String _modeToString(ModelPromptMode mode)`
- `@immutable class ModelPromptConfig`  — Per-model system prompt configuration.
- `String? mergeModelPrompt({ required String? base, required String? modelPrompt, required ModelPromptMode mode, })`  — Pure helper: merge a per-model prompt into a base system prompt according
- `class PerModelSystemPromptService`  — Manages per-model system prompts.

### profile_service.dart  (85 Z.)
- `class ProfileRecord`
- `class ProfileService`
- `class ProfileServiceException implements Exception`

### round_content_block_service.dart  (326 Z.)
- `class RoundContentBlockResult`
- `class RoundContentBlockService`

### service_credentials_service.dart  (212 Z.)
- `class ServiceCredentialsService`  — Syncs encrypted OAuth tokens (Google, GitHub, MCP connectors, etc.) to

### session_manager_service.dart  (275 Z.)
- `typedef SessionEventCallback = void Function()`  — Callback for session-related events
- `class SessionManagerService extends ChangeNotifier`  — Service for managing user authentication sessions and security

### session_recovery.dart  (559 Z.)
- `@immutable class SessionStash`  — Session recovery through the paired host (bead cowork-2n1).
- `enum RecoveryOutcome`  — Why a recovery ended the way it did.
- `@immutable class RecoveryResult`  — What a recovery came back with.
- `bool isTransportFailure(Object? error)`  — True when [error] means the request never got an answer from GoTrue.
- `abstract interface class RecoveryLink`  — The relay side of a recovery, behind a small seam so the procedure is
- `class AgentsRelayRecoveryLink implements RecoveryLink`  — [RecoveryLink] over a real [AgentsRelayClient] built from the app's stored
- `class SessionRecovery`  — Runs one recovery: host first, own refresh token second, login page last.
- `class _RecoverySessionSource implements AccountSessionSource`

### session_refresh_scheduler.dart  (144 Z.)
- `class SessionRefreshScheduler with WidgetsBindingObserver`  — The app's own access-token refresh, replacing gotrue's auto refresh

### settings_sync_service.dart  (65 Z.)
- `class SettingsSyncService`  — Central coordinator for cross-device settings sync.

### slack_oauth.dart  (476 Z.)
- `class SlackOAuth`  — Slack OAuth Service

### streaming_chat_service.dart  (39 Z.)
- `class StreamingChatService`  — Service for handling streaming chat responses with Server-Sent Events (SSE).
- `class StreamingChatException implements Exception`  — Exception thrown when streaming chat fails.

### streaming_foreground_service.dart  (43 Z.)
- `class StreamingForegroundService`

### streaming_foreground_service_io.dart  (307 Z.)
- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.
- `@pragma('vm:entry-point') void _foregroundTaskCallback()`  — Callback for foreground task - we don't need to do anything here
- `class _StreamingTaskHandler extends TaskHandler`  — Minimal task handler - just keeps the service running

### streaming_foreground_service_stub.dart  (71 Z.)
- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.

### streaming_manager.dart  (5 Z.)
- reicht weiter: 'streaming_manager_stub.dart' if (dart.library.io) 'streaming_manager_io.dart'

### streaming_manager_base.dart  (702 Z.)
- `abstract class StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats.
- `class ActiveStream`  — One tracked stream: its subscription, buffers and bookkeeping.

### streaming_manager_io.dart  (407 Z.)
- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats

### streaming_manager_stub.dart  (54 Z.)
- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats

### streaming_transcription_service.dart  (244 Z.)
- `class StreamingTranscriptionService`  — Manages a WebSocket connection for streaming audio chunks to the

### supabase_schema_errors.dart  (22 Z.)
- `bool isMissingPreferencesColumn(PostgrestException error)`  — True when [error] says the `preferences` JSONB column is not there.

### supabase_service.dart  (232 Z.)
- `class SupabaseService`

### system_tray_service.dart  (5 Z.)
- reicht weiter: 'system_tray_service_stub.dart' if (dart.library.io) 'system_tray_service_io.dart'

### system_tray_service_io.dart  (421 Z.)
- `class SystemTrayService with WindowListener`  — Desktop system tray integration for Linux, Windows, and macOS.

### system_tray_service_stub.dart  (16 Z.)
- `class SystemTrayService`

### theme_settings_service.dart  (162 Z.)
- `class ThemeSettings`  — The synced look. A theme pack is the three colours *plus* the contrast and
- `double? _clampContrast(Object? raw)`  — Null stays null — "never stored" is not the same as "stored as default".
- `String? _sanitizeUiFont(String? raw)`
- `class ThemeSettingsService`
- `class ThemeSettingsServiceException implements Exception`

### title_generation_service.dart  (877 Z.)
- `class TitleGenerationService`  — Service for automatically generating chat titles using AI.

### token_activity_stats.dart  (285 Z.)
- `enum HeatmapMode`  — How the token-activity heatmap colours each day cell.
- `@immutable class DailyTokenPoint`  — One calendar day of token activity.
- `@immutable class TokenActivityStats`  — The result of aggregating a single [UsageLogsService] fetch for the
- `class TokenActivityStatsService`  — Pure aggregation for the token-activity panel. Stateless: every method is
- `class _DayAggregate`

### tool_call_handler.dart  (2179 Z.)
- const: _readOnlyToolNames repeatableLookupToolNames kRepeatedToolCallNote kToolsClosedNote kMaxToolRoundsPerTurn _kMalformedArgumentsKey
- `@visibleForTesting String toolCallIdentityKey(String name, Map<String, dynamic> arguments)`  — A key that is equal for two calls with the same name and the same
- `Object? _canonicalJson(Object? value)`
- `class ToolLoopSession`
- `class ToolLoopStep`
- `class RoundSegment`  — One segment in the model's interleaved output for a single round.
- `class ToolLoopResult`
- `class ToolTurnSignals`  — Provider/tool-loop hints extracted from stream metadata.
- `class ToolCallHandler`
- `class _DiscoveryContextState`  — Per-chat context that survives across user turns (in memory only — it does

### tool_enforcer.dart  (420 Z.)
- `class ToolEnforcer`  — Client-side Tool Call Enforcer (inspired by Kimi K2's Enforcer).
- `class HallucinationCheckResult`
- `class EnforcedToolCall`
- `class RejectedToolCall`
- `class EnforcerResult`
- `class ToolCallResult`

### tool_executor.dart  (1472 Z.)
- const: _excalidrawSchemaText _technicalDrawingSchemaText _typstSchemaText _mermaidSchemaText _svgSchemaText
- `class ToolExecutionResult`
- `class ToolExecutor`  — Service to execute tools client-side.

### tool_image_result_service.dart  (510 Z.)
- `class ToolImageUpdateResult`
- `class _ExtractionResult`
- `class ToolImageResultService`

### tool_prompt_builder.dart  (1367 Z.)
- `class ToolPromptBuilder`  — Builds system prompts with tool calling protocol for LLM.

### tool_registry.dart  (1814 Z.)
- const: _serverBackedToolNames toolCategoryMap discoveryCatalog builtinTools
- `bool _isMobileRuntime()`  — Whether the current platform is a mobile device (Android/iOS).
- `void registerBuiltinTools(ToolExecutor executor)`  — Register all built-in tools from [builtinTools] into a [ToolExecutor].

### tool_result_cache_registry.dart  (139 Z.)
- const: _uuid kCacheMissErrorCode
- `class _RegistryEntry`
- `class ToolResultCacheRegistry`  — Process-wide registry mapping a previously-uploaded message string to the

### tour_key_registry.dart  (89 Z.)
- `class TourSlots`  — Known target slots used by the onboarding tour.
- `class TourKeyRegistry`  — Singleton store of [GlobalKey]s by slot name. Always returns the SAME

### tray_action_bus.dart  (21 Z.)
- `class TrayActionBus`  — Decouples the desktop system tray menu from the widget tree.

### update_check_service.dart  (302 Z.)
- `class UpdateCheckService`  — Checks for app updates via the GitHub Releases API.
- `class UpdateInfo`  — Information about an available update.

### usage_logs_service.dart  (452 Z.)
- `class UsageLogEntry`
- `class UsageModelSummary`
- `class UsageOverview`
- `class UsageLogsService`
- `class UsageLogsServiceException implements Exception`
- `class _UsageBillingSnapshot`
- `class _MutableModelSummary`
- `int _parseInt(dynamic value)`
- `double _parseDouble(dynamic value)`
- `double? _parseNullableDouble(dynamic value)`
- `DateTime? _parseDateTime(dynamic value)`

### user_model_prefs_realtime_service.dart  (118 Z.)
- `class UserModelPrefsRealtimeService`

### user_preferences_service.dart  (980 Z.)
- `class UserPreferencesService`

### user_status_service.dart  (177 Z.)
- `class UserStatusService`

### websocket_chat_service.dart  (375 Z.)
- `class WebSocketChatService`  — Service for handling streaming chat responses.

### websocket_connector.dart  (10 Z.)
- reicht weiter: 'websocket_connector_web.dart' if (dart.library.io) 'websocket_connector_io.dart'

### websocket_connector_io.dart  (66 Z.)
- const: _sharedPinnedClient _kWsPingInterval
- `Future<WebSocketChannel> connectWebSocket(Uri url)`  — Create a [WebSocketChannel] with certificate pinning on native platforms.

### websocket_connector_web.dart  (15 Z.)
- `Future<WebSocketChannel> connectWebSocket(Uri url)`  — Create a [WebSocketChannel] on web.

### window_close_service.dart  (5 Z.)
- reicht weiter: 'window_close_service_stub.dart' if (dart.library.io) 'window_close_service_io.dart'

### window_close_service_io.dart  (40 Z.)
- `Future<void> initializeWindowCloseHandler()`
- `class _CloseListener extends WindowListener`

### window_close_service_stub.dart  (5 Z.)
- `Future<void> initializeWindowCloseHandler()`

### workspace_file_upload.dart  (88 Z.)
- `class WorkspaceUploadOutcome`  — What came out of [pickAndUploadWorkspaceFile].
- `Future<WorkspaceUploadOutcome> pickAndUploadWorkspaceFile({ required String workspaceId, required void Function(String f …)`  — Asks for a file and uploads it to [workspaceId].

### workspace_message_service.dart  (388 Z.)
- `class WorkspaceMessageService`  — Service for composing AI messages with workspace context

### workspace_storage_service.dart  (1992 Z.)
- `typedef SealedRowRead = ({ /// The row with every sealed field resolved; safe for `fromJson`. Map<String, dynamic> row, `  — One `projects` / `project_files` row after its `encrypted_meta` envelope
- `@visibleForTesting class ResealJob`  — One row to write again sealed: a snapshot of the row as it was read.
- `class WorkspaceStorageService`  — Service for managing workspace workspaces, chat assignments, and file attachments

## lib/services/agents
### agent_control_source.dart  (496 Z.)
- `@immutable sealed class ControlValue<T>`  — One block of the control surface: known, loading, or not connected.
- `@immutable class ControlAvailable<T> extends ControlValue<T>`  — The host reported a real value.
- `@immutable class ControlLoading<T> extends ControlValue<T>`  — A request is in flight.
- `@immutable class ControlUnavailable<T> extends ControlValue<T>`  — Nothing on the other side reports this yet. [reason] is shown to the user.
- `@immutable class AgentSkill`  — One skill the agent can load on demand (§11).
- `@immutable class AgentModelChoice`  — The model this coworker's last run really used.
- `@immutable class AgentTokenUsage`  — What this coworker has spent, summed over the runs it really made.
- `@immutable class AgentSessionRuntime`  — The coworker's clock: when it first ran, and how long it has been working.
- `@immutable class AgentSandbox`  — The box this coworker works in (§6, bead cowork-jo2).
- `@immutable class AgentControlSnapshot`  — Everything the control surface shows, one [ControlValue] per block.
- `abstract interface class AgentControlSource`  — The control surface's data source. One instance for the app; every call
- `class RelayAgentControlSource implements AgentControlSource`  — The production source: the host's own figures, over the relay.
- `class HostUnavailableControlSource extends RelayAgentControlSource`  — The name the shell constructs. It **is** [RelayAgentControlSource].
- `@visibleForTesting class FakeAgentControlSource implements AgentControlSource`  — A stand-in source with values in it.

### agent_file_saver.dart  (11 Z.)
- reicht weiter: 'agent_file_saver_base.dart' · 'agent_file_saver_stub.dart' if (dart.library.io) 'agent_file_saver_io.dart'

### agent_file_saver_base.dart  (29 Z.)
- `abstract interface class AgentFileSaver`  — Writes a received file somewhere the user can find it.
- `String sanitizeAgentFileName(String raw)`  — Reduces a name from the wire to a plain, single-segment file name.

### agent_file_saver_io.dart  (38 Z.)
- `class DownloadsAgentFileSaver implements AgentFileSaver`

### agent_file_saver_stub.dart  (18 Z.)
- `class DownloadsAgentFileSaver implements AgentFileSaver`

### agent_profile_store.dart  (281 Z.)
- `enum AgentAvatarShape`  — One coworker's display profile. Every field is optional: an agent with no
- `@immutable class AgentProfile`
- `class AgentProfileStore extends ChangeNotifier`

### agent_read_marks.dart  (175 Z.)
- `class AgentReadMarks extends ChangeNotifier`

### agent_roster_source.dart  (517 Z.)
- `abstract class AgentRosterSource extends ChangeNotifier`  — Read/write access to the roster, as a [ChangeNotifier] the UI listens to.
- `class LocalAgentRosterSource extends AgentRosterSource`  — The roster the app ships with, kept in memory and cached on disk.
- `class AgentNameGenerator`  — Auto-assigned coworker names (§4): adjective-noun, the same shape the

### agent_roster_store.dart  (258 Z.)
- const: kAgentRosterPrefsKey
- `@immutable class AgentRosterSnapshot`  — What one launch reads back off disk.
- `class AgentRosterStore`

### agents_approved_devices.dart  (154 Z.)
- `class AgentsApprovedDevices`  — The executor's **local** set of device public keys it will accept frames

### agents_backoff.dart  (59 Z.)
- `class AgentsBackoff`  — The delay curve for one kind of work.

### agents_chat_core.dart  (31 Z.)
- const: debugAgentsChatCoreOverride

### agents_chat_transport.dart  (838 Z.)
- const: _taskSeq
- `class AgentsChatTransport`  — Service for handling streaming chat responses.
- `PendingTask _unrecorded(String sessionKey, String taskId)`  — The value a failed [AgentsPendingTasks.record] falls back to.
- `String mintTaskId()`  — Mints the id that names ONE send on the wire.
- `String _taskRejectionText(String? reason)`  — One plain sentence for a `task_ack` rejection.
- `Future<OutboxTask?> _queueForLater( String message, String sessionKey, Future<ChatModelSelection> selectedRoute, { Strin …)`  — Puts a prompt the socket would not take into the per-thread outbox.
- `Future<void> _queueAndMark( String message, String sessionKey, Future<ChatModelSelection> selectedRoute, { String? reaso …)`  — Queues the prompt, then marks the bubble it came from.

### agents_cloud_relay.dart  (1129 Z.)
- const: kAgentsRelayPath kAgentsPairChannelParam kAgentsTargetDeviceParam kAgentsHealChannelParam
- `@immutable class AgentsCloudRelayAddress`  — A dial address for the cloud relay, expressed as a [Uri] so it fits the
- `class AgentsCloudRelayException implements Exception`  — Raised when the relay refuses the handshake or the pairing claim. The
- `class AgentsClaimCancel`  — Stops a waiting claim ([AgentsCloudRelaySocket.waitForPairingClaim]): the
- `RelaySocketConnector agentsCloudRelayConnector({ required String deviceId, required AccountSessionSource sessionSource …)`  — Builds the app's production connector: cloud for `…/v2/relay/ws`, the plain
- `class AgentsCloudRelaySocket implements RelaySocket`  — A [RelaySocket] that speaks the cloud relay downward and the local blind

### agents_controller_session.dart  (97 Z.)
- `class AgentsControllerSession`

### agents_device_keys.dart  (115 Z.)
- `class AgentsDeviceKeys`  — Per-device Ed25519 identity helpers.

### agents_frame.dart  (334 Z.)
- const: kAgentsFrameVersion kAgentsFrameNonceLength kAgentsFrameSignatureLength kAgentsFrameMacLength _kDomain
- `enum AgentsFrameRejection`  — Why a frame was refused.
- `class AgentsFrameRejectedException implements Exception`  — Thrown whenever a frame is refused. Carries a machine-readable [rejection]
- `class AgentsFrame`  — A sealed Agents frame, as it travels over the relay.

### agents_frame_codec.dart  (350 Z.)
- const: _cipher kAgentsChannelKeyLength
- `class AgentsFrameSealer`  — Seals outgoing Agents frames: AES-256-GCM under the account key, then an
- `class AgentsFrameOpener`  — Opens incoming Agents frames, in this order:

### agents_heal_channel.dart  (48 Z.)
- const: kAgentsHealChannelLabel
- `Future<String> deriveAgentsHealChannel( List<int> channelKey, String channelId, )`  — HMAC-SHA256(channelKey, label + channelId), url-safe base64, no padding:

### agents_host_session.dart  (109 Z.)
- const: kAgentsHostSessionPath
- `class AgentsHostSession`  — A session minted for the host. Key material: never logged, never stored.
- `typedef AgentsHostSessionMinter = Future<AgentsHostSession?> Function(AccountSession appSession)`  — Mints a host session for the signed-in account. Null when it could not.
- `Future<AgentsHostSession?> mintAgentsHostSession( AccountSession appSession, { http.Client? client, String? baseUrl, Dur …)`  — The production minter: one POST with the app's own bearer token.

### agents_install_flow.dart  (240 Z.)
- `typedef AgentsInstallClaimWaiter = Future<String?> Function( AgentsPairingInvite invite, { required DateTime deadline, r`  — Waits until the computer has parked on the invite's channel and claims it.
- `typedef AgentsInstallPairer = Future<void> Function(AgentsPairingInvite invite)`  — Runs the shared invite pairing and saves the trust. Throws on failure.
- `enum AgentsInstallPhase`
- `class AgentsInstallFlow extends ChangeNotifier`

### agents_install_ticket.dart  (245 Z.)
- const: kAgentsInstallTicketLifetime kAgentsInstallChannelLength kAgentsInstallDigitsLength _channelPattern _digitsPattern
- `@immutable class AgentsInstallTicket`  — A pending install: the token halves, when it was made, when it stops
- `String agentsInstallCommand(String token)`  — The command for [token]: the installer piped to bash, the token as its one
- `class AgentsInstallTicketStore`  — Keeps the one pending ticket in secure storage.

### agents_invite_pairing.dart  (111 Z.)
- `Future<AgentsStoredPairing?> pairAgentsFromInvite({ required AgentsRelayController controller, required AgentsPairingInv …)`  — Runs the whole invite pairing on [controller] and returns the trust it
- `Future<AgentsStoredPairing?> persistAgentsTrust({ required AgentsRelayController controller, required AgentsPairingStore …)`  — Saves the trust [controller] established, addressed at [hostUrl] when one

### agents_pairing.dart  (955 Z.)
- `enum AgentsPairingRole`  — Which side of the ceremony a session drives.
- `enum AgentsPairingState`  — Ordered lifecycle. Illegal transitions and any use after a terminal state
- `enum AgentsPairingRejection`  — Why a pairing step was refused. Every value is a hard stop.
- `class AgentsPairingException implements Exception`  — Thrown whenever a pairing step is refused, carrying a machine-readable
- `class AgentsPairingCrypto`  — Byte-exact protocol constants + pure crypto helpers, shared by both roles and
- `class AgentsPairing`  — A single-use pairing session state machine for one role.
- `int _wallClock()`
- `String _randomChannelId()`
- `String _randomDigits(int n)`
- `bool _isAllDigits(String s)`

### agents_pairing_restore.dart  (354 Z.)
- `enum AgentsPairingRestoreReason`  — Why the last restore pass ended the way it did. The shell reads it to say
- `class AgentsPairingRestore`  — Restores the account's pairing onto this device, and keeps trying until it

### agents_pairing_store.dart  (245 Z.)
- `abstract interface class AgentsSecureKeyValueStore`  — The minimal secure key/value surface the store needs. Backed by
- `class FlutterSecureKeyValueStore implements AgentsSecureKeyValueStore`  — Production backend over `flutter_secure_storage`.
- `class AgentsDeviceIdentity`  — The app's stable long-term device identity.
- `class AgentsStoredPairing`  — A persisted pairing: everything the app needs to reconnect with no code.
- `class AgentsPairingStore`  — Loads and saves the app's stable identity and single trust record.
- `class _PairingChanges extends ChangeNotifier`  — The store's change signal. The store lives as long as the shell that made

### agents_pairing_uri.dart  (202 Z.)
- const: kDefaultAgentsRelayBase kAgentsInstallScriptUrl kAgentsPairingUriScheme kAgentsPairingUriHost
- `class AgentsPairingInvite`  — A parsed pairing invite: what to claim, what to prove, where to dial.

### agents_permissions_service.dart  (347 Z.)
- const: kAgentPermissionsCapability
- `enum AgentWorkspaceMount`  — How the workspace is bound into the sandbox.
- `@immutable class AgentPermissions`  — One coworker's permissions. The defaults are the host's defaults.
- `typedef AgentsControlFrameSender = Future<void> Function( Map<String, dynamic> payload, )`  — Seals and sends one control frame to the host. Throws when nothing is
- `Future<void> _sendOverRelay(Map<String, dynamic> payload)`
- `class AgentsPermissionsService extends ChangeNotifier`  — The app's copy of the host's answers, per coworker.

### agents_queued_marks.dart  (168 Z.)
- `typedef QueuedMarkReader = List<Map<String, dynamic>>? Function(String sessionKey)`  — Reads and writes the transcript. Tests replace both.
- `typedef QueuedMarkWriter = Future<void> Function(String sessionKey, List<Map<String, dynamic>> rows)`
- `class AgentsQueuedMarks`

### agents_reconnect.dart  (453 Z.)
- `enum AgentsReconnectRole`  — Which side of the reconnect a session drives. Same naming as §15 pairing.
- `enum AgentsReconnectState`  — Ordered lifecycle. Any use after [authenticated] / [aborted] is refused.
- `enum AgentsReconnectRejection`  — Why a reconnect step was refused. Every value is a hard stop.
- `class AgentsReconnectException implements Exception`  — Thrown whenever a reconnect step is refused, carrying a machine-readable
- `class AgentsReconnectCrypto`  — Byte-exact protocol constants + pure helpers, shared by both roles and the
- `class AgentsReconnect`  — A single-use, code-free reconnect handshake state machine for one role.
- `SimplePublicKey agentsReconnectPeerKeyFromBase64(String encoded)`  — Parses a peer public key stored in a trust record. Delegates the length +

### agents_relay_client.dart  (3355 Z.)
- const: kReplayPageSize
- `abstract interface class RelaySocket`  — A minimal duplex socket seam: an inbound stream of text frames and a way to
- `typedef RelaySocketConnector = Future<RelaySocket> Function(Uri url)`  — Opens a [RelaySocket] to [url]. Default is [defaultRelaySocketConnector];
- `Future<RelaySocket> defaultRelaySocketConnector(Uri url)`  — Production connector.
- `class _WebSocketRelaySocket implements RelaySocket`
- `enum AgentsRelayPhase`  — Where the relay client is in its lifecycle. Drives the UI directly.
- `@immutable class AgentsRelayState`  — Immutable snapshot of the relay client state, exposed as a [ValueListenable].
- `sealed class AgentsRelayInbound`  — A decoded, opened frame delivered from the executor into the thread.
- `class AgentsRelayHeartbeat extends AgentsRelayInbound`  — The host says the run for [sessionKey] is still running (wire `heartbeat`).
- `class AgentsRelayTaskAck extends AgentsRelayInbound`  — The host says what it did with one `task` frame (wire `task_ack`).
- `class AgentsRelayDelta extends AgentsRelayInbound`  — An assistant text delta.
- `class AgentsRelayUser extends AgentsRelayInbound`  — A user turn, only ever produced by a transcript replay (the server is the
- `class AgentsRelayReasoning extends AgentsRelayInbound`  — A reasoning delta — the model's thinking, which is a separate channel from
- `DateTime? epochSecondsToDateTime(Object? value)`  — A host clock value (unix seconds, float) as a local [DateTime]. Null for
- `class AgentsRelayTool extends AgentsRelayInbound`  — One tool call that ran, as reported by the executor.
- `class AgentsRelayFile extends AgentsRelayInbound`  — A file the agent produced and pushed into the thread (§9,
- `class AgentsRelayDone extends AgentsRelayInbound`  — The run finished. The executor reports why, and how many rounds it took.
- `class AgentsRelayRunState extends AgentsRelayInbound`  — The host's answer to a `replay`: is a run for this session in flight right
- `class AgentsRelaySubagent extends AgentsRelayInbound`  — A child agent's lifecycle step (§7.6). Only state transitions surface here —
- `class AgentsRelayAutomation extends AgentsRelayInbound`  — One state change of an automation (docs/WIRE_CONTRACT.md, "Automations"):
- `class AgentsRelayAutomationList extends AgentsRelayInbound`  — The host's answer to an `automation_list` request: every automation of
- `class AgentsRelaySkillsList extends AgentsRelayInbound`  — The host's answer to a `skills_list` request or a `skill_control`
- `@immutable class AgentsRelayAgentStatus`  — What one coworker runs on, has spent and how long it has worked
- `@immutable class AgentsHostAgentName`  — One coworker name the host keeps for this pairing (bead cowork-817,
- `class AgentsRelayAgentList extends AgentsRelayInbound`  — The host's `agent_list`: every coworker name it keeps, sent once per attach
- `class AgentsRelayRoomTurn extends AgentsRelayInbound`  — One member's turn in a group room (§16.1). Streamed live as the room talks.
- `class AgentsRelayRoomDone extends AgentsRelayInbound`  — A group-room exchange ended. [reason] is a raw stop string from the host
- `class AgentsRelayRoomHistory extends AgentsRelayInbound`  — A room's stored transcript, replayed on request (§16.1). Replaces whatever
- `class AgentsRelayRunError extends AgentsRelayInbound`  — The executor reported an error.
- `class AgentsRelayDebugContext extends AgentsRelayInbound`  — The raw context the executor sent to the model for one round, echoed back
- `class AgentsRelayBrowserData extends AgentsRelayInbound`  — One raw RFB byte chunk of the live browser view (§9.1). Opaque on purpose —
- `class AgentsRelayBrowserView extends AgentsRelayInbound`  — Status of the live browser view: `started`, `stopped`, or `error` (§9.1).
- `class AgentsRelayApprovalRequest extends AgentsRelayInbound`  — The executor is asking the user to approve one here.now publish before it
- `class AgentsRelaySecretRequest extends AgentsRelayInbound`  — The model asked for secrets by name (`request_secrets`) and the run is
- `abstract interface class AgentsRelayController`
- `class AgentsRelayDocuments extends AgentsRelayInbound`  — The real transport. Also an [ExecutorTransport]: [provisionAccount] shapes
- `abstract interface class AgentsDocumentsControl`
- `abstract interface class AgentsAgentStatusControl`  — Asks the host what a coworker runs on and what it has spent
- `class AgentsRelayClient implements AgentsRelayController, ExecutorTransport, AgentsAutomationControl, AgentsDocumentsCon …)`

### agents_relay_link.dart  (89 Z.)
- `class AgentsRelayLink`  — Process-wide singleton joining the relay transport to the imported chat UI.

### agents_replay_guard.dart  (89 Z.)
- `class AgentsReplayGuard`  — Replay protection for one peer device: a strictly monotonic `seq` inside a

### agents_replay_loader.dart  (950 Z.)
- const: kReplayCursorPrefix kReplayTimestampCursorPrefix kReplayRepeatRepairKey
- `class _Draft`  — One session's in-progress replay fold.
- `class AgentsReplayLoader extends ChangeNotifier`  — Folds the host's replay stream into the local instant-paint cache.

### agents_run_ledger.dart  (955 Z.)
- `ToolCall toolCallFromRelay(AgentsRelayTool event, {DateTime? now})`  — The renderer's shape of one host `tool` frame.
- `enum AgentsRunOutcome`  — How a run ended, once it is over.
- `AgentsRunOutcome agentsRunOutcomeFor({String? reason, String? finalAnswer})`  — What a run terminal means for the thread, from the two fields that say it.
- `String? agentsRunEndNotice(AgentsRunOutcome outcome)`  — The one quiet line a run that produced nothing leaves in the thread. Null
- `class AgentsRun`  — Everything one run produced, in renderer shapes.
- `ToolCall subagentCallFromRelay( ToolCall? existing, { required String subagentId, required String title, required String …)`  — Process-wide ledger of host runs, keyed by session key.
- `ContentBlock artifactBlockFromFile(String storagePath, AgentsRelayFile file)`  — The renderer's shape of one relayed file, once its bytes are in the local
- `ToolCall approvalCallFromRelay( AgentsRelayApprovalRequest request, { bool decided = false, DateTime? now, })`  — The renderer's shape of a here.now publish approval, as a completed
- `class AgentsRunLedger extends ChangeNotifier`

### agents_shell_status.dart  (129 Z.)
- `enum AgentsLinkState`  — The link as the thread view sees it.
- `@immutable class AgentsLinkReport`  — One snapshot of the link, published by the thread view for the shell.
- `enum AgentsShellStatus`  — What the shell shows in place of a conversation.
- `AgentsShellStatus resolveAgentsShellStatus({ required AgentsLinkReport link, required AgentsPairingRestoreReason restore …)`  — Resolves the one status the shell shows.

### agents_task_outbox.dart  (637 Z.)
- const: kTaskOutboxPrefix kPendingTaskPrefix
- `@immutable class OutboxTask`  — One prompt waiting for a socket.
- `class AgentsTaskOutbox`  — Reads and writes the per-thread queue. Static because there is one queue
- `@immutable class PendingTask`  — One task the socket took, still waiting for the host's `task_ack`.
- `class AgentsPendingTasks`  — Tasks the socket accepted but the host has not acknowledged.

### agents_tool_call_handler.dart  (160 Z.)
- `class AgentsToolCallHandler implements ToolCallHandler`  — The Agents fold: one pass per turn, no client-side tool dispatch.

### agents_voice_call_frames.dart  (101 Z.)
- `abstract interface class AgentsVoiceCallControl`  — The app → host half: a transport that can send a `voice_call_state`.
- `class AgentsVoiceCallFrames`  — The process-wide router of the voice-call control frames.

### browser_presence.dart  (269 Z.)
- const: kBrowserPresenceFreshness
- `class BrowserPresence extends ValueNotifier<bool>`  — Whether the host explicitly offers a viewable sandbox browser.

### chat_debug_export.dart  (307 Z.)
- `abstract final class ChatDebugExport`  — Builds and copies the structured debug export for one thread.

### media_index.dart  (236 Z.)
- `enum MediaKind`  — What kind of thing an entry points at.
- `@immutable class MediaEntry`  — One thing a coworker handed over.
- `List<Object?> contentBlocksOf(Map<String, dynamic> row)`  — The content blocks of a stored row.
- `class MediaIndex extends ChangeNotifier`

### room_source.dart  (214 Z.)
- `abstract class RoomSource extends ChangeNotifier`  — Read/write access to the app's rooms, as a [ChangeNotifier] the UI listens to.
- `class LocalRoomSource extends RoomSource`  — In-memory room source.

### schedule_spec.dart  (504 Z.)
- `enum ScheduleKind`  — The four schedule shapes Agents accepts.
- `class ScheduleFormatException implements Exception`  — Thrown when a schedule string cannot be read.
- `@immutable class ScheduleSpec`  — A parsed schedule, plus the calculation of when it fires next.
- `@immutable class _CronField`  — One field of a cron expression, expanded into the values it matches.
- `@immutable class _CronSchedule`  — A parsed 5-field cron expression and the forward scan over it.

### supabase_pairing_sync.dart  (215 Z.)
- `class SupabasePairingSync`  — Reads and writes the encrypted trust-record mirror in Supabase.
- `enum AgentsCloudPairingOutcome`  — How a read of the encrypted mirror ended.
- `@immutable class AgentsCloudPairingRead`  — One read of the encrypted mirror: the record, or why there is none.

### thread_preview_store.dart  (267 Z.)
- `@immutable class ThreadPreview`  — One thread's last line.
- `List<Object?> contentBlocksOf(Map<String, dynamic> row)`  — The content blocks of a stored row.
- `class ThreadPreviewStore extends ChangeNotifier`

## lib/services/automations
### agents_automation.dart  (203 Z.)
- `@immutable class AgentsAutomation`  — One automation of a coworker: a schedule (cron / every / at) or a watcher
- `abstract interface class AgentsAutomationControl`  — The two frames the app sends about automations. Kept apart from

### automation_ledger.dart  (74 Z.)
- `ToolCall automationCallFromRelay( ToolCall? existing, AgentsRelayAutomation event, { DateTime? now, })`  — The transcript line of one automation: ONE [ToolCall] per automation id,
- `String automationEventText(AgentsRelayAutomation event)`  — One line of English for an automation event, for the transcript card.

### automations_source.dart  (190 Z.)
- `class AutomationsSource extends ChangeNotifier`  — The app's copy of the host's automations, kept current from the relay.

## lib/services/herenow
### herenow_store.dart  (104 Z.)
- `enum HereNowApproval`  — Whether a public publish must be approved each time (`ask`, the default and
- `@immutable class HereNowSettings`  — The connector's settings: on/off and the approval mode.
- `class HereNowStore`

## lib/services/mcp
### chuk_mcp_mirror.dart  (187 Z.)
- `@immutable class ChukMcpRow`  — One chuk row, decrypted: the connection as JSON and its secrets, if any.
- `abstract interface class ChukMcpMirror`
- `class NoopChukMcpMirror implements ChukMcpMirror`
- `class ChukMcpSync implements ChukMcpMirror`

### mcp_availability.dart  (33 Z.)
- `List<McpCatalogueEntry> unconnectedCatalogueEntries()`  — Every catalogue server the reader has NOT connected yet, in catalogue
- `McpCatalogueEntry? catalogueEntryById(String id)`  — The catalogue entry with this [id]. Null when no catalogue entry uses the

### mcp_catalogue.dart  (982 Z.)
- const: kBundledMcpIcons kMcpCategories kMcpCatalogue
- `class McpCredentialField`  — One credential a server takes on its URL instead of through a browser
- `class McpCatalogueEntry`  — A connector as offered to the reader.
- `String? bundledIconAsset(String id)`  — The bundled logo path for [id], or null when no logo ships for it. The
- `List<McpCatalogueEntry> firstPartyConnectors()`  — Connectors our own API server fronts.
- `String? namespaceDomain(String serverName)`  — The domain a registry namespace stands for: `com.notion` → `notion.com`.
- `bool isFirstPartyRemote(String serverName, String remoteUrl)`  — Whether [remoteUrl] is served by the same domain that publishes
- `bool _isCurrentRegistryEntry(Object? meta)`  — Whether the registry still stands behind this entry — `active`, and the
- `Future<List<McpCatalogueEntry>> searchMcpRegistry( String query, { http.Client? httpClient, int limit = 20, bool firstPa …)`  — Search the official MCP registry for anything not in the catalogue.
- `String slugFor(String nameOrUrl)`  — A short, stable id for a server: used to prefix its tool names, so two

### mcp_client.dart  (352 Z.)
- const: kMcpProtocolVersion
- `class McpUnauthorized implements Exception`  — Thrown when the server wants a token. [wwwAuthenticate] carries the
- `class McpException implements Exception`  — Any other failure: transport, HTTP status, or a JSON-RPC error.
- `class McpServerInfo`  — What a server says about itself in the initialize result.
- `class McpTool`  — One tool a server offers.
- `class McpCallResult`  — The outcome of a tools/call: the text the model gets, plus whether the
- `class McpClient`

### mcp_connection.dart  (216 Z.)
- `enum McpAuth`  — How a connection proves who it is.
- `class McpTool`  — One tool a server offers. Kept minimal because Agents discovers the live
- `class McpConnection`  — A configured MCP server. The non-secret config; the token or the API

### mcp_connector_sync.dart  (142 Z.)
- `class McpConnectorSync`  — Reads and writes the encrypted connector mirror in Supabase.

### mcp_icon_cache.dart  (122 Z.)
- `class McpIconCache`

### mcp_oauth.dart  (511 Z.)
- `class McpAuthServer`  — What a server's authorization looks like once discovered.
- `class McpClientCredentials`  — The client id (and secret, if the server insists on one) we registered.
- `class McpTokens`  — The tokens a server issued.
- `class McpAuthException implements Exception`
- `class McpAuthorizationRequest`  — One authorization attempt, kept together so the verifier, the state and
- `class McpOAuth`

### mcp_probe_control.dart  (17 Z.)
- `abstract interface class McpProbeControl`

### mcp_redirect.dart  (12 Z.)
- reicht weiter: 'mcp_redirect_stub.dart' if (dart.library.io) 'mcp_redirect_io.dart'

### mcp_redirect_io.dart  (62 Z.)
- `class McpRedirectListener`  — A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.

### mcp_redirect_stub.dart  (23 Z.)
- `class McpRedirectListener`

### mcp_service.dart  (1312 Z.)
- const: kMcpProtocolVersion
- `enum McpConnectStatus`  — What a connect attempt ended in, for the UI to show.
- `class McpConnectCanceler`  — A handle the screen keeps so it can stop a connect. On Agents the connect
- `class _ConnectCanceled implements Exception`  — Thrown inside [McpService] when the user cancels the sign-in. Private: it
- `class McpConnectResult`
- `class McpService`

### mcp_store.dart  (592 Z.)
- `class McpSecrets`  — Everything secret about one connection: the client this device registered
- `class McpListBackend`  — Where [McpStore] keeps the connection list: the SQLite kv_cache by
- `class McpStore`

### mcp_support_dir.dart  (11 Z.)
- reicht weiter: 'mcp_support_dir_stub.dart' if (dart.library.io) 'mcp_support_dir_io.dart'

### mcp_support_dir_io.dart  (21 Z.)
- `Future<String?> mcpSupportDirPath()`  — The absolute path of the app support directory on a native build.
- `Future<void> mcpDeleteDir(String path)`  — Delete the directory at [path] and everything under it. Native-only, so the

### mcp_support_dir_stub.dart  (12 Z.)
- `Future<String?> mcpSupportDirPath()`  — Null on web: there is no disk support directory to cache into.
- `Future<void> mcpDeleteDir(String path)`  — No-op on web: there is no disk cache directory to delete.

### mcp_sync_service.dart  (44 Z.)
- `class McpSyncService`

### mcp_tool_bridge.dart  (59 Z.)
- `void syncMcpTools(ToolExecutor executor)`  — Register the tools of every connected server, replacing whatever was
- `void watchMcpConnections(ToolExecutor executor)`  — Keep an executor in step with the connections for as long as it lives.
- `List<String> _tagsFor(String serverName, String id, String toolName)`  — What `find_tools` matches on: the server, and the words of the tool name.

## lib/services/notifications
### agents_notifications.dart  (106 Z.)
- `typedef ThreadLabelResolver = String Function(String sessionKey)`  — Resolves the label a toast carries for a thread — the coworker's name.
- `class AgentsNotifications`

### local_notifications.dart  (327 Z.)
- const: kAgentsNotificationChannelId kAgentsNotificationChannelName kAgentsNotificationChannelDescription kAgentsNotificationIconAsset
- `abstract class LocalNotificationsBackend`  — What the service needs from the platform. The real one wraps
- `class LocalNotifications`
- `class _PluginBackend implements LocalNotificationsBackend`  — The real backend: `flutter_local_notifications` on Android, iOS, macOS

### notification_router.dart  (79 Z.)
- `@immutable class NotificationTarget`
- `class NotificationRouter`

### push_service.dart  (353 Z.)
- `@immutable class PushMessage`  — A push message as the service sees it: only the `data` map matters.
- `abstract class PushTransport`  — What the service needs from the push provider. [FirebasePushTransport]
- `abstract class DeviceTokenStore`  — The `cowork_device_tokens` row.
- `class PushService`
- `class SupabaseDeviceTokenStore implements DeviceTokenStore`  — `cowork_device_tokens` over the Supabase client (RLS: own rows only).
- `class FirebasePushTransport implements PushTransport`  — Firebase Cloud Messaging. Only Android and iOS carry a push; everywhere
- `@pragma('vm:entry-point') Future<void> agentsPushBackgroundHandler(RemoteMessage message)`  — Runs in a background isolate when a push arrives while the app is not

### run_notifications.dart  (98 Z.)
- `typedef RunNotificationsWriter = Future<void> Function({ required String userId, String? sessionKey, String? runId, requ`  — Test seam: how a consume is written. The default talks to Supabase.
- `class RunNotifications`

## lib/services/secrets
### secrets_service.dart  (171 Z.)
- `typedef SecretsHostSink = Future<void> Function(SecretsSet set, {String? requestId})`  — Where a `secrets` frame goes. Defaults to the link's bound controller.
- `class SecretsService`

### secrets_store.dart  (162 Z.)
- `@immutable class SecretsSet`  — A snapshot of the set: the values and the revision they belong to.
- `class SecretsStore`

### secrets_sync.dart  (127 Z.)
- `abstract interface class SecretsMirror`  — The pluggable half, so a test and a signed-out app can swap it out.
- `class NoopSecretsMirror implements SecretsMirror`  — A mirror that does nothing. The default before sign-in and in tests.
- `class SecretsSync implements SecretsMirror`

## lib/services/settings
### debug_settings.dart  (41 Z.)
- `abstract final class DebugSettings`  — Reads and writes the developer debug toggles, so the settings page and the

### embedding_model_service.dart  (90 Z.)
- `class EmbeddingModelService`  — The embedding model the host uses for semantic memory (Mem0).
- `@immutable class EmbeddingModelOption`  — One embedding-model choice: an id, a display name, and its vector size.

### mobile_chat_preferences.dart  (64 Z.)
- `class MobileChatPreferences extends ChangeNotifier`  — Mobile presentation only. Never changes the model's reasoning effort or

### theme_controller.dart  (60 Z.)
- `class ThemeController extends ValueNotifier<ThemeMode>`  — The app's theme mode, persisted so the choice survives a restart.

### verbose_service.dart  (82 Z.)
- `class VerboseService extends ChangeNotifier`  — The persisted verbose-view switch, as a [ChangeNotifier] singleton.

## lib/services/skills
### agents_skill.dart  (94 Z.)
- `@immutable class AgentsSkill`  — One skill as the host lists it (docs/WIRE_CONTRACT.md, "Skills").
- `abstract interface class AgentsSkillsControl`  — The two frames the app sends about skills. Kept apart from

### skill_frontmatter_parser.dart  (241 Z.)
- const: _kSpecFields _kNamePattern _kFrontmatterPattern
- `class SkillParseException implements Exception`  — Thrown when a SKILL.md violates the spec.
- `Skill parseSkillMarkdown( String source, { String? expectedName, SkillSource skillSource = SkillSource.builtin, })`  — Parses [source] (the full contents of a SKILL.md) into a [Skill].
- `Map<String, String> _parseMetadata(YamlMap parsed)`
- `List<String> _parseAllowedTools(YamlMap parsed)`
- `String _requireString(YamlMap parsed, String field)`
- `String? _optionalString(YamlMap parsed, String field)`

### skill_registry.dart  (115 Z.)
- `class SkillRegistry`

### skill_settings_sync.dart  (88 Z.)
- `abstract interface class SkillSettingsMirror`
- `class NoopSkillSettingsMirror implements SkillSettingsMirror`
- `class SkillSettingsSync implements SkillSettingsMirror`

### skills_catalog_service.dart  (418 Z.)
- `class CatalogSkill`  — One entry in the catalog manifest.
- `class LocalSkillState`  — The local state the reconciler needs about one stored catalog skill.
- `class SkillUpdateSuggestion`  — An edited skill whose catalog version moved — the user is asked, never
- `class ReconcilePlan`  — The outcome of a reconcile: what to add, silently update, and suggest.
- `ReconcilePlan planCatalogReconcile({ required List<CatalogSkill> catalog, required Map<String, LocalSkillState> localByC …)`  — Pure reconciliation: decide what to do with each catalog entry given the
- `class SkillsCatalogService`

### skills_source.dart  (152 Z.)
- `class SkillsSource extends ChangeNotifier`  — The app's copy of the host's skill list, kept current from the relay.

### user_skills_service.dart  (412 Z.)
- `class UserSkillException implements Exception`  — Thrown for storage-level failures. Spec violations surface as
- `class UserSkillsService`

## lib/services/storage
### agents_chat_cache_migration.dart  (224 Z.)
- const: kReplayCursorPrefsPrefix kMigratedSuffix
- `typedef AgentsThreadWriter = Future<StoredChat?> Function( String sessionKey, List<Map<String, dynamic>> rows, { DateTim`
- `class AgentsChatCacheMigration`

### agents_chat_storage_bootstrap.dart  (267 Z.)
- `class AgentsChatStorageBootstrap`

### agents_chat_store.dart  (1479 Z.)
- const: kAgentsChatsTable _kReplayCursorPrefix kCloudOutboxPrefix kLastCacheUserKey _kFullColumns
- `typedef AgentsCloudUpsert = Future<Map<String, dynamic>?> Function( String userId, Map<String, dynamic> row, )`  — Signature of the cloud upsert. Injectable so the store is testable with no
- `typedef AgentsCloudSelect = Future<List<Map<String, dynamic>>> Function( String userId, { List<String>? ids, required St`  — Signature of a cloud read of [kAgentsChatsTable]. [ids] null reads every
- `@immutable class AgentsCloudThread`  — One Agents thread of the cloud, decrypted: what a password change re-seals.
- `class AgentsChatStore`
- `class _LocalCopy`
- `class _CloudRow`  — One decrypted `cowork_chats` row.

### chat_origin.dart  (77 Z.)
- `class ChatOrigin`

## lib/theme
### theme_presets.dart  (365 Z.)
- const: kThemePresets
- `@immutable class ThemeVariant`  — One complete look: palette + contrast + font, for a single brightness.
- `@immutable class ThemePreset`  — A named pack with a light and a dark variant.

## lib/tool_handlers
### artifact_tools.dart  (204 Z.)
- const: _requestTimeout
- `String _formatSuccess(Map<String, dynamic> data)`  — Builds the human/model-readable success string from a service response.
- `String _formatError(int statusCode, String body)`  — Maps a non-200 status code to a clear, actionable message.
- `String? _baseUrlError(String baseUrl)`  — Validates the configured base URL before any credential is sent. The Bearer
- `Map<String, dynamic> _buildBody(Map<String, dynamic> args, String html)`
- `Future<String> executeCreateArtifact({ required Map<String, String> serverHeaders, required Map<String, dynamic> args, } …)`  — Publish a new self-contained HTML page. Returns a public shareable URL.
- `Future<String> executeUpdateArtifact({ required Map<String, String> serverHeaders, required Map<String, dynamic> args, } …)`  — Replace the HTML of a previously created artifact. Returns its public URL.

### calculate_handler.dart  (317 Z.)
- `String executeCalculate(Map<String, dynamic> args)`  — Calculator tool with full expression parsing.
- `String _evalExpression(String raw)`  — Evaluate a math expression using a simple recursive descent parser.
- `class _ExprParser`  — Simple recursive descent parser for math expressions.
- `String _formatNum(num value)`  — Format a number: strip trailing .0 for integers.
- `num _toNum(dynamic v)`  — Safely convert dynamic to num.

### chat_search_tools.dart  (813 Z.)
- const: _defaultChatLimit _maxChatLimit _defaultMessageLimit _maxMessageLimit _snippetRadius _minLocalScanChats _maxLocalScanChats _localScanMultiplier _previewSnippetsTop _previewSnippetsRest _topCandidatesWithPreview _defaultRecentLimit _maxRecentLimit _recentSnippetChars _actionFindChats _actionSearchInChat _actionRecentMessages _validRoles
- `Future<String> executeSearchChats(Map<String, dynamic> args)`
- `String? _resolveAction(dynamic rawAction, {required String chatId})`
- `String? _normalizeRole(dynamic raw)`
- `Future<String> _findChats({required String query, required int limit})`
- `_ChatCandidate? _candidateFromStoredChat(StoredChat chat, String queryLower)`
- `_ChatCandidate? _candidateFromCacheRow( Map<String, dynamic> row, String queryLower, )`
- `Future<String> _searchInChat({ required String query, required String chatId, required int messageLimit, })`
- `Future<String> _recentMessages({ required String chatId, required int limit, required String role, })`
- `String _renderMessageText(ChatMessage message)`
- `Future<_LoadedChatContent?> _loadChatContent(String chatId)`
- `_ParsedPayload? _parsePayload(String? payload)`
- `Map<String, dynamic> _coerceStringMap(Map raw)`
- `DateTime _rowTimestamp(Map<String, dynamic> row)`
- `DateTime? _parseDate(dynamic value)`
- `_MessageMatchSummary _summarizeMatches( List<ChatMessage> messages, String queryLower, )`
- `_MessageMatch? _buildMessageMatch({ required ChatMessage message, required String queryLower, required int index, })`
- `List<_SearchField> _messageFields(ChatMessage message)`
- `String _rowTitle( Map<String, dynamic> row, List<ChatMessage>? messages, { String? customName, })`
- `String _chatTitle(StoredChat chat, [List<ChatMessage>? messages])`
- `String _titleFromMessages(List<ChatMessage>? messages)`
- `String _extractSnippet(String text, String queryLower)`
- `void _upsertCandidate( Map<String, _ChatCandidate> candidatesById, _ChatCandidate candidate, )`
- `int _compareCandidates(_ChatCandidate a, _ChatCandidate b)`
- `String _formatChatCandidates({ required String query, required int totalSearched, required List<_ChatCandidate> candidat …)`
- `String _formatChatDetails({ required String query, required String chatId, required String title, required int messageCo …)`
- `int _coerceInt(dynamic value, {required int fallback})`
- `class _LoadedChatContent`
- `class _ParsedPayload`
- `class _SearchField`
- `class _MessageMatchSummary`
- `class _ChatCandidate`
- `class _MessageMatch`
- `class _RecentMessageEntry`

### find_tools_handler.dart  (343 Z.)
- const: companions
- `void _appendToolDefinition( StringBuffer buf, ClientTool tool, String Function(String) getDescription, )`
- `String executeFindTools({ required Map<String, dynamic> args, required Map<String, ClientTool> tools, required String Fu …)`  — Find tools by keyword/query. Returns full tool definitions for matching
- `String _mcpConnectHints( List<String> queryWords, List<McpCatalogueEntry> unconnected, )`  — Lines describing not-connected catalogue servers whose id / name / category

### image_tools.dart  (253 Z.)
- const: imageModelDisplayNames
- `Future<String> _generateImageRequest({ required String? serverHttpUrl, required String? accessToken, required String end …)`  — Shared helper: send a multipart POST to an image generation endpoint
- `Future<String> executeGenerateImage({ required String? serverHttpUrl, required String? accessToken, required Map<String …)`  — Single image generation/editing tool. `args['model']` selects the
- `Future<String> executeFetchImage( Map<String, dynamic> args, { http.Client? client, })`
- `String executeViewChatImagesUnsupported()`
- `String _detectMimeType({required String contentType, required String url})`

### map_tools.dart  (660 Z.)
- const: _networkTimeout _nominatimBaseUrl _osrmBaseUrl _defaultHeaders kMaxPlacesOnMap
- `class PlacesToolResult`  — What a places lookup produces: the text the model reads, and the map
- `String? buildPlacesMapTag({ required List<Map<String, dynamic>> places, required String title, int max = kMaxPlacesOnMap …)`  — Build the `<map>` block for [places], or null when none can be pinned.
- `double? _asDouble(Object? value)`
- `Future<String> executeSearchPlaces({ required String? serverHttpUrl, required Map<String, String> serverHeaders, require …)`  — Search places via server-side Brave Local proxy.
- `Future<PlacesToolResult> searchPlacesWithMap({ required String? serverHttpUrl, required Map<String, String> serverHeader …)`  — Search places via the server-side Brave Local proxy, and build the map
- `Future<String> executeSearchRestaurants({ required String? serverHttpUrl, required Map<String, String> serverHeaders, re …)`  — Text-only form, kept for callers that do not render a map card.
- `Future<PlacesToolResult> searchRestaurantsWithMap({ required String? serverHttpUrl, required Map<String, String> serverH …)`  — Search restaurants via the server-side Brave Local proxy, and build the
- `Future<String> executeGeocode( Map<String, dynamic> args, { http.Client? client, })`  — Forward / reverse geocoding via Nominatim (kept; no server proxy).
- `Future<String> executeGetRoute( Map<String, dynamic> args, { http.Client? client, })`
- `Future<List<Map<String, dynamic>>> _fetchBravePlaces({ required String baseUrl, required Map<String, String> serverHeade …)`
- `String _formatBravePlaces({ required String heading, required List<Map<String, dynamic>> places, })`
- `Future<List<Map<String, dynamic>>> _searchNominatim({ required http.Client client, required String query, required int l …)`
- `String _extractCountry(Map<String, dynamic> args)`
- `String _extractLang(Map<String, dynamic> args)`
- `String _buildInstruction({ required Map<String, dynamic> maneuver, required String roadName, })`
- `String _formatDistance(double meters)`
- `double? _coerceDouble(dynamic value)`
- `int _coerceInt(dynamic value, {required int fallback})`
- `String _asString(dynamic value)`  — Coerce a JSON-decoded value to a String. Server tools normally hand back

### notes_tools.dart  (926 Z.)
- const: _notesPrefsKey _memoryPrefsKey _soulPrefsKey _userInfoPrefsKey _identityEnabledKey _identitySoulColumn _identityUserColumn _identityMemoryColumn _identityEnabledColumn _legacyPreferencesColumn _selectedModelColumn _fallbackSelectedModelId _identitySyncCacheTtl _cachedIdentityRow _cachedIdentityUserId _cachedIdentityFetchedAt _identityRowInFlight
- `String? _safeCurrentUserId()`
- `Session? _safeCurrentSession()`
- `void _resetIdentityCacheForUser(String? userId)`
- `void _invalidateIdentityCache()`
- `Future<Map<String, dynamic>?> _loadIdentityRowFromSupabase({ bool forceRefresh = false, })`
- `void _mergeIdentityCache(String userId, Map<String, dynamic> updates)`
- `String _identitySyncedMarkerKey(String localKey)`
- `Future<bool> _upsertIdentityFields(Map<String, dynamic> fields)`
- `Future<String?> _resolveSelectedModelIdForUpsert(String userId)`
- `Future<bool> _upsertIdentityFieldsLegacy( String userId, Map<String, dynamic> fields, )`
- `Future<String?> _decryptIdentityValue( dynamic encryptedValue, { required String column, })`
- `Future<String> _loadIdentityText({ required String localKey, required String remoteColumn, String? localOverride, })`
- `bool _isMissingIdentityColumnsError(PostgrestException error)`
- `bool _isMissingLegacyPreferencesError(PostgrestException error)`
- `Map<String, dynamic> _extractLegacyPreferencesMap(dynamic rawPreferences)`
- `bool? _coerceIdentityEnabled(dynamic raw)`
- `Future<Map<String, dynamic>?> _loadIdentityRowFromLegacyPreferences( String userId, )`
- `Future<void> _saveIdentityText({ required String localKey, required String remoteColumn, required String text, })`
- `Future<String> _loadLocalMemoryText(SharedPreferences prefs)`
- `Future<bool> isIdentityEnabled()`  — Whether the identity system (Soul / User / Memory) is active.
- `Future<void> setIdentityEnabled(bool value)`  — Persist the identity system toggle.
- `Future<void> syncIdentityFromSupabase({bool forceRefresh = false})`  — Sync identity data (Soul/User/Memory/toggle) from Supabase into
- `Future<String> executeNotes(Map<String, dynamic> args)`
- `String _buildDiffResult( String type, String title, String before, String after, )`  — Builds a <diff> visual block showing what changed.
- `List<ArtifactEdit>? _parseEdits(dynamic rawEdits)`  — Parse `edits` arg into a list of [ArtifactEdit].
- `Future<String> loadSoulText()`  — Load Soul text. Public for system prompt injection.
- `Future<void> saveSoulText(String text)`  — Save Soul text. Called from settings UI.
- `Future<String> loadUserInfoText()`  — Load User info text. Public for system prompt injection.
- `Future<void> saveUserInfoText(String text)`  — Save User info text. Called from settings UI or AI tool.
- `Future<String> _updateUserInfo(Map<String, dynamic> args)`  — AI action: update the user info text.
- `Future<String> _patchUserInfo(Map<String, dynamic> args)`  — AI action: apply targeted edits to the user info text.
- `Future<String> loadMemoryText()`  — Load Memory text, with one-time migration from legacy key-value store.
- `Future<void> saveMemoryText(String text)`  — Save Memory text. Called from settings UI.
- `Future<String> _updateMemory(Map<String, dynamic> args)`  — AI action: update the memory text.
- `Future<String> _patchMemory(Map<String, dynamic> args)`  — AI action: apply targeted edits to the memory text.
- `Future<String> _updateSoul(Map<String, dynamic> args)`  — AI action: update the soul (personality) text.
- `Future<String> _patchSoul(Map<String, dynamic> args)`  — AI action: apply targeted edits to the soul text.
- `Future<Map<String, String>> loadAllNotes()`  — Load all saved notes. Public so the system prompt builder can inject them.
- `Future<void> _persistNotes(Map<String, String> notes)`
- `Future<String> _saveNote(Map<String, dynamic> args)`
- `Future<String> _getNote(Map<String, dynamic> args)`
- `Future<String> _listNotes()`
- `Future<String> _deleteNote(Map<String, dynamic> args)`
- `Future<String> _clearNotes()`

### platform_tools.dart  (7 Z.)
- reicht weiter: 'platform_tools_stub.dart' if (dart.library.io) 'platform_tools_native.dart'

### platform_tools_native.dart  (766 Z.)
- const: _bashSandbox _gitHubOAuth _slackOAuth _googleOAuth _deviceServices _approvalConfig connectableServices
- `Future<void> initPlatformServices()`  — Initialize platform services — loads saved tokens/configs.
- `bool isPlatformServiceConnected(String service)`  — Check if a platform service is connected.
- `Future<bool> connectPlatformService(String service)`  — Start the OAuth flow for a service. Returns true on success.
- `Future<void> disconnectPlatformService(String service)`  — Disconnect a service by clearing its stored tokens.
- `Future<void> setBashSandboxFolder(String path)`  — Folder the local bash tool is confined to, null while unset.
- `Future<void> clearBashSandboxFolder()`  — Forget the sandbox folder; bash commands are refused until a new one is set.
- `Future<String> executeBash(Map<String, dynamic> args)`
- `Future<String> executeGitHub(Map<String, dynamic> args)`
- `Future<String> executeSlack(Map<String, dynamic> args)`
- `Future<String> executeGoogleCalendar(Map<String, dynamic> args)`
- `Future<String> executeGmail(Map<String, dynamic> args)`
- `Future<String> executeDevice(Map<String, dynamic> args)`
- `Future<String> executeCalendar(Map<String, dynamic> args)`
- `Future<String> executeReminder(Map<String, dynamic> args)`
- `Future<String> executeDraftEmail(Map<String, dynamic> args)`

### platform_tools_stub.dart  (58 Z.)
- const: connectableServices
- `Future<void> setBashSandboxFolder(String path)`  — The local bash sandbox is desktop-only; on web there is no folder.
- `Future<void> clearBashSandboxFolder()`
- `Future<String> executeBash(Map<String, dynamic> args)`
- `Future<String> executeGitHub(Map<String, dynamic> args)`
- `Future<String> executeSlack(Map<String, dynamic> args)`
- `Future<String> executeGoogleCalendar(Map<String, dynamic> args)`
- `Future<String> executeGmail(Map<String, dynamic> args)`
- `Future<String> executeDevice(Map<String, dynamic> args)`
- `Future<String> executeCalendar(Map<String, dynamic> args)`
- `Future<String> executeReminder(Map<String, dynamic> args)`
- `Future<void> initPlatformServices()`  — Initialize platform services (no-op on web).
- `bool isPlatformServiceConnected(String service)`  — Check if a platform service is connected (always false on web).
- `Future<bool> connectPlatformService(String service)`  — Start the OAuth flow for a service (not available on web).
- `Future<void> disconnectPlatformService(String service)`  — Disconnect a service (no-op on web).

### qr_tools.dart  (61 Z.)
- `Future<String> executeGenerateQr(Map<String, dynamic> args)`  — Generate a QR code locally using pretty_qr_code — no network call, fully

### typst_tools.dart  (281 Z.)
- const: _deliveryNote _orphanFillPctThreshold
- `class TypstCompileResult`  — Result of a Typst compile: the rendered bytes plus optional layout
- `Future<TypstCompileResult> compileTypstToPdf({ required String serverHttpUrl, required String? accessToken, required Str …)`  — Compile Typst source via the backend. Returns the rendered bytes and
- `class _TypstCompileError implements Exception`
- `Future<String> executeTypstCompile({ required String? serverHttpUrl, required String? accessToken, required String? chat …)`  — Tool handler: validate the Typst source by compiling it, then create a
- `class TypstLayoutSnapshot`  — Snapshot of a compiled Typst PDF's layout (page count + last-page
- `TypstLayoutSnapshot? _layoutFromHeaders(Map<String, String> headers)`  — Parses layout headers the server attaches to every PDF compile:
- `String _layoutGuidance(TypstLayoutSnapshot? layout)`  — Builds the layout suffix appended to the tool result string. Always
- `String _compileErrorGuidance(String compilerError)`  — Wraps a Typst compile error so the AI sees both the compiler output

### weather_tools.dart  (653 Z.)
- const: kWeatherCompleteNote
- `Future<String> executeWeather({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required Map …)`  — Weather via server-side Brave Rich Callback proxy.
- `String _buildQuery({ required String location, double? latitude, double? longitude, required String action, int? days, i …)`
- `String _formatWeather({ required String locationLabel, required String action, int? days, int? hours, required String ve …)`
- `Map<String, dynamic>? _braveWeather(Map<String, dynamic> payload)`  — The `weather` map of a Brave rich weather payload, or null when the
- `String _formatBraveWeather( Map<String, dynamic> weather, { required String locationLabel, required String action, int? …)`
- `num? _asNum(Object? value)`
- `String _fmt(num? value)`
- `num? _precipAmount(Object? value)`  — Rain or snow amount: OpenWeatherMap sends a number or `{"1h": n}`.
- `String? _conditionPart(Object? weather)`
- `String? _windPart(Object? wind)`
- `DateTime? _localDateTime(Object? ts, int tzOffsetSeconds)`
- `String _two(int n)`
- `String _isoDate(DateTime t)`
- `String _hhmm(DateTime t)`
- `@visibleForTesting String compassPoint(num degrees)`  — Eight-point compass direction for a wind bearing in degrees.
- `@visibleForTesting int owmToWmoCode(int id)`  — Maps an OpenWeatherMap condition id to the WMO weather code the
- `void _writeCurrent(StringBuffer buf, Map<String, dynamic> src)`
- `void _writeDay(StringBuffer buf, Map<String, dynamic> day)`
- `void _writeHour(StringBuffer buf, Map<String, dynamic> hour)`
- `Map<String, dynamic>? _pickMap(Map<String, dynamic> src, List<String> keys)`
- `List? _pickList(Map<String, dynamic> src, List<String> keys)`
- `String? _pickString(Map<String, dynamic> src, List<String> keys)`

### web_tools.dart  (715 Z.)
- const: _defaultSearchCount _maxSearchCount _defaultAutoCrawlCount _maxAutoCrawlCount _defaultAutoCrawlMaxChars _maxAutoCrawlMaxChars _maxExcerptCharsPerPage
- `Map<String, String> _buildJsonHeaders(Map<String, String> serverHeaders)`
- `int _coerceInt( dynamic value, { required int fallback, required int min, required int max, })`
- `bool _coerceBool(dynamic value, {required bool fallback})`
- `String _truncate(String input, int maxChars)`
- `class _CrawlContext`
- `Future<_CrawlContext> _crawlForContext({ required String baseUrl, required Map<String, String> serverHeaders, required S …)`
- `Future<String> executeWebSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required M …)`  — Web search via server-side Brave Search proxy.
- `Future<String> executeImageSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required …)`  — Image search via server-side Brave Image Search proxy.
- `Future<String> executeNewsSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required …)`  — News search via server-side Brave News Search proxy.
- `Future<String> executeWebCrawl({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required Ma …)`  — Crawl a webpage via server-side crawler and return markdown content.

## lib/ui/expressive
### agent_face.dart  (316 Z.)
- const: kAgentAccents
- `ShapeBorder agentAvatarShape(String id, AgentAvatarShape? shape, double size)`  — The selected silhouette, shared by monograms, photos and editor previews.
- `class _OvalAvatarBorder extends ShapeBorder`
- `Color agentAccent( BuildContext context, String agentId, { AgentProfileStore? store, })`  — The accent colour of a coworker: the picked colour, else the stable hue from
- `int _paletteIndex(String agentId)`  — A stable index into [kAgentAccents] from the agent id. Its own hash, so a
- `class ExpressiveFace extends StatelessWidget`  — A face for an identity the caller only knows as an id and a label — a room
- `class AgentFace extends StatelessWidget`

### agent_status.dart  (256 Z.)
- const: kStatusDotSizeFactor kStatusDotGap
- `String humanToolLabel(String rawName)`  — What one running tool is called, in words a reader recognises. The host's
- `String? workInProgressLabel(AgentsAgent agent, AgentsRun? run)`  — The words for the status line, or null while the coworker is simply idle
- `class StatusDot extends StatelessWidget`  — The presence dot of a status line, on ONE optical line with its words.
- `class _BaselinedBox extends SingleChildRenderObjectWidget`  — A box whose baseline is its own bottom edge.
- `class _RenderBaselinedBox extends RenderProxyBox`
- `class AgentStatusLine extends StatelessWidget`  — The line itself: the dot, and the words next to it.

### bubble_kind.dart  (68 Z.)
- `enum AgentBubbleKind`
- `@immutable class AgentBubbleColors`  — The fill and the foreground for a coworker's bubble.
- `AgentBubbleColors agentBubbleColors(ColorScheme scheme, AgentBubbleKind kind)`
- `AgentBubbleKind agentBubbleKindFor({ required bool hasProblem, required bool hasMedia, required bool hasToolRuns, requir …)`  — Picks the kind from the facts a bubble has.

### bubble_shape.dart  (99 Z.)
- const: kBubbleRadiusBig kBubbleRadiusSmall kBubbleGapInGroup kBubbleGapBetweenGroups kBubbleGroupPause
- `enum BubblePosition`  — Where a bubble sits inside a run of consecutive same-sender messages.
- `double bubbleGapAbove({required bool startsNewGroup})`  — The gap above a block, from the flag the chat screens already carry.
- `BubblePosition bubblePositionFor(int index, int length)`  — The position of item [index] in a run of [length].
- `BubblePosition bubblePositionFromFlags({ required bool startsNewGroup, required bool endsGroup, })`  — The position derived from the two flags the chat screens already carry.
- `BubblePosition bubblePositionInStack({ required int index, required int length, required bool startsNewGroup, required b …)`  — Where one block of a message sits in the run, when the message draws more
- `BorderRadius bubbleRadius( bool isMine, BubblePosition pos, { double big = kBubbleRadiusBig, double small = kBubbleRadiu …)`  — The corner radii for a bubble at [pos]. [isMine] flips which side carries
- `String formatClock(int seconds)`  — Formats seconds as `m:ss` (75 → "1:15"). Used for voice clips.

### connected_group.dart  (187 Z.)
- `class ConnectedGroup extends StatelessWidget`
- `class _Segment extends StatelessWidget`

### expressive_screen.dart  (150 Z.)
- `class ExpressiveScreen extends StatelessWidget`

### face_image.dart  (10 Z.)
- reicht weiter: 'face_image_stub.dart' if (dart.library.io) 'face_image_io.dart'

### face_image_io.dart  (15 Z.)
- `ImageProvider<Object>? faceImageProvider(String? path)`

### face_image_stub.dart  (8 Z.)
- `ImageProvider<Object>? faceImageProvider(String? path)`

### feedback.dart  (174 Z.)
- `void pillToast(BuildContext context, String message, {IconData? icon})`  — A floating pill toast — the expressive replacement for a flat SnackBar.
- `Future<T?> expressiveSheet<T>( BuildContext context, { required String title, required Widget child, })`  — An expressive modal sheet: 36 px top corners, a drag handle, generous pad.
- `class SheetAction extends StatelessWidget`  — A big tappable action row for an expressive sheet.

### huge_icon.dart  (8 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/huge_icon.dart'

### icon_map.dart  (14 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/icon_map.dart'

### motion.dart  (530 Z.)
- const: kExpressiveDecelerate kExpressiveShort kSpatialSpring kEffectSpring
- `class MorphTap extends StatefulWidget`  — A surface that springs and morphs on press. Wrap ANY tappable element.
- `class _MorphTapState extends State<MorphTap> with SingleTickerProviderStateMixin`
- `class _PressOutlinePainter extends CustomPainter`  — Draws [MorphTap.pressedOutline] along the shape the surface currently has.
- `class ExpressiveButton extends StatelessWidget`  — A fully rounded button that springs and morphs on press.
- `class ExpressiveIconButton extends StatelessWidget`  — The expressive icon target: a soft squircle that squashes a touch more
- `class ExpressiveLoader extends StatefulWidget`  — The expressive spinner: a cookie blob that turns while its scallop depth
- `class _ExpressiveLoaderState extends State<ExpressiveLoader> with SingleTickerProviderStateMixin`
- `class _BlobPainter extends CustomPainter`

### pill_geometry.dart  (102 Z.)
- `abstract final class PillGeometry`

### shapes.dart  (244 Z.)
- `class CookieShape extends ShapeBorder`  — A scalloped blob. [softness] 0 is a circle; about 0.2 is a deep scallop.
- `int shapeIndexFor(String key)`  — A stable shape index from an identity [key] (an agent id). Same key, same
- `ShapeBorder expressiveShapeFor(String key)`  — [expressiveShape] keyed by identity instead of list position.
- `ShapeBorder expressiveShape(int i)`  — One curated silhouette per index.
- `class PolygonShape extends ShapeBorder`  — A regular polygon with rounded corners, inscribed in the box.
- `double monogramDrop(ShapeBorder shape)`  — How far the monogram of a face has to sit below the middle of its box for

### staggered.dart  (90 Z.)
- `class StaggeredItem extends StatefulWidget`
- `class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin`

### top_veil.dart  (94 Z.)
- `BoxDecoration topVeilDecoration(ColorScheme scheme)`  — The gradient itself, for surfaces that place their own bar (a pinned
- `class TopVeil extends StatelessWidget`
- `BoxDecoration bottomVeilDecoration(ColorScheme scheme)`  — The veil under a floating bottom bar: nothing at the top, heaviest at the
- `class BottomVeil extends StatelessWidget`  — [child] on the bottom veil, with room above it for the gradient to fade in.

### waveform.dart  (9 Z.)
- reicht weiter: 'package:chuk_chat/widgets/waveform.dart'

### working_dots.dart  (75 Z.)
- `class WorkingDots extends StatefulWidget`
- `class _WorkingDotsState extends State<WorkingDots> with SingleTickerProviderStateMixin`

## lib/utils
### answer_blocks_parser.dart  (480 Z.)
- const: _kBlockNames _openRe _closeRe _partialCloseRe _alertRe _stepNumRe _stepLetterRe _lettersArgRe _numRe _rangeRe
- `enum AnswerBlockKind`  — The block kinds the renderer draws natively.
- `sealed class AnswerSegment`  — One slice of a message: Markdown text or a parsed block.
- `class AnswerTextSegment extends AnswerSegment`  — Markdown between the blocks, verbatim.
- `class AnswerBlockSegment extends AnswerSegment`  — A block with its raw body lines.
- `bool _isFence(String line)`
- `List<AnswerSegment> splitAnswerBlocks(String text)`  — Splits [text] into Markdown and block segments.
- `enum StepPartKind`
- `class StepPart`  — One piece of a step body. A [StepPartKind.command] part holds one or more
- `class StepItem`
- `class StepsSpec`
- `String _letter(int index)`
- `StepsSpec parseSteps(String arg, List<String> lines)`
- `class TimelineEntry`
- `(String, String) splitKeyValue(String line)`  — Splits at the first `: ` (colon and space), so `12:30: Lunch` keeps its
- `List<TimelineEntry> parseTimeline(List<String> lines)`
- `class ScalePoint`
- `class ScaleSpec`
- `double? parseLooseNumber(String s)`  — Reads the first number in [s]. Accepts `2700`, `2.700` and `2,700`
- `ScaleSpec? parseScale(String arg, List<String> lines)`  — Returns null when the block cannot be drawn (no range and fewer than two

### api_rate_limiter.dart  (248 Z.)
- `class RateLimitConfig`  — API rate limiting configuration for different endpoint types.
- `class RateLimitResult`  — Result of a rate limit check.
- `class ApiRateLimiter`  — Manages API rate limiting with per-endpoint and per-user tracking.

### arch_helper.dart  (4 Z.)
- reicht weiter: 'arch_helper_stub.dart' if (dart.library.ffi) 'arch_helper_native.dart'

### arch_helper_native.dart  (43 Z.)
- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### arch_helper_stub.dart  (7 Z.)
- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### artifact_tag_parser.dart  (140 Z.)
- const: _artifactBlockPattern _artifactStartPattern _attrPattern _leadingCodeFence _trailingCodeFence
- `class ParsedArtifactTag`  — A single `<artifact>` tag parsed out of assistant text.
- `List<ParsedArtifactTag> parseArtifactTags(String text)`  — Returns all complete `<artifact>` blocks found in [text]. Partial
- `String _stripWrappingFence(String content)`  — Strip a single surrounding "```lang\n … \n```" fence if present. Leaves
- `String stripArtifactTagsForDisplay( String content, { bool stripIncomplete = true, })`  — Strips complete `<artifact>...</artifact>` blocks from [content]. When

### automation_message.dart  (55 Z.)
- const: _headerPattern
- `class AutomationWake`  — A user turn that a fired automation produced, not a person.
- `AutomationWake? parseAutomationWake(String text)`  — Reads the automation header off [text], or returns null when this is an

### build_info.dart  (50 Z.)
- `class BuildInfo`

### certificate_pinning.dart  (127 Z.)
- `class CertificatePin`  — Certificate pin configuration for a domain.
- `class CertificatePinning`  — Manages SSL certificate pinning for secure API communications.

### certificate_pinning_io.dart  (83 Z.)
- `void configureDioWithPinning(Dio dio, List<CertificatePin> pins)`  — Configure Dio with a [badCertificateCallback] that validates
- `void _installBadCertCallback(HttpClient client, List<CertificatePin> pins)`
- `List<int> _sha256Sync(List<int> data)`  — Synchronous SHA-256 hash.
- `HttpClient createPinnedHttpClient(List<CertificatePin> pins)`  — Create an [HttpClient] with certificate pinning configured.

### certificate_pinning_register.dart  (9 Z.)
- reicht weiter: 'certificate_pinning_register_stub.dart' if (dart.library.io) 'certificate_pinning_register_io.dart'

### certificate_pinning_register_io.dart  (80 Z.)
- const: _trustedToolApiHosts
- `class _WindowsCertOverrides extends HttpOverrides`  — [HttpOverrides] that accepts certificates for known trusted public API
- `void registerCertificatePinning()`  — Register the native certificate pinning configurator.

### certificate_pinning_register_stub.dart  (10 Z.)
- `void registerCertificatePinning()`  — No-op on web. The browser's TLS stack validates certificates.

### chat_font_resolver.dart  (72 Z.)
- const: kFontFamilyArimo kFontFamilyMerriweather kFontFamilyJetBrainsMono
- `String? resolveChatFontFamily(String id)`  — Map a stored identifier (e.g. `'arimo'`) to a font family string usable
- `String sanitizeChatFontFamily(String? id)`  — Normalize an unknown id (e.g. from Supabase) back to a known value so the
- `String? resolveUiFontFamily(String? id)`  — Map a stored UI-font identifier to a font family string for
- `String sanitizeUiFontFamily(String? id)`  — Normalize an unknown UI-font id back to a supported value. Defaults to the

### client_platform.dart  (26 Z.)
- `String clientPlatformName()`  — Human-readable name of the current client platform.

### clipboard_text_sanitizer.dart  (64 Z.)
- `class ClipboardTextSanitizer`

### color_extensions.dart  (62 Z.)
- `extension ColorExtension on Color`  — Helper extension to subtly lighten or darken colors.

### debug_chat_formatter.dart  (276 Z.)
- `class DebugChatFormatter`  — Formats the full chat message list as a debug-friendly text string.

### desktop_drop_stub.dart  (36 Z.)
- `class DropTarget extends StatelessWidget`
- `class DropDoneDetails`
- `class DropEventDetails`
- `class XFile`

### exponential_backoff.dart  (205 Z.)
- `class BackoffConfig`  — Configuration for exponential backoff retry logic.
- `class BackoffResult<T>`  — Result of a backoff operation.
- `class ExponentialBackoff`  — Handles exponential backoff for failed API requests.

### favicon.dart  (97 Z.)
- `List<String> faviconUrls(String host, {int size = 64})`  — Where a site logo is fetched from, best source first.
- `class FaviconImage extends StatefulWidget`  — The logo of [host], falling back through [faviconUrls] and ending on a
- `class _FaviconImageState extends State<FaviconImage>`

### file_upload_validator.dart  (461 Z.)
- `class FileValidationResult`  — File upload validation result.
- `class FileUploadValidator`  — Utility for validating file uploads to prevent security issues.

### format_bytes.dart  (21 Z.)
- `String formatBytes(int bytes)`  — Formats a byte count for a reader: `842 B`, `1.5 KB`, `12 MB`.

### highlight_registry.dart  (98 Z.)
- const: allLanguages

### image_clipboard_service.dart  (37 Z.)
- `class ImageClipboardService`

### incomplete_markdown_links.dart  (21 Z.)
- `String presentIncompleteMarkdownLinks(String text, {required bool streaming})`  — Keep a partial streamed URL from filling the bubble with encoded bytes.

### input_validator.dart  (372 Z.)
- `enum PasswordStrength`  — Password strength levels.
- `class PasswordValidationResult`  — Result of password validation with detailed feedback.
- `class InputValidator`  — Input validation and sanitization utilities for security.

### io_helper.dart  (4 Z.)
- reicht weiter: 'io_helper_stub.dart' if (dart.library.io) 'io_helper_io.dart'

### io_helper_io.dart  (12 Z.)
- reicht weiter: 'dart:io' show File, Directory, Platform, Process, SocketException, HttpException, IOException

### io_helper_stub.dart  (83 Z.)
- `class File`  — Stub File class for web
- `class Directory`  — Stub Directory class for web
- `class Platform`  — Stub Platform class for web
- `class ProcessResult`  — Stub ProcessResult for web
- `class Process`  — Stub Process class for web
- `abstract class IOException implements Exception`  — Stub IOException for web: the common type of every I/O failure, as in
- `class SocketException implements IOException`  — Stub SocketException for web
- `class HttpException implements IOException`  — Stub HttpException for web

### json_helpers.dart  (72 Z.)
- `Map<String, dynamic>? tryDecodeJsonObject(String body)`  — Decodes [body] into a JSON object, or returns null when it is not one.
- `dynamic tryParseLenientJson(String raw)`  — Lenient JSON parse for model output, which makes two mistakes often
- `bool looksLikeEncryptedPayload(String raw)`  — True when [raw] is one of our AES-GCM envelopes rather than plaintext.

### lenient_json.dart  (84 Z.)
- `String stripTrailingCommas(String source)`  — Remove commas that sit directly before `}` or `]`, outside of any string.
- `String stripCodeFence(String source)`  — Strip a markdown fence (```json … ```) around a JSON body.
- `Object? tryDecodeLenientJson(String source)`  — Decode a JSON value a model wrote, repairing only a fence and a trailing
- `Map<String, dynamic>? tryDecodeLenientJsonObject(String source)`  — The same, narrowed to a JSON object.

### lru_byte_cache.dart  (86 Z.)
- `class LruByteCache`  — LRU (Least Recently Used) cache with a maximum total byte size.

### map_geometry.dart  (30 Z.)
- `bool hasPointSpread(List<LatLng> points)`  — True when [points] cover more than one place on the map.
- `double _shortestLonDelta(double a, double b)`  — Degrees between two longitudes the short way round.

### path_provider_stub.dart  (8 Z.)
- `Future<Directory> getTemporaryDirectory()`
- `Future<Directory> getApplicationDocumentsDirectory()`
- `Future<Directory> getApplicationSupportDirectory()`

### permission_handler_stub.dart  (24 Z.)
- `class Permission`
- `enum PermissionStatus`

### phone_linkify.dart  (95 Z.)
- const: _scanPattern _minDigits _maxDigits
- `String linkifyPhoneNumbers(String markdown)`  — Rewrites every bare phone number in [markdown] as `[display](tel:+…)`.
- `String? telUriForDisplay(String display)`  — Normalises a written number to a `tel:` URI, or returns `null` when the

### privacy_logger.dart  (73 Z.)
- `class PrivacyLogger`  — Privacy-aware logging utility.
- `void pLog(String message)`  — Shorthand for PrivacyLogger.call()

### secure_token_handler.dart  (148 Z.)
- `class SecureTokenHandler`  — Utility for secure handling of authentication tokens.

### service_error_handler.dart  (178 Z.)
- `class ServiceErrorHandler`  — Centralized error handling for service operations

### shift_key_tracker.dart  (6 Z.)
- reicht weiter: 'shift_key_tracker_native.dart' if (dart.library.js_interop) 'shift_key_tracker_web.dart'

### shift_key_tracker_native.dart  (10 Z.)
- `void initShiftKeyTracker()`

### shift_key_tracker_web.dart  (38 Z.)
- const: _shiftDown _initialized
- `void initShiftKeyTracker()`

### stream_error_notice.dart  (76 Z.)
- const: kConnectionErrorNotice
- `String stripStreamErrorNotice(String text)`  — Removes the transport error notice from [text], wherever it sits.
- `String? stripStreamErrorNoticeFromBlocksJson(String? blocksJson)`  — The same cleanup for a stored content-block list.

### stream_error_sanitizer.dart  (41 Z.)
- `String sanitizeStreamError(Object error)`  — Turns a transport exception into something safe and readable to show.

### theme_extensions.dart  (257 Z.)
- `extension ThemeDataIconColorX on ThemeData`
- `@immutable class MaterialYouTokens extends ThemeExtension<MaterialYouTokens>`  — Material You extension tokens that aren't exposed on the default
- `extension MaterialYouTokensX on ThemeData`

### token_estimator.dart  (58 Z.)
- `class TokenEstimator`

### tool_detail_format.dart  (91 Z.)
- const: _markdownMarkers
- `enum ToolBodyKind`  — How a tool-detail body should be shown.
- `class ToolBody`  — A tool body together with how to show it.
- `ToolBody classifyToolBody(String raw)`  — Decide how [raw] should be shown, and hand back the text to show.
- `String? prettyJsonOrNull(String raw)`  — [raw] indented, or null when it is not a JSON object or array.

### tool_helpers.dart  (21 Z.)
- `double toDouble(dynamic v)`  — Safely parse a coordinate value that may be num or String.
- `String formatDuration(int ms)`  — Format milliseconds duration as mm:ss string.
- `String truncate(String text, int maxLength)`  — Truncate text with ellipsis if it exceeds maxLength.

### tool_history_formatter.dart  (102 Z.)
- const: _maxResultChars _maxTotalChars
- `String? formatAssistantContent( Map<String, String> message, { bool includeReasoning = false, bool includeToolResults = …)`  — Builds the assistant `content` string for one stored message, optionally
- `String _buildPreviousToolResultsBlock(String? toolCallsJson)`

### tool_parser.dart  (774 Z.)
- const: toolCallStart toolCallEnd _xmlToolCallBlockPattern _xmlDirectToolTagBlockPattern _xmlToolCallStartPattern _kimiToolCallStartPattern _previousToolResultsBlockPattern _previousToolResultsStartPattern _foreignToolTagNames _foreignToolTagNamespace _notCanonicalToolCallTag _foreignToolProtocolBlockPattern _invokeToolCallPattern _invokeParameterPattern _foreignToolProtocolStartPattern _knownDirectXmlToolNames
- `Map<String, dynamic>? tryParseToolJson(String raw)`  — Try to parse JSON from a tool call, with repair for common LLM errors:
- `Map<String, dynamic>? _parseLegacyToolCallSyntax(String raw)`
- `Map<String, dynamic>? _extractEmbeddedToolJson(String raw)`
- `Map<String, dynamic>? _extractInlineArgumentsObject(String s)`
- `String? _extractBalancedObject(String s, int startIndex)`
- `int _countUnclosedBracesOutsideStrings(String s)`
- `Map<String, dynamic> _coerceStringKeyedMap(dynamic rawArgs)`
- `bool hasToolCallStartMarker(String content)`  — Returns true when a response has started emitting a tool-call marker,
- `bool hasForeignToolProtocolMarker(String content)`  — True when the text carries a tool-call protocol this app does not parse
- `List<({int start, int end})> _codeSpanRanges(String content)`  — Start/end offsets of fenced blocks and inline code spans.
- `bool _isInsideCode(int index, List<({int start, int end})> codeRanges)`
- `Match? _firstMatchOutsideCode( RegExp pattern, String content, List<({int start, int end})> codeRanges, )`
- `String _stripForeignToolProtocol( String content, { required bool stripIncomplete, })`  — Removes foreign tool-call protocol text so it never reaches the user.
- `String stripToolCallBlocksForDisplay( String content, { bool stripIncomplete = true, })`  — Removes tool-call XML blocks from user-visible text.
- `int _earliestCaseInsensitiveIndex(String haystack, String needle)`
- `List<Map<String, dynamic>> parseToolCalls(String content)`  — Parse ALL tool calls from LLM response content (supports multiple).
- `dynamic _decodeInvokeParameterValue(String raw)`  — `<parameter>` bodies are untyped text. Only unambiguous JSON shapes are
- `bool hasToolCalls(String content)`  — Check if the content contains any tool call tags.
- `bool _isKnownDirectXmlToolName(String tagName)`
- `Map<String, dynamic> _parseDirectXmlToolArgs(String inner)`
- `int _earliestDirectXmlToolStart(String content)`

### tool_sanitizer.dart  (45 Z.)
- `String sanitizeResultForModel(String result)`  — Strip large binary/base64 data from tool results before sending to the

### upload_rate_limiter.dart  (95 Z.)
- `class UploadRateLimiter`  — Upload rate limiter to prevent DoS attacks via excessive file uploads.

### url_launcher_helper.dart  (22 Z.)
- `Future<void> launchExternalUrl(String url)`  — Opens [url] in the system browser.

## lib/voice
### voice_call.dart  (25 Z.)
- reicht weiter: 'voice_call_controller.dart' show VoiceCallController · 'voice_call_models.dart' · 'voice_call_service.dart' show VoiceCallService, VoiceCallException · 'voice_call_store.dart' show VoiceCallStore · 'widgets/voice_call_button.dart' show VoiceCallButton · 'widgets/voice_call_panel.dart' show VoiceCallPanel, VoiceTurnLine, formatVoiceCallClock · 'widgets/voice_agent_card.dart' show VoiceAgentCard · 'widgets/voice_call_record_card.dart' show VoiceCallRecordCard, describeVoiceCall, voiceCallTimeline

### voice_call_controller.dart  (944 Z.)
- `class VoiceCallController extends ChangeNotifier`

### voice_call_models.dart  (313 Z.)
- `enum VoiceCallMode`  — Which kind of chat the call belongs to. The worker reads it from the
- `enum VoiceCallPhase`  — Where the one app-wide call is in its life.
- `class VoiceTurn`  — One spoken turn of the live transcript.
- `class VoiceCallRecord`  — What a finished call leaves behind in its chat: when it ran and what was
- `class VoiceCard`  — A rich payload the agent pushed to the screen during a call (`ui.card`
- `class VoiceToolActivity`  — The live state of one tool call on the worker (`ui.tool` data topic).
- `String? _string(Object? raw)`
- `class VoiceTaskResult`  — A result for a task the worker started through the delegate.
- `abstract class VoiceTaskDelegate`  — Hands work from the voice worker to the chat model (normal chat) or the
- `DateTime _parseTime(Object? raw)`

### voice_call_service.dart  (152 Z.)
- `abstract final class VoiceCallService`
- `class VoiceCallException implements Exception`  — A call failure with a message that is safe to show and to log: it never

### voice_call_store.dart  (97 Z.)
- `abstract final class VoiceCallStore`

### voice_location.dart  (105 Z.)
- `enum VoiceLocationPermission`  — What the OS says about location access, before asking.
- `class VoiceLocationResolver`

### voice_location_platform_io.dart  (31 Z.)
- `Future<VoiceLocationPermission> checkLocationPermission()`
- `Future<Map<String, dynamic>> fetchCurrentLocation()`

### voice_location_platform_stub.dart  (14 Z.)
- `Future<VoiceLocationPermission> checkLocationPermission()`
- `Future<Map<String, dynamic>> fetchCurrentLocation()`

### voice_protocol.dart  (304 Z.)
- `abstract final class VoiceProtocol`
- `class VoiceCredentials`  — Where and how to join: the LiveKit server URL and the room token.
- `String truncateRunes(String text, int maxRunes)`  — Cuts [text] to at most [maxRunes] Unicode code points, never splitting a

### voice_tasks.dart  (90 Z.)
- const: kVoiceResultBackoff
- `class VoiceTaskLedger`  — The started tasks of one delegate that have no result yet.
- `Future<bool> deliverWithRetry( Future<bool> Function() attempt, { List<Duration> backoff = kVoiceResultBackoff, bool Fun …)`  — Runs [attempt] until it returns true, retrying after each wait in

### voice_transcript.dart  (121 Z.)
- `abstract final class VoiceTranscriptionAttributes`  — Attribute keys livekit-agents puts on a transcription text stream.
- `class VoiceTranscript`
- `class _Segment`

## lib/voice/incoming
### callkit_port.dart  (67 Z.)
- `class FlutterCallkitPort implements CallkitPort`

### incoming_call.dart  (156 Z.)
- `enum IncomingCallUrgency`  — How urgent the agent says the call is.
- `class IncomingCall`  — One `voice_call_incoming` frame.
- `class HostCallState`  — One `voice_call_state` frame from the host (the echo).

### incoming_call_book.dart  (137 Z.)
- `enum IncomingCallStatus`  — Where one known call is on this device.
- `class IncomingCallEntry`  — One known call.
- `enum IncomingAdmission`  — What [IncomingCallBook.admit] decided about a frame.
- `class IncomingCallBook`

### incoming_call_bootstrap.dart  (70 Z.)
- `abstract final class IncomingCallBootstrap`  — Whether this build takes agent calls and shows the ongoing-call

### incoming_call_mapping.dart  (158 Z.)
- const: kIncomingRingMax kIncomingRingMin kIncomingHandleNormal kIncomingHandleUrgent kOngoingChatCallName _callingNotification
- `CallKitParams? incomingCallkitParams( IncomingCall call, DateTime now, { bool startServiceOnAccept = true, })`  — The callkit ring for [call] at [now], or null when the ring is already
- `CallKitParams outgoingCallkitParams({ required String id, required String name, })`  — The callkit call for a call the user started: no ring, only the ongoing
- `class VoiceStartRequest`  — What `VoiceCallController.start` gets for an accepted call.
- `VoiceStartRequest voiceStartRequestFor( IncomingCall call, { String? chatTitle, String context = '', })`  — The start of the voice session for an accepted [call]: its Agents thread,

### incoming_call_ports.dart  (220 Z.)
- `enum CallkitSignalKind`  — What the callkit UI reports.
- `@immutable class CallkitSignal`
- `abstract interface class CallkitPort`  — The ring screen and the self-managed "ongoing call" of the OS.
- `abstract interface class CallStateSender`  — Sends `voice_call_state` to the host. Never throws: a frame that cannot go
- `enum OngoingCallAction`  — A button on the ongoing-call notification that needs the Dart side.
- `@immutable class OngoingCallSnapshot`  — What the ongoing-call notification shows.
- `abstract interface class OngoingCallUi`  — The ongoing-call notification with its buttons, and the two small native
- `abstract interface class MicPermission`  — The microphone permission. A call accepted without it would run the
- `typedef CallChatOpener = void Function(String chatId, VoiceCallMode? mode)`  — Opens the chat a call belongs to (the Agents thread for an agent call).
- `typedef IncomingCallStarter = Future<void> Function(IncomingCall call)`  — Opens the thread of an accepted [call] and starts its voice session.
- `abstract interface class VoiceCallView implements Listenable`  — The part of the app-wide call the service reads and drives.
- `class ControllerVoiceCallView implements VoiceCallView`  — [VoiceCallView] over the real controller.

### incoming_call_service.dart  (513 Z.)
- const: kMicNeededNotice
- `class IncomingCallService`
- `class _Session`  — One voice call as the OS sees it: its callkit id, and the agent call it

### incoming_call_starter.dart  (64 Z.)
- const: kAcceptedCallThreadWait
- `void openVoiceCallChat(String chatId, VoiceCallMode? mode)`  — Brings the chat of a call to the front: the Agents thread through the
- `Future<void> startAcceptedAgentCall( IncomingCall call, { VoiceCallController? controller, Duration waitForThread = kAcc …)`  — Opens the thread of an accepted [call] and starts its voice session:

### ongoing_call_notification.dart  (104 Z.)
- `class OngoingCallNotification implements OngoingCallUi`

### relay_call_state_sender.dart  (135 Z.)
- `class RelayCallStateSender implements CallStateSender`
- `class _Queued`

### voice_call_permissions.dart  (143 Z.)
- `enum VoiceCallGrant`  — One thing a voice call needs, in the order the settings show them.
- `abstract final class VoiceCallPermissions`
- `class PermissionHandlerMic implements MicPermission`  — [MicPermission] over permission_handler (the incoming-call service).

### voice_call_permissions_section.dart  (144 Z.)
- const: _copy
- `class VoiceCallPermissionsSection extends StatefulWidget`
- `class _GrantCopy`
- `class _VoiceCallPermissionsSectionState extends State<VoiceCallPermissionsSection> with WidgetsBindingObserver`

## lib/voice/widgets
### voice_agent_card.dart  (861 Z.)
- `class VoiceAgentCard extends StatelessWidget`
- `class _Header extends StatelessWidget`
- `void _openWebLink(String? url)`  — Opens a web link the card carries. Only http(s): the card comes from a
- `class _LinkRow extends StatelessWidget`
- `class _LinksBody extends StatelessWidget`
- `class _TextLink extends StatelessWidget`  — A small text link in the card's accent ("Open in browser").
- `class _WeatherBody extends StatelessWidget`
- `class _HourColumn extends StatelessWidget`
- `class _SearchBody extends StatelessWidget`
- `class _ArticleBody extends StatelessWidget`
- `class _StockBody extends StatelessWidget`
- `class _SparklinePainter extends CustomPainter`
- `class _MapBody extends StatelessWidget`
- `class _ValueBody extends StatelessWidget`
- `class _FactsBody extends StatelessWidget`
- `class _TaskBody extends StatelessWidget`
- `class _DeviceBody extends StatelessWidget`
- `class _GenericBody extends StatelessWidget`

### voice_call_button.dart  (67 Z.)
- `class VoiceCallButton extends StatelessWidget`

### voice_call_controls.dart  (253 Z.)
- `class VoiceCallControl extends StatelessWidget`  — A square call control: the expressive squircle (corner = size x 0.34),
- `class VoiceMicGlyph extends StatelessWidget`  — The microphone, with a slash across it when [muted]. The icon set has no
- `class _SlashPainter extends CustomPainter`
- `class VoiceHangUpGlyph extends StatelessWidget`  — The handset laid down: `call02` turned 135 degrees, the hang-up sign
- `class VoiceSpeakingBars extends StatefulWidget`  — Three bars that move while the agent speaks and rest flat when it does
- `class _VoiceSpeakingBarsState extends State<VoiceSpeakingBars> with SingleTickerProviderStateMixin`
- `class _BarsPainter extends CustomPainter`

### voice_call_panel.dart  (486 Z.)
- `class VoiceCallPanel extends StatelessWidget`
- `class _PanelBody extends StatelessWidget`
- `class _StatusRow extends StatelessWidget`
- `class _SpeakerToggle extends StatelessWidget`  — Speaker or earpiece. Words, not a glyph: the icon set has no speaker, and
- `class _CallClock extends StatefulWidget`  — mm:ss since the call went live, ticking once a second.
- `class _CallClockState extends State<_CallClock>`
- `String formatVoiceCallClock(Duration d)`  — `mm:ss`, or `h:mm:ss` past an hour.
- `class _ToolLine extends StatelessWidget`  — "Searching the web…" while a worker tool runs.
- `class _CardStrip extends StatelessWidget`  — The agent's cards, newest first, side by side. A card taller than the
- `class _Transcript extends StatelessWidget`
- `class VoiceTurnLine extends StatelessWidget`  — One transcript line: who spoke, then what was said. A partial line is
- `class _FailedRow extends StatelessWidget`

### voice_call_record_card.dart  (176 Z.)
- `class VoiceCallRecordCard extends StatefulWidget`
- `class _VoiceCallRecordCardState extends State<VoiceCallRecordCard>`
- `List<Object> voiceCallTimeline(VoiceCallRecord record)`  — The record's turns and cards in one list, by time. A card sorts after a
- `String describeVoiceCall(VoiceCallRecord record)`  — "Voice call · 3 min · 12 turns" — the collapsed line of a record.

## lib/widgets
### accent_icon_button.dart  (70 Z.)
- `class AccentIconButton extends StatelessWidget`  — A round, accent-filled icon button — one shared widget so the "new chat"

### agent_avatar.dart  (88 Z.)
- `class AgentAvatar extends StatelessWidget`

### agent_control_panel.dart  (413 Z.)
- `class AgentControlPanel extends StatefulWidget`
- `class _AgentControlPanelState extends State<AgentControlPanel>`
- `String formatRuntime(Duration d)`  — `1h 04m` / `4m 12s` / `12s`.
- `String formatCount(int value)`  — `1 234 567` — grouped, so a six-figure token count is readable at a glance.
- `String formatTimestamp(DateTime when)`  — `2026-02-03 14:00` — stable and unambiguous, no locale guessing.

### agent_markdown.dart  (153 Z.)
- const: _chartBlock _chartStart _chartEnd
- `sealed class AgentSegment`  — One piece of an agent reply: prose, or a chart the agent asked for.
- `class AgentTextSegment extends AgentSegment`  — Markdown prose between the visual blocks.
- `class AgentChartSegment extends AgentSegment`  — A parsed `<chart>` block, already decoded to its JSON map.
- `Map<String, dynamic>? decodeChartBody(String body)`  — Decode a chart body, tolerating the two things a model gets wrong: a fenced
- `List<AgentSegment> splitAgentSegments(String data)`  — Split an agent reply into prose and `<chart>` blocks.
- `class AgentMarkdown extends StatelessWidget`  — Renders an agent reply as Markdown, with `<chart>` blocks drawn as charts.

### agent_roster_view.dart  (1201 Z.)
- reicht weiter: 'package:chuk_chat/widgets/coworker_name_dialog.dart'
- const: kRosterTileFace
- `class DesktopRosterPins extends ChangeNotifier`  — Which coworkers the user pinned to the top of the desktop roster. Local to
- `List<AgentsAgent> desktopRosterOrder( List<AgentsAgent> agents, Set<String> pinned, )`  — The agents in the order the desktop roster shows them: pinned first, then
- `class AgentRosterView extends StatefulWidget`
- `class _NavRow`  — One row of the navigation block. The open pane draws it as a card, the
- `class _AgentRosterViewState extends State<AgentRosterView>`
- `String lastActivityLabel(DateTime? when, {required DateTime now})`  — "just now" / "5m ago" / "2h ago" / "3d ago", or a plain statement that

### agent_run_views.dart  (389 Z.)
- `class AgentToolLine extends StatefulWidget`  — One tool call, as a single quiet line that opens on tap.
- `class _AgentToolLineState extends State<AgentToolLine>`
- `class AgentReasoningBlock extends StatefulWidget`  — The model's thinking, kept apart from the answer.
- `class _AgentReasoningBlockState extends State<AgentReasoningBlock>`
- `class AgentFileCard extends StatefulWidget`  — A file the agent produced: a preview for an image, a save action otherwise.
- `class _AgentFileCardState extends State<AgentFileCard>`
- `String formatBytes(int bytes)`  — Formats a byte count the way a file manager does.

### agents_status_panel.dart  (276 Z.)
- `class AgentsStatusPanel extends StatelessWidget`
- `class _Primary extends StatelessWidget`  — The one filled action. While [busy] it says what it is doing and ignores

### agents_thread_header.dart  (444 Z.)
- `enum AgentsThreadConnection`  — One button in the thread's floating row.
- `@immutable class AgentsThreadAction`
- `class AgentsThreadHeader extends StatelessWidget`  — The actions of a desktop thread, as chuk_chat draws the buttons over its
- `class ChromeIconButton extends StatelessWidget`  — chuk's icon button over the chat: a 20 px glyph in the icon colour, round
- `class _OfflineChip extends StatelessWidget`  — The relay is down: a quiet dot and "Offline", with the way back when there
- `class _AutomationChip extends StatelessWidget`  — The running automation, as small as it can be and still be read: a state

### agents_thread_view.dart  (2296 Z.)
- const: kAgentsThreadHeaderInset kAgentsDevHostUrl
- `class AgentsThreadView extends StatefulWidget`
- `class AgentsThreadViewState extends State<AgentsThreadView> with WidgetsBindingObserver`

### anchored_menu.dart  (395 Z.)
- const: _kAnchorGap _kEdgeMargin _kMinRoomAbove _kMenuDuration
- `Future<T?> showAnchoredMenu<T>( BuildContext anchorContext, { required List<Widget> items, required Color color, // Kept …)`  — Show [items] as a dropdown anchored to the widget of [anchorContext].
- `class _AnchoredMenuRoute<T> extends PopupRoute<T>`
- `class _AnchoredMenuLayout extends SingleChildLayoutDelegate`  — Puts the menu above the anchor when it does not fit below it. The child
- `List<List<Widget>> _splitOnDividers(List<Widget> items)`  — Splits a flat item list into runs at every divider, so a divider becomes

### answer_blocks.dart  (728 Z.)
- part of 'markdown_message.dart'
- `class _AnswerBlockStyle`  — Colours and type the blocks share, taken from the surrounding message.
- `Widget _buildAnswerBlock(AnswerBlockSegment block, _AnswerBlockStyle s)`  — Builds the widget for one block. Throws only on a programming error; the
- `class _BlockFrame extends StatelessWidget`  — The frame of a block: a rule on top and an optional small-caps title.
- `class _StepsBlock extends StatelessWidget`
- `class _TerminalLines extends StatelessWidget`  — Command lines on a dark terminal card, with the code block's copy button.
- `class _WarningLine extends StatelessWidget`
- `class _TimelineBlock extends StatelessWidget`
- `class _ScaleBlock extends StatelessWidget`  — A labelled band with ticks and a marker. Experimental: the prompt offers
- `class _AlertBlock extends StatelessWidget`

### api_availability_polling.dart  (51 Z.)
- `mixin ApiAvailabilityPolling<T extends StatefulWidget> on State<T>`  — Retries a failed model fetch once the API answers again.

### app_lifecycle_observer.dart  (59 Z.)
- `class AppLifecycleObserver extends StatefulWidget`
- `class _AppLifecycleObserverState extends State<AppLifecycleObserver> with WidgetsBindingObserver`

### app_mode_switch.dart  (76 Z.)
- `class AppModeSwitch extends StatelessWidget`

### app_notification.dart  (209 Z.)
- `enum AppNotificationKind`  — What kind of thing happened. Picks the glyph and the accent down the side.
- `class AppNotification extends StatelessWidget`  — The floating pill the app talks to the reader in.
- `SnackBar appNotificationSnackBar({ required String message, AppNotificationKind kind = AppNotificationKind.info, Duratio …)`  — The SnackBar an [AppNotification] travels in.
- `abstract final class AppNotifications`  — How a message reaches the screen.

### artifact_panel.dart  (2158 Z.)
- `class ArtifactPanel extends StatefulWidget`
- `enum _ArtifactViewMode`
- `class _ArtifactPanelState extends State<ArtifactPanel>`
- `class ArtifactBottomSheet extends StatelessWidget`
- `class _TypeBadge extends StatelessWidget`
- `class _ArtifactRenderer extends StatelessWidget`
- `class _ExcalidrawMarkdrawEditor extends StatefulWidget`  — Native cross-platform Excalidraw editor backed by the `markdraw`
- `class _ExcalidrawMarkdrawEditorState extends State<_ExcalidrawMarkdrawEditor>`
- `class _TypstPdfRenderer extends StatefulWidget`  — Renders a Typst artifact's PDF. Prefers the persisted encrypted
- `class _TypstPdfRendererState extends State<_TypstPdfRenderer>`
- `class _ViewModeToggle extends StatelessWidget`  — Preview / Code toggle shown in the artifact header for types that support
- `IconData _iconForType(ArtifactType type)`
- `class _ZoomableVisual extends StatefulWidget`  — Zoomable wrapper with +/- buttons for visual artifacts (SVG, drawings).
- `class _ZoomableVisualState extends State<_ZoomableVisual>`
- `class _DownloadFormat`
- `class _HistoryReadOnlyBanner extends StatelessWidget`  — Thin banner shown above the renderer when the user has selected a
- `class _ArtifactSwitcher extends StatelessWidget`  — Header title + switcher. When the current chat has more than one artifact,
- `class _ZoomButton extends StatelessWidget`

### ask_user_card.dart  (101 Z.)
- `class AskUserCard extends StatelessWidget`  — Interactive option buttons shown below messages that used the ask_user tool.
- `class _OptionChip extends StatefulWidget`
- `class _OptionChipState extends State<_OptionChip>`

### attachment_preview_bar.dart  (1015 Z.)
- const: _kMaxExtensionChars _kImageCardSize _kImageCardBorderWidth
- `typedef AttachmentRemoveCallback = void Function(String fileId)`
- `typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file)`
- `typedef AttachmentContentChangedCallback = void Function(String fileId, String newContent)`
- `class AttachmentPreviewBar extends StatefulWidget`
- `class _AttachmentPreviewBarState extends State<AttachmentPreviewBar>`
- `class _ImageAttachmentCard extends StatelessWidget`
- `class _RemoveButton extends StatelessWidget`  — The remove target on an attachment card.
- `class _DocumentAttachmentTile extends StatelessWidget`
- `void _showDocumentPreview( BuildContext context, AttachedFile file, Color textColor, { AttachmentContentChangedCallback? …)`
- `class _DocumentPreviewDialog extends StatefulWidget`
- `class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog>`
- `Future<String?> _loadPlainTextContent(AttachedFile file)`
- `bool _isImageFile(String fileName)`
- `bool _isPdfFile(String fileName)`
- `bool _isPlainTextFile(String fileName)`
- `String _extensionLabel(String fileName)`
- `String _extractExtension(String fileName)`

### auth_gate.dart  (347 Z.)
- `class AuthGate extends StatefulWidget`  — The auth gate: swaps between the login screen and the messenger shell on
- `class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver`
- `class _RecoveringView extends StatelessWidget`  — Shown while the host is asked for the live session: a quiet wait, not a

### automation_card.dart  (226 Z.)
- `class AutomationCard extends StatefulWidget`  — One automation as a settings row: what it is, when it runs, what state it
- `class _AutomationCardState extends State<AutomationCard>`

### brand_wordmark.dart  (36 Z.)
- `class BrandWordmark extends StatelessWidget`  — Brand lockup rendered from the frozen brand SVG (assets/wordmark.svg,

### browser_view_page.dart  (676 Z.)
- `class BrowserViewPage extends StatefulWidget`  — The live browser view (§9.1): watch and control the agent's sandbox
- `class _BrowserViewPageState extends State<BrowserViewPage>`
- `class _StatusBanner extends StatelessWidget`

### chart_widget.dart  (939 Z.)
- const: _defaultColors
- `Color? _tryParseColor(Object? raw)`  — Parse a hex color like "#FF5722", "FF5722" or "#CCFF5722" into a Color.
- `Color _colorAt(int index)`
- `Map<String, dynamic> normalizeChartData(Map<String, dynamic> raw)`  — Normalize the shorthand chart shapes the model may emit into the canonical
- `class ChartRenderer extends StatelessWidget`  — Top-level widget: parses a JSON map and picks the right chart builder.

### chat_composer_box.dart  (151 Z.)
- `class ChatComposerBox extends StatelessWidget`
- `class ChatComposerField extends StatelessWidget`  — The composer's text field, with the chat's typography and its borderless

### chat_document_inline.dart  (721 Z.)
- const: kInlineDocumentRows kInlineDocumentProseHeight _documentMemo
- `bool inlineDocumentHasContent(Map<String, dynamic> document)`  — Whether [document] carries content the thread can draw.
- `bool documentIsChart(Map<String, dynamic> document)`  — Whether [document] draws as a chart.
- `List<String> documentColumns(Map<String, dynamic> document)`  — The column names of a table document.
- `List<Map> documentRows(Map<String, dynamic> document)`  — The rows of a table document.
- `List<Map> documentChartRows(Map<String, dynamic> document)`  — The rows of a chart document that have a bar to draw.
- `Map<String, Object?> documentChartJson(Map<String, dynamic> document)`  — The chart JSON of [document], in the contract `chart_spec.dart` documents.
- `String documentSourceName(Object? raw)`  — A source URL as a chart footer says it: the host, not the whole path.
- `@immutable class DocumentChart`  — A document's chart, ready to draw, with what had to be left out of it.
- `DocumentChart documentChart( Map<String, dynamic> document, { int? maxPoints, bool withSource = true, })`  — Reads the chart out of [document].
- `DocumentChart _documentChart( Map<String, dynamic> document, { int? maxPoints, bool withSource = true, })`
- `String documentCellText(Object? raw)`  — One cell as [ChukTable] reads it. A bare URL becomes a markdown link
- `ParsedTable documentParsedTable(Map<String, dynamic> document, {int? maxRows})`  — A table document in the shape [ChukTable] draws.
- `ParsedTable _documentParsedTable( Map<String, dynamic> document, { int? maxRows, })`
- `Future<void> openDocumentLink(BuildContext context, String href)`  — Open a link out of a document cell, in the platform browser.
- `class InlineChatDocument extends StatefulWidget`  — A document, drawn in the thread in the coworker's bubble.
- `class _InlineChatDocumentState extends State<InlineChatDocument>`
- `class _OpenAction extends StatelessWidget`  — The one action a cut document offers, in the app's button family: a tonal
- `class _CutAtHeight extends StatelessWidget`  — Shows the top [maxHeight] of its child and fades the cut into the bubble.
- `class _HeightCap extends SingleChildRenderObjectWidget`
- `class _RenderHeightCap extends RenderProxyBox`

### chat_document_view.dart  (680 Z.)
- `DateTime? documentUpdatedAt(Map<String, dynamic> document)`  — The agent stamps `updated_at` in epoch seconds — a float for chat documents,
- `String? documentFreshness(Map<String, dynamic> document, {DateTime? now})`  — How fresh a document is, as one short line: `v17 · 00:06`.
- `String documentFileStem(Object? title)`  — A file name for a document, from its title.
- `class ChatDocumentView extends StatefulWidget`
- `class _ChatDocumentViewState extends State<ChatDocumentView>`
- `class _UpdatedMark extends StatelessWidget`  — The quiet end of "make an update legible": a mark, not a message. It never
- `class _DocumentCell extends StatelessWidget`
- `class _DocumentScreen extends StatelessWidget`  — The phone presentation of a document: its own screen, a bar that floats on
- `class _MiddleEllipsis extends StatelessWidget`  — One line that loses its middle, not its end.

### chat_documents_explorer.dart  (706 Z.)
- part of 'chat_documents_panel.dart'
- const: _kScopes _kScopeLabels
- `class _ExplorerOptions`
- `class _DocumentExplorer extends StatefulWidget`  — A view of the real catalog, never a second filesystem or fabricated tree.
- `class _DocumentExplorerState extends State<_DocumentExplorer>`
- `class _Crumb extends StatelessWidget`  — One step of the workspace path. It is a target, so it is the app's own
- `class _SearchField extends StatelessWidget`  — The list's search input, in the shape the roster uses: one rounded filled
- `class _FileGridTile extends StatelessWidget`

### chat_documents_panel.dart  (1237 Z.)
- part 'chat_documents_explorer.dart'
- const: _kTwoPaneWidth _kListWidth
- `class ChatDocumentsPanel extends StatefulWidget`
- `class _ChatDocumentsPanelState extends State<ChatDocumentsPanel>`
- `class _GroupHeading extends StatelessWidget`  — A group heading with its count, in the shape the house uses for the sections
- `class _DocumentRow extends StatelessWidget`  — One list row, in the shape every other list in the app uses (the roster, the
- `class _KindTile extends StatelessWidget`  — The square that carries a row's type glyph: the corner of the icon targets
- `class _PillAction extends StatelessWidget`  — The app's labelled button, with an icon from the app's own set.
- `String? _folderLabel(String path)`  — Where a workspace file sits, short enough for one line. Twenty skills all
- `String? _sizeLabel(Map<String, dynamic> document)`  — The house file-size wording, byte for byte the one the workspace file tiles
- `String _kindLabel(Map<String, dynamic> document)`
- `HugeIconData _documentIcon(Map<String, dynamic> document)`  — The glyph for a row, from the app's own set: the kind first, then the file
- `class _EmptyBlock extends StatelessWidget`  — The panel's one empty state, in the house shape: a large quiet icon, the
- `class _MiddleEllipsis extends StatelessWidget`  — A screen title that loses its middle, not its end.

### chat_maintenance_gate.dart  (303 Z.)
- `class ChatMaintenanceGate extends StatefulWidget`
- `class _ChatMaintenanceGateState extends State<ChatMaintenanceGate>`
- `class _Checking extends StatefulWidget`  — The app surface while the check runs. On a normal start that is a few
- `class _CheckingState extends State<_Checking>`
- `class ChatMaintenanceScreen extends StatelessWidget`
- `class _ProgressRow extends StatelessWidget`

### chat_mode_selector.dart  (593 Z.)
- `class ChatModeSelector extends StatelessWidget`
- `String prettyModelId(String id)`  — A readable name for a model id the catalogue does not know, so the menu
- `class ChatModelChoice`  — A model the reader has picked, as shown in the second menu.
- `class _MenuChoice`  — What a row in the first menu stands for: a mode, or the way one level
- `class _DeeperChoice`  — What a row in the second menu stands for: a reasoning level, a model, or
- `class _SubmenuOpener<T> extends PopupMenuEntry<T>`  — A menu row that opens a cascading submenu on tap WITHOUT popping the menu
- `class _SubmenuOpenerState<T> extends State<_SubmenuOpener<T>>`

### chat_theme.dart  (150 Z.)
- `abstract final class ChatMetrics`  — Shared look tokens for the Agents chat surface.
- `class ChatPalette`  — Role-based colours for the transcript, derived from the active theme so the
- `class ChatAssistantTextTheme extends StatelessWidget`  — Wraps [child] so any Markdown inside it reads at the chat's paragraph size.
- `class ChatColumn extends StatelessWidget`  — Centres its [child] in the reading column: horizontally capped at

### chuk_table.dart  (1202 Z.)
- const: _delimiterCell _wholeCellLink _kEdgePad _kGutter _kMinTextWidth _kActionGlyph _kRowsSampled _kActionHeader _kMaxTextWidth _kRowPadY _kPinnedShare
- `class ParsedTable`  — One parsed markdown table plus the metadata needed to render it.
- `List<String> _splitRow(String line)`  — Splits a single row of raw cell text on unescaped `|`, dropping the empty
- `List<String> splitTableRow(String line)`  — Public wrapper around row splitting, used by the markdown splitter to count
- `TextAlign _alignmentOf(String delimiter)`
- `bool isTableDelimiterRow(String line)`  — Returns true if [line] is a valid GFM delimiter row (`| --- | :-: |`).
- `ParsedTable? parseTable(List<String> lines)`  — Parses a block of lines (header, delimiter, body rows) into a [ParsedTable].
- `({String label, String href})? chukCellLink(String raw)`  — The label and target of a cell that is exactly one link, else null.
- `int chukVisibleLength(String raw)`  — The text a cell actually PAINTS, with the inline markdown taken off.
- `String chukVisibleText(String raw)`  — The same thing as a string: markers dropped, a link reduced to its label.
- `class ChukTable extends StatefulWidget`  — A rounded, dense, copyable rendering of a markdown table.
- `class _Plan`  — The geometry of one drawn table: what each column gets, how tall a row is,
- `class _ChukTableState extends State<ChukTable>`
- `class _CopyButton extends StatelessWidget`  — The copy control under a table.

### chuk_table_classic.dart  (399 Z.)
- const: _kScrollbarLane
- `class ChukTableClassic extends StatefulWidget`  — Upstream's rounded-card table: a shaded, bold header row, thin row
- `class _ChukTableClassicState extends State<ChukTableClassic>`
- `class _CopyButton extends StatelessWidget`

### composer_recording.dart  (184 Z.)
- `class ComposerInputRow extends StatelessWidget`  — Row one of the mobile composer: the text field, and — while the microphone
- `class RecordingWaveformBar extends StatefulWidget`  — The open microphone: the live waveform, and the elapsed time beside it.
- `class _RecordingWaveformBarState extends State<RecordingWaveformBar>`
- `class ComposerSelectionControls extends MaterialTextSelectionControls`  — Selection controls for the composer that leave out the collapsed cursor

### coworker_name_dialog.dart  (179 Z.)
- const: _fieldBorder
- `Future<String?> showCoworkerNameDialog( BuildContext context, { required String title, required String submitLabel, Stri …)`  — Asks for a coworker's name. Returns the trimmed text, or null on Cancel.
- `class CoworkerNameDialog extends StatefulWidget`
- `class _CoworkerNameDialogState extends State<CoworkerNameDialog>`

### credit_display.dart  (897 Z.)
- const: _supabase _kCachedCredits _kCachedHasSubscription _kCachedFreeMessagesRemaining _kCachedFreeMessagesTotal _kCachedTotalCreditsAllocated _kCachedRemainingCredits _kCachedBillingPeriodStart _kCachedBillingPeriodEnd
- `class CreditBalances`
- `mixin _CreditListenerMixin<T extends StatefulWidget> on State<T>`
- `class CreditDisplay extends StatefulWidget`
- `class _CreditDisplayState extends State<CreditDisplay> with _CreditListenerMixin<CreditDisplay>`
- `class CreditBadge extends StatefulWidget`
- `class _CreditBadgeState extends State<CreditBadge> with _CreditListenerMixin<CreditBadge>`
- `class BalanceBadge extends StatefulWidget`  — Smart badge that shows credits for subscribed users OR free messages for non-subscribed u…
- `class _BalanceBadgeState extends State<BalanceBadge>`
- `class _MetaLine extends StatelessWidget`  — Two small captions on one line — the pattern used under both bars.

### diff_widget.dart  (515 Z.)
- const: _kContextLines
- `enum _LineType`
- `class _DiffLine`
- `class _Span`
- `class DiffWidget extends StatefulWidget`  — Renders a before/after comparison as a VS Code–style unified diff:
- `class _DiffWidgetState extends State<DiffWidget>`
- `class _Chip extends StatelessWidget`

### document_viewer.dart  (120 Z.)
- `class DocumentViewer extends StatefulWidget`  — Document viewer for markdown-converted files
- `class _DocumentViewerState extends State<DocumentViewer>`

### encrypted_image_widget.dart  (211 Z.)
- `class EncryptedImageWidget extends StatefulWidget`  — Widget that downloads, decrypts, and displays an encrypted image from storage
- `class _EncryptedImageWidgetState extends State<EncryptedImageWidget>`

### excalidraw_svg_export.dart  (588 Z.)
- `String? excalidrawToSvg(String jsonString)`
- `List<double>? _bounds(Map<String, dynamic> e)`
- `List<double> _rotate(double x, double y, double cx, double cy, double angle)`
- `void _emitElement(StringBuffer buf, Map<String, dynamic> e)`
- `void _emitRectangle( StringBuffer buf, Map<String, dynamic> e, double x, double y, double w, double h, )`
- `void _emitEllipse( StringBuffer buf, Map<String, dynamic> e, double x, double y, double w, double h, )`
- `void _emitDiamond( StringBuffer buf, Map<String, dynamic> e, double x, double y, double w, double h, )`
- `void _emitLine( StringBuffer buf, Map<String, dynamic> e, double x, double y, { required bool arrow, })`
- `void _emitArrowhead( StringBuffer buf, List<double> from, List<double> tip, _Stroke stroke, String shape, )`
- `void _emitText( StringBuffer buf, Map<String, dynamic> e, double x, double y, double w, double h, )`
- `void _emitFreedraw( StringBuffer buf, Map<String, dynamic> e, double x, double y, )`
- `void _emitFrame( StringBuffer buf, Map<String, dynamic> e, double x, double y, double w, double h, )`
- `class _Stroke`
- `_Stroke _resolveStroke(Map<String, dynamic> e)`
- `String? _resolveFill(Map<String, dynamic> e)`
- `String _svgFontFamily(dynamic raw)`
- `String _escapeXml(String s)`
- `String _escapeAttr(String s)`
- `String _fmt(num v)`
- `double _d(dynamic v)`

### expressive_settings.dart  (503 Z.)
- const: kExpressiveOuterRadius kExpressiveInnerRadius kExpressiveTileGap
- `extension ExpressiveOnColor on ColorScheme`  — Picks the contrast colour of a tone from the scheme.
- `class ExpressiveGroup extends StatelessWidget`  — A group of settings tiles. The first and last tile round outwards, the
- `class _ExpressiveTileShape extends InheritedWidget`  — Hands the radii of its place in the group down to the tile.
- `class ExpressiveRow extends StatefulWidget`  — One settings row: a tonal icon, a title, an optional line under it, and
- `class _ExpressiveRowState extends State<ExpressiveRow>`
- `class ExpressiveTile extends StatefulWidget`  — The filled tile every row in a group sits in. Anything can go inside —
- `class _ExpressiveTileState extends State<ExpressiveTile>`
- `class ExpressiveSwitchRow extends StatelessWidget`  — A settings row that carries a switch. The whole tile is the target — the
- `class ExpressiveCard extends StatelessWidget`  — A block that is not a row: a slider, a preview, an editor. It carries the
- `class ExpressiveInfoCard extends StatelessWidget`  — The quiet paragraph under a group: what the setting means, or why it is
- `class ExpressiveField extends StatelessWidget`  — A filled field that holds a dropdown, a text field or a picker, so that
- `class ExpressiveIconTile extends StatelessWidget`  — The rounded tile an icon sits in.
- `class ExpressiveSectionHeader extends StatelessWidget`  — The label above a group. Large and heavy, the way Expressive titles are
- `class ExpressiveBadge extends StatelessWidget`  — A trailing pill: a short state word on the right of a row.

### floating_app_bar.dart  (254 Z.)
- const: kFloatingAppBarHeight kFloatingAppBarChip _kTitleRadius
- `EdgeInsets floatingHeaderInset(BuildContext context, {double extra = 0})`  — The room a scroll view has to leave above its first item so the floating
- `class FloatingHeaderButton extends StatelessWidget`  — A round floating chip for the header — the back arrow, and whatever a
- `class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget`  — The header of a settings-style page: a floating back chip, a floating

### floating_chrome_surface.dart  (84 Z.)
- `Color floatingChromeBase(BuildContext context)`  — One step off the page background — the colour a floating card takes so it
- `class FloatingChromeSurface extends StatelessWidget`  — The one surface every floating piece of chrome uses: the two bars of the

### fullscreen_text_editor.dart  (181 Z.)
- `Future<String?> showFullscreenComposer( BuildContext context, { required String initialText, String title = 'Compose', S …)`  — Opens the message being written on a screen of its own.
- `class _FullscreenComposerPage extends StatefulWidget`
- `class _FullscreenComposerPageState extends State<_FullscreenComposerPage>`

### html_artifact_view.dart  (8 Z.)
- reicht weiter: 'html_artifact_view_io.dart' if (dart.library.js_interop) 'html_artifact_view_web.dart'

### html_artifact_view_io.dart  (114 Z.)
- `bool shouldLoadInWebView(Uri? uri)`  — Returns true for schemes that are allowed to load inside the WebView
- `class HtmlArtifactView extends StatelessWidget`
- `class _HtmlWebView extends StatelessWidget`

### html_artifact_view_source_fallback.dart  (38 Z.)
- `class HtmlSourceFallback extends StatelessWidget`

### html_artifact_view_web.dart  (136 Z.)
- `bool shouldLoadInWebView(Uri? uri)`  — Matches the native predicate so the test surface is shared.
- `class HtmlArtifactView extends StatefulWidget`
- `class _HtmlArtifactViewState extends State<HtmlArtifactView>`

### image_viewer.dart  (472 Z.)
- `class ImageViewer extends StatefulWidget`  — Full-screen image viewer with zoom and pan capabilities
- `class _ImageViewerState extends State<ImageViewer>`

### linux_webview.dart  (92 Z.)
- `class LinuxWebView extends StatelessWidget`

### map_block_renderer.dart  (992 Z.)
- const: mapBlockRegex _kLightTilesUrl _kDarkTilesUrl _kTileSubdomains
- `bool hasMapBlocks(String content)`  — Returns true if [content] contains at least one <map> block.
- `class MapContentSegment`  — A segment of message content — either plain text or a map block.
- `class MapBlockWidget extends StatelessWidget`  — Renders a single <map> JSON block as a Flutter widget.
- `String _tileUrlForBrightness(BuildContext context)`
- `double _toDouble(dynamic v)`
- `bool _isValidLatLon(dynamic latRaw, dynamic lonRaw)`
- `bool _isExplicitNumericZero(dynamic v)`
- `List<Map<String, dynamic>> _filterValidCoordItems(List<dynamic>? items)`
- `List<Map<String, dynamic>> _dedupeCoordItems(List<Map<String, dynamic>> items)`  — Drops repeated places / markers from one block. A multi-pass answer often
- `@visibleForTesting List<Map<String, dynamic>> debugFilterAndDedupeCoordItems( List<dynamic>? items, )`  — Test-only view of [_filterValidCoordItems] + [_dedupeCoordItems].
- `double _mapPreviewHeight(BuildContext context)`
- `double _calculateZoom(List<double> lats, List<double> lons)`
- `double _calculateRouteZoom( double fromLat, double fromLon, double toLat, double toLon, )`
- `MapOptions _buildMapOptions({ required LatLng center, required double zoom, List<LatLng>? fitPoints, })`
- `void _openFullscreenMap( BuildContext context, { required LatLng center, required double zoom, String? title, List<Map<S …)`
- `Widget _buildMapPreview( BuildContext context, { required LatLng center, required double zoom, required List<Widget> map …)`
- `class _MarkersMapBlock extends StatelessWidget`
- `class _PlacesMapBlock extends StatelessWidget`
- `class _PlaceCard extends StatelessWidget`
- `class _RouteMapBlock extends StatelessWidget`

### markdown_message.dart  (2158 Z.)
- part 'answer_blocks.dart'
- const: _latexTag
- `TextStyle _overlayStyle(TextStyle? base, TextStyle overlay)`  — Lays [overlay] on top of [base] field by field.
- `class InlineCodeNode extends SpanNode`  — Inline `` `code` `` that keeps its monospace font, its own colour and its
- `class AccentLinkNode extends LinkNode`  — A link that reads as a link: the accent colour plus an underline in that
- `class _MdSegment`  — One slice of a message: plain markdown, a GFM table block, or an answer
- `class _MdParseCache`  — Splits raw markdown into alternating plain-markdown and table segments so
- `List<Widget> _buildMarkdownWidgets( MarkdownGenerator generator, String data, MarkdownConfig config, { required bool kee …)`  — `MarkdownGenerator.buildWidgets` of markdown_widget 2.3, with the parse
- `List<_MdSegment> _splitSegments(String text)`  — Answer blocks first, then the tables inside the Markdown between them.
- `List<_MdSegment> _splitMarkdownTables(String text)`
- `class MarkdownMessage extends StatefulWidget`
- `class _MarkdownMessageState extends State<MarkdownMessage>`
- `class _AsyncCodeBlock extends StatefulWidget`  — Widget that handles async code highlighting to prevent UI jank
- `class _AsyncCodeBlockState extends State<_AsyncCodeBlock>`
- `List<hi.Node> _parseCode(Map<String, dynamic> args)`
- `bool _isMostlyNonAsciiCode(String text)`  — Top-level helper for checking if text is mostly non-ASCII (for isolate use)
- `List<TextSpan> _convertNodesSafely( List<hi.Node>? nodes, Map<String, TextStyle> theme, TextStyle baseStyle, )`
- `List<TextSpan> _collectSpans( hi.Node? node, Map<String, TextStyle> theme, TextStyle baseStyle, TextStyle? parentThemeSt …)`
- `class LatexSyntax extends m.InlineSyntax`  — LaTeX inline syntax parser - matches $$...$$ and \(...\) and \[...\].
- `class LatexNode extends SpanNode`  — LaTeX node that renders math using flutter_math_fork
- `class _CopyButton extends StatefulWidget`  — Copy button widget for code blocks
- `class _CopyButtonState extends State<_CopyButton>`
- `class _SafeCodeBlockNode extends ElementNode`  — Replacement for markdown_widget's CodeBlockNode that avoids noisy
- `class _MarkdownImage extends StatelessWidget`  — Polished markdown image: full-width on mobile bubbles (capped at 540px wide
- `class _NetworkImageViewer extends StatelessWidget`

### mcp_connect_card.dart  (207 Z.)
- `class McpConnectCard extends StatefulWidget`  — A single Connect button for one catalogue server, shown inline under an
- `class _McpConnectCardState extends State<McpConnectCard>`

### measure_size.dart  (49 Z.)
- `typedef OnWidgetSizeChange = void Function(Size size)`  — Callback invoked whenever the measured child changes size.
- `class MeasureSize extends SingleChildRenderObjectWidget`  — Reports its child's laid-out size via [onChange] after every layout in which
- `class _MeasureSizeRenderObject extends RenderProxyBox`

### menu_tile_group.dart  (349 Z.)
- const: kMenuOuterRadius kMenuInnerRadius kMenuTileGap kMenuGroupGap
- `class MenuTileGroup extends StatelessWidget`  — A menu drawn as a run of filled tiles instead of one boxed card.
- `class MenuActionRow extends StatelessWidget`  — One row of a menu: an icon, a label, an optional line under it and
- `Future<T?> showMenuSheet<T>( BuildContext context, { required List<List<Widget>> groups, Widget? header, Color? color, } …)`  — A menu as a bottom sheet: the house sheet chrome, then the same tiles a
- `class MenuAnchorButton extends StatelessWidget`  — The control a menu hangs off: the current value, an arrow, and the tap

### message_bubble.dart  (471 Z.)
- part 'message_bubble/models.dart' · part 'message_bubble/layout.dart' · part 'message_bubble/chrome.dart' · part 'message_bubble/rich_blocks.dart' · part 'message_bubble/tools.dart' · part 'message_bubble/images.dart' · part 'message_bubble/cards.dart'
- const: _kBlockGap _kArtifactGap _kCardStackGap _kInfoBarGap _kMobileBottomBarHeight _richBlockRegex _visualBlockStartRegex _diffBlockRegex _attachmentHeaderRe _kAiResponseFontFamilyDefault _cachedShowReasoningTokens _cachedShowModelInfo
- `class MessageBubble extends StatefulWidget`
- `class _MessageBubbleState extends State<MessageBubble>`

### message_fly_in.dart  (70 Z.)
- `class MessageFlyIn extends StatefulWidget`  — A one-shot entrance for a just-sent message: the bubble starts a little
- `class _MessageFlyInState extends State<MessageFlyIn> with SingleTickerProviderStateMixin`

### messenger_context_menu.dart  (211 Z.)
- `Future<String?> showMessengerContextMenu({ required BuildContext context, required Rect anchor, required Widget preview …)`  — A focused message above a separate action sheet, like a messenger's

### messenger_typing_indicator.dart  (96 Z.)
- `class MessengerTypingIndicator extends StatefulWidget`  — A local presentation of a real in-flight turn; never a synthetic message.
- `class _MessengerTypingIndicatorState extends State<MessengerTypingIndicator> with SingleTickerProviderStateMixin`

### model_selection_dropdown.dart  (1432 Z.)
- const: _menuHorizontalPadding _menuTrailingAllowance _menuExtraAllowance _buttonHorizontalPadding _buttonTrailingAllowance kAutoCheapestProviderSlug
- `class ModelProviderSummary`
- `class _WidthMetrics`
- `class ModelProviderLimits`
- `class _AuthRequiredException implements Exception`
- `class _FilteredModelResult`
- `class ModelSelectionDropdown extends StatefulWidget`
- `class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> with ApiAvailabilityPolling<ModelSelectionDropd …)`
- `String _stripLabPrefix(String name)`  — OpenRouter model names arrive as "Lab: Model Name" (e.g. "Qwen: Qwen3.5-9B").

### nice_snackbar.dart  (55 Z.)
- `class NiceSnackBar`  — The old name for [AppNotifications], kept so the call sites that already

### pane_header.dart  (71 Z.)
- `class PaneHeader extends StatelessWidget`  — A side pane's header: 56 px high, a quiet line under it, an 18 px glyph

### password_strength_meter.dart  (145 Z.)
- `class PasswordStrengthMeter extends StatelessWidget`  — A widget that displays password strength with visual indicators.

### per_model_system_prompt_sheet.dart  (285 Z.)
- `Future<bool?> showPerModelSystemPromptSheet({ required BuildContext context, required String modelId, required String mo …)`  — Bottom sheet for editing a per-model system prompt and merge mode.
- `class _PerModelSystemPromptEditor extends StatefulWidget`
- `class _PerModelSystemPromptEditorState extends State<_PerModelSystemPromptEditor>`
- `class _ModeChips extends StatelessWidget`

### room_create_sheet.dart  (234 Z.)
- const: kRoomSearchThreshold
- `class RoomCreateSheet extends StatefulWidget`
- `class _RoomCreateSheetState extends State<RoomCreateSheet>`

### room_faces.dart  (190 Z.)
- const: kRoomFacesMax _kFaceOfSlot _kFaceGap kRoomFacesInbox kRoomFacesRail
- `String roomMembersLabel(AgentsRoom room)`  — Who is in a room, by the handle they are mentioned with. This is the line
- `typedef RoomFacePlacement = ({double left, double top, double size})`  — One geometry entry: where a face sits in the slot, and how big it is.
- `class RoomFaces extends StatelessWidget`
- `class _RingedFace extends StatelessWidget`  — One member's face with the gap that lifts it off the face beneath it.

### room_list_view.dart  (295 Z.)
- `class RoomListView extends StatelessWidget`
- `class _RenameDialog extends StatefulWidget`  — The rename dialog. A StatefulWidget so it owns and disposes its own text
- `class _RenameDialogState extends State<_RenameDialog>`

### room_members_sheet.dart  (177 Z.)
- `class RoomMembersSheet extends StatelessWidget`

### room_mention_picker.dart  (421 Z.)
- const: kBroadcastHandle kBroadcastAliases
- `bool _isHandleChar(int code)`  — A character that may sit inside a handle. Mirrors the manager's `_MENTION`
- `bool _isSpace(int code)`
- `@immutable class MentionToken`  — The `@token` the caret is inside, as a range over the text.
- `MentionToken? activeMentionToken(String text, int caret)`  — The `@token` [caret] sits in, or null when it sits nowhere near one.
- `@immutable class MentionEdit`  — The text and caret after a pick.
- `MentionEdit applyMention({ required String text, required MentionToken token, required String handle, })`  — Replace [token] with `@handle ` and say where the caret goes.
- `@immutable class MentionEntry`  — One row of the picker: a member of the room, or the broadcast row.
- `List<MentionEntry> mentionEntriesFor({ required List<AgentsRoomMember> members, List<AgentsAgent> agents = const <Agents …)`  — The room's members as picker rows, with `@all` first.
- `bool _prefix(String value, String query)`
- `List<MentionEntry> filterMentions(List<MentionEntry> entries, String query)`  — The rows that match what is typed: the broadcast row first, then the ones
- `class RoomMentionPicker extends StatefulWidget`  — The list that floats over the composer while a token is open.
- `class _RoomMentionPickerState extends State<RoomMentionPicker>`
- `class _MentionRow extends StatelessWidget`  — One compact line: the face, the name, the handle in the quiet colour, and

### room_thread_page.dart  (508 Z.)
- `class RoomThreadPage extends StatefulWidget`
- `class _RoomThreadPageState extends State<RoomThreadPage>`

### room_thread_view.dart  (280 Z.)
- const: _kFaceSize _kFaceGap
- `class RoomThreadView extends StatelessWidget`

### route_map_widget.dart  (345 Z.)
- `class RouteMapWidget extends StatefulWidget`  — Displays a route map with OSRM polyline, start/end markers,
- `class _RouteMapWidgetState extends State<RouteMapWidget>`

### sandbox_artifact_block.dart  (765 Z.)
- `class SandboxArtifactBlock extends StatefulWidget`
- `class _SandboxArtifactBlockState extends State<SandboxArtifactBlock>`
- `class _ArtifactCard extends StatelessWidget`
- `class _FileName extends StatelessWidget`  — The file name, with the extension in the quieter colour.
- `String _kindLabel(String mime)`  — A short, readable name for a mime type. `text/markdown` says nothing to a
- `class _ArtifactErrorRow extends StatelessWidget`

### searchable_picker.dart  (311 Z.)
- `class PickerOption<T>`  — One row of a picker.
- `Future<T?> showSearchablePicker<T>( BuildContext anchorContext, { required List<PickerOption<T>> options, String? hintTe …)`  — Opens the picker at [anchorContext]'s widget and returns the chosen value,
- `Future<T?> _showPickerSheet<T>( BuildContext context, { required List<PickerOption<T>> options, required String hintText …)`
- `class _PickerPanel<T> extends StatefulWidget`
- `class _PickerPanelState<T> extends State<_PickerPanel<T>>`

### selection_copy_area.dart  (243 Z.)
- `class SelectionCopyShortcut`  — Pure decision logic for the copy shortcut, kept out of the widget so it can
- `class SelectionCopyArea extends StatefulWidget`  — A [SelectionArea] whose Ctrl+C / Cmd+C does not depend on the focus tree.
- `class SelectionCopyAreaState extends State<SelectionCopyArea>`

### settings_list_view.dart  (108 Z.)
- `class SettingsListView extends StatefulWidget`  — Scroll container for settings-style pages with a bounded set of rows.
- `class _SettingsListViewState extends State<SettingsListView>`

### settings_search_bar.dart  (211 Z.)
- const: kSettingsSearchBarHeight _kFieldHeight
- `class SettingsSearchBar extends StatefulWidget`  — The search field of a settings page: a floating pill with the magnifier on
- `class _SettingsSearchBarState extends State<SettingsSearchBar>`
- `class PinnedSettingsSearchBar extends StatelessWidget implements PreferredSizeWidget`  — The same bar, sized to sit in a [FloatingAppBar]'s `bottom` slot so it

### technical_drawing_layers.dart  (28 Z.)
- `int technicalDrawingLayerPriority(Map<String, dynamic> element)`  — Paint order for one element of a technical drawing.

### technical_drawing_svg_export.dart  (485 Z.)
- `String? technicalDrawingToSvg(String jsonString)`  — Converts a technical_drawing JSON string into an SVG document string.
- `void _writeElement(StringBuffer sb, Map<String, dynamic> e)`
- `String _strokeWidth(String weight)`
- `String? _dashArray(String lineStyle)`
- `String _strokeAttrs(Map<String, dynamic> e)`
- `String? _normalizeHex(dynamic v)`  — Normalize hex (#RGB, #RRGGBB, RGB, RRGGBB) → "#RRGGBB". Returns null
- `void _writeRect(StringBuffer sb, Map<String, dynamic> e)`
- `void _writeCircle(StringBuffer sb, Map<String, dynamic> e)`
- `void _writeLine(StringBuffer sb, Map<String, dynamic> e)`
- `void _writeDimension(StringBuffer sb, Map<String, dynamic> e)`
- `void _writeArrow( StringBuffer sb, double tipX, double tipY, double fromX, double fromY, )`
- `void _writeDimText( StringBuffer sb, String value, double cx, double cy, { required bool rotate, })`  — Text with opaque white background — used when text must break through
- `void _writeDimTextAbove( StringBuffer sb, String value, double anchorX, double anchorY, { required bool rotate, })`  — DIN-style dim text: placed ABOVE the dim line, no background needed since
- `void _writeNote(StringBuffer sb, Map<String, dynamic> e)`
- `void _writeTitleBlock( StringBuffer sb, Map<String, dynamic> meta, double sheetW, double sheetH, )`
- `double _d(dynamic v)`
- `String _f(double v)`
- `String _escapeXml(String s)`

### technical_drawing_widget.dart  (856 Z.)
- `class TechnicalDrawingWidget extends StatelessWidget`
- `class TechDrawData`
- `class TechDrawPainter extends CustomPainter`
- `class _ErrorCard extends StatelessWidget`

### top_centre_slot.dart  (69 Z.)
- `class TopCentreSlot extends StatelessWidget`  — Lays [child] out on the centre line of the box it fills, pushed sideways
- `class _TopCentreDelegate extends SingleChildLayoutDelegate`

### update_banner.dart  (97 Z.)
- `class UpdateBanner extends StatelessWidget`  — A compact banner shown in the sidebar when a new app version is available.

### vnc_local_server.dart  (353 Z.)
- `typedef VncAssetReader = Future<Uint8List> Function(String assetKey)`  — Reads one app asset. Injected so the server can be tested without a bundle.
- `Future<Uint8List> _bundleAsset(String assetKey)`
- `class VncLocalServer`  — The loopback server that feeds the noVNC viewer page.

### vnc_trackpad_overlay.dart  (999 Z.)
- `class VncTrackpadOverlay extends StatefulWidget`  — A touch trackpad over the agent's browser view, for phones and tablets.
- `enum _TwoFingerMode`  — What a two-finger gesture turned out to be. It starts undecided: the same
- `class _VncTrackpadOverlayState extends State<VncTrackpadOverlay>`
- `class _VncCursor extends StatelessWidget`  — The virtual mouse cursor: an arrow you can actually see.
- `class _VncCursorPainter extends CustomPainter`
- `class _ZoomChip extends StatelessWidget`  — The zoom readout. It says how far in the picture is and takes it back to
- `class _SpecialKeyBar extends StatelessWidget`  — The keys a phone keyboard does not give you, and a browser needs: escape a
- `class _TrackpadHelpCard extends StatelessWidget`  — The gesture cheat-sheet shown on first use and behind the "?" button.
- `class _HelpRow extends StatelessWidget`

### vnc_view_fit.dart  (195 Z.)
- `@immutable class VncViewFit`  — Where the remote framebuffer sits on the screen, and how to convert between

### vnc_webview_controls.dart  (356 Z.)
- `class VncLoadingSteps extends StatelessWidget`  — What the view is still waiting for, as named steps rather than a spinner.
- `class _VncStep extends StatelessWidget`
- `class VncReconnectingNote extends StatefulWidget`  — The note over a frozen picture while the socket re-handshakes.
- `class _VncReconnectingNoteState extends State<VncReconnectingNote>`
- `class VncControlBar extends StatelessWidget`  — The row of controls under the agent's screen.
- `class VncKeyboardField extends StatelessWidget`  — The invisible field that takes the soft keyboard.

### vnc_webview_screen.dart  (268 Z.)
- `enum VncPhase`  — What the viewer page says about its socket.
- `class VncWebViewController extends ChangeNotifier`  — The host side of the noVNC viewer page.
- `class VncWebView extends StatefulWidget`  — The WebView that runs the viewer page.
- `class _VncWebViewState extends State<VncWebView>`

### waveform.dart  (143 Z.)
- `class WaveformPainter extends CustomPainter`  — Paints [bars] (each 0..1) as rounded vertical bars, colouring everything
- `class LiveWaveform extends StatelessWidget`  — The live level meter of an open microphone, in the waveform shape.

### weather_widget.dart  (519 Z.)
- `class WeatherBlockWidget extends StatelessWidget`  — Renders `<weather>` JSON blocks emitted by the AI as a polished weather card.

### workspace_file_viewer.dart  (666 Z.)
- `class WorkspaceFileViewer extends StatefulWidget`  — Dialog to view and edit workspace files and their markdown summaries
- `class _WorkspaceFileViewerState extends State<WorkspaceFileViewer> with SingleTickerProviderStateMixin`

### workspace_panel.dart  (706 Z.)
- `class WorkspacePanel extends StatefulWidget`  — Right-side panel for workspace settings (Instructions + Files)
- `class _WorkspacePanelState extends State<WorkspacePanel> with WorkspaceActionsMixin<WorkspacePanel>`

### workspace_selection_dropdown.dart  (283 Z.)
- `class WorkspaceSelectionDropdown extends StatefulWidget`
- `class _WorkspaceSelectionDropdownState extends State<WorkspaceSelectionDropdown>`

## lib/widgets/agent_activity
### agent_activity_model.dart  (462 Z.)
- const: _subjectKeys _maxDetailChars _maxThinkingChars maxSourcesPerStep
- `enum AgentActivityKind`  — What a timeline line represents. Drives the icon and the wording.
- `class AgentActivitySource`  — A page a step pulled in, shown as a chip under that step.
- `class AgentActivityEntry`  — One line in the timeline.
- `AgentActivityKind _kindOf(ToolCall call)`
- `String? _subjectOf(ToolCall call)`
- `String _clip(String value, int max)`
- `String _shortenUrl(String url)`  — Strip the scheme and any `www.` so a URL reads as a place, not a link.
- `String _humanizeToolName(String name)`  — Human wording for a tool name: `generate_image` → `generate image`.
- `String? runningActivityLabel(List<ToolCall> calls)`  — Present-tense name for what a running turn is doing RIGHT NOW, so the
- `String _runningVerbFor(String name)`  — Present-tense phrase for a non-search, non-page tool the turn is waiting on.
- `AgentActivityEntry _entryFor(ToolCall call)`
- `class AgentActivityStep`  — One thing that happened in a round, in the order it happened: either a
- `AgentActivityEntry reasoningEntry(String text)`  — The line and the body for one stretch of reasoning.
- `List<AgentActivityEntry> buildAgentActivityEntriesFromSteps( List<AgentActivityStep> steps, )`  — Build the timeline lines for an ordered mix of reasoning and calls.
- `List<AgentActivityEntry> buildAgentActivityEntries( List<ToolCall> calls, { bool includeRoundThinking = true, })`  — Build the timeline lines for [calls].
- `List<AgentActivitySource> extractSourcesFor(ToolCall call)`  — The pages a call pulled in.
- `String _firstSentence(String text)`  — First sentence of [text], or the whole string when it has no break.
- `Duration? agentActivityDuration( List<ToolCall> calls, { required DateTime now, bool running = false, })`  — Total wall time of a round: first start to last completion.
- `String formatAgentDurationLive(Duration duration)`  — Compact duration wording: `4s`, `1m 3s`, `2h 5m`.
- `String formatAgentDuration(Duration duration)`

### agent_activity_timeline.dart  (507 Z.)
- `class AgentActivityTimeline extends StatefulWidget`
- `class _AgentActivityTimelineState extends State<AgentActivityTimeline>`

### turn_status.dart  (124 Z.)
- `class TurnStatus`  — The status of one assistant turn, as the header above it reports it.
- `bool hasRunningToolCall(List<ToolCall> calls)`  — True while any call in [calls] is still pending or running.
- `Duration? resolveTurnElapsed({ Duration? finalDuration, DateTime? startedAt, required DateTime now, required bool isRunn …)`  — How long the turn has taken, from the most trustworthy source available.

## lib/widgets/agents_desktop
### desktop_controls.dart  (79 Z.)
- `class PaneResizeHandle extends StatelessWidget`  — The drag target on a pane border, drawn as chuk_chat draws the divider in
- `String deskShortcutLabel(String keys)`  — The platform's name for the primary modifier: Cmd on a Mac, Ctrl
- `bool deskPrimaryModifierPressed()`  — Whether the platform's primary modifier is down (Cmd on a Mac).

### desktop_dialog.dart  (61 Z.)
- `bool isAgentsDesktop(BuildContext context)`  — Whether [context] is laid out as the desktop (not the phone).
- `Future<T?> showAgentsSheetOrDialog<T>({ required BuildContext context, required WidgetBuilder builder, })`  — A form that is a bottom sheet on the phone and a centred dialog, at most
- `class AgentsDesktopDialog extends StatelessWidget`  — The dialog frame itself: chuk_chat's dialog — the surface, corner and

### desktop_metrics.dart  (31 Z.)
- const: kDeskRosterMin kDeskRosterMax kDeskRosterDefault kDeskRailWidth kDeskDetailsMin kDeskDetailsMax kDeskDetailsDefault kDeskThreadMin kDeskDialogMaxWidth kDeskDialogRadius

### quick_switcher.dart  (335 Z.)
- `sealed class QuickSwitcherPick`  — What the user picked.
- `class QuickSwitcherAgent extends QuickSwitcherPick`
- `class QuickSwitcherRoom extends QuickSwitcherPick`
- `Future<QuickSwitcherPick?> showQuickSwitcher( BuildContext context, { required List<AgentsAgent> agents, required List<A …)`  — Opens the switcher near the top of the window. Returns the pick, or null
- `class QuickSwitcher extends StatefulWidget`
- `class _QuickSwitcherState extends State<QuickSwitcher>`

## lib/widgets/agents_permissions
### agent_permissions_section.dart  (316 Z.)
- const: kAgentPermissionSpecs kPermissionsAppliesLine kPermissionNotEnforced
- `@immutable class AgentPermissionSpec`  — One switch of the section: the wire key, the words and the icon.
- `class AgentPermissionsSection extends StatefulWidget`
- `enum _Phase`
- `class _AgentPermissionsSectionState extends State<AgentPermissionsSection>`

## lib/widgets/charts
### chart_painter.dart  (1458 Z.)
- const: _kMinLabelFontSize _kAxisFontSize _kLabelFontSize _kValueFontSize
- `enum ChartLabelLayout`  — How the category labels under the plot are laid out, once measured.
- `class ChartGeometry`  — Everything the painter worked out from the spec and the box it was given.
- `enum ChartBoxKind`  — What a measured box belongs to. The reference label dodges all of them;
- `@immutable class ChartBox`  — One box the painter put down, kept so the reference label can step around
- `class ChukChartPainter extends CustomPainter`
- `TextStyle _axisStyle()`
- `TextStyle _labelStyle()`
- `TextStyle _valueStyle()`
- `TextPainter _paint( String text, TextStyle style, TextScaler scaler, String? fontFamily, { double maxWidth = double.infi …)`
- `class _RefLabel`  — The reference line's label once it has found a spot: what it says, laid
- `class _Span`  — A stretch of a strip, in x.
- `class _Range`
- `_Range _rangeFor(ChartSpec spec)`  — The value range and the gridline step.
- `double _niceStep(double range, int target)`
- `int _decimalsFor(double step)`
- `String _tickText(double v, ChartSpec spec, int decimals)`  — An axis tick. Big numbers are abbreviated (62k, 1.2M) so the axis column
- `String _trimZeros(String s)`

### chart_palette.dart  (149 Z.)
- `@immutable class ChartPalette`  — The resolved colours for one chart in one theme.

### chart_spec.dart  (888 Z.)
- `enum ChartKind`  — What the chart draws.
- `enum ChartSort`  — How the points are ordered before they are drawn.
- `enum ChartDirection`  — Whether a series is a good thing going up or a bad thing going down. Used
- `@immutable class ChartPoint`  — One category and its value.
- `@immutable class ChartSeries`  — One line or one bar family.
- `@immutable class ChartAxis`  — The optional min/max the agent asked for.
- `@immutable class ChartReferenceLine`  — One horizontal rule across the plot — the 5 % threshold.
- `@immutable class ChartSpec`  — A parsed, validated chart.
- `List<ChartPoint> _parsePoints( Object? raw, List<String> problems, { required String where, List<String>? xLabels, })`  — Reads a list of points. Accepts three shapes, because all three turn up in
- `List<String>? _labelList(Object? raw)`
- `String? _asText(Object? raw)`
- `bool? _asBool(Object? raw)`
- `int? _asInt(Object? raw)`
- `double? _asNumber(Object? raw)`  — A number out of a number, or out of the many ways a model writes one:
- `DateTime? _asDate(Object? raw)`
- `Color? parseChartColor(Object? raw)`  — "#RRGGBB", "RRGGBB", "#AARRGGBB" or an int, into a [Color]. Anything else

### chuk_chart.dart  (532 Z.)
- reicht weiter: 'package:chuk_chat/widgets/charts/chart_spec.dart'
- const: kChukChartRadius kChukChartEntrance
- `Widget chukChartFromJson( Object? json, { Key? key, Color? accentColor, String? fontFamily, bool animate = true, })`  — Builds a chart from whatever the agent emitted: a decoded map, a JSON
- `class ChukChart extends StatefulWidget`  — Draws a [ChartSpec]: a card with a title, a plot and a source line.
- `class _ChukChartState extends State<ChukChart> with SingleTickerProviderStateMixin`
- `String chartSourceLine(ChartSpec spec)`  — "Source · 2026-09-12 20:15", or an empty string when neither is known.
- `String _stamp(DateTime d)`
- `String _semanticLabel(ChartSpec spec)`  — A one-sentence description for a screen reader.
- `class _Heading extends StatelessWidget`  — The heading of a chart card: title, then subtitle.
- `class ChukChartFallback extends StatelessWidget`  — What a chart that could not be drawn shows instead.

## lib/widgets/icons
### huge_icon.dart  (211 Z.)
- const: _opticalInset
- `@immutable class HugeIconData`  — One icon of the set. The name is the file stem, so `HugeIcons.message01`
- `abstract final class HugeIcons`
- `class HugeIcon extends StatelessWidget`  — An icon of the set, drawn like a Material [Icon].

### icon_map.dart  (266 Z.)
- const: _map
- `HugeIconData? hugeIconFor(IconData icon)`  — The app's icon for [icon], or null when the set has nothing for it.
- `class AppIcon extends StatelessWidget`  — An icon that prefers the app's set and falls back to Material.

### model_logo.dart  (84 Z.)
- const: kModelLogoByLab
- `String? modelLogoAsset(String modelId)`  — The bundled logo for [modelId], or null when its lab has no logo.
- `class ModelLogo extends StatelessWidget`  — A model row's leading glyph: the lab logo at [logoSize] inside a

## lib/widgets/message_bubble
### cards.dart  (905 Z.)
- part of '../message_bubble.dart'
- `class _CachedImageThumbnail extends StatefulWidget`  — Cached image thumbnail that decodes once and caches the bytes
- `class _CachedImageThumbnailState extends State<_CachedImageThumbnail> with AutomaticKeepAliveClientMixin`
- `class _ArtifactInlineCard extends StatefulWidget`  — Compact artifact card shown inline in chat after artifact_manager calls.
- `class _ArtifactInlineCardState extends State<_ArtifactInlineCard>`
- `class _ArtifactErrorCard extends StatelessWidget`  — Visible error chip when an inline artifact tag (or artifact_manager tool
- `class _NewsCard extends StatelessWidget`  — News article card: thumbnail (left, 96x96), title, publisher · age, summary,

### chrome.dart  (412 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleChrome on _MessageBubbleState`

### images.dart  (642 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleImages on _MessageBubbleState`

### layout.dart  (1134 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleLayout on _MessageBubbleState`

### models.dart  (135 Z.)
- part of '../message_bubble.dart'
- `class ImageMeta`  — Per-image metadata describing how an image arrived in the chat and
- `class DocumentAttachment`  — Document attachment data
- `class MessageBubbleAction`
- `class _RenderSegment`
- `class _ToolTimelineEntry`

### rich_blocks.dart  (562 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleRichBlocks on _MessageBubbleState`

### tools.dart  (828 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleTools on _MessageBubbleState`

### web_search_sources.dart  (289 Z.)
- `class WebSearchSource`  — One parsed hit from a web_search result.
- `String _clean(String s)`  — Strip HTML tags + the handful of entities the search backend emits, and
- `String _hostOf(String url)`
- `List<WebSearchSource> parseWebSearchSources(String result)`  — Parse a `web_search` result into ordered source hits. Returns an empty
- `class WebSearchSourcesCard extends StatelessWidget`  — Renders parsed [WebSearchSource]s as tappable source cards.
- `class _SourceCard extends StatelessWidget`
- `class _Favicon extends StatelessWidget`  — Favicon for [host] via Google's public favicon service, with a globe

## lib/widgets/sidebar
### hover_marquee_text.dart  (215 Z.)
- `class HoverMarqueeText extends StatefulWidget`  — A single-line title that shows an ellipsis at rest and, when the pointer
- `class _HoverMarqueeTextState extends State<HoverMarqueeText> with SingleTickerProviderStateMixin`

### sidebar_chrome.dart  (1795 Z.)
- const: kSbCardGap kSbBlockInset kSbCardRadius kSbCardJointRadius kSbNavCardHeight kSbNavRowStep _kSbMenuCentre kSbNavBlockTop kSbNavIconLeft kSbNavIconTile kSbNavIconTop kSbNavIconCentre
- `Color sbPanelBackground(BuildContext context)`  — The colour the sidebar panel is painted in — the same step off the page
- `double sbNavRowTop(int index)`  — Top of row [index] of the navigation block — the cards when the panel is
- `class SidebarTokens`
- `class SbCard extends StatefulWidget`  — The filled, rounded card every sidebar row sits in.
- `class _SbCardState extends State<SbCard>`
- `class SbCardHoverScope extends InheritedWidget`  — Publishes the hover state of the enclosing [SbCard] to its content.
- `class SbBlock extends StatelessWidget`  — A stack of cards that belong together — the navigation block, or the chats
- `BorderRadius sbBlockRadiusFor({ required int index, required int length, bool joinTop = false, })`  — The corners of the card at [index] in a block of [length] cards: outward
- `class SbCardShape extends InheritedWidget`  — Carries the shape a card should take from its block down to the card.
- `class SbNavIcon extends StatelessWidget`  — The glyph of a navigation entry: the bare icon in the accent colour, in a
- `class SbNavCard extends StatelessWidget`  — One navigation entry: a full-width card with a coloured icon and a bold
- `class SbRoundAction extends StatelessWidget`  — A round icon button on the card fill — the shape the head bar and the
- `class SbGroupHeader extends StatelessWidget`  — The header above a block: a quiet label, the number of items in the group,
- `class SbSearchField extends StatefulWidget`  — The pill-shaped search field of the bottom bar.
- `class _SbSearchFieldState extends State<SbSearchField>`
- `class SbAccountLine extends StatelessWidget`  — The bottom bar of the phone sidebar: who is signed in, what is left on the
- `class SbChatTile extends StatelessWidget`  — One chat in a group block: the title, the date under it, and the actions
- `class _SbChatTileBody extends StatelessWidget`  — Split out so it can read the card's hover state, which the card publishes
- `class SbChatGroup<T>`  — A time group: the header label and the chats that fall into it.
- `List<SbChatGroup<T>> sbGroupByTime<T>( List<T> items, DateTime Function(T item) dateOf, { required String Function(DateT …)`  — Buckets chats into Today / This week / This month / one group per older
- `String sbChatDateLine(BuildContext context, DateTime? date, {DateTime? now})`  — The muted line under a chat title: the time for anything from today, the
- `class SbOfflineNotice extends StatelessWidget`  — The strip that says the list is stale because the device is offline, with
- `class SbRailSlot extends StatelessWidget`  — One target of the folded rail: the round ink the mini rail's icons take,
- `class SbFloatingBar extends StatelessWidget`  — A card that floats over the scrolling list — the app name at the top of
- `class SbBrand extends StatelessWidget`  — Brand row: optional logo square + text. Trailing widget on the right.
- `class SbSearchTrigger extends StatelessWidget`  — Subtle search trigger — rounded icon button with "Search" label.
- `class SbNewChatPill extends StatelessWidget`  — Compact accent pill — used for mobile top-right "New chat".
- `class SbNavItem extends StatelessWidget`  — Sidebar nav row (icon + label, stacked vertically). Primary highlights accent.
- `class SbRailRow extends StatelessWidget`  — Rail-aligned nav row. 48 px tall, icon centred inside a 48x48 square at
- `class SbSectionLabel extends StatelessWidget`  — Mixed-case section label with optional count. Claude.ai style.
- `class SbPinnedBento extends StatelessWidget`  — Accent-tinted "Pinned" bento card. Caller supplies the row widgets.
- `class SbStickyLabelDelegate extends SliverPersistentHeaderDelegate`  — Sliver delegate that renders an SbSectionLabel as a pinned header. The
- `class SbHairline extends StatelessWidget`  — Hairline divider matching app palette.

### sidebar_common.dart  (530 Z.)
- const: kSidebarPageSize kSidebarAddComputerLabel kSidebarAddComputerKey
- `String normalizeSidebarTitle(String title)`  — Strips generated Markdown decoration from a chat title before display.
- `String deriveSidebarChatTitle(StoredChat chat)`
- `String sidebarDisplayName(ProfileRecord? profile)`
- `List<Widget> buildSidebarNavigationCards({ required BuildContext context, required bool showWorkspaces, required VoidCal …)`  — The destinations shared by both sidebars, with a platform-owned search
- `mixin SidebarStateCommon<T extends StatefulWidget> on State<T>`  — Common state, mutations, and grouped-list construction for both sidebars.

## lib/widgets/workspace
### workspace_actions_mixin.dart  (277 Z.)
- `mixin WorkspaceActionsMixin<T extends StatefulWidget> on State<T>`  — Shared workspace actions for a [State] that manages a single workspace.

### workspace_common_widgets.dart  (348 Z.)
- `class WorkspaceCountBadge extends StatelessWidget`  — Small pill with a count, used in the workspace tab bars.
- `class WorkspaceEmptyState extends StatelessWidget`  — Centered "nothing here yet" placeholder used by the files and chats tabs.
- `class WorkspaceUploadProgressCard extends StatelessWidget`  — Card that shows the running file upload (progress bar + status text).
- `class WorkspaceFileTile extends StatelessWidget`  — One row in a workspace file list: icon, name, caller-supplied subtitle and
- `class WorkspaceChatsTab extends StatelessWidget`  — The "Chats" tab shared by the workspace detail and management pages.

## scripts
### generate_icons.py  (270 Z.)
- `def draw_chat_brain_icon(size, line_width_ratio=0.08, padding_ratio=0.05)`  — Draw a chat bubble with brain icon (Material You style)
- `def generate_android_icons()`  — Generate Android launcher icons (mipmap)
- `def generate_ios_icons()`  — Generate iOS app icons
- `def generate_web_icons()`  — Generate web app icons
- `def generate_adaptive_icon()`  — Generate Android Adaptive Icon (foreground + background)

### generate_wordmark_svg.py  (185 Z.)
- const: REPO OUT BOLD REGULAR WORDMARK WORDMARK_PX SLOGAN SLOGAN_PX SLOGAN_TRACKING_PX SLOGAN_OPACITY WORDMARK_BASELINE_Y
- `def find_font(filename, fc_pattern)`  — Locate a Liberation Mono face: known Debian path, else fc-match.
- `def fmt(v, nd=3)`
- `def glyph_ink_bbox(d)`  — Ink bbox of an SVG path in font units (control points; exact enough
- `def line_paths(font_path, text, px, baseline_y, pen_x, tracking=0.0)`  — Outline one text line. Returns (svg path elements, ink bbox).
- `def css_baseline_gap()`  — Distance between the two baselines when Chrome stacks a 22px line
- `def main(): # Line 1 — frozen wordmark. Pen starts at -0.859 so the C's ink hits # x=0 exactly, matching the original ha …)`

### release_notes.py  (195 Z.)
- const: DEFAULT_REPO SECTIONS COMMIT_RE MERGE_RE
- `def run(*args: str) -> str`
- `def tag_exists(tag: str) -> bool`
- `def version_key(tag: str) -> tuple[int, int, int, int, int, str]`  — Sort key for `v1.2.3` and `v1.2.3-pre.4` tags.
- `def previous_tag(tag: str) -> str | None`  — The release tag the changelog starts from.
- `def commit_of(tag: str) -> str`  — The short commit a tag points at, or "" when it cannot be resolved.
- `def collect(rev_range: str) -> list[tuple[str, str]]`  — Every non-merge commit in the range, oldest first.
- `def section_for(subject: str) -> tuple[str, str]`  — Return (section title, cleaned subject) for one commit subject.
- `def render(tag: str, prev: str | None, repo: str) -> str`
- `def main() -> int`

## tool
### gen_skills.dart  (191 Z.)
- const: kSkillsDir kOutputPath
- `void main(List<String> args)`
- `List<Skill> loadSkillsFromDisk(Directory skillsDir)`  — Parses every `<dir>/<name>/SKILL.md`, validating each against the spec plus
- `void _validateBudgets(Skill skill, String path)`  — Budgets that are stricter than the spec, because built-in skills are
- `String renderBuiltinSkillsFile(List<Skill> skills)`  — Renders the generated Dart source for [skills].
- `String _dartString(String value)`  — Escapes [value] into a single-quoted Dart string literal.

### generate_hugeicons.py  (119 Z.)
- const: WANTED CAMEL
- `def parse(source: str) -> list`  — Read the module's array. Keys are bare identifiers, values are already
- `def attribute_name(key: str) -> str`  — `strokeLinecap` -> `stroke-linecap`.
- `def to_svg(nodes: list) -> str`
- `def file_stem(icon: str) -> str`  — `ArrowLeft02Icon` -> `arrow-left02`.
- `def main() -> int`

## Befunde

**Waisen (11)** — von keiner Datei importiert. Nicht wiederbeleben, ohne vorher zu prüfen, ob sie noch gebraucht werden.
- `lib/platform_specific/chat/composer_menu.dart` — 59 Zeilen, von keiner Datei benutzt
- `lib/platform_specific/chat/composer_menu_choices.dart` — 18 Zeilen, von keiner Datei benutzt
- `lib/platform_specific/mobile/mobile_chips.dart` — 63 Zeilen, von keiner Datei benutzt
- `lib/services/notification_service_io.dart` — 250 Zeilen, von keiner Datei benutzt
- `lib/services/notification_service_stub.dart` — 38 Zeilen, von keiner Datei benutzt
- `lib/services/service_credentials_service.dart` — 212 Zeilen, von keiner Datei benutzt
- `lib/services/settings/debug_settings.dart` — 41 Zeilen, von keiner Datei benutzt
- `lib/services/streaming_foreground_service_io.dart` — 307 Zeilen, von keiner Datei benutzt
- `lib/services/streaming_foreground_service_stub.dart` — 71 Zeilen, von keiner Datei benutzt
- `lib/ui/expressive/waveform.dart` — 9 Zeilen, von keiner Datei benutzt
- `lib/widgets/chat_theme.dart` — 150 Zeilen, von keiner Datei benutzt

**Importzyklen (16)**
- 3 Dateien: lib/services/account_session.dart → lib/services/session_refresh_scheduler.dart → lib/services/supabase_service.dart
- 2 Dateien: lib/services/agents/agents_pairing_store.dart → lib/services/agents/supabase_pairing_sync.dart
- 2 Dateien: lib/services/mcp/mcp_catalogue.dart → lib/services/mcp/mcp_connection.dart
- 5 Dateien: lib/services/agents/agents_cloud_relay.dart → lib/services/agents/agents_relay_client.dart → lib/services/agents/agents_relay_link.dart → lib/services/mcp/mcp_service.dart → lib/services/mcp/mcp_store
- 9 Dateien: lib/services/agents/agents_queued_marks.dart → lib/services/chat_preload_service.dart → lib/services/chat_storage_crud.dart → lib/services/chat_storage_mutations.dart → lib/services/chat_storage_servi

**Größte Dateien (76 über der Schwelle)**
- `lib/platform_specific/chat/chat_ui_mobile.dart` — 4177 Zeilen, 167 Symbole
- `lib/services/agents/agents_relay_client.dart` — 3355 Zeilen, 411 Symbole
- `lib/services/artifact_storage_service.dart` — 3209 Zeilen, 133 Symbole
- `lib/platform_specific/chat/chat_ui_desktop.dart` — 2706 Zeilen, 134 Symbole
- `lib/platform_specific/chat/desktop_send_logic.dart` — 2573 Zeilen, 24 Symbole

## Mehrfach vergebene Namen

271 Namen existieren in mehr als einer Datei. Meist kopierter Code. Bevor du so etwas neu schreibst, eine der Stellen wiederverwenden. Volle Liste: `pseudomap dupes`.

- `_load` — lib/pages/diagnostics_settings_page.dart:42 · lib/pages/settings/embedding_settings_page.dart:32 · lib/pages/workspace_files_page.dart:70 · lib/pages/workspace_mobile_detail_page.dart:68 +7
- `_save` — lib/pages/agent_profile_edit_page.dart:149 · lib/pages/skills_settings_page.dart:323 · lib/pages/workspace_instructions_page.dart:57 · lib/services/agents/agents_task_outbox.dart:229 +7
- `Function` — lib/pages/mcp_connectors_page.dart:1041 · lib/platform_specific/chat/handlers/scanned_pdf_pages.dart:20 · lib/platform_specific/chat/voice/voice_record_placement.dart:43 · lib/services/chat_payload_codec.dart:488 +5
- `_persist` — lib/services/agents/agent_profile_store.dart:264 · lib/services/agents/agent_read_marks.dart:156 · lib/services/agents/agent_roster_source.dart:184 · lib/services/agents/agent_roster_store.dart:169 +5
- `_key` — lib/platform_specific/chat/voice/voice_turn_queue.dart:156 · lib/services/agents/agents_task_outbox.dart:192 · lib/services/agents/agents_task_outbox.dart:472 · lib/services/chat_dirty_store.dart:50 +4
- `_open` — lib/pages/assistant_settings_page.dart:153 · lib/pages/mcp_connectors_page.dart:354 · lib/services/offline_queue_service_native.dart:37 · lib/widgets/agents_desktop/quick_switcher.dart:162 +3
- `_row` — lib/pages/mcp_connectors_page.dart:330 · lib/pages/mobile_agents_settings_page.dart:345 · lib/pages/skills_settings_page.dart:724 · lib/voice/incoming/voice_call_permissions_section.dart:120 +3
- `_onInbound` — lib/services/agents/browser_presence.dart:177 · lib/services/automations/automations_source.dart:139 · lib/services/skills/skills_source.dart:104 · lib/widgets/agents_thread_view.dart:1168 +2
- `_formatDate` — lib/pages/media_manager_page.dart:580 · lib/pages/usage_details_page.dart:920 · lib/pages/workspace_mobile_detail_page.dart:526 · lib/services/workspace_message_service.dart:260 +1
- `_onChanged` — lib/pages/automations_page.dart:60 · lib/pages/skills_settings_page.dart:592 · lib/pages/workspace_instructions_page.dart:53 · lib/widgets/agents_permissions/agent_permissions_section.dart:194 +1
- `_refresh` — lib/pages/assistant_settings_page.dart:123 · lib/pages/automations_page.dart:64 · lib/pages/skills_settings_page.dart:596 · lib/voice/incoming/voice_call_permissions_section.dart:87 +1
- `_build` — lib/pages/agent_profile_page.dart:130 · lib/ui/expressive/agent_face.dart:235 · lib/ui/expressive/shapes.dart:29 · lib/ui/expressive/shapes.dart:140
- `_coerceInt` — lib/services/tool_executor.dart:1288 · lib/tool_handlers/chat_search_tools.dart:726 · lib/tool_handlers/map_tools.dart:632 · lib/tool_handlers/web_tools.dart:24
- `_confirmDelete` — lib/pages/agent_profile_page.dart:362 · lib/pages/skills_settings_page.dart:108 · lib/pages/workspace_mobile_detail_page.dart:111 · lib/widgets/agent_roster_view.dart:360
- `_connect` — lib/pages/mcp_connectors_page.dart:745 · lib/voice/voice_call_controller.dart:314 · lib/widgets/agents_thread_view.dart:943 · lib/widgets/mcp_connect_card.dart:54
- `_copy` — lib/pages/agents_install_page.dart:161 · lib/widgets/chuk_table.dart:408 · lib/widgets/chuk_table_classic.dart:68 · lib/widgets/selection_copy_area.dart:175
- `_emit` — lib/platform_specific/chat/voice/voice_task_delegates.dart:88 · lib/services/offline_queue_service_native.dart:223 · lib/services/offline_queue_service_web.dart:151 · lib/services/offline_retry_manager.dart:341
- `_ensureEncryptionKey` — lib/services/agents/supabase_pairing_sync.dart:178 · lib/services/mcp/chuk_mcp_mirror.dart:182 · lib/services/mcp/mcp_connector_sync.dart:137 · lib/services/secrets/secrets_sync.dart:122
- `_formatDuration` — lib/assistant/assistant_tools.dart:809 · lib/services/device_services.dart:518 · lib/utils/api_rate_limiter.dart:207 · lib/widgets/agent_run_views.dart:150
- `_onControllerChanged` — lib/platform_specific/chat/chat_ui_mobile.dart:866 · lib/widgets/settings_search_bar.dart:81 · lib/widgets/sidebar/sidebar_chrome.dart:685 · lib/widgets/vnc_trackpad_overlay.dart:188
- `_select` — lib/pages/agents_shell_state.dart:200 · lib/pages/messenger_shell.dart:622 · lib/services/storage/agents_chat_store.dart:904 · lib/widgets/chat_documents_panel.dart:254
- `_set` — lib/assistant/assistant_session.dart:467 · lib/services/agents/agents_install_flow.dart:225 · lib/services/agents/agents_relay_client.dart:3334 · lib/services/chat_payload_migration_service.dart:1211
- `_submit` — lib/pages/secrets_settings_page.dart:222 · lib/pages/workspaces_page.dart:619 · lib/widgets/coworker_name_dialog.dart:69 · lib/widgets/room_create_sheet.dart:85
- `_syncCacheToCurrentUser` — lib/services/per_model_system_prompt_service.dart:153 · lib/services/skills/user_skills_service.dart:63 · lib/services/title_generation_service.dart:106 · lib/services/user_preferences_service.dart:45
- `_table` — lib/services/customization_preferences_service.dart:214 · lib/services/profile_service.dart:44 · lib/services/theme_settings_service.dart:129 · lib/widgets/chat_document_view.dart:364
- … +246 weitere
