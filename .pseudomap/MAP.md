# pseudomap · chuk_chat

383 Dateien · 1644 Typen/Funktionen · 8670 Member · 604/934 öffentliche Symbole mit Zweckzeile · Stand 2026-09-12

Diese Datei ist `.pseudomap/MAP.md` — Stufe 1: was es gibt und wo es liegt.

Vor dem Schreiben neuer Funktionen hier nachsehen, ob die Sache schon existiert. Tut sie es, wird sie wiederverwendet statt neu geschrieben.

- Lange Parameterlisten sind hier gekürzt (`…)`). Volle Signaturen mit Zeilennummern stehen in `.pseudomap/detail/<ordner>.md`, Pfad mit `__` statt `/` — `lib/services` liegt in `.pseudomap/detail/lib__services.md`.
- Suche über alles: `pseudomap find <begriff>`.
- Neu bauen: `pseudomap build` (läuft nach jedem Edit automatisch).

## lib

### constants.dart  (547 Z.)

- const: kDefaultBgColor kDefaultAccentColor kDefaultIconFgColor kDefaultThemeMode kDefaultDynamicColorEnabled kDefaultShowReasoningTokens kDefaultShowModelInfo kDefaultShowTps kDefaultUiLocale kDefaultToolCallingEnabled kDefaultToolDiscoveryMode kDefaultShowToolCalls kDefaultIncludeToolResultsInHistory kDefaultChatFontSize kMinChatFontSize kMaxChatFontSize kDefaultUiScale kMinUiScale kMaxUiScale kChatFontFamilySystem kChatFontFamilyArimo kChatFontFamilyMerriweather kChatFontFamilyJetBrainsMono kDefaultChatFontFamily kSupportedChatFontFamilies +25
- `double contrastFactor(double contrast)`  — Maps the [kMinContrast]..[kMaxContrast] slider value to the multiplier
- `ThemeData buildAppTheme({ required Color accent, required Color iconFg, required Color bg, required Brightness brightnes …)`
- `Color _shiftHue(Color c, double degrees)`

### env_loader.dart  (158 Z.)

- `class EnvLoader`  — Loads environment variables from .env file at runtime.
  - load loadSync `_parseEnvFile` get has `_isDesktop`

### main.dart  (573 Z.)

- `void _installLogDeduper()`  — Collapse consecutive identical debug log lines into a single line with a
- `Future<void> main()`
- `class ChukChatApp extends StatefulWidget`
- `class _ChukChatAppState extends State<ChukChatApp> with WidgetsBindingObserver`
  - `_initializeDesktopTrayInBackground` `_onThemeChanged` `_onPasswordMismatch` `_syncSettingsInBackground` `_scheduleStartupSettingsSync` `_initializeNotificationsInBackground` `_initializeApp` `_buildHome` `_toFlutterScheme` `_buildShellConfig` `_isLinuxDesktop` `_isAssistantLaunch` navigatorKey
- `class _OnboardingFirstLaunchGate extends StatefulWidget`  — Starts the interactive onboarding tour if the signed-in user has never
  - child shellConfig
- `class _OnboardingFirstLaunchGateState extends State<_OnboardingFirstLaunchGate>`
  - `_maybeStart`

### model_selector_page.dart  (2074 Z.)

- `class PricingDetails`
  - formatTokenPrice formatRequestPrice prompt completion request image webSearch internalReasoning
- `class ModelProviderInfo`
  - slug name pricing contextLength maxCompletionTokens isModerated iconUrl
- `class CustomModelInfo`
  - id name description providers iconUrl
- `enum _ModelListFilter`  — Which slice of the catalogue the model list shows.
  - all active inactive
- `class ModelSelectorPage extends StatefulWidget`
- `class _ModelSelectorPageState extends State<ModelSelectorPage> with ApiAvailabilityPolling<ModelSelectorPage>`
  - onApiReachable `_loadModeConfigs` `_isFlashModelId` `_healFastToFlash` `_modelNameFor` `_pickModelForMode` `_modelById` `_setProviderForMode` `_reasoningLevelsForMode` `_setReasoningForMode` `_initializeModelSelections` `_fetchModels` `_handleApiUnavailable` `_buildApiUnavailableMessage` `_showSnackBar` `_onEditModelPrompt` `_onProviderSelect` `_onAutoSelect` `_cheapestProvider` `_formatContextLength` apiPollBaseUrl `_enabledModels` `_filteredModels` `_displayModels` size
- `class ModelSelectionRow extends StatefulWidget`
  - model selectedProvider promptConfig isAutoSelected isFirstRow onProviderChanged onAutoSelected onEditPrompt formatContextLength buildIconWidget
- `class _ModelSelectionRowState extends State<ModelSelectionRow>`
  - `_buildDescriptionBlock` `_buildStatsBlock`
- `class _NameRow extends StatelessWidget`
  - model buildIconWidget promptConfig onEditPrompt trailing
- `class _ProviderPill extends StatelessWidget`
  - `_buildCollapsedFace` `_cheapestProvider` `_buildDisabledDisplay` `_buildAutoDisplay` `_buildProviderDisplay` `_formatInOutPrice` model selectedProvider isAutoSelected onProviderChanged onAutoSelected buildIconWidget maxWidth
- `class _AuthRequiredException implements Exception`
- `class _SearchField extends StatelessWidget`
  - controller hintText hasQuery
- `class _ModeRowData`  — One mode's data for the picker panel.
  - icon title modelId modelName reasoningEffort reasoningLevels providerSlug providers onPickModel onPickReasoning onPickProvider
- `class _ModePickerPanel extends StatelessWidget`  — The panel at the top of the model screen that assigns a model, a provider
  - `_modeCard` `_labelledRow` `_staticValue` `_providerMenu` `_modelMenu` `_reasoningMenu` `_menuRow` models fast thinking buildIconWidget subtle
- `class _ListFilterBar extends StatelessWidget`  — A three-way pill toggle above the model list: All / Active / Inactive.
  - `_labelFor` `_segment` value onChanged
- `class _StatChip extends StatelessWidget`
  - label value

### platform_config.dart  (107 Z.)

- const: kPlatformMobile kPlatformDesktop kAutoDetectPlatform kFeatureVoiceMode kFeatureWorkspaces kFeatureArtifacts kFeatureImageGen kFeatureMediaManager kFeatureServerTools kFeatureMcp kFeatureArtifactHosting kFeatureSystemTray kFeatureLinuxKeyring kFeaturePaymentsDirect

### supabase_config.dart  (121 Z.)

- `class SupabaseConfig`
  - initialize initializeSync supabaseUrl supabaseAnonKey isUsingPlaceholderValues

### web_env.dart  (5 Z.)

- const: webSupabaseUrl webSupabaseAnonKey

## lib/assistant

### assistant_bridge.dart  (327 Z.)

- `class AssistantBridge`  — Untyped wrappers around the native assistant channel.
  - startVoiceService stopVoiceService openAccessibilitySettings openNotificationAccessSettings openOverlaySettings openAssistantSettings openAppDetailsSettings requestAssistantRole isAccessibilityEnabled getPermissionStatuses requestContactsPermission requestLocationPermission getCurrentContext getRecentNotifications findContact openDialerForContact callContactDirect openApp listInstalledApps composeSmsForContact isClockAppInstalled clockCommand dismissTimer dismissAlarm showTimers showAlarms getLastKnownLocation captureScreenshotBase64 clickByText performGlobalAction cancelTimerNotifications mediaCommand getNowPlaying volumeGet spotifySearch maxScrolls navigate message showUi

### assistant_cards.dart  (382 Z.)

- `class AssistantCardView extends StatelessWidget`  — Renders one [AssistantCard]. Every colour comes from the running theme, so
  - card
- `class _CardHeader extends StatelessWidget`
  - icon title trailing
- `class _PlacesCardView extends StatelessWidget`
  - card
- `class _PlaceRow extends StatelessWidget`
  - `_navigate` place
- `class _RatingChip extends StatelessWidget`
  - rating reviewCount
- `class _LinksCardView extends StatelessWidget`
  - `_host` card
- `class _ActionCardView extends StatelessWidget`
  - card
- `class _FactsCardView extends StatelessWidget`
  - card

### assistant_config.dart  (84 Z.)

- const: kAssistantModelId kAssistantProviderSlug kAssistantReasoningEffort kAssistantMaxToolRounds kAssistantMaxTokens
- `abstract final class AssistantPlatform`  — Where the assistant surface can run at all.
  - isSupported
- `@immutable class AssistantSettings`  — User-owned assistant preferences. Everything model-related is a constant
  - copyWith defaultLanguage language
- `abstract final class AssistantSettingsStore`  — Persistence for [AssistantSettings].
  - load save

### assistant_microphone.dart  (284 Z.)

- `class AssistantMicrophone`  — Continuous microphone capture with energy-based endpointing.
  - hasPermission start pause resume debugFeed `_onChunk` `_finishUtterance` `_resetUtterance` `_pushPreRoll` `_trackNoiseFloor` `_setLevel` `_durationOf` `_bytesOf` `_rms` isRunning isPaused level `_activeRecorder` onUtterance onLevel sampleRate channels
- `Uint8List pcmToWav( Uint8List pcm, { required int sampleRate, required int channels, })`  — Wraps raw 16-bit little-endian PCM in a 44-byte RIFF header.
- `void _writeAscii(ByteData buffer, int offset, String value)`

### assistant_overlay.dart  (674 Z.)

- const: assistantOverlayRouteName
- `Route<void> buildAssistantOverlayRoute()`  — Transparent, instant route for the assistant surface.
- `class AssistantOverlayPage extends StatefulWidget`
- `class _AssistantOverlayPageState extends State<AssistantOverlayPage>`
  - `_startSession` `_close`
- `@immutable class AssistantToolBadge`  — One tool call, as the surface shows it.
  - label done failed
- `class AssistantOverlayView extends StatelessWidget`  — Presentation separated from transport so the layout can be checked offline.
  - `_hasError` `_showPanel` onScreen errorText contextOpen level tools card
- `class AssistantToolRow extends StatelessWidget`  — One line per tool call, so the user sees what the assistant really does.
  - tool
- `class AssistantSurface extends StatelessWidget`  — One floating, blurred panel. The surface colour is the user's, only the
  - child padding
- `class AssistantAction extends StatelessWidget`  — Label and icon as one centred group with a 48 dp minimum target.
  - label icon onPressed iconOnly
- `class AssistantWaveform extends StatefulWidget`  — Microphone level as a symmetric bar field.
  - level busy
- `class _AssistantWaveformState extends State<AssistantWaveform> with SingleTickerProviderStateMixin`
  - `_sync`
- `class _WavePainter extends CustomPainter`
  - paint shouldRepaint level busy idleColor

### assistant_result.dart  (141 Z.)

- `sealed class AssistantCard`  — A visual result the assistant surface renders next to (or instead of) the
- `@immutable class AssistantPlace`  — One place from the Brave Local proxy.
  - hasCoordinates name address rating reviewCount openingHours priceRange cuisine description phone latitude longitude
- `class AssistantPlacesCard extends AssistantCard`  — A list of places — restaurants, shops, anything from a local lookup.
  - title places
- `@immutable class AssistantLink`  — One web result.
  - title url snippet
- `class AssistantLinksCard extends AssistantCard`  — Ranked web results from the Brave Search proxy.
  - title links
- `class AssistantActionCard extends AssistantCard`  — A device action that happened: a timer was set, maps opened, an app
  - icon label detail
- `class AssistantFactsCard extends AssistantCard`  — Anything with a heading and a block of prepared text — weather, a summary,
  - icon title body
- `@immutable class AssistantToolOutcome`  — What one tool call produced: the JSON the model reads back, and the card
  - modelResult card

### assistant_session.dart  (510 Z.)

- `enum AssistantPhase`  — Where one assistant turn currently stands.
  - starting listening transcribing thinking acting paused error
- `class AssistantSession extends ChangeNotifier`  — The whole assistant turn: endpointed microphone, transcription through the
  - start toggleMute attachScreenContext `_onUtterance` `_runTurn` `_chatPass` `_describeScreenshot` `_trimHistory` `_accessToken` `_awaitAccessToken` `_systemPrompt` `_decodeArguments` `_humanError` `_set` `_fail` `_notify` phase settings userText answer error level muted listening tools card busy statusLabel
- `@immutable class _AssistantPass`
  - content toolCalls error

### assistant_tools.dart  (874 Z.)

- const: assistantTools assistantToolsByName assistantToolSchemas
- `class AssistantToolRuntime`  — Everything a tool handler may use besides its own arguments.
  - country serverUrl serverHeaders describeScreenshot language httpClient
- `typedef AssistantToolHandler = Future<AssistantToolOutcome> Function( Map<String, dynamic> args, AssistantToolRuntime ru`
- `class AssistantTool`  — One function the model may call, in the OpenAI tool schema.
  - toOpenAiFunction name description parameters handler label
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
  - name label done failed content card
- `Future<void> runAssistantTool({ required AssistantToolRun run, required Map<String, dynamic> args, required AssistantToo …)`  — Runs one tool call and always produces a JSON string — the `tool` message

## lib/constants

### file_constants.dart  (185 Z.)

- `class FileConstants`  — Shared constants for file handling across the application.
  - isPlainText requiresConversion isImage maxFileSizeBytes maxConcurrentUploads maxImageAttachments allowedExtensions imageExtensions plainTextExtensions convertApiExtensions

## lib/core

### model_selection_events.dart  (32 Z.)

- `class ModelSelectionEventBus`  — Event bus for model selection changes to decouple services from UI widgets.
  - notifyRefresh notifyModelSelected refreshStream modelSelectedStream

## lib/demo

### app_palette.dart  (63 Z.)

- `class AppPalette`
  - of isDark bg surfaceLow surface surfaceHigh fg muted hairline accent accentSubtle accentText dark light

### demo_data.dart  (182 Z.)

- `class DemoChat`
  - id title preview time unread emoji accent pinned
- `class DemoProject`
  - id name color chatCount
- `class DemoData`
  - chats projects relativeTime groupOf
- `class SidebarCallbacks`
  - onChatTap onNewChat onSettings onMedia onWorkspaces onSearch

### shared_widgets.dart  (645 Z.)

- `class SbBrand extends StatelessWidget`  — Brand row: optional logo square + name. Trailing widget on the right.
  - trailing padding label showLogo
- `class SbNewChatPill extends StatelessWidget`  — Accent pill "New chat" button — used in top-right or as full-width.
  - onTap label icon wide hint
- `class SbSearch extends StatelessWidget`  — Generic search field with bordered surface.
  - onChanged hint padding radius bordered
- `class SbSectionLabel extends StatelessWidget`  — Uppercase section header (PINNED, RECENT, etc.).
  - label count padding color
- `class SbChatRow extends StatelessWidget`  — Full-width flat chat row with selection tint, pin icon, unread dot, time.
  - chat selected onTap padding radius showPin
- `class SbPinnedRow extends StatelessWidget`  — Compact pinned row variant (smaller padding/font, used inside Pinned bento).
  - chat selected onTap
- `class SbFooter extends StatelessWidget`  — Account footer (avatar + name + email + settings icon).
  - onSettings showName
- `class SbNavItem extends StatelessWidget`  — Sidebar nav row (icon + label, vertically stacked). Like original top stack.
  - icon label onTap primary hint
- `class SbBento extends StatelessWidget`  — Generic rounded surface "bento" card.
  - child padding margin color borderColor radius
- `class SbPinnedBento extends StatelessWidget`  — Accent-tinted pinned bento card with header + rows.
  - pinned selectedId onTap margin
- `class SbQuickTile extends StatelessWidget`  — Bento quick tile (icon + title + subtitle).
  - icon title subtitle onTap primary
- `class SbHairline extends StatelessWidget`  — Hairline divider matching app palette.
- `class ChatSplit`  — Splits chats into pinned + rest. Convenience for variants.
  - pinned rest

### sidebar_demo_main.dart  (589 Z.)

- const: kSidebarWidth
- `void main()`
- `class SidebarDemoApp extends StatefulWidget`
- `class _SidebarDemoAppState extends State<SidebarDemoApp>`
- `enum FrameMode`
  - desktop mobile
- `class DemoHome extends StatefulWidget`
  - themeMode onToggleTheme
- `class _DemoHomeState extends State<DemoHome>`
  - `_cb` `_toast` `_sidebar` `_toolbar` `_tabChip` `_segmented` `_stage` `_desktopFrame` `_mobileFrame` `_windowChrome` `_dot` `_mockChatArea` `_msgUser` `_msgAssistant` `_composer` `_description` `_chats`

## lib/demo/variants

### variant_1_minimal.dart  (83 Z.)

- `class VariantMinimal extends StatelessWidget`
  - chats selectedId cb mobile

### variant_2_glass.dart  (126 Z.)

- `class VariantGlass extends StatelessWidget`
  - chats selectedId cb mobile

### variant_3_dense.dart  (114 Z.)

- `class VariantDense extends StatelessWidget`
  - chats selectedId cb mobile

### variant_4_playful.dart  (160 Z.)

- `class VariantPlayful extends StatelessWidget`
  - chats selectedId cb mobile

### variant_5_bento.dart  (112 Z.)

- `class VariantBento extends StatelessWidget`
  - chats selectedId cb mobile

### variant_6_final.dart  (142 Z.)

- `class VariantFinal extends StatelessWidget`
  - chats selectedId cb mobile
- `class _SearchTrigger extends StatelessWidget`  — Subtle search icon button. No layout shift, no inline bar.
  - onTap

## lib/l10n

### app_localizations.dart  (784 Z.)

- `class AppLocalizations`  — Holds all translated UI strings for the current locale.
  - of `_getDe` `_getEs` `_getFr` `_getPt` `_get` skillDeleteBody savedToPath exportFailed uiScalePercentage editedAt disconnectCategory lockedChatsCount emailUpdated failedToLoadProfile failedToSaveProfile failedToChangePassword verificationFailed failedToDeleteAccount versionText builtOn updateAvailable copyrightYear devOptionsTaps unexpectedError verifySignupBody verifyRecoveryBody resendCodeIn encryptedWithVersion lockedChatCount deleteLockedChatsBody confirmDeleteChats recoveredChats deletedChats failedFocusedDebug failedToShareLog failedToClearLog autoCheapestCurrently deleteFailed modelError +542
- `class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations>`
  - isSupported load shouldReload

### strings_de.dart  (759 Z.)

- const: stringsDe

### strings_en.dart  (747 Z.)

- const: stringsEn

### strings_es.dart  (524 Z.)

- const: stringsEs

### strings_fr.dart  (610 Z.)

- const: stringsFr

### strings_pt.dart  (539 Z.)

- const: stringsPt

## lib/models

### app_shell_config.dart  (147 Z.)

- `class AppShellConfig`  — Bundles all theme, display, image-generation, and AI-context settings
  - currentThemeMode currentAccentColor currentIconFgColor currentBgColor setThemeMode setAccentColor setIconFgColor setBgColor dynamicColorEnabled setDynamicColorEnabled contrast setContrast uiFontFamily setUiFontFamily showReasoningTokens setShowReasoningTokens showModelInfo setShowModelInfo showTps setShowTps autoSendVoiceTranscription setAutoSendVoiceTranscription imageGenEnabled setImageGenEnabled imageGenDefaultSize setImageGenDefaultSize imageGenCustomWidth setImageGenCustomWidth imageGenCustomHeight setImageGenCustomHeight imageGenUseCustomSize setImageGenUseCustomSize includeRecentImagesInHistory setIncludeRecentImagesInHistory includeAllImagesInHistory setIncludeAllImagesInHistory includeReasoningInHistory setIncludeReasoningInHistory includeToolResultsInHistory setIncludeToolResultsInHistory +14

### artifact.dart  (217 Z.)

- `enum ArtifactType`
  - code markdown html mermaid svg technicalDrawing typst excalidraw
- `extension ArtifactTypeX on ArtifactType`
  - fromValue value displayLabel defaultExtension
- `class ArtifactDocument`
  - copyWith toMap fromMap id chatId userId messageId title type language content version createdAt updatedAt attachmentPath
- `class ArtifactVersionSnapshot`
  - fromMap artifactId version content createdAt attachmentPath
- `class ArtifactEdit`
  - fromMap oldStr newStr

### chat_message.dart  (269 Z.)

- `enum ChatMessageStatus`  — Delivery status of a chat message in the local queue/UI.
  - sent pending failed interrupted
- `ChatMessageStatus? _statusFromString(String? raw)`
- `int? parseFlexibleInt(dynamic value)`  — Parse an int that may arrive as an int, a num, or a String — the UI map
- `String? _statusToString(ChatMessageStatus? status)`
- `class ChatMessage`  — Represents a single message in a chat.
  - copyWith toJson workedFor sender effectiveStatus statusString role text reasoning replyContext images imageMetas imageCostEur imageGeneratedAt attachments attachedFilesJson toolCalls contentBlocks modelId provider status queueId messageId startedAt generationMs variants activeVariant

### chat_model.dart  (122 Z.)

- `class ModelItem`
  - name value isToggle badge iconUrl supportsReasoning supportsReasoningEffort operator
- `class AttachedFile`
  - copyWith toJson id fileName markdownContent isUploading localPath fileSizeBytes encryptedImagePath isImage

### chat_stream_event.dart  (161 Z.)

- `sealed class ChatStreamEvent`  — Events that can be received from chat streaming services.
  - content reasoning usage meta tps toolCalls error done
- `class NativeToolCall`  — A native OpenAI-format tool call assembled from the provider stream.
  - id name arguments
- `class ToolCallsEvent extends ChatStreamEvent`  — Event carrying one or more native tool calls the model requested this turn.
  - calls
- `class ContentEvent extends ChatStreamEvent`  — Event containing message content text.
  - text
- `class ReasoningEvent extends ChatStreamEvent`  — Event containing reasoning/thinking process text.
  - text
- `class UsageEvent extends ChatStreamEvent`  — Event containing token usage information.
  - usage
- `class MetaEvent extends ChatStreamEvent`  — Event containing metadata about the response.
  - meta
- `class TpsEvent extends ChatStreamEvent`  — Event containing tokens per second (TPS) metric.
  - tokensPerSecond
- `class ErrorEvent extends ChatStreamEvent`  — Event indicating an error occurred.
  - message code
- `class DoneEvent extends ChatStreamEvent`  — Event indicating the stream has completed.
- `typedef StreamErrorCallback = void Function(String error, {String? code})`  — Signature for stream error callbacks.
- `abstract final class StreamErrorCodes`  — Failure classes carried on [ErrorEvent.code].
  - upstreamNetwork upstreamStatus upstreamNoStream upstreamFirstByteTimeout connectionLost idleTimeout streamFailure retryable

### client_tool.dart  (71 Z.)

- `class ClientTool`  — Represents a tool that can be executed client-side.
  - toJson toOpenAiFunction id name description parameters type config tags
- `enum ToolType`  — Type of tool.
  - builtin mcp
- `enum ToolCategory`  — Tool categories for grouping and enabling/disabling.
  - basic search map device bash github slack google mcp sandbox

### content_block.dart  (128 Z.)

- `enum ContentBlockType`  — The type of a content block within an AI response.
  - text toolCalls reasoning sandboxArtifact
- `class SandboxArtifactPayload`  — Payload for a [ContentBlockType.sandboxArtifact] block.
  - toJson storagePath filename mime sizeBytes
- `class ContentBlock`  — An ordered block of content within an AI response.
  - toJson type text toolCalls sandboxArtifact

### queued_message.dart  (105 Z.)

- `class QueuedMessage`  — A message persisted in the offline queue, waiting for connectivity so it
  - toRow id chatId sendPayload attemptCount lastError createdAt updatedAt clearLastError

### skill.dart  (276 Z.)

- `enum SkillSource`  — Where a [Skill] came from. Determines its trust level.
  - builtin user
- `class SkillResource`  — A file bundled alongside a skill (Level 3): a `references/`, `scripts/` or
  - path url operator
- `class Skill`
  - copyWith isFromCatalog version isBuiltin id name description body license compatibility metadata allowedTools source catalogName baselineHash resources kMaxNameChars kMaxDescriptionChars kSpecMaxDescriptionChars kMaxCompatibilityChars kMaxBodyLines operator
- `bool _resourceListEquals(List<SkillResource> a, List<SkillResource> b)`
- `bool _listEquals(List<String> a, List<String> b)`
- `bool _mapEquals(Map<String, String> a, Map<String, String> b)`

### stored_chat.dart  (202 Z.)

- `class StoredChat`  — Represents a stored chat with metadata.
  - copyWith withMessages messages isFullyLoaded messagesOrNull previewText id createdAt updatedAt isStarred customName title keyVersion assistantId isLocked

### stream_phase.dart  (39 Z.)

- `enum StreamPhase`  — The phases of one assistant turn, in the order they occur.
  - label connecting processing thinking working writing

### tool_call.dart  (95 Z.)

- `class ToolCall`  — Represents a single tool call made by the AI during a conversation.
  - toJson elapsed id name arguments result status roundThinking startedAt completedAt
- `enum ToolCallStatus`  — Status of a tool call in its lifecycle.
  - pending running completed error
- `bool finalizeStaleToolCalls(List<ToolCall> toolCalls)`  — Utility to finalize any stale (running/pending) tool calls.

### workspace_model.dart  (465 Z.)

- `class Workspace`  — Represents a workspace that combines AI persona, system prompts, files,
  - toJson copyWith `_formatFileSize` chatCount fileCount hasCustomPrompt totalFileSize totalFileSizeFormatted displayColor displayIcon hasCustomImage updatedAgo initials id name description customSystemPrompt createdAt updatedAt isArchived memoryEnabled modelId avatarColor avatarIcon avatarImagePath isPublic userId ownerDisplayName chatIds files kWorkspaceColors kWorkspaceIcons
- `class WorkspaceFile`  — Represents a file attached to a workspace
  - toJson copyWith hasMarkdownSummary fileSizeFormatted fileIcon isPreviewable isTextFile extension isImage isPdf estimatedTokens estimatedTokensFormatted id workspaceId fileName storagePath fileType fileSize uploadedAt markdownSummary

## lib/pages

### about_page.dart  (560 Z.)

- `class AboutPage extends StatefulWidget`
  - `_openLicenses` `_formattedVersion`
- `class _AboutPageState extends State<AboutPage>`
  - `_handleVersionTap`
- `class _ThemedLicensePage extends StatefulWidget`
  - applicationName applicationVersion applicationLegalese
- `class _ThemedLicensePageState extends State<_ThemedLicensePage>`
  - `_loadLicenses`
- `class _LicenseTile extends StatelessWidget`
  - package
- `class _LicenseHeader extends StatelessWidget`
  - applicationName applicationVersion applicationLegalese
- `class _LicensePackage`
  - name license
- `class _LicenseDetailPage extends StatelessWidget`
  - package
- `String? _inferLicenseName(String text)`

### account_settings_page.dart  (735 Z.)

- `class AccountSettingsPage extends StatefulWidget`
- `class _AccountSettingsPageState extends State<AccountSettingsPage>`
  - `_loadProfile` `_saveAccountSettings` `_buildRecoverChatsSection` `_changePassword` `_deleteAccount`
- `class _FieldLabel extends StatelessWidget`
  - label helper

### assistant_settings_page.dart  (407 Z.)

- `class AssistantSettingsPage extends StatefulWidget`  — One job: make Chuk Chat the assistant of this phone.
- `class _Grant`  — One freedom the assistant needs, and what it buys.
  - key icon title buys open required
- `class _AssistantSettingsPageState extends State<AssistantSettingsPage> with WidgetsBindingObserver`
  - `_refresh` `_claimAssistantRole` `_open` `_granted`
- `class _HowTo extends StatelessWidget`
  - isDefault
- `class _Step extends StatelessWidget`
  - number text
- `class _AllSet extends StatelessWidget`

### coming_soon_page.dart  (49 Z.)

- `class ComingSoonPage extends StatelessWidget`
  - title message

### connector_detail_page.dart  (245 Z.)

- `class ConnectorDetailPage extends StatefulWidget`  — Full-screen detail page for a single tool, showing enable/disable,
  - tool toolExecutor displayName icon
- `class _ConnectorDetailPageState extends State<ConnectorDetailPage>`
  - `_buildParameterRow` `_isEnabled` `_isAlwaysOn` `_hasCustomPrompt` `_currentDescription` `_promptChanged`

### customization_page.dart  (748 Z.)

- `class CustomizationPage extends StatefulWidget`
  - config
- `class _CustomizationPageState extends State<CustomizationPage>`
  - `_loadAutoTitleSetting` `_refreshAutoTitleSettingFromSupabase` `_saveSystemPrompt` `_resetSystemPrompt` `_fontFamilyLabel` `_systemPromptEditor`
- `class _CardLabel extends StatelessWidget`  — Title and explanation at the top of a card that is not a row.
  - title subtitle

### desktop_settings_modal.dart  (790 Z.)

- `Future<void> showDesktopSettingsModal( BuildContext context, { required AppShellConfig config, String? initialSectionId …)`  — Opens the desktop settings modal over the current chat UI.
- `class _SettingsDest`  — A settings destination: either a page shown in the right pane, or an
  - isPage id icon label keywords builder onAction tone
- `class _SettingsGroup`
  - title items
- `class DesktopSettingsModal extends StatefulWidget`
  - config initialSectionId
- `class _DesktopSettingsModalState extends State<DesktopSettingsModal>`
  - `_onDevOptions` `_groups` `_findPage` `_onSelect` `_buildWide` `_buildCompact` `_buildNavRail` `_navItem` `_buildRailFooter` `_logout` `_replayOnboarding` `_exportChats` `_snack`

### diagnostics_settings_page.dart  (336 Z.)

- `class DeveloperOptionsPage extends StatefulWidget`
- `class _DeveloperOptionsPageState extends State<DeveloperOptionsPage>`
  - `_load` `_setDeveloperOptionsEnabled` `_setEnabled` `_refreshLogs` `_copyRecentLogs` `_copyFocusedModelMenuDebug` `_shareLogFile` `_clearLogs`

### download_settings_page.dart  (136 Z.)

- `class DownloadSettingsPage extends StatefulWidget`
- `class _DownloadSettingsPageState extends State<DownloadSettingsPage>`
  - `_onPrefChanged` `_pickFolder` `_clearFolder`

### forgot_password_page.dart  (208 Z.)

- `class ForgotPasswordPage extends StatefulWidget`  — Page for requesting a password reset code, then verifying it and setting
- `class _ForgotPasswordPageState extends State<ForgotPasswordPage>`
  - `_handleSendResetCode` `_openRecoveryOtpVerification` `_buildFormView`

### fullscreen_map_page.dart  (1137 Z.)

- `class FullscreenMapPage extends StatefulWidget`
  - center zoom title places markers fitPoints routeFromLat routeFromLon routeToLat routeToLon routeFromLabel routeToLabel initialSelectedPlaceIndex
- `class _FullscreenMapPageState extends State<FullscreenMapPage>`
  - `_refreshLocationAvailability` `_buildMapWidget` `_buildFallbackMapOptions` `_applyInitialCamera` `_applyInitialSelection` `_fitToPoints` `_focusMarker` `_selectPlace` `_loadRouteForEndpoints` `_loadRoute` `_fetchRouteGeometry` `_animateTo` `_centerOnCurrentLocation` `_resolveExternalTarget` `_openCurrentViewInExternalMaps` `_launchExternalMaps` `_ensureCurrentLocation` `_buildStatusChip` `_buildPlacePopup` `_buildPopupAction` `_toDouble` `_hasPlaces` `_hasMarkers` `_hasRouteEndpoints` `_routeStart` `_routeEnd` size
- `class _RouteGeometry`
  - points distanceMeters durationSeconds

### fullscreen_text_editor_page.dart  (217 Z.)

- `Future<String?> showFullscreenTextEditor( BuildContext context, { required String initialText, required String title, St …)`  — Opens [initialText] in a fullscreen editor.
- `class FullscreenTextEditorPage extends StatefulWidget`
  - initialText title hintText monospace
- `class _FullscreenTextEditorPageState extends State<FullscreenTextEditorPage>`
  - `_onChanged` `_confirmDiscard` `_isDirty`

### github_connection_page.dart  (469 Z.)

- `class GitHubConnectionPage extends StatefulWidget`
- `class _GitHubConnectionPageState extends State<GitHubConnectionPage>`
  - `_accessToken` `_refreshStatus` `_startConnect` `_runPoll` `_disconnect` `_intro` `_disconnectedCard` `_connectedCard` `_deviceCodeCard` `_errorBanner`

### login_page.dart  (569 Z.)

- `class LoginPage extends StatefulWidget`
- `class _LoginPageState extends State<LoginPage>`
  - `_handleSubmit` `_openSignupOtpVerification` `_toggleMode` `_validatePassword`

### mcp_connectors_page.dart  (887 Z.)

- `class McpConnectorsPage extends StatefulWidget`
- `class _McpConnectorsPageState extends State<McpConnectorsPage>`
  - `_searchRegistry` `_searchField` `_row` `_open` `_addByUrl` `_report` `_query`
- `class McpConnectorDetailPage extends StatefulWidget`  — One connector: connect or disconnect it, and see what it can do.
  - id entry
- `class _McpConnectorDetailPageState extends State<McpConnectorDetailPage>`
  - `_legalNote` `_openLegal` `_cancelConnect` `_connect` `_disconnect`
- `Future<Map<String, String>?> showMcpCredentialDialog( BuildContext context, List<McpCredentialField> fields, String name …)`  — Collect a reader's own credentials for an [McpAuth.apiKey] server. Returns
- `class McpConnectorIcon extends StatefulWidget`  — A connector logo. The bundled brand logo first (shipped in the binary for
  - assetPath url serverUrl name size fallback
- `class _McpConnectorIconState extends State<McpConnectorIcon>`
  - `_loadFirstThatWorks` `_networkIcon` `_placeholder` `_candidates`
- `Future<T> _withProgress<T>( BuildContext context, Future<T> Function() work, { McpConnectCanceler? canceler, })`

### media_manager_page.dart  (1141 Z.)

- `enum _MediaFilter`
  - images artifacts
- `class MediaManagerPage extends StatefulWidget`
  - embedded
- `class _MediaManagerPageState extends State<MediaManagerPage>`
  - `_loadArtifacts` `_loadImages` `_loadThumbnail` `_downloadThumbnail` `_deleteImage` `_deleteSelectedImages` `_toggleSelection` `_enterSelectionMode` `_exitSelectionMode` `_downloadImage` `_downloadSelectedImages` `_formatFileSize` `_formatDate` `_buildBody` `_buildImagesEmpty` `_buildArtifactsView` `_showArtifactPreview` `_buildDesktopGrid` `_buildMobileList` `_showImagePreview` compact
- `class _MediaFilterChip extends StatelessWidget`
  - label count selected onTap
- `class _ArtifactTile extends StatelessWidget`
  - `_relative` `_iconForType` artifact onTap

### otp_verification_page.dart  (291 Z.)

- `class OtpVerificationPage extends StatefulWidget`  — Reusable page for entering a 6-digit email verification code.
  - email body onSubmit onResend
- `class _OtpVerificationPageState extends State<OtpVerificationPage>`
  - `_startCooldown` `_messageForError` `_handleVerify` `_handleResend`

### pricing_page.dart  (673 Z.)

- const: `_supabase` `_apiBaseUrl`
- `Future<void> _launchExternalUrl(String url)`
- `Future<String> _getAccessToken()`
- `Future<void> startCheckout()`
- `Future<void> openBillingPortal()`
- `Future<void> syncSubscription()`
- `Future<Map<String, dynamic>> getUserStatus()`  — Always a live read — used before opening Stripe checkout, where a stale
- `class PricingPage extends StatefulWidget`
- `class _PricingPageState extends State<PricingPage> with WidgetsBindingObserver`
  - `_handleSubscribe` `_handleManageBilling` `_showError` `_openUsageDetails` force
- `class _PlanCard extends StatelessWidget`
  - title price features badgeLabel badgeTone highlighted child

### recover_chats_page.dart  (389 Z.)

- `class RecoverChatsPage extends StatefulWidget`  — Page for recovering or deleting chats encrypted with old passwords.
- `class _RecoverChatsPageState extends State<RecoverChatsPage>`
  - `_loadLockedInfo` `_recoverVersion` `_deleteVersion` `_showDeleteConfirmation` `_showTypeDeleteConfirmation` `_buildVersionCard`

### sandbox_management_page.dart  (314 Z.)

- `class SandboxManagementPage extends StatefulWidget`
- `class _SandboxManagementPageState extends State<SandboxManagementPage>`
  - `_accessToken` `_loadGitHubStatus` `_refresh` `_openGitHub` `_destroy` `_shortId` `_formatTime`
- `class _SandboxRow extends StatelessWidget`
  - info isDestroying onDestroy shortId formatTime

### set_new_password_page.dart  (269 Z.)

- `class SetNewPasswordPage extends StatefulWidget`  — Page shown after a user clicks a password reset link.
  - onComplete
- `class _SetNewPasswordPageState extends State<SetNewPasswordPage>`
  - `_handleSetPassword`

### settings_page.dart  (1008 Z.)

- `class SettingsPage extends StatefulWidget`
  - config
- `class _SettingsPageState extends State<SettingsPage>`
  - `_onDeveloperOptions` `_refreshDeveloperOptions` `_replayOnboarding` `_exportChats` `_saveExportToLinux` `_linuxInitialDirectory`
- `class _PlanInfo`
  - heroLabel
- `class _AccountRow extends StatefulWidget`
  - onTap
- `class _AccountRowState extends State<_AccountRow>`
  - `_loadProfile` `_loadPlan` `_planInfoFrom` `_identity`
- `class _PlanBadge extends StatelessWidget`
  - label
- `class _SettingsRow extends StatelessWidget`
  - icon title subtitle trailing onTap
- `class _DevTile extends StatelessWidget`
  - title subtitle onTap
- `enum BadgeTone`
  - neutral primary success warning error
- `class _Badge extends StatelessWidget`
  - label tone
- `class _MiniChip extends StatelessWidget`
  - label connected
- `class DottedBorderBox extends StatelessWidget`  — Paints a dashed rounded-rectangle border around [child].
  - child color radius
- `class _DashedRectPainter extends CustomPainter`
  - paint shouldRepaint color radius dashWidth dashSpace

### skills_settings_page.dart  (475 Z.)

- `class SkillsSettingsPage extends StatefulWidget`  — Lists built-in skills and lets the user author their own.
- `class _SkillsSettingsPageState extends State<SkillsSettingsPage>`
  - `_openEditor` `_confirmDelete` forceRefresh
- `class SkillEditorPage extends StatefulWidget`  — Edits one skill's SKILL.md source.
  - skill
- `class _SkillEditorPageState extends State<SkillEditorPage>`
  - `_sourceOf` `_yamlScalar` `_quote` `_save`
- `class _SkillsEmptyState extends StatelessWidget`  — Shown when the user has authored no skills of their own. A quiet centred
  - onCreate
- `class _SkillRow extends StatelessWidget`
  - skill onTap onDelete

### system_prompt_page.dart  (813 Z.)

- `class SystemPromptPage extends StatefulWidget`
- `class _SystemPromptPageState extends State<SystemPromptPage>`
  - `_selectedTextOrAll` `_buildDesktopTextContextMenu` `_onTextChanged` `_loadAll` `_backgroundSyncIdentity` `_saveAll` `_importMemory` `_showSnackBar` `_isDesktopPlatform` `_hasPromptChanges` `_hasSoulChanges` `_hasUserInfoChanges` `_hasMemoryChanges` `_hasIdentityToggleChanged` `_hasAnyChanges` or
- `class _MaterialTextField extends StatelessWidget`
  - controller hintText minLines maxLines fontFamily contextMenuBuilder

### theme_page.dart  (1134 Z.)

- `class ThemePage extends StatefulWidget`
  - config
- `class _ThemePageState extends State<ThemePage>`
  - `_applyThemeChanges` `_updateThemeMode` `_updateDynamicColorEnabled` `_selectPresetVariant` `_applyPreset` `_updateUiFont` `_updateChatFont` `_fontLabel` `_dynamicColorNote` `_matchedPreset` commit
- `class _ColorCard extends StatelessWidget`
  - description hexLabel currentColor options hexController gridColumns onColorSelected onHexChanged
- `class _ColorPickerDialog extends StatefulWidget`
  - initial
- `class _ColorPickerDialogState extends State<_ColorPickerDialog>`
  - `_setHsv` `_onHexSubmit`
- `class _GradientSlider extends StatelessWidget`
  - colors value onChanged
- `class _Swatch extends StatelessWidget`
  - color selected size onTap
- `class _PresetPicker extends StatelessWidget`
  - presets selected brightness onSelected title subtitle customLabel
- `class _PresetDots extends StatelessWidget`
  - preset brightness
- `class _FontCard extends StatelessWidget`
  - title subtitle sample value options labelFor onChanged

### tool_calling_settings_page.dart  (805 Z.)

- `class ToolCallingSettingsPage extends StatefulWidget`
  - config
- `class _ToolCallingSettingsPageState extends State<ToolCallingSettingsPage>`
  - `_toolDisplayNames` `_onDevOptionsChanged` `_loadToolPreferences` `_categoryOrder` `_categoryLabel` `_categoryIcon` `_categoryDescription` `_categoryServiceName` `_isCategoryConnectable` `_isCategoryConnected` `_connectService` `_disconnectService` `_displayName` `_isCategoryDevOnly` `_anyRegistered` `_visibleTools` `_buildToolSections` `_appendCollapsedInfraRows` `_openToolDetail` `_resetAllToolPreferences` maxChars
- `class _ToolRow extends StatelessWidget`  — One tool: the switch turns it off, the tile itself opens its detail.
  - icon iconEnabled title subtitle value onChanged onTap alwaysOn
- `class _CategoryLabel extends StatelessWidget`  — A light category label under the single "Tools" section header. Smaller and
  - label

### usage_details_page.dart  (1337 Z.)

- const: `_kMonthNames`
- `class UsageDetailsPage extends StatefulWidget`
- `class _UsageDetailsPageState extends State<UsageDetailsPage>`
  - `_loadUsageOverview` `_syncSelectedScope` `_appBar` `_hasCreditProgress` `_buildScopeSelector` `_buildSummaryCard` `_buildTokenActivitySection` `_buildHeatmapModeSelector` `_buildHeatmapLegend` `_heatmapCaption` `_buildBillingCard` `_buildModelSummaryCard` `_buildRequestCard` `_buildInlineWarning` `_buildScopeOptions` `_selectedScope` `_firstScopeByType` `_buildSlice` `_matchesScope` `_formatMonthYear` `_formatCount` `_formatDate` `_formatDateTime` `_twoDigits` `_formatEurSmart` decimals
- `enum _UsageScopeType`
  - allTime billingPeriod calendarMonth
- `class _UsageScopeOption`
  - key label type start end
- `class _UsageSlice`
  - entries requests textTokens mediaRequests totalCreditsEur totalCostUsd cacheReadTokens models
- `class _ModelSliceSummary`
  - modelId primaryProvider requestCount textTokens mediaRequests totalCreditsEur totalCostUsd
- `class _MutableModelSliceSummary`
  - freeze modelId providerHits requestCount textTokens mediaRequests totalCreditsEur totalCostUsd
- `class _StatGrid extends StatelessWidget`  — Label/value pairs on baseline-aligned rows. Replaces the boxed metric
  - rows
- `class _StreakTile extends StatelessWidget`  — One of the two streak read-outs: a big number over a quiet label.
  - label value icon
- `class _TokenActivityHeatmap extends StatelessWidget`  — A GitHub-contribution-style grid: one column per ISO week (oldest at the
  - `_cell3` `_buildWeekdayLabels` `_tooltipFor` `_formatDay` `_formatTokens` series values mode
- `int _heatmapLevel(int value, int maxValue)`  — Quartile of [value] against [maxValue]: 0 (none) then 1–4 (light→dark).
- `Color _heatmapCellColor(BuildContext context, int level)`  — Cell colour for a heat level, from theme tokens so both themes read well:

### workspace_detail_page.dart  (1021 Z.)

- `class WorkspaceDetailPage extends StatelessWidget`
  - `_isMobileForm` workspaceId onStartNewChat
- `class _WorkspaceDetailDesktop extends StatefulWidget`
  - workspaceId onStartNewChat
- `class _WorkspaceDetailPageState extends State<_WorkspaceDetailDesktop> with SingleTickerProviderStateMixin, WorkspaceAct …)`
  - `_loadModelId` `_loadProject` `_saveSettings` `_addChat` `_confirmContextBudget` `_buildFilesTab` `_formatTokenCount` `_contextChipColor` `_buildChatsTab` `_buildSettingsTab` workspaceId
- `class _ContextUsageBar extends StatelessWidget`
  - ratio totalTokens contextWindow displayColor isOverBudget
- `class _ChatSelectorDialog extends StatefulWidget`
  - chats
- `class _ChatSelectorDialogState extends State<_ChatSelectorDialog>`
  - `_filter`

### workspace_files_page.dart  (770 Z.)

- `class WorkspaceFilesPage extends StatefulWidget`
  - workspaceId
- `class _WorkspaceFilesPageState extends State<WorkspaceFilesPage> with WorkspaceActionsMixin<WorkspaceFilesPage>`
  - `_load` `_loadModel` `_uploadBytes` `_pickFromDevice` `_takePhoto` `_pickImage` `_createDocument` `_timestampedName` `_showAddSheet` `_deleteFile` workspaceId
- `class _SheetTile extends StatelessWidget`
  - icon label onTap
- `class _FileTile extends StatelessWidget`
  - file workspaceId color onDelete
- `class _UploadProgress extends StatelessWidget`
  - fileName status progress color
- `class _DocumentDraft`
  - title content
- `class _NewDocumentPage extends StatefulWidget`
- `class _NewDocumentPageState extends State<_NewDocumentPage>`

### workspace_instructions_page.dart  (223 Z.)

- `class WorkspaceInstructionsPage extends StatefulWidget`
  - workspaceId
- `class _WorkspaceInstructionsPageState extends State<WorkspaceInstructionsPage>`
  - `_onChanged` `_save` `_confirmDiscard` `_hasChanges`

### workspace_management_page.dart  (747 Z.)

- `class WorkspaceManagementPage extends StatefulWidget`  — Mobile-friendly workspace management page
  - workspaceId onStartNewChat
- `class _WorkspaceManagementPageState extends State<WorkspaceManagementPage> with SingleTickerProviderStateMixin, Workspac …)`
  - `_loadProject` `_saveInstructions` `_addChat` `_startNewChatWithProject` `_buildFilesTab` `_buildFileCard` `_buildChatsTab` `_buildSettingsTab` `_showEditProjectDialog` `_showDeleteProjectDialog` workspaceId
- `class _ChatSelectorSheet extends StatelessWidget`  — Bottom sheet for selecting a chat to add to workspace
  - chats

### workspace_mobile_detail_page.dart  (565 Z.)

- `class WorkspaceMobileDetailPage extends StatefulWidget`
  - workspaceId onStartNewChat
- `class _WorkspaceMobileDetailPageState extends State<WorkspaceMobileDetailPage>`
  - `_load` `_openFiles` `_openInstructions` `_confirmDelete` `_editNameDescription`
- `class _PrivacyChip extends StatelessWidget`
  - isPublic theme
- `class _InfoCard extends StatelessWidget`
  - title bodyText bodyIsPlaceholder footer onTap
- `String _formatDate(DateTime date, BuildContext context)`
- `class _ChatRow extends StatelessWidget`
  - chat theme

### workspaces_page.dart  (853 Z.)

- `enum ProjectSortMode`  — Sort options for workspace list
  - recentlyUpdated name mostFiles mostChats
- `class WorkspacesPage extends StatefulWidget`
  - onOpenWorkspace embedded
- `class _WorkspacesPageState extends State<WorkspacesPage>`
  - `_onSearchChanged` `_loadProjects` `_filterProjects` `_createProject` `_deleteProject` `_archiveProject` `_buildEmptyState` `_buildDesktopGrid` `_buildMobileList` `_buildFlatList` `_openProjectDetail`
- `class _SortButton extends StatelessWidget`
  - `_sortItem` sortMode onChanged
- `class _ProjectRow extends StatelessWidget`
  - `_showRowMenu` `_editedLabel` workspace onTap onDelete onArchive
- `class _CreateProjectDialog extends StatefulWidget`
- `class _CreateProjectDialogState extends State<_CreateProjectDialog>`
  - `_submit`

## lib/platform_specific

### root_wrapper.dart  (5 Z.)

- conditional export: 'root_wrapper_stub.dart' if (dart.library.io) 'root_wrapper_io.dart'

### root_wrapper_desktop.dart  (780 Z.)

- `class RootWrapperDesktop extends StatefulWidget`
  - config
- `class _RootWrapperDesktopState extends State<RootWrapperDesktop>`
  - `_onArtifactChanged` `_onPanelOpenChanged` `_onArtifactOpenRequested` `_closeArtifactPanel` `_openSourceChatForArtifact` `_openSettingsPage` `_openWorkspacesPage` `_openWorkspace` `_startWorkspaceChat` `_exitProject` `_closePanel` `_openMediaPage` `_handleChatSelected` `_toggleSidebar` `_copyDebugChat` `_buildMiniRail` `_onTrayNewChat` `_handleNewChatFromSidebar` `_handleChatDeleted`

### root_wrapper_io.dart  (76 Z.)

- `class RootWrapper extends StatelessWidget`
  - `_isMobilePhone` config

### root_wrapper_mobile.dart  (768 Z.)

- `class RootWrapperMobile extends StatefulWidget`
  - config
- `class _RootWrapperMobileState extends State<RootWrapperMobile> with WidgetsBindingObserver, SingleTickerProviderStateMix …)`
  - `_onPanelOpenRequested` `_onArtifactChanged` `_maybeOpenArtifactSheet` `_refreshSessionOnResume` `_ensurePermissions` `_ensureBatteryOptimizationDisabled` `_showPermissionBlockedSnackBar` `_toggleSidebar` `_openSettingsPage` `_openWorkspacesPage` `_openMediaPage` `_handleChatSelected` `_handleChatDeleted` `_newChatFromAppBar` `_currentChatTitle` `_buildFloatingTopBar` `_floatIconChip` `_newChatFromSidebar` `_openArtifactSheet` `_copyDebugChat`

### root_wrapper_stub.dart  (19 Z.)

- `class RootWrapper extends StatelessWidget`  — Web wrapper - renders desktop UI since web is a desktop-like environment
  - config

### sidebar_desktop.dart  (520 Z.)

- `class SidebarDesktop extends StatefulWidget`
  - onChatSelected onSettingsTapped onWorkspacesTapped onMediaTapped onNewChatTapped onChatDeleted onCollapseTapped selectedChatId isCompactMode showWorkspacesButton
- `class _SidebarDesktopState extends State<SidebarDesktop> with SidebarStateCommon<SidebarDesktop>`
  - applyChatFilter `_focusDesktopSearch` `_onDesktopSearchChanged` `_clearDesktopSearch` `_refreshDesktopChats` `_filterDesktopChats` `_buildDesktopSlivers` `_selectDesktopChat` `_buildDesktopChatItem` `_openChatActionsMenu` `_handleMenuSelection` `_buildMenuItems` `_showChatContextMenu` onChatDeletedCallback

### sidebar_mobile.dart  (694 Z.)

- `class SidebarMobile extends StatefulWidget`
  - onChatSelected onSettingsTapped onWorkspacesTapped onMediaTapped onNewChatTapped onChatDeleted onCollapseTapped selectedChatId isCompactMode
- `class _SidebarMobileState extends State<SidebarMobile> with SidebarStateCommon<SidebarMobile>`
  - applyChatFilter `_focusMobileSearch` `_onSearchFocusChanged` `_onMobileSearchChanged` `_clearMobileSearch` `_refreshMobileChatsFromGesture` `_refreshChats` `_performRefresh` `_filterMobileChats` `_filterChatsLocally` `_buildMobileSlivers` `_buildMobileNavigationCards` `_selectMobileChat` `_buildMobileChatItem` `_showChatOptionsMenu` `_chatOptionRow` onChatDeletedCallback
- `List<String> _filterChatsIsolate(Map<String, dynamic> params)`

## lib/platform_specific/chat

### chat_api_service.dart  (400 Z.)

- `class ChatApiService`  — A service for handling chat-related API interactions,
  - performFileUpload performFileUploadFromBytes transcribeAudioFile transcribeAudioBytes `_messageFromErrorPayload` `_apiBaseUrl` onUploadStatusUpdate
- `class TranscriptionResult`
  - text metadata
- `class TranscriptionException implements Exception`
  - message statusCode

### chat_debug_snapshot.dart  (56 Z.)

- `abstract class ChatDebugSnapshot`  — What the "copy debug chat" action reads out of a running chat screen.
  - debugMessages debugModelId debugProviderSlug debugWorkspaceId debugReasoningEffort debugActiveChatId
- `Map<String, String> chatDebugContext( ChatDebugSnapshot? state, { required String platform, })`  — The context block that rides along with a copied debug chat.

### chat_message_edit_mixin.dart  (343 Z.)

- `mixin ChatMessageEditMixin<W extends StatefulWidget> on State<W>, ChatScrollMixin<W>`
  - deleteComposerAttachment sendMessage onEditStarted onComposerAttachmentRemoved isValidMessageIndex showSnackBar reconstructAttachedFilesForResend editMessageAt cancelEditMessage removeComposerAttachment sendOrSubmitEdit resendMessageAt branchFromIndex captureRegenSeed switchVariantAt updateAiMessage messages activeChatId messageActionsHandler persistenceHandler composerController composerFocusNode restoredAttachmentIds composerAttachedFiles nothingToResendMessage removeFollowingAssistant waitForCompletion

### chat_model_selection_mixin.dart  (322 Z.)

- `mixin ChatModelSelectionMixin<W extends StatefulWidget> on State<W>, ModelProviderResolutionMixin<W>`
  - presentModelScreen refreshSelectedModelName refreshCustomModelName refreshPickedModels applyPickedModels openModelScreen setChatMode setReasoningEffort clampedReasoningEffort applyModelSelection restoreChatMode applyModeConfig loadSavedModelPreference selectedModelId selectedProviderSlug chatMode reasoningEffort selectedModelName pickedModels customModelName

### chat_scroll_mixin.dart  (215 Z.)

- `mixin ChatScrollMixin<T extends StatefulWidget> on State<T>`  — Shared message-list scroll behaviour for the desktop and mobile chat UIs.
  - onScrollChanged onComposerHeightChanged pinToBottomDuringStream showScrollButtonDistance hideScrollButtonDistance scrollController showScrollToBottom isStickyBottom composerHeight animate lastExtent

### chat_ui_desktop.dart  (2824 Z.)

- part 'desktop_send_logic.dart'
- `class ChukChatUIDesktop extends StatefulWidget`
  - onToggleSidebar selectedChatId onChatIdChanged isSidebarExpanded isCompactMode showReasoningTokens showModelInfo showTps workspaceId onExitProject imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls autoSendVoiceTranscription onOpenModelSettings
- `class ChukChatUIDesktopState extends State<ChukChatUIDesktop> with SingleTickerProviderStateMixin, ChatScrollMixin, Mode …)`
  - deleteComposerAttachment onComposerAttachmentRemoved sendMessage `_buildComposerContextMenu` `_buildMessageContextMenu` `_loadChatById` `_applyLoadedChat` `_loadChatByIdAsync` `_populateMessagesFromStoredChat` `_messageToRawMap` newChat newChatWithWorkspace `_openComingSoonFeature` `_loadSystemPrompt` `_resolveWorkspaceForCurrentChat` `_resolveSystemPromptForSend` `_handleMicTap` `_handleAudioSend` `_askUserCallbackForIndex` `_connectMcpCallbackForIndex` `_buildMessageActionsForIndex` `_buildUserMessageActionsForIndex` `_wrapWithSmartPasteActions` `_buildAudioVisualizer` `_buildRecordingPill` `_persistChatWithId` `_persistChatWithIdAndMessages` `_buildMessageRenderData` `_clearMessageDecodeCaches` `_buildSearchBar` `_buildModelControlPill` presentModelScreen messages activeChatId composerAttachedFiles `_isSending` `_isStreaming` `_isLinuxDesktop` debugMessages debugSystemPrompt +15
- `class _DesktopRecordingDot extends StatefulWidget`
- `class _DesktopRecordingDotState extends State<_DesktopRecordingDot> with SingleTickerProviderStateMixin`

### chat_ui_helpers.dart  (1047 Z.)

- `class MessageRenderData`  — Data class holding pre-parsed render information for a single chat message.
  - isUser sender displayText reasoning isReasoningStreaming modelLabel modelProvider tps images imageMetas imageCostEur imageGeneratedAt attachments toolCalls contentBlocks isStreamingMessage turnStartedAt workedFor status queueId lastError variantIndex variantCount
- `class ChatUiHelpers`  — Static utility functions shared between the desktop and mobile chat UIs.
  - stableUiKey formatModelInfo modelSupportsImageInput showSnackBar openComingSoonFeature loadProviderSlugForModel ensureProviderSlug loadSystemPrompt resolveSystemPromptForSend messageToRawMap variantSnapshotOf decodeVariants writeVariants switchVariant finalizeStaleToolCallsInRawMessage `_finalizeStaleToolCallsForRecovery` decodeImages decodeAttachments decodeToolCalls decodeContentBlocks extractArtifactIdsFromRawMessage trimCachesIfNeeded reconstructAttachedFilesForResend writeAttachmentsToMessage extractResendUserQuery `_looksLikeGeneratedAttachmentHeader` buildResendUserPrompt `_buildMarkdownFence` detectImageMimeType buildMessageRenderData kUiKeyField kVariantContentKeys kVariantArchiveOnlyKeys

### chat_ui_mobile.dart  (4013 Z.)

- `enum _AttachChoice`  — What the plus menu can start.
  - camera photos files workspace
- `class _WorkspaceChoice`  — A row in the workspace menu: a workspace to switch to (null clears it),
  - workspaceId create
- `class ChukChatUIMobile extends StatefulWidget`
  - onToggleSidebar selectedChatId onChatIdChanged isSidebarExpanded showReasoningTokens showModelInfo showTps autoSendVoiceTranscription topInset imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls
- `class ChukChatUIMobileState extends State<ChukChatUIMobile> with ChatScrollMixin, ModelProviderResolutionMixin, ChatMode …)`  — Serialize a [ChatMessageStatus] into the wire-format string used inside
  - deleteComposerAttachment onEditStarted `_initializeHandlers` `_persistStreamTick` `_markAssistantMessageInterrupted` `_handleAppResumed` `_handleAppPaused` `_showPaymentRequiredDialog` `_initializeListeners` `_onControllerChanged` `_loadInitialData` `_loadChatById` `_applyLoadedChat` `_loadChatByIdAsync` newChat `_handleMicTap` `_handleAudioSend` `_handleAddAttachmentTap` `_showAnchoredComposerMenu` `_buildWorkspaceChip` `_openWorkspaceMenu` `_openProjectManagement` startNewChatWithWorkspace `_startNewChatWithProject` `_handleFileUploadUpdate` `_clearMessageDecodeCaches` `_decodeImages` `_decodeAttachments` `_decodeToolCalls` `_decodeContentBlocks` `_updateToolCallsForMessage` `_handleToolImagesProcessed` `_updateContentBlocksForMessage` `_updateRequestPayloadForMessage` `_finalizeAiMessage` `_cancelPendingMessage` `_drainPendingMessage` sendMessage `_buildApiHistory` `_resolveSystemPromptForSend` +37

### desktop_send_logic.dart  (2394 Z.)

- part of 'chat_ui_desktop.dart'
- `extension DesktopSendLogic on ChukChatUIDesktopState`  — Extension on [ChukChatUIDesktopState] containing the large send/streaming
  - `_extractResendUserQueryFromDisplayText` `_buildResendUserPrompt` `_beginSendOperation` `_isSendOperationCancelled` `_clearSendOperation` `_markLastAssistantMessageCancelled` `_cancelPendingSendOperation` `_cancelStream` `_cancelCurrentOperation` `_isSendingForChat` `_showPaymentRequiredDialog` `_sendMessage` `_detectImageMimeType` `_buildApiHistoryWithPendingMessage` `_updateToolCallsForMessage` `_appendDebugRequestForMessage` `_processToolImages` `_finalizeAiMessage` `_cancelPendingMessage` `_drainPendingMessage` `_enqueueOfflineSend` removeFollowingAssistant foldVariant

### model_provider_resolution_mixin.dart  (120 Z.)

- `mixin ModelProviderResolutionMixin<T extends StatefulWidget> on State<T>`  — Shared model → provider-slug resolution for the desktop and mobile chat UIs.
  - ensureProviderSlugForCurrentModel selectedModelId selectedProviderSlug modelSupportsImageInput forceFromPrefs

### regen_variant_seed.dart  (150 Z.)

- `mixin RegenVariantSeedMixin<W extends StatefulWidget> on State<W>`
  - armVariantSeed clearVariantSeed stashVariantSeedForBackground restoreVariantSeedForChat foldRegenVariantOnto foldBackgroundVariantOnto variantActiveChatId

## lib/platform_specific/chat/handlers

### audio_recording_handler.dart  (453 Z.)

- `class AudioRecordingHandler`  — Handles microphone recording + transcription.
  - setTranscribing startRecording transcribeLastRecording resetAudioLevels `_handlePcmChunk` `_tryConnectStreaming` `_transcribeStreaming` `_transcribeBufferedPcm` `_pcmToWav` `_writeAscii` `_computeAmplitudeFromPcm` `_resetAudioLevels` `_ensureMicPermission` isMicActive isTranscribingAudio audioLevels isStreamingMode onLevelsChanged keepFile
- `class TranscriptionResult`  — Result of audio transcription.
  - success text error requiresLogout

### chat_persistence_handler.dart  (447 Z.)

- `@visibleForTesting bool keepsMoreThanPatch(String? stored, String? patch)`  — Handles chat persistence and storage
- `class ChatPersistenceHandler`
  - flushPending stampWorkedFor `_flushBackgroundUpdate` waitForCompletion silent immediate
- `class _PendingBackgroundUpdate`
  - chatId messageIndex content reasoning toolCallsJson contentBlocksJson images imageMetas imageCostEur imageGeneratedAt tps attempts status

### desktop_clipboard_handler.dart  (265 Z.)

- `class DesktopClipboardHandler`  — Handles desktop-specific clipboard operations and context menus.
  - selectedTextOrAll buildComposerContextMenu buildMessageContextMenu sanitizeClipboardInPlace handleSmartPaste cleanupOldPasteTempDirectories kLongPasteThreshold kPasteTempRetention onProcessFilePaths

### desktop_file_handler.dart  (439 Z.)

- `class ValidatedFile`  — Temporary container for validated files before upload.
  - file fileName fileSize isImage id
- `class DesktopFileHandler`  — Handles desktop-specific file attachment processing including:
  - initialize getUploadedFiles processFilePaths `_uploadEncryptedImage` uploadFiles processWebFiles `_uploadEncryptedImageFromBytes` handleDroppedFiles removeAttachedFile handleFileUploadUpdate clearAll hasAttachments hasUploading attachedFiles onShowSnackBar onUpdate onScrollToBottom modelSupportsImageInput

### file_attachment_handler.dart  (429 Z.)

- `class FileAttachmentHandler`  — Handles file and image attachments
  - initialize pickImageFromSource pickImagesFromGallery uploadFiles `_handleFileAttachment` Function `_uploadEncryptedImageFromBytes` `_isImageExtension` handleUploadStatusUpdate removeFile clearAll getUploadedFiles attachedFiles hasAttachments hasUploading onUpdate

### message_actions_handler.dart  (196 Z.)

- `class MessageActionsHandler`  — Handles message-related actions (copy, edit, resend)
  - `_forExport` copyToClipboard startEdit cancelEdit submitEdit resend Function editingMessageIndex isEditing canRetryToolPass

### mobile_workspace_handler.dart  (155 Z.)

- `class MobileWorkspaceHandler`  — Handles mobile-specific workspace selection UI and workspace–chat linking.
  - Function addChatToProject removeChatFromProject

### scanned_pdf_pages.dart  (89 Z.)

- `Future<void> replaceWithScannedPages({ required List<String> dataUrls, required String fileId, required String fileName …)`  — Replaces a scanned PDF in [attachedFiles] with its rendered pages.
- `void discardScannedPages(List<String> paths)`  — Deletes pages that were uploaded before the replacement failed, so a

### streaming_message_handler.dart  (1571 Z.)

- `class StreamingMessageHandler`  — Handles message streaming and sending
  - cancelStream `_processToolImages` `_acquireForegroundKeepAlive` `_releaseForegroundKeepAlive` `_updateForegroundNotification` resetState isChatStreaming getBufferedContent getBufferedReasoning getStreamingMessageIndex hasCompletedStream consumeCompletedStream setBackgroundMessages getBackgroundMessages hasBackgroundMessages getSessionSafely `_markStreamFinalized` `_recordSnapshot` `_clearSnapshot` `_handleAppPaused` `_markInterruptedIfStreaming` isStreaming isSending activeToolLoopFuture includeRecentImagesInHistory includeRecentImages forceImmediate
- `class _StreamingSnapshot`
  - chatId index content reasoning contentBlocksJson

## lib/platform_specific/chat/widgets

### desktop_chat_widgets.dart  (64 Z.)

- `Widget buildDesktopIconButton({ required IconData icon, required VoidCallback onTap, required bool isActive, required Co …)`  — Build icon button for desktop UI

### fullscreen_composer.dart  (149 Z.)

- `Future<String?> showFullscreenComposer( BuildContext context, { required String initialText, })`  — Opens the message being written on a screen of its own.
- `class _FullscreenComposerPage extends StatefulWidget`
  - initialText
- `class _FullscreenComposerPageState extends State<_FullscreenComposerPage>`
  - `_close`

### mobile_chat_widgets.dart  (346 Z.)

- `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive …)`  — Build a tiny icon button widget
- `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color …)`  — Build a tiny action button widget (for send, etc.)
- `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, requir …)`  — Build attachment sheet option (for bottom sheet)
- `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCal …)`  — Build keyboard listener for text field (handles Enter/Shift+Enter)
- `class ComposerInputRow extends StatelessWidget`  — Row one of the mobile composer: the text field, and — while the microphone
  - isRecording audioLevels accentColor timeColor child
- `class RecordingWaveformBar extends StatefulWidget`  — The open microphone: the live waveform, and the elapsed time beside it.
  - audioLevels color timeColor
- `class _RecordingWaveformBarState extends State<RecordingWaveformBar>`
  - `_format`

## lib/services

### api_config_base.dart  (116 Z.)

- const: apiConfigEnvApiUrl apiConfigEnvApiHost apiConfigEnvApiPort apiConfigDefaultPort apiConfigDefaultProtocol apiConfigDefaultProductionUrl apiConfigLocalUrl apiConfigProductionUrl artifactsConfigEnvUrl artifactsConfigDefaultProductionUrl
- `String? getConfiguredUrl()`  — Resolves an explicitly configured URL from environment variables, or null.
- `String getApiBaseUrl()`  — Gets the appropriate API base URL based on the current environment.
- `String getArtifactsBaseUrl()`  — Gets the artifacts hosting base URL.
- `String getEnvironment()`  — Whether the current build is pointing at the local development server.
- `bool getIsConfigured()`  — Checks whether the API was explicitly configured via environment variables,
- `String getConfigurationDescription(String platformName)`  — Gets a human-readable description of the current configuration.

### api_config_service.dart  (5 Z.)

- conditional export: 'api_config_service_stub.dart' if (dart.library.io) 'api_config_service_io.dart'

### api_config_service_io.dart  (35 Z.)

- `class ApiConfigService`  — Service for managing API configuration across different environments and platforms.
  - apiBaseUrl artifactsBaseUrl environment platform isConfigured configurationDescription

### api_config_service_stub.dart  (27 Z.)

- `class ApiConfigService`  — Service for managing API configuration across different environments and platforms.
  - apiBaseUrl artifactsBaseUrl environment platform isConfigured configurationDescription

### api_status_service.dart  (59 Z.)

- `class ApiStatusService`  — Utility helpers for checking the availability of the primary API.
  - `_buildUri` `_defaultBaseUrl` timeout method

### app_initialization_service.dart  (413 Z.)

- `class AppInitializationService`  — Callback for initialization events
  - initializeCoreServices `_preloadEncryptionKey` initializeUserSession `_startSyncWhenKeyReady` `_tryLoadKeyWithTimeout` `_loadUserData` `_startSyncAfterKey` `_startSyncAfterSidebarLoad` `_onLinuxKeyReady` `_startDeferredPreload` instance `_isLinuxDesktop` timeout

### app_lifecycle_service.dart  (155 Z.)

- `class AppLifecycleService extends ChangeNotifier`  — Callback when app state changes
  - addOnResumeCallback removeOnResumeCallback addOnPauseCallback removeOnPauseCallback handleLifecycleState `_handleResumed` `_checkNetworkThenResume` `_handlePaused` instance `_isDesktopPlatform`

### app_theme_service.dart  (810 Z.)

- `typedef ThemeChangedCallback = void Function()`  — Callback type for theme changes
- `class AppThemeService extends ChangeNotifier`  — Service for managing application theme state, persistence, and Supabase sync
  - `_onboardingKeyFor` `_getPrefs` loadFromPrefs `_readLocalOnboarding` `_clampChatFontSize` `_clampUiScale` `_clampContrast` `_sanitizeChatFontFamily` `_sanitizeUiFontFamily` `_loadFromSupabase` `_reconcileOnboarding` `_persistToPrefs` `_debouncedSyncTheme` `_debouncedSyncCustomization` `_syncThemeToSupabase` `_syncCustomizationToSupabase` setThemeMode setAccentColor setIconFgColor setBgColor setDynamicColorEnabled setShowReasoningTokens setShowModelInfo setShowTps setAutoSendVoiceTranscription setImageGenEnabled setImageGenDefaultSize setImageGenCustomWidth setImageGenCustomHeight setImageGenUseCustomSize setIncludeRecentImagesInHistory setIncludeAllImagesInHistory setIncludeReasoningInHistory setIncludeToolResultsInHistory setToolCallingEnabled setToolDiscoveryMode setShowToolCalls setUiLocale setChatFontSize setChatFontFamily +39

### approval_config.dart  (140 Z.)

- `enum ApprovalCategory`  — Categories of actions that may require approval
  - bash gmail slack github calendar
- `class ApprovalAction`  — Specific actions within each category that can require approval
  - category action description riskLevel riskDescription
- `class ApprovalConfig`  — Universal Approval Configuration
  - load isApprovalRequired allActions

### artifact_context_service.dart  (111 Z.)

- `class ArtifactContextService`
  - buildArtifactsSystemMessage

### artifact_diff_engine.dart  (134 Z.)

- `class ArtifactDiffEngine`
  - applyEdits `_findOccurrences` `_buildMatchError` `_trimPreview` `_escapeForMessage` `_extractContext` maxEditsPerUpdate

### artifact_storage_service.dart  (1888 Z.)

- `class ArtifactStorageService`
  - Function flushPendingEdits requestOpen listAllUserArtifacts loadArtifactById createArtifact updateArtifactWithEdits overwriteCurrentArtifact repairVersionChain `_insertVersion` rollbackArtifactsForMessages `_rollbackOneArtifact` `_loadLatestRemainingSnapshot` latestRemainingVersion computeOrphanBrackets filterOrphanSnapshotsInBrackets `_findOrphanSnapshotsForMessages` `_removeArtifactFromCache` deleteArtifactsByIds setAttachmentPath `_emitChange` `_insertIntoCache` `_requireUser` `_ensureCacheForUser` `_validateArtifactId` `_validateContentSize` `_isDuplicateArtifactError` `_handleMissingArtifactSchema` `_isMissingArtifactSchemaError` `_encryptOrThrow` `_decryptMaybe` changes activeChatId maxContentBytes activeArtifactNotifier panelOpenNotifier openRequestNotifier pendingInitialOpen currentMessageId forceRefresh +1

### artifact_tag_processor.dart  (142 Z.)

- `class ArtifactTagProcessor`  — Processes inline `<artifact>` tags emitted by the assistant. For each tag:
  - processTags `_processOne` `_errorCall`

### auth_service.dart  (197 Z.)

- `class AuthService`
  - signInWithPassword signUpWithPassword verifySignupOtp verifyRecoveryOtp `_verifyEmailOtp` resendSignupOtp `_mapOtpException` signOut
- `class AuthServiceException implements Exception`
  - message code codeEmailAlreadyRegistered codeOtpInvalidOrExpired codeOtpRateLimited

### bash_sandbox.dart  (457 Z.)

- `typedef ApprovalCallback = Future<bool> Function(String command, String reason)`  — Callback type for approval dialogs
- `class BashSandbox`  — Sandboxed Bash Command Executor
  - loadSavedFolder setSandboxFolder clearSandboxFolder isSafeCommand getUnsafeReason `_metaCharLabel` isWithinSandbox `_resolvedSandboxRoot` `_resolveThroughExistingParents` `_extractPathCandidates` `_isPathInsideSandbox` execute `_executeDirectly` isConfigured sandboxFolder safeCommands dangerousPatterns forbiddenMetaCharacters

### chat_cache_search_text.dart  (41 Z.)

- `String? buildChatSearchText(String payload)`  — Build the searchable text of a chat payload: message text only.

### chat_history_builder.dart  (295 Z.)

- `class ChatHistoryBuilder`
  - foldAttachmentsIntoText `_foldAttachmentsIntoText` `_dropPendingUserTurn` entryText resolveHistoryImages includeRecentImages

### chat_mode_service.dart  (560 Z.)

- `enum ChatMode`
  - fast thinking custom
- `@immutable class ModeConfig`  — One mode's independent settings: which model, on which provider, at which
  - copyWith toJson reasoningOn modelId providerSlug reasoningEffort operator
- `class ChatModeService`
  - isDeepThinking defaultConfig isFireworksProvider reasoningLevelsForModel sanitizeReasoningForModel `_clampToAllowed` reasoningLabel `_configKey` loadConfig saveConfig hasStoredConfig setModelForMode setReasoningForMode setProviderForMode load save parse defaultModelId defaultProviderSlug reasoningOff reasoningOn reasoningLevelsGraded reasoningLevelsAll reasoningLevelsFireworks fallbackMode supportsReasoning

### chat_preload_service.dart  (390 Z.)

- `class ChatPreloadService`  — Service for background preloading all chat messages.
  - startBackgroundPreload `_fetchFromRemote` `_decryptAndStoreRows` awaitPreload preloadNewChats reset isPreloading isPreloadComplete failureCount progress progressStream loadedCount totalCount fullyLoadedCount

### chat_runtime.dart  (184 Z.)

- `@immutable class StreamingLive`  — Immutable snapshot of the assistant placeholder's live streaming body,
  - index text reasoning operator
- `class ChatRuntime`  — Per-chat in-memory live state.
  - touch setMessages appendMessage updateMessage removeMessageAt beginStream pushStreamingText endStream isIdle chatId messages isSending isStreaming streamingLive placeholderIndex modelId provider cancelHandler lastTouchedAt

### chat_runtime_registry.dart  (95 Z.)

- `class ChatRuntimeRegistry`  — Singleton registry of per-chat [ChatRuntime]s.
  - get lookup release clear `_evictIdleIfNeeded` isAnyStreaming streamingChatIds instance maxIdleRuntimes

### chat_storage_crud.dart  (1281 Z.)

- `class ChatStorageCrud`  — Handles CRUD operations for chat storage: save, update, delete, load.
  - extractTitleFromMessages `_resolveStoredTitle` `_repairEncryptedTitleIfNeeded` loadFullChat `_syncChatFromRemote` `_loadFullChatFromCache` loadFromCache `_sidebarChatFromCacheRow` `_decryptChatRowsBatch` loadChats `_buildAndCachePlaintextRows` `_extractImagePaths` `_mapToChatMessages` saveChat `_doSaveChat` updateChat `_doUpdateChat` deleteChat

### chat_storage_mutations.dart  (288 Z.)

- const: kChatPayloadVersion
- `class ChatStorageMutations`  — Handles chat mutations: star, rename, re-encrypt, export
  - setChatStarred renameChat reencryptChats exportChats exportChatsAsJson
- `Future<void> saveTitlesToCache(String userId, List<StoredChat> chats)`  — Save decrypted titles to local cache for instant loading.

### chat_storage_service.dart  (174 Z.)

- conditional export: 'package:chuk_chat/models/chat_message.dart' · 'package:chuk_chat/models/stored_chat.dart' · 'package:chuk_chat/services/chat_storage_state.dart' show initChatStorageCache
- `class ChatStorageService`  — Facade class providing backward-compatible API for chat storage.
  - getChatById getChatTimestamps loadFullChat loadFromCache loadChats saveChat updateChat deleteChat loadSavedChatsForSidebar syncTitlesFromNetwork setChatStarred renameChat reencryptChats exportChats exportChatsAsJson mergeSyncedChat mergeSyncedChatsBatch removeChatLocally reset initialSyncComplete selectedChatIdNotifier selectedChatId isMessageOperationInProgress activeMessageChatId isLoadingChat savedChats changes

### chat_storage_sidebar.dart  (521 Z.)

- const: `_kSidebarApplyChunkSize` `_kSidebarIsolateParseThresholdChars`
- `List<Map<String, Object?>> _parseSidebarTitleCache(String raw)`  — Parse cached sidebar title JSON into a typed list.
- `class ChatStorageSidebar`  — Handles sidebar-specific chat loading and title caching.
  - loadSavedChatsForSidebar syncTitlesFromNetwork `_loadTitlesFromCache` `_syncTitlesFromNetwork` `_decryptTitlesBatch` `_loadSidebarFromCache`

### chat_storage_state.dart  (243 Z.)

- const: sharedPrefsInstance
- `Future<void> initChatStorageCache()`  — Pre-initialize SharedPreferences at app startup for instant cache access
- `String chatTitlesCacheKey(String userId)`  — kv_cache key holding the sidebar title list for [userId].
- `class ChatStorageState`  — Central state management for chat storage.
  - markDeleted wasRecentlyDeleted getChatById notifyChanges notifyChangesImmediate checkNetworkStatus getChatTimestamps reset selectedChatId isMessageOperationInProgress isLoading savedChats changes chatsById changesController initialSyncComplete selectedChatIdNotifier activeMessageChatId isLoadingChat uuid savingChats pendingSaves recentlyDeletedChats cacheLoaded loadingCompleter

### chat_storage_sync.dart  (468 Z.)

- `class DeserializeResult`  — Internal class for deserialize results from isolate
  - messages customName
- `DeserializeResult deserializePayloadIsolate(String json)`  — Top-level function for background JSON deserialization
- `class ChatPayload`  — Internal class for chat payload
  - messages customName
- `Future<ChatPayload> deserializePayloadAsync(String json)`  — Deserialize chat payload in background isolate to avoid UI blocking
- `List<ChatPayload?> _deserializeBatchIsolate(List<String> jsonPayloads)`  — Top-level function for batch deserialization in a single isolate.
- `Future<List<ChatPayload?>> deserializePayloadBatchAsync( List<String> jsonPayloads, )`  — Batch deserialize multiple payloads in a single isolate (much faster
- `String chatTitleFromMessages(List<ChatMessage> messages)`  — The title a chat gets when nobody named it: its first user message,
- `String plaintextPayloadJson(ChatPayload chatPayload)`  — Serialises a decrypted [ChatPayload] for the plaintext local cache.
- `class ChatStorageSync`  — Handles chat synchronization from cloud to local state.
  - mergeSyncedChat `_upsertPlaintextCache` mergeSyncedChatsBatch removeChatLocally

### chat_sync_service.dart  (405 Z.)

- `class ChatSyncService`  — Service for syncing chats between local state and Supabase.
  - start stop pause resume `_syncTitlesOnResume` syncNow `_performSync` isEnabled isSyncing hasCompletedFirstSync lastSyncAt lastSyncOutcome firstSyncComplete `_initialSyncDelay`

### current_user.dart  (49 Z.)

- `abstract final class CurrentUser`  — Who is signed in, for the static caches that are keyed on it.
  - stillOwns id debugIdOverride

### customization_preferences_service.dart  (249 Z.)

- `class CustomizationPreferences`
  - copyWith toMap defaults fromMap userId autoSendVoiceTranscription showReasoningTokens showModelInfo showTps imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls uiLocale chatFontSize chatFontFamily onboardingCompleted
- `String _sanitizeFontFamily(String? id)`
- `class CustomizationPreferencesService`
  - loadOrCreate save `_table`
- `class CustomizationPreferencesServiceException implements Exception`
  - message

### developer_options_service.dart  (206 Z.)

- `class DeveloperOptionsService`  — Cross-device developer options toggle.
  - initialize isEnabled setEnabled `_saveRemote` `_extractPreferencesMap` `_extractRemoteFlag` `_coerceBool` enabledNotifier forceRefresh

### device_services.dart  (728 Z.)

- `class DeviceServices`  — Singleton service providing access to native device features.
  - `_ensureTimezones` `_getNotificationsPlugin` getCurrentLocation getLastKnownLocation calculateDistance `_createCalendarUrl` `_icsDateTime` `_googleDateTime` `_icsEscape` `_pad` setAlarm setTimer cancelAlarm listAlarms `_fireAlarmNotification` `_persistAlarms` `_formatDuration` createSmsDraft createEmailDraft showNotification getPlatformCapabilities allDay

### diagnostics_log_service.dart  (5 Z.)

- conditional export: 'diagnostics_log_service_stub.dart' if (dart.library.io) 'diagnostics_log_service_io.dart'

### diagnostics_log_service_io.dart  (566 Z.)

- `class DiagnosticsLogService`  — Opt-in diagnostics logger that also works in release builds.
  - setAppInForeground initialize isEnabled setEnabled info warning error timing getLogFilePath clearLogs `_parseLogLine` `_parseTimestamp` `_formatCompactEntry` `_write` `_ensureLogFile` `_appendRaw` `_rotateIfNeeded` `_encodeLine` `_sanitizeData` `_setFrameMonitoring` `_onFrameTimings` maxLines lookbackMinutes

### diagnostics_log_service_stub.dart  (53 Z.)

- `class DiagnosticsLogService`
  - setAppInForeground initialize isEnabled setEnabled info warning error timing getLogFilePath clearLogs maxLines lookbackMinutes

### download_preferences_service.dart  (70 Z.)

- `class DownloadPreferencesService`  — User preferences for how downloaded files are saved across the app.
  - ensureLoaded `_loadFromPrefs` setAlwaysAsk setDefaultFolder shouldSkipPrompt defaultFolder alwaysAsk alwaysAskNotifier defaultFolderNotifier

### encryption_service.dart  (974 Z.)

- `class _EncryptionParams`  — Parameters for background encryption
  - bytes keyBytes payloadVersion keyVersion
- `class _DecryptionParams`  — Parameters for background decryption
  - encrypted keyBytes payloadVersion
- `class _BatchDecryptionParams`  — Parameters for batch background decryption
  - encryptedList keyBytes payloadVersion
- `Future<String> _encryptBytesInBackground(_EncryptionParams params)`  — Top-level function for background encryption
- `Future<Uint8List> _decryptBytesInBackground(_DecryptionParams params)`  — Top-level function for background decryption
- `Future<String> _decryptStringInBackground(_DecryptionParams params)`  — Top-level function for background string decryption (for chat text)
- `Future<List<String?>> _decryptBatchInBackground( _BatchDecryptionParams params, )`  — Top-level function for batch background decryption
- `class _KeyDerivationParams`  — Parameters for PBKDF2 key derivation in background isolate
  - password salt iterations bits
- `Future<List<int>> _deriveKeyInBackground(_KeyDerivationParams params)`  — Top-level function for background PBKDF2 key derivation
- `class EncryptionService`
  - `_prefs` `_readLocalSecret` `_writeLocalSecret` `_deleteLocalSecret` initializeForPassword initializeForPasswordReset tryLoadKey `_syncMetadataInBackground` Function clearKey encrypt decrypt encryptBytes decryptBytes decryptInBackground decryptBatchInBackground tryDecryptWithKey tryDecryptBatchWithKey deriveKeyFromPasswordAndSalt `_ensureKey` `_deriveKey` `_randomNonce` `_constantTimeEquals` `_requireAuthenticatedUser` `_resolveCanonicalSalt` `_decodeBase64OrThrow` `_parseKeyVersion` extractKeyVersion `_updateUserMetadata` currentKeyVersion hasKey `_usePrefsBackend`

### file_conversion_service.dart  (424 Z.)

- `class FileConversionService`  — Service for converting files to markdown using the /v1/ai/convert-file endpoint.
  - extractPageImages convertFile convertFileFromBytes `_apiBaseUrl` maxTokensPerFile maxCharsPerFile

### file_save_service.dart  (144 Z.)

- `class SaveResult`  — Outcome of a save attempt. Callers use this to drive snackbars or follow-up
  - success outcome path
- `enum SaveOutcome`
  - savedToFolder savedViaPicker savedViaShare cancelled failed
- `class FileSaveService`  — Centralised file-save entry point. Every download in the app should funnel
  - save `_writeWithCollisionSuffix`

### github_connection_service.dart  (252 Z.)

- `class GitHubConnectionStatus`
  - connected githubLogin githubUserId scopes connectedAt lastUsedAt disconnected
- `class GitHubConnectInit`
  - state userCode verificationUri expiresIn interval
- `enum GitHubConnectPollState`  — Poll result from /connect/poll. ``success`` means the token is
  - pending success expired denied
- `class GitHubConnectPollResult`
  - state githubLogin
- `class GitHubConnectionException implements Exception`
  - statusCode message
- `class GitHubConnectionService`
  - `_headers` `_uri` status startConnect poll disconnect Function `_detail`

### github_oauth.dart  (465 Z.)

- `class GitHubOAuth`  — GitHub OAuth Service - Supports both OAuth App and Personal Access Token
  - loadSavedToken setPersonalToken setClientId startAuth completeAuth `_saveToken` logout getAccessToken getUser getRepo createIssue addComment redirectUri isAuthenticated isPersonalToken `_authHeaders` callbackPort authEndpoint tokenEndpoint apiBase scopes perPage state

### google_oauth.dart  (807 Z.)

- `class GoogleOAuth`  — Google OAuth Service - Backend-assisted flow for Gmail & Calendar APIs
  - startAuth completeAuth refreshAccessToken getAccessToken logout `_getMessageDetail` readMessage sendEmail getLabels listCalendars `_fetchUserInfo` `_extractBody` `_decodeBase64Url` `_saveTokens` `_loadTokens` redirectUri isAuthenticated userEmail `_authHeaders` callbackPort scopes maxResults calendarId

### image_compression_service.dart  (243 Z.)

- `Future<Uint8List> _compressImageInBackground(_CompressionParams params)`  — Top-level function for background image compression
- `class _CompressionParams`  — Parameters for background image compression
  - imageBytes maxDimension targetFileSizeBytes initialQuality minQuality
- `class ImageCompressionService`  — Service for compressing images with no size limit
  - compressImage detectImageFormat getFileSizeMB maxDimension targetFileSizeBytes initialQuality minQuality maxInputSizeBytes maxDecodedDimension

### image_storage_service.dart  (339 Z.)

- `class StoredImage`  — Represents a stored image with metadata
  - path name createdAt size
- `class ChatUsingImage`  — Represents a chat that uses a specific image
  - chatId chatName
- `String _utf8DecodeInBackground(Uint8List bytes)`  — Top-level function for UTF-8 decoding in background isolate
- `class ImageStorageService`  — Service for storing and retrieving encrypted images in Supabase Storage
  - clearFromCache clearCache getCached uploadEncryptedImage `_downloadAndDecryptImageInternal` deleteEncryptedImage listUserImages findChatsUsingImage onImageDeleted bucketName bypassCache

### key_version_service.dart  (149 Z.)

- `class PreviousKeyInfo`  — Represents a previous encryption key's metadata.
  - toJson salt version
- `class KeyVersionService`  — Manages encryption key versions for password reset recovery.
  - getPreviousKeys promoteCurrentToPrevious removePreviousKey hasPreviousKeys getSaltForVersion deriveKeyForVersion `_parseVersion` `_updateMetadata`

### local_chat_cache_native.dart  (934 Z.)

- `class LocalChatCacheService`
  - `_getDb` `_compressExistingPayloads` debugReset kvGet kvSet kvDelete `_createSkillsTable` skillRows upsertSkill deleteSkill replaceSkills buildPlaintextRow replaceAll upsert delete updateStarred loadMeta `_fetchBatched` count loadById ensureMigrated `_cleanupOldPrefsData` clear hasOldEncryptedCache migrateFromEncrypted `_runMigrations` `_migrateV3File` `_migrateV2Prefs` `_encodePayload` `_decodePayload` `_toDbRow` `_fromDbMetaRow` `_fromDbRow` `_sanitizeRow` `_escapeLikePattern` limit
- `List<Map<String, dynamic>> _parseJsonCacheInIsolate(String raw)`  — Parse JSON cache data in a background isolate (for migration reads).

### local_chat_cache_rows.dart  (66 Z.)

- `Map<String, dynamic> buildPlaintextCacheRow({ required String id, required String payload, required String createdAt, re …)`  — Builds a plaintext cache row.
- `Map<String, dynamic>? sanitizeCacheRow(Map<String, dynamic> row)`  — Normalises a row read back from storage, or returns null when it is not

### local_chat_cache_service.dart  (5 Z.)

- conditional export: 'local_chat_cache_web.dart' if (dart.library.io) 'local_chat_cache_native.dart'

### local_chat_cache_web.dart  (296 Z.)

- `class LocalChatCacheService`
  - debugReset kvGet kvSet kvDelete skillRows upsertSkill deleteSkill replaceSkills `_loadSkills` `_persistSkills` buildPlaintextRow replaceAll upsert delete updateStarred loadMeta count loadById ensureMigrated clear hasOldEncryptedCache migrateFromEncrypted `_loadChats` `_persist` `_sanitizeRow` limit

### message_composition_service.dart  (413 Z.)

- `class MessageCompositionResult`  — Result of message composition preparation
  - isValid errorMessage displayMessageText aiPromptContent accessToken providerSlug maxResponseTokens effectiveSystemPrompt images
- `class MessageCompositionService`  — Service for composing and validating chat messages before sending
  - Function `_buildMessageContent` resolveResponseTokenBudget `_calculateTokenLimits`
- `class _MessageContent`  — Internal class for message content
  - displayText aiPromptContent images
- `class _TokenLimits`  — Internal class for token limits
  - isValid errorMessage maxResponseTokens

### model_cache_service.dart  (184 Z.)

- `class ModelCacheService`
  - `_migrateFromPrefs` `_runMigration` saveAvailableModels isCacheValid loadAvailableModels displayNameFor saveSelectedModel loadSelectedModel saveProviderPreferences loadProviderPreferences updateProviderPreference clearProviderPreference clearAllForUser `_selectedModelKey` `_providerPrefsKey`

### model_capabilities_service.dart  (209 Z.)

- `class ModelCapabilitiesService`  — Service for determining model capabilities like vision and reasoning.
  - initialize `_enqueueLoad` `_loadIntoMaps` supportsImageInputSync supportsReasoningSync supportsReasoningEffortSync isReasoningMandatorySync supportedEffortsSync reasoningDefaultEffortSync refresh revision

### model_prefetch_service.dart  (113 Z.)

- `class ModelPrefetchService`
  - prefetch

### multiplex_connection.dart  (644 Z.)

- const: `_uuid`
- `class MultiplexException implements Exception`  — Error surfaced by [MultiplexConnection.tool] (and the chat stream's
  - detail code
- `String _newReqId()`  — Generate a fresh request id. ≤ 32 hex chars — comfortably under the
- `class MultiplexConnection`  — Multiplexed WebSocket client.
  - ensureReady `_openAndAuthenticate` `_resolveWsUrl` `_startHeartbeat` `_onFrame` `_dispatchChat` `_dispatchTool` chat tool cancel `_sendCancel` `_send` `_handleTransportFailure` `_teardown` sinceLastInbound hasInFlight accessTokenProvider baseUrl

### multiplex_session.dart  (419 Z.)

- const: `_idleCloseDelay` `_staleReconnectThreshold`
- `class MultiplexSession`
  - openForChat prewarm ensureCurrent closeForChat `_scheduleIdleClose` shutdown chatForChat `_tokenProvider` current currentChatId `_hasActiveStreams` timeout
- `class _ActiveChatStream`  — Per-chatId book-keeping for the single in-flight chat stream
  - controller subscription

### multiplex_tool_proxy.dart  (76 Z.)

- `class MultiplexToolOutcome`  — Result of [tryToolViaMultiplex]. Either holds a decoded body (when
  - isOk isError body fallback error
- `Future<MultiplexToolOutcome> tryToolViaMultiplex({ required String tool, required Map<String, dynamic> payload, })`  — Attempt to send a tool call over the multiplex socket. Designed so

### network_status_service.dart  (203 Z.)

- `class NetworkStatusService`  — Provides utilities for checking general internet reachability.
  - `_checkWithParallelProbes` `_checkSingleProbe` quickCheck `_updateStatus` resetFailureCount setOffline setOnline isNetworkError isOnlineListenable isOnline timeout
- `class _ConnectivityProbe`
  - uri headers expectedStatusCodes

### notification_service.dart  (5 Z.)

- conditional export: 'notification_service_stub.dart' if (dart.library.io) 'notification_service_io.dart'

### notification_service_io.dart  (250 Z.)

- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)
  - initialize `_createCompletionChannel` showCompletionNotification `_onNotificationTapped` checkLaunchNotification requestPermission isInitialized maxLength

### notification_service_stub.dart  (38 Z.)

- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)
  - initialize showCompletionNotification checkLaunchNotification requestPermission isInitialized

### oauth_loopback_server.dart  (158 Z.)

- `class OAuthResultPageTheme`  — Colours of the small page the browser shows after the redirect.
  - successColor errorColor background card border text
- `class OAuthLoopbackServer`  — Loopback HTTP server for the desktop OAuth redirect.
  - generateState start stop `_handle` `_fail` `_respond` `_page` redirectUri code port successTitle theme

### offline_queue_service.dart  (9 Z.)

- conditional export: 'offline_queue_service_web.dart' if (dart.library.io) 'offline_queue_service_native.dart'

### offline_queue_service_native.dart  (249 Z.)

- `class OfflineQueueService`  — Persistent offline send queue. Used by [OfflineRetryManager] to replay
  - `_open` init enqueue markFailed incrementAttempts remove listForChat listAll getById count watch `_emit` debugClearAll debugReset instance debugDatabasePath debugDatabaseFactory

### offline_queue_service_web.dart  (171 Z.)

- `class OfflineQueueService`  — SharedPreferences-backed persistent queue used on web where SQLite is not
  - `_read` `_write` init enqueue markFailed incrementAttempts remove listForChat listAll getById count watch `_emit` debugClearAll debugReset instance debugDatabasePath debugDatabaseFactory

### offline_retry_manager.dart  (220 Z.)

- `class SendExecutorResult`  — Outcome of a send executor call.
  - success error
- `typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg)`  — Performs the actual send for one queued message. Returns success or a
- `enum OfflineRetryEventType`  — Lifecycle event for retry attempts. Mostly useful for diagnostics + UI
  - started success failedNonRetryable failedDeferred noExecutor
- `class OfflineRetryEvent`
  - type queueId chatId error
- `class OfflineRetryManager`  — Watches connectivity and drains the offline queue when the device returns
  - init registerExecutor retryNow `_retryAll` `_retryOne` `_emit` debugReset events instance
- `class _RetryableError implements Exception`
  - message

### offline_send_coordinator.dart  (114 Z.)

- `class OfflineSendPayload`
  - toJson images chatId messageText modelId providerSlug systemPrompt imagesJson attachmentsJson attachedFilesJson maxTokens reasoningEffort
- `class OfflineSendCoordinator`  — Convenience wrapper around [OfflineQueueService] + [OfflineRetryManager].
  - enqueue retryNow payloadFrom

### offline_send_executor.dart  (166 Z.)

- `class OfflineSendExecutor`
  - register `_execute`

### onboarding_tour_controller.dart  (1155 Z.)

- `enum _Step`  — Step in the interactive tour state machine.
  - welcome pointerMenu pointerSettings settingsPage pointerSettingsModelSelection pointerProviderPill pointerSettingsPricing pointerSettingsAiIdentity pointerSettingsAssistant finale
- `class TourNavigatorObserver extends NavigatorObserver`  — Navigator observer the controller installs on the root navigator. It
  - Function detach didPush didPop
- `class OnboardingTourController`  — Singleton controller for the interactive onboarding tour.
  - start cancel `_finish` `_teardown` `_handleRoutePushed` `_handleRoutePopped` `_goTo` `_startMountWatch` `_stopMountWatch` `_onContinuePressed` `_onSkipPressed` `_onEndTourPressed` `_showOverlay` `_refreshOverlay` `_disposeOverlay` `_buildOverlayContent` `_slotFor` `_bodyKindFor` isActive `_stepAfterAiIdentity` instance navigatorObserver
- `enum _BodyKind`  — Marker for which copy block the banner should show.
  - welcome settingsPage finale pointerProviderPill pointerMenu pointerSettings pointerSettingsModelSelection pointerSettingsPricing pointerSettingsAiIdentity pointerSettingsAssistant
- `class _TourModalCard extends StatelessWidget`  — Welcome / finale full-screen card with a scrim.
  - showLogo onPrimary onSkip bodyKind
- `class _TourBannerOverlay extends StatefulWidget`  — Overlay shown for pointer + page-banner steps. Reads the target slot's
  - slot bodyKind showContinue onContinue onSkip onEndTour useScrim absorbTargetTap
- `class _TourBannerOverlayState extends State<_TourBannerOverlay> with SingleTickerProviderStateMixin`
  - `_onTick` `_headlineFor` `_bodyFor`
- `class _PulsingRing extends StatefulWidget`  — Animated pulsing ring rendered at the target position. Never receives
- `class _PulsingRingState extends State<_PulsingRing> with SingleTickerProviderStateMixin`

### password_change_service.dart  (189 Z.)

- `class PasswordChangeService`
  - changePassword `_rotateEncryptionForPasswordChange` `_tryRestoreEncryption`
- `class PasswordChangeException implements Exception`
  - message

### password_reset_service.dart  (263 Z.)

- `class RecoveryException implements Exception`  — Exception thrown by password reset recovery operations.
  - message
- `class PasswordResetService`  — Service for recovering or deleting chats encrypted with old keys
  - getLockedChatInfo getRecoverableVersions recoverChatsWithOldPassword deleteLockedChats lockedChatCount

### password_revision_service.dart  (171 Z.)

- `class PasswordRevisionService`  — Keeps track of a password revision marker so that other sessions can detect
  - hasRevisionMismatch ensureRevisionSeeded bumpRevision clearCachedRevision `_updateRemoteRevision` `_readRemoteRevision` `_cacheRevision` `_storageKey` `_prefs` `_readLocalValue` `_writeLocalValue` `_deleteLocalValue` `_usePrefsBackend`

### pdf_attachment_service.dart  (144 Z.)

- `String _utf8DecodeInBackground(Uint8List bytes)`
- `class PdfAttachmentService`
  - getCached clearFromCache clearCache upload `_downloadInternal` delete bucketName bypassCache

### per_model_system_prompt_service.dart  (558 Z.)

- const: `_kModelPromptSeparator`
- `enum ModelPromptMode`  — How a per-model system prompt combines with the base (global + workspace)
  - off replace append prepend
- `ModelPromptMode _modeFromString(String? raw)`
- `String _modeToString(ModelPromptMode mode)`
- `@immutable class ModelPromptConfig`  — Per-model system prompt configuration.
  - copyWith isActive prompt mode
- `String? mergeModelPrompt({ required String? base, required String? modelPrompt, required ModelPromptMode mode, })`  — Pure helper: merge a per-model prompt into a base system prompt according
- `class PerModelSystemPromptService`  — Manages per-model system prompts.
  - `_localKey` `_syncCacheToCurrentUser` `_dropLegacyLocalCache` loadAll get save delete `_loadFromLocal` `_decryptMap` `_persistAll` `_syncFromRemote` `_saveRemote` debugReset debugStillOwns debugPrimeCacheForUser debugSyncCacheToUser localCacheKeyForUser debugCache legacyLocalCacheKey

### profile_service.dart  (85 Z.)

- `class ProfileRecord`
  - copyWith toMap fromMap id email displayName
- `class ProfileService`
  - loadOrCreateProfile saveProfile `_table`
- `class ProfileServiceException implements Exception`
  - message

### round_content_block_service.dart  (321 Z.)

- `class RoundContentBlockResult`
  - blocks interimOutputText
- `class RoundContentBlockService`
  - `_lastReasoningMatches` `_tailMatches` `_blocksEqual` `_toolCallEqual` isDuplicateOfEarlierTextBlock normalizeTextForCompare `_mergeReasoning` foldInterimIntoReasoning interimBeforeToolCalls

### sandbox_service.dart  (598 Z.)

- `class SandboxInfo`
  - sessionId chatId status createdAt lastActivity snapshotRestored
- `class SandboxExecResult`
  - stdout stderr exitCode executionTimeMs
- `class SandboxFileEntry`
  - name size isDir permissions
- `class SandboxUploadResult`
  - path size
- `class SandboxDownloadResult`
  - bytes filename contentType
- `class SandboxServiceException implements Exception`
  - statusCode message
- `class SandboxService`
  - create list get_ extend destroy downloadFile `_toException` `_filenameFromDisposition` `_base` json language path contentType
- `DateTime _parseDate(dynamic value)`
- `int? _asInt(dynamic value)`
- `class SandboxSessionCache`  — Per-chat sandbox session bookkeeping.
  - ensureSession `_ensureImpl` forgetChat clearAll

### service_credentials_service.dart  (212 Z.)

- `class ServiceCredentialsService`  — Syncs encrypted OAuth tokens (Google, GitHub, MCP connectors, etc.) to
  - save load throwOnError

### session_manager_service.dart  (254 Z.)

- `typedef SessionEventCallback = void Function()`  — Callback for session-related events
- `class SessionManagerService extends ChangeNotifier`  — Service for managing user authentication sessions and security
  - initialize `_handleAuthStateChange` `_handleSessionActive` `_initializeUserSessionAsync` `_verifyPasswordRevisionInBackground` `_handleSessionInactive` `_handlePasswordRevisionMismatch` `_checkNetworkStatus` `_performLogoutCleanup` performFullLogout instance isInitialized

### settings_sync_service.dart  (65 Z.)

- `class SettingsSyncService`  — Central coordinator for cross-device settings sync.
  - forceRefresh

### slack_oauth.dart  (476 Z.)

- `class SlackOAuth`  — Slack OAuth Service
  - setCredentials `_generateRandomString` startAuth `_startCallbackServer` `_buildCallbackHtml` completeAuth getAccessToken `_saveTokens` `_loadTokens` isAuthenticated logout `_apiGet` `_apiPost` testAuth sendMessage findChannel redirectUri hasToken teamName teamId userId callbackPort authEndpoint tokenEndpoint apiBase userScopes types limit count

### streaming_chat_service.dart  (162 Z.)

- `class StreamingChatService`  — Service for handling streaming chat responses with Server-Sent Events (SSE).
  - `_apiBaseUrl` maxTokens
- `class StreamingChatException implements Exception`  — Exception thrown when streaming chat fails.
  - message statusCode

### streaming_foreground_service.dart  (5 Z.)

- conditional export: 'streaming_foreground_service_stub.dart' if (dart.library.io) 'streaming_foreground_service_io.dart'

### streaming_foreground_service_io.dart  (307 Z.)

- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.
  - initialize startService releaseKeepAliveLock updateNotification canStart isIgnoringBatteryOptimizations requestIgnoreBatteryOptimization `_stripMarkdown` isRunning hasKeepAliveLock startIfNeeded force
- `@pragma('vm:entry-point') void _foregroundTaskCallback()`  — Callback for foreground task - we don't need to do anything here
- `class _StreamingTaskHandler extends TaskHandler`  — Minimal task handler - just keeps the service running
  - onStart onRepeatEvent onDestroy onReceiveData onNotificationButtonPressed onNotificationPressed onNotificationDismissed

### streaming_foreground_service_stub.dart  (71 Z.)

- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.
  - initialize startService releaseKeepAliveLock updateNotification canStart isIgnoringBatteryOptimizations requestIgnoreBatteryOptimization isRunning hasKeepAliveLock startIfNeeded force

### streaming_manager.dart  (5 Z.)

- conditional export: 'streaming_manager_stub.dart' if (dart.library.io) 'streaming_manager_io.dart'

### streaming_manager_base.dart  (668 Z.)

- `abstract class StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats.
  - Function beforeCompletion completionNotification onAllStreamsCancelled stopBackgroundServiceIfIdle onAppBackgroundChanged contentForSnapshot isStreaming phaseOf startedAtOf cancelStream cancelAllStreams cleanupStream completeStream evictStaleCompletedStreams onAppLifecycleChanged getActiveStreamsInfo getBufferedContent getBufferedReasoning getStreamingMessageIndex getTps getLatestMeta getNativeToolCalls hasCompletedStream consumeCompletedStream setBackgroundMessages getBackgroundMessages hasBackgroundMessages isAppInBackground hasActiveStreams activeStreams
- `class ActiveStream`  — One tracked stream: its subscription, buffers and bookkeeping.
  - cancelIdleTimer cancelUiThrottle subscription messageIndex chatId chatTitle contentBuffer reasoningBuffer isActive tps latestMeta nativeToolCalls startedAt firstTokenAt firstEventAt phase completedAt idleTimer uiThrottleTimer uiUpdatePending backgroundMessages modelId provider

### streaming_manager_io.dart  (273 Z.)

- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats
  - Function beforeCompletion completionNotification onAllStreamsCancelled stopBackgroundServiceIfIdle contentForSnapshot `_updateNotificationThrottled` onAppBackgroundChanged `_shouldShowCompletionNotification`

### streaming_manager_stub.dart  (21 Z.)

- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats
  - getNativeToolCalls

### streaming_transcription_service.dart  (240 Z.)

- `class StreamingTranscriptionService`  — Manages a WebSocket connection for streaming audio chunks to the
  - sendAudioChunk finishAndTranscribe abort `_onMessage` `_onError` `_onDone` `_completeWithError` `_cleanup` `_wsUrl` sampleRate

### supabase_schema_errors.dart  (22 Z.)

- `bool isMissingPreferencesColumn(PostgrestException error)`  — True when [error] says the `preferences` JSONB column is not there.

### supabase_service.dart  (134 Z.)

- `class SupabaseService`
  - initialize refreshSession signOut client auth isInitialized initializedListenable

### system_tray_service.dart  (5 Z.)

- conditional export: 'system_tray_service_stub.dart' if (dart.library.io) 'system_tray_service_io.dart'

### system_tray_service_io.dart  (394 Z.)

- `class SystemTrayService with TrayListener, WindowListener`  — Desktop system tray integration for Linux, Windows, and macOS.
  - initialize `_scheduleRetry` `_setTrayIconWithFallback` `_resolveTrayIconCandidates` `_materializeBundledTrayIcon` `_syncWindowVisibility` `_installMenu` `_toggleWindowVisibility` showWindow hideWindow `_startNewChat` `_quitApplication` `_rollbackInitialization` onTrayIconMouseDown onTrayIconRightMouseDown onTrayMenuItemClick onWindowClose `_isDesktop` `_supportsTooltip` `_linuxTrayFallbackCandidates` instance resetQuitFlag

### system_tray_service_stub.dart  (16 Z.)

- `class SystemTrayService`
  - initialize showWindow hideWindow instance resetQuitFlag

### theme_settings_service.dart  (116 Z.)

- `class ThemeSettings`
  - copyWith toMap defaults fromMap userId themeMode accentColor iconColor backgroundColor
- `class ThemeSettingsService`
  - loadOrCreate save `_table`
- `class ThemeSettingsServiceException implements Exception`
  - message

### title_generation_service.dart  (860 Z.)

- `class TitleGenerationService`  — Service for automatically generating chat titles using AI.
  - `_settingsKey` `_systemPromptKey` `_syncCacheToCurrentUser` `_dropLegacyKeys` isEnabled setEnabled getSystemPrompt setSystemPrompt resetSystemPrompt `_isMissingTitleColumnsError` `_decryptRemotePrompt` `_resolveTitleProvider` hasCustomSystemPrompt generateTitle generateAndApplyTitle `_hasCustomName` `_stripWrappingMarkdown` `_normalizeGeneratedTitle` `_waitUntilChatAvailable` `_applyTitleWithRetry` debugStillOwns debugPrimeCachesForUser debugSyncCacheToUser settingsKeyForUser systemPromptKeyForUser debugDropLegacyKeys `_remoteSyncTtl` debugCustomSystemPrompt debugAutoGenerateTitlesEnabled defaultSystemPrompt forceRefresh legacySettingsKey legacySystemPromptKey

### token_activity_stats.dart  (285 Z.)

- `enum HeatmapMode`  — How the token-activity heatmap colours each day cell.
  - daily weekly cumulative
- `@immutable class DailyTokenPoint`  — One calendar day of token activity.
  - isActive day tokens requests operator
- `@immutable class TokenActivityStats`  — The result of aggregating a single [UsageLogsService] fetch for the
  - isEmpty totalActiveDays daily currentStreak longestStreak
- `class TokenActivityStatsService`  — Pure aggregation for the token-activity panel. Stateless: every method is
  - dateOnly addDays mondayOf computeCurrentStreak computeLongestStreak heatmapValues maxWeeks
- `class _DayAggregate`
  - tokens requests

### tool_call_handler.dart  (1999 Z.)

- const: `_readOnlyToolNames`
- `class ToolLoopSession`
  - latestUserMessage history accessToken enforcer toolCallingEnabled discoveryMode baseSystemPrompt discoveryContextKey modelId skipIdentity nativeToolCalling discoveredTools discoveredToolNames activeSkillNames toolCalls producedBlocks consecutiveSandboxInfraFailures emptyFinalRecoveryAttempts malformedToolProtocolRecoveryAttempts truncatedCompletionRecoveryAttempts deferredActionRecoveryAttempts nonFinalTurnRecoveryAttempts factCheckRecoveryAttempts factCheckCandidate factCheckCandidateReasoning
- `class ToolLoopStep`
  - message history systemPrompt
- `class RoundSegment`  — One segment in the model's interleaved output for a single round.
  - isText isToolCall text toolCall
- `class ToolLoopResult`
  - shouldContinue nextStep finalContent finalReasoning interimContent interimBeforeToolCalls toolCalls interleavedSegments producedBlocks
- `class ToolTurnSignals`  — Provider/tool-loop hints extracted from stream metadata.
  - fromMeta `_firstLowercasedString` `_readPath` indicatesToolUse indicatesFinalStop indicatesTruncated stopReason finishReason rawMeta
- `class ToolCallHandler`
  - buildInitialSystemPrompt nativeToolDefinitions `_buildSafetyLimitMessage` `_splitInterleavedSegments` `_countToolGroups` `_nativeCallsToParsed` `_appendRoundToHistory` `_updateDiscoveredTools` `_updateActiveSkills` `_applyPerModelPrompt` `_stripToolCallBlocks` `_extractPreToolText` `_extractRoundThinking` `_stripThinkingTags` trailingToolCallBlockStart `_trailingToolCallBlockStart` `_trailingToolCallBlockStartImpl` `_indexOfFirstToolCallBlock` `_hasInterimTextBeforeToolCalls` looksLikeDeferredActionWithoutToolCall `_looksLikeDeferredActionWithoutToolCall` `_lastSentence` `_isDeferredIntentSentence` `_cloneHistory` `_cloneToolCalls` `_restoreDiscoveryContext` `_storeDiscoveryContext` `_refreshDiscoveredToolDefinitions` `_pruneDiscoveryContextsIfNeeded` toolExecutor toolCallingEnabled nativeToolCalls activeSkillNames
- `class _DiscoveryContextState`  — Per-chat context that survives across user turns (in memory only — it does
  - lastUsedAt discoveredToolNames activeSkillNames

### tool_enforcer.dart  (420 Z.)

- `class ToolEnforcer`  — Client-side Tool Call Enforcer (inspired by Kimi K2's Enforcer).
  - setDeclaredTools resetIteration reset checkForHallucination enforce `_validateFindToolsArgs` buildResultMessage `_coerceMap` alwaysAllowedTools maxIterations discoveryMode discoveredToolNames
- `class HallucinationCheckResult`
  - cleanedContent warnings hadHallucination
- `class EnforcedToolCall`
  - callId name arguments warnings
- `class RejectedToolCall`
  - name arguments reason
- `class EnforcerResult`
  - hasValidCalls hasRejections validCalls rejectedCalls iterationLimitReached currentIteration
- `class ToolCallResult`
  - callId name result isError

### tool_executor.dart  (1551 Z.)

- const: `_excalidrawSchemaText` `_technicalDrawingSchemaText` `_typstSchemaText` `_mermaidSchemaText` `_svgSchemaText`
- `class ToolExecutionResult`
  - output isError producedBlocks
- `class ToolExecutor`  — Service to execute tools client-side.
  - `_serverHeaders` registerTool unregisterTool loadPreferences `_loadPreferencesInternal` `_deferredSupabaseSync` `_safeCurrentUserId` `_syncToolEnabledPreferencesFromSupabase` `_syncSingleToolEnabledToSupabase` `_syncAllToolEnabledToSupabase` isAlwaysOnTool setToolEnabled isToolEnabled getDefaultToolDescription getToolDescription hasCustomDescription setToolDescription resetToolDescription resetAllToolPreferences isToolAvailable isServiceConnected execute `_executeBuiltin` `_executeArtifactManager` `_executeArtifactSchema` `_executeSkill` `_executeUpdateProject` `_executeAskUser` `_executeRequestMcpServer` `_placesResult` looksLikeToolFailure `_coerceInt` serverHttpUrl tools allRegisteredTools allTools asserts currentChatId toolCategories sniff +1

### tool_image_result_service.dart  (446 Z.)

- `class ToolImageUpdateResult`
  - toolCalls imagePaths imageMetas imageCostEur imageGeneratedAt
- `class _ExtractionResult`
  - storagePath updatedPayload
- `class ToolImageResultService`
  - processToolCalls `_ensureStoragePath` `_uploadFromDataUri` `_isPrivateHost` `_uploadFromUrl` Function `_tryDecodeMap` `_decodeMap` `_extractLeadingJsonObject` `_nonEmptyString` `_coerceDouble` `_coerceDateTimeIso`

### tool_prompt_builder.dart  (1338 Z.)

- `class ToolPromptBuilder`  — Builds system prompts with tool calling protocol for LLM.
  - `_migratedToSkill` `_buildNativeToolGuidance` `_buildActiveSkillSection` `_buildIdentitySection` `_buildAlwaysAvailableSection` `_dedupeToolsByName` `_appendAlwaysOnVisualTags` `_appendWeatherProtocol` `_appendNewsProtocol` `_visualOutputProtocol` toolCallStart toolCallEnd discoveryMode isToolResult native allToolNames undiscoveredToolNames

### tool_registry.dart  (2032 Z.)

- const: `_serverBackedToolNames` toolCategoryMap discoveryCatalog builtinTools
- `bool _isMobileRuntime()`  — Whether the current platform is a mobile device (Android/iOS).
- `void registerBuiltinTools(ToolExecutor executor)`  — Register all built-in tools from [builtinTools] into a [ToolExecutor].

### tool_result_cache_registry.dart  (139 Z.)

- const: `_uuid` kCacheMissErrorCode
- `class _RegistryEntry`
  - id expiresAt
- `class ToolResultCacheRegistry`  — Process-wide registry mapping a previously-uploaded message string to the
  - shouldCache register refFor clear handleMiss `_purgeExpired` `_evictIfNeeded` `_refsPaused` length instance minContentLength now

### tour_key_registry.dart  (78 Z.)

- `class TourSlots`  — Known target slots used by the onboarding tour.
  - modelDropdown modelProviderPill menuButton settingsEntry chatInput settingsPricingTile settingsAiIdentityTile settingsModelSelectionTile kSettingsAssistantTile
- `class TourKeyRegistry`  — Singleton store of [GlobalKey]s by slot name. Always returns the SAME
  - keyFor contextFor isMounted isVisibleOnScreen clear instance

### tray_action_bus.dart  (21 Z.)

- `class TrayActionBus`  — Decouples the desktop system tray menu from the widget tree.
  - requestNewChat instance newChatRequested

### update_check_service.dart  (302 Z.)

- `class UpdateCheckService`  — Checks for app updates via the GitHub Releases API.
  - `_isNewerVersion` `_findDownloadUrl` `_getAssetPatterns` launchDownload dismiss `_isLinuxFull` updateAvailable force
- `class UpdateInfo`  — Information about an available update.
  - currentVersion latestVersion downloadUrl releasePageUrl

### usage_logs_service.dart  (452 Z.)

- `class UsageLogEntry`
  - textTokens cachedTokens isMediaRequest modelId providerSlug promptTokens completionTokens totalTokens totalCostUsd creditsDeductedEur createdAt cacheReadTokens cacheWriteTokens cacheReadCostUsd cacheWriteCostUsd promptCostUsd completionCostUsd
- `class UsageModelSummary`
  - modelId primaryProvider requestCount textTokens mediaRequestCount totalCostUsd totalCreditsEur totalPromptCostUsd totalCompletionCostUsd
- `class UsageOverview`
  - creditsUsedThisPeriod entries modelSummaries totalRequests totalPromptTokens totalCompletionTokens totalTextTokens totalMediaRequests totalCostUsd totalCreditsEur totalCacheReadTokens totalCacheWriteTokens totalCacheReadCostUsd totalCacheWriteCostUsd totalPromptCostUsd totalCompletionCostUsd totalCreditsAllocated creditsRemaining creditsLastRenewedPeriod
- `class UsageLogsService`
  - loadOverview `_loadUsageEntries` `_loadBillingSnapshot` `_buildModelSummaries`
- `class UsageLogsServiceException implements Exception`
  - message
- `class _UsageBillingSnapshot`
  - totalCreditsAllocated creditsRemaining creditsLastRenewedPeriod
- `class _MutableModelSummary`
  - primaryProvider modelId providerHits requestCount textTokens mediaRequestCount totalCostUsd totalCreditsEur totalPromptCostUsd totalCompletionCostUsd
- `int _parseInt(dynamic value)`
- `double _parseDouble(dynamic value)`
- `double? _parseNullableDouble(dynamic value)`
- `DateTime? _parseDateTime(dynamic value)`

### user_model_prefs_realtime_service.dart  (114 Z.)

- `class UserModelPrefsRealtimeService`
  - start stop `_handleProviderChange` `_handleSelectedModelChange` instance

### user_preferences_service.dart  (931 Z.)

- `class UserPreferencesService`
  - `_syncCacheToCurrentUser` saveSelectedModel refreshModelSelections loadSelectedModel forceLoadSelectedModel `_fetchModelFromNetwork` `_syncModelFromNetwork` clearSelectedModel saveSelectedProvider clearSelectedProvider loadSelectedProvider loadAllProviderPreferences invalidateProviderPreferencesCache invalidateSelectedModelCache `_systemPromptCacheKey` `_dropLegacySystemPromptCache` loadSystemPromptFast loadSystemPromptLocal `_loadSystemPromptLocalForUser` saveSystemPrompt loadSystemPrompt clearSystemPrompt debugStillOwns debugPrimeCachesForUser debugSyncCacheToUser systemPromptCacheKeyForUser debugLoadSystemPromptLocalForUser debugSystemPromptMemCache debugSelectedModelCache debugProviderPreferencesCache debugCacheOwnerUserId legacySystemPromptCacheKey

### user_status_service.dart  (177 Z.)

- `class UserStatusService`
  - refresh clear `_reset` `_fetch` `_readCache` `_writeCache` `_userId` status forceRefresh

### websocket_chat_service.dart  (285 Z.)

- `class WebSocketChatService`  — Service for handling streaming chat responses.
  - `_foldHistoryRefs` `_convertImagesToBase64` maxTokens

### websocket_connector.dart  (10 Z.)

- conditional export: 'websocket_connector_web.dart' if (dart.library.io) 'websocket_connector_io.dart'

### websocket_connector_io.dart  (53 Z.)

- const: `_sharedPinnedClient`
- `Future<WebSocketChannel> connectWebSocket(Uri url)`  — Create a [WebSocketChannel] with certificate pinning on native platforms.

### websocket_connector_web.dart  (15 Z.)

- `Future<WebSocketChannel> connectWebSocket(Uri url)`  — Create a [WebSocketChannel] on web.

### window_close_service.dart  (5 Z.)

- conditional export: 'window_close_service_stub.dart' if (dart.library.io) 'window_close_service_io.dart'

### window_close_service_io.dart  (40 Z.)

- `Future<void> initializeWindowCloseHandler()`
- `class _CloseListener extends WindowListener`
  - onWindowClose

### window_close_service_stub.dart  (5 Z.)

- `Future<void> initializeWindowCloseHandler()`

### workspace_file_upload.dart  (88 Z.)

- `class WorkspaceUploadOutcome`  — What came out of [pickAndUploadWorkspaceFile].
  - fileName error
- `Future<WorkspaceUploadOutcome> pickAndUploadWorkspaceFile({ required String workspaceId, required void Function(String f …)`  — Asks for a file and uploads it to [workspaceId].

### workspace_message_service.dart  (384 Z.)

- `class WorkspaceMessageService`  — Service for composing AI messages with workspace context
  - `_estimateContentLength` buildProjectSystemMessage `_buildChatSummary` `_formatDate` getProjectContextSummary hasContext estimateTotalFileTokens estimateProjectContextTokens getModelContextWindow contextUsageRatio fileContextRatio remainingFileTokenBudget maxTotalContentLength maxChatHistoryContentLength

### workspace_storage_service.dart  (1062 Z.)

- `class WorkspaceStorageService`  — Service for managing workspace workspaces, chat assignments, and file attachments
  - `_notifyChangesImmediate` loadFromCache `_saveToCache` loadProjects createProject updateProject deleteProject archiveProject getWorkspace getWorkspaceForChat linkChatToWorkspace addChatToProject removeChatFromProject getProjectChats uploadAvatar deleteFile decryptFile downloadFile updateFileContent updateFileMarkdown reset `_isLoading` projects activeProjects archivedProjects changes bucketName selectedWorkspaceId updateCache generateMarkdown

## lib/services/mcp

### mcp_availability.dart  (36 Z.)

- `List<McpCatalogueEntry> unconnectedCatalogueEntries()`  — Every catalogue server (our own first-party ones plus the offered
- `McpCatalogueEntry? catalogueEntryById(String id)`  — The catalogue entry with this [id], searching the first-party connectors

### mcp_catalogue.dart  (1001 Z.)

- const: kBundledMcpIcons kMcpCategories kMcpCatalogue
- `class McpCredentialField`  — One credential a server takes on its URL instead of through a browser
  - key label hint secret required
- `class McpCatalogueEntry`  — A connector as offered to the reader.
  - faviconFor faviconCandidates brandDomain legalUrl icon id name url category description iconUrl publisher websiteUrl termsUrl privacyUrl auth credentials
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
  - wwwAuthenticate
- `class McpException implements Exception`  — Any other failure: transport, HTTP status, or a JSON-RPC error.
  - message
- `class McpServerInfo`  — What a server says about itself in the initialize result.
  - displayName name title version iconUrl websiteUrl instructions
- `class McpTool`  — One tool a server offers.
  - toJson fromJson name description inputSchema
- `class McpCallResult`  — The outcome of a tools/call: the text the model gets, plus whether the
  - text isError
- `class McpClient`
  - initialize listTools callTool close `_headers` `_notify` `_request` `_readSseReply` `_firstIcon` sessionId endpoint accessToken timeout

### mcp_connection.dart  (109 Z.)

- `enum McpAuth`  — How a connection proves who it is.
  - oauth appSession apiKey
- `class McpConnection`
  - copyWith toJson fromJson toolNameFor icon id name url description iconUrl tools addedByHand auth

### mcp_icon_cache.dart  (120 Z.)

- `class McpIconCache`
  - load `_download` `_fileFor` `_openDirectory` clear httpClient

### mcp_oauth.dart  (506 Z.)

- `class McpAuthServer`  — What a server's authorization looks like once discovered.
  - issuer authorizationEndpoint tokenEndpoint registrationEndpoint scopesSupported
- `class McpClientCredentials`  — The client id (and secret, if the server insists on one) we registered.
  - toJson fromJson clientId clientSecret
- `class McpTokens`  — The tokens a server issued.
  - toJson fromJson fromTokenResponse isExpired accessToken refreshToken expiresAt scope
- `class McpAuthException implements Exception`
  - message
- `class McpAuthorizationRequest`  — One authorization attempt, kept together so the verifier, the state and
  - url state codeVerifier server credentials redirectUri resource scope
- `class McpOAuth`
  - canonicalResource resourceMetadataUrl challengeScopes resourceMetadataCandidates authServerMetadataCandidates discover register exchange refresh `_token` `_getJson` `_uriOrNull` `_randomString` clientName clientUri scopes

### mcp_redirect.dart  (13 Z.)

- conditional export: 'mcp_redirect_stub.dart' if (dart.library.io) 'mcp_redirect_io.dart'

### mcp_redirect_io.dart  (59 Z.)

- `class McpRedirectListener`  — A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
  - start `_listen` close `_page` redirectUri callback

### mcp_redirect_stub.dart  (22 Z.)

- `class McpRedirectListener`
  - start close redirectUri callback

### mcp_service.dart  (778 Z.)

- `enum McpConnectStatus`  — What a connect attempt ended in, for the UI to show.
  - connected cancelled failed
- `class McpConnectCanceler`  — A handle the screen keeps so it can stop a connect while the browser
  - cancel isCanceled whenCanceled
- `class _ConnectCanceled implements Exception`  — Thrown inside [McpService] when the reader cancels the sign-in. Private:
- `class McpConnectResult`
  - status message connection
- `class _McpSecrets`  — The secrets of one connection. Never written to shared preferences.
  - toJson fromJson withTokens authServer credentials tokens issuer authorizationEndpoint tokenEndpoint scope apiCredentials
- `class McpService`
  - load `_readConnectionsRaw` `_persist` `_readSecrets` `_writeSecrets` `_endpointWithCredentials` endpointWithCredentialsForTest `_authorize` `_launch` `_closeBrowser` disconnect `_forgetLocal` refreshTools connectionFor resolve call `_isAcceptableEndpoint` `_appSessionToken` `_clientFor` connectByUrl internalIsAcceptableUrl internalReadSecretsJson internalWriteSecretsJson internalUpsertConnection internalForgetLocal internalFetchTools connections launcher description

### mcp_sync_service.dart  (763 Z.)

- `@immutable class McpSyncBlob`  — One connection as it travels between devices: its metadata without the
  - fromConnection toJson fromJson accessToken expiresAt connection secrets
- `@visibleForTesting String? accessTokenOf(Map<String, dynamic>? secrets)`  — The access token buried in a `_McpSecrets.toJson` map, or null. Public only
- `@visibleForTesting DateTime? expiresAtOf(Map<String, dynamic>? secrets)`  — The access token's expiry from a `_McpSecrets.toJson` map, or null. Public
- `@immutable class McpSyncPlan`  — What one reconcile pass decided to do.
  - toAdd toUpdate toRemove nextKnownSyncedIds
- `McpSyncPlan reconcileMcpSync({ required Set<String> localIds, required Set<String> knownSyncedIds, required Set<String> …)`  — Decide the sync actions. Pure: no IO, no clock, no globals.
- `@visibleForTesting bool metadataDiffers(McpConnection a, McpConnection b)`  — True when two connections differ in any synced metadata field. Tools are
- `bool _remoteTokenIsNewer({ required String? remoteToken, required String? localToken, required DateTime? remoteExpiry, r …)`  — True when the remote token should replace the local one: it exists, it
- `class McpSyncService`  — The IO around [reconcileMcpSync]: push on change, delete on disconnect,
  - `_serviceName` resetForTests push delete markPendingDelete clearPendingDelete deleteIfStillPending Function `_repairAfterLateDelete` pullAndReconcile `_retryPendingDeletes` `_applyAdd` `_healEmptyTools` `_loadKnownSyncedIds` `_saveKnownSyncedIds` `_loadIdSet` `_saveIdSet` pendingDeleteKeyForTest

### mcp_tool_bridge.dart  (59 Z.)

- `void syncMcpTools(ToolExecutor executor)`  — Register the tools of every connected server, replacing whatever was
- `void watchMcpConnections(ToolExecutor executor)`  — Keep an executor in step with the connections for as long as it lives.
- `List<String> _tagsFor(String serverName, String id, String toolName)`  — What `find_tools` matches on: the server, and the words of the tool name.

## lib/services/skills

### skill_frontmatter_parser.dart  (241 Z.)

- const: `_kSpecFields` `_kNamePattern` `_kFrontmatterPattern`
- `class SkillParseException implements Exception`  — Thrown when a SKILL.md violates the spec.
  - message field
- `Skill parseSkillMarkdown( String source, { String? expectedName, SkillSource skillSource = SkillSource.builtin, })`  — Parses [source] (the full contents of a SKILL.md) into a [Skill].
- `Map<String, String> _parseMetadata(YamlMap parsed)`
- `List<String> _parseAllowedTools(YamlMap parsed)`
- `String _requireString(YamlMap parsed, String field)`
- `String? _optionalString(YamlMap parsed, String field)`

### skill_registry.dart  (115 Z.)

- `class SkillRegistry`
  - byName exists bySource setUserSkills `_invalidate` resetForTest all `_index` names builtinNames forceRefresh

### skills_catalog_service.dart  (418 Z.)

- `class CatalogSkill`  — One entry in the catalog manifest.
  - fromJson name description path hash license allowedTools resources enabled
- `class LocalSkillState`  — The local state the reconciler needs about one stored catalog skill.
  - isEdited id sourceHash baselineHash
- `class SkillUpdateSuggestion`  — An edited skill whose catalog version moved — the user is asked, never
  - id catalog
- `class ReconcilePlan`  — The outcome of a reconcile: what to add, silently update, and suggest.
  - isEmpty toAdd toUpdate suggestions skippedBuiltin toRemove
- `ReconcilePlan planCatalogReconcile({ required List<CatalogSkill> catalog, required Map<String, LocalSkillState> localByC …)`  — Pure reconciliation: decide what to do with each catalog entry given the
- `class SkillsCatalogService`
  - hashOf `_manifestUri` `_bodyUri` `_cacheFresh` `_readCachedManifest` `_parseManifest` `_fetchBody` `_applyCatalogSkill` acceptSuggestion resetForTest suggestions forceRefresh

### user_skills_service.dart  (397 Z.)

- `class UserSkillException implements Exception`  — Thrown for storage-level failures. Spec violations surface as
  - message
- `class UserSkillsService`
  - `_syncCacheToCurrentUser` `_nowIso` `_encodeEnvelope` `_decodeEnvelope` `_loadLocal` `_rowToSkill` `_refreshFromServer` `_decodeRows` save delete resetForTest kMaxUserSkills forceRefresh

## lib/theme

### theme_presets.dart  (365 Z.)

- const: kThemePresets
- `@immutable class ThemeVariant`  — One complete look: palette + contrast + font, for a single brightness.
  - accent iconFg bg contrast uiFont
- `@immutable class ThemePreset`  — A named pack with a light and a dark variant.
  - variantFor matches applyTo name light dark

## lib/tool_handlers

### artifact_tools.dart  (204 Z.)

- const: `_requestTimeout`
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
  - parseExpression parseTerm parsePower parseUnary parsePrimary parseNumber `_match` `_matchWord` `_evalFunction` input pos
- `String _formatNum(num value)`  — Format a number: strip trailing .0 for integers.
- `num _toNum(dynamic v)`  — Safely convert dynamic to num.

### chat_search_tools.dart  (807 Z.)

- const: `_defaultChatLimit` `_maxChatLimit` `_defaultMessageLimit` `_maxMessageLimit` `_snippetRadius` `_minLocalScanChats` `_maxLocalScanChats` `_localScanMultiplier` `_previewSnippetsTop` `_previewSnippetsRest` `_topCandidatesWithPreview` `_defaultRecentLimit` `_maxRecentLimit` `_recentSnippetChars` `_actionFindChats` `_actionSearchInChat` `_actionRecentMessages` `_validRoles`
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
  - title messages
- `class _ParsedPayload`
  - messages customName
- `class _SearchField`
  - label text
- `class _MessageMatchSummary`
  - matchCount snippets
- `class _ChatCandidate`
  - chatId title idMatch titleMatch matchCount previewSnippets messageCount updatedAt
- `class _MessageMatch`
  - index role snippet
- `class _RecentMessageEntry`
  - index role text

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

- const: `_networkTimeout` `_nominatimBaseUrl` `_osrmBaseUrl` `_defaultHeaders` kMaxPlacesOnMap
- `class PlacesToolResult`  — What a places lookup produces: the text the model reads, and the map
  - text mapTag places
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

### notes_tools.dart  (923 Z.)

- const: `_notesPrefsKey` `_memoryPrefsKey` `_soulPrefsKey` `_userInfoPrefsKey` `_identityEnabledKey` `_identitySoulColumn` `_identityUserColumn` `_identityMemoryColumn` `_identityEnabledColumn` `_legacyPreferencesColumn` `_selectedModelColumn` `_fallbackSelectedModelId` `_identitySyncCacheTtl` `_cachedIdentityRow` `_cachedIdentityUserId` `_cachedIdentityFetchedAt` `_identityRowInFlight`
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

- conditional export: 'platform_tools_stub.dart' if (dart.library.io) 'platform_tools_native.dart'

### platform_tools_native.dart  (766 Z.)

- const: `_bashSandbox` `_gitHubOAuth` `_slackOAuth` `_googleOAuth` `_deviceServices` `_approvalConfig` connectableServices
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

### sandbox_tools.dart  (575 Z.)

- const: `_stdStreamCap` `_textFileCap` `_textInlineByteLimit` `_maxTimeoutSeconds` kSandboxBackedToolNames kSandboxUnavailableThisTurnMessage `_extensionMimeMap`
- `String _capStream(String s)`
- `bool _looksLikeText(Uint8List bytes)`
- `({String dir, String name}) _splitPath(String path)`
- `bool _isUnderSandbox(String path)`
- `String _formatError(SandboxServiceException e)`
- `bool isSandboxBackedTool(String name)`  — True when [name] is a sandbox-backed tool (see [kSandboxBackedToolNames]).
- `bool isSandboxInfraError(String result)`  — True when a tool result string signals a sandbox INFRASTRUCTURE failure —
- `Future<String> executeCodeRun({ required String? accessToken, required String? chatId, required Map<String, dynamic> arg …)`
- `Future<String> executeSandboxListFiles({ required String? accessToken, required String? chatId, required Map<String, dyn …)`
- `Future<String> executeSandboxReadFile({ required String? accessToken, required String? chatId, required Map<String, dyna …)`
- `Future<String> executeSandboxWriteFile({ required String? accessToken, required String? chatId, required Map<String, dyn …)`
- `Future<String> executeSandboxReset({ required String? accessToken, required String? chatId, required Map<String, dynamic …)`
- `String _extOf(String filename)`
- `String _inferMimeFromFilename(String filename)`
- `String _lastSegment(String path)`
- `Future<ToolExecutionResult> executeSandboxSendFileToUser({ required String? accessToken, required String? chatId, requir …)`

### typst_tools.dart  (281 Z.)

- const: `_deliveryNote` `_orphanFillPctThreshold`
- `class TypstCompileResult`  — Result of a Typst compile: the rendered bytes plus optional layout
  - bytes layout
- `Future<TypstCompileResult> compileTypstToPdf({ required String serverHttpUrl, required String? accessToken, required Str …)`  — Compile Typst source via the backend. Returns the rendered bytes and
- `class _TypstCompileError implements Exception`
  - message
- `Future<String> executeTypstCompile({ required String? serverHttpUrl, required String? accessToken, required String? chat …)`  — Tool handler: validate the Typst source by compiling it, then create a
- `class TypstLayoutSnapshot`  — Snapshot of a compiled Typst PDF's layout (page count + last-page
  - pageCount lastPageFillPct
- `TypstLayoutSnapshot? _layoutFromHeaders(Map<String, String> headers)`  — Parses layout headers the server attaches to every PDF compile:
- `String _layoutGuidance(TypstLayoutSnapshot? layout)`  — Builds the layout suffix appended to the tool result string. Always
- `String _compileErrorGuidance(String compilerError)`  — Wraps a Typst compile error so the AI sees both the compiler output

### weather_tools.dart  (359 Z.)

- `Future<String> executeWeather({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required Map …)`  — Weather via server-side Brave Rich Callback proxy.
- `String _buildQuery({ required String location, double? latitude, double? longitude, required String action, int? days, i …)`
- `String _formatWeather({ required String locationLabel, required String action, required String vertical, required Map<St …)`
- `void _writeCurrent(StringBuffer buf, Map<String, dynamic> src)`
- `void _writeDay(StringBuffer buf, Map<String, dynamic> day)`
- `void _writeHour(StringBuffer buf, Map<String, dynamic> hour)`
- `Map<String, dynamic>? _pickMap(Map<String, dynamic> src, List<String> keys)`
- `List? _pickList(Map<String, dynamic> src, List<String> keys)`
- `String? _pickString(Map<String, dynamic> src, List<String> keys)`

### web_tools.dart  (715 Z.)

- const: `_defaultSearchCount` `_maxSearchCount` `_defaultAutoCrawlCount` `_maxAutoCrawlCount` `_defaultAutoCrawlMaxChars` `_maxAutoCrawlMaxChars` `_maxExcerptCharsPerPage`
- `Map<String, String> _buildJsonHeaders(Map<String, String> serverHeaders)`
- `int _coerceInt( dynamic value, { required int fallback, required int min, required int max, })`
- `bool _coerceBool(dynamic value, {required bool fallback})`
- `String _truncate(String input, int maxChars)`
- `class _CrawlContext`
  - url content truncated error
- `Future<_CrawlContext> _crawlForContext({ required String baseUrl, required Map<String, String> serverHeaders, required S …)`
- `Future<String> executeWebSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required M …)`  — Web search via server-side Brave Search proxy.
- `Future<String> executeImageSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required …)`  — Image search via server-side Brave Image Search proxy.
- `Future<String> executeNewsSearch({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required …)`  — News search via server-side Brave News Search proxy.
- `Future<String> executeWebCrawl({ required String? serverHttpUrl, required Map<String, String> serverHeaders, required Ma …)`  — Crawl a webpage via server-side crawler and return markdown content.

## lib/utils

### api_rate_limiter.dart  (248 Z.)

- `class RateLimitConfig`  — API rate limiting configuration for different endpoint types.
  - maxRequests timeWindow minRequestInterval chat fileConversion general
- `class RateLimitResult`  — Result of a rate limit check.
  - allowed errorMessage retryAfter requestsRemaining
- `class ApiRateLimiter`  — Manages API rate limiting with per-endpoint and per-user tracking.
  - checkRateLimit recordRequest getRequestsRemaining getTimeUntilReset clearUserHistory clearAllHistory `_formatDuration` logRateLimitStatus

### arch_helper.dart  (4 Z.)

- conditional export: 'arch_helper_stub.dart' if (dart.library.ffi) 'arch_helper_native.dart'

### arch_helper_native.dart  (43 Z.)

- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### arch_helper_stub.dart  (7 Z.)

- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### artifact_tag_parser.dart  (141 Z.)

- const: `_artifactBlockPattern` `_artifactStartPattern` `_attrPattern` `_leadingCodeFence` `_trailingCodeFence`
- `class ParsedArtifactTag`  — A single `<artifact>` tag parsed out of assistant text.
  - id type title content language matchStart matchEnd
- `List<ParsedArtifactTag> parseArtifactTags(String text)`  — Returns all complete `<artifact>` blocks found in [text]. Partial
- `String _stripWrappingFence(String content)`  — Strip a single surrounding "```lang\n … \n```" fence if present. Leaves
- `String stripArtifactTagsForDisplay( String content, { bool stripIncomplete = true, })`  — Strips complete `<artifact>...</artifact>` blocks from [content]. When

### build_info.dart  (44 Z.)

- `class BuildInfo`
  - formatted buildTimestamp buildTimestampRaw

### certificate_pinning.dart  (127 Z.)

- `class CertificatePin`  — Certificate pin configuration for a domain.
  - domain sha256Hashes includeSubdomains
- `class CertificatePinning`  — Manages SSL certificate pinning for secure API communications.
  - Function configureDio createSecureDio isEnabled configuredPins

### certificate_pinning_io.dart  (83 Z.)

- `void configureDioWithPinning(Dio dio, List<CertificatePin> pins)`  — Configure Dio with a [badCertificateCallback] that validates
- `void _installBadCertCallback(HttpClient client, List<CertificatePin> pins)`
- `List<int> _sha256Sync(List<int> data)`  — Synchronous SHA-256 hash.
- `HttpClient createPinnedHttpClient(List<CertificatePin> pins)`  — Create an [HttpClient] with certificate pinning configured.

### certificate_pinning_register.dart  (9 Z.)

- conditional export: 'certificate_pinning_register_stub.dart' if (dart.library.io) 'certificate_pinning_register_io.dart'

### certificate_pinning_register_io.dart  (80 Z.)

- const: `_trustedToolApiHosts`
- `class _WindowsCertOverrides extends HttpOverrides`  — [HttpOverrides] that accepts certificates for known trusted public API
  - createHttpClient
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
  - containsImageData sanitize sanitizeClipboardInPlace

### color_extensions.dart  (62 Z.)

- `extension ColorExtension on Color`  — Helper extension to subtly lighten or darken colors.
  - toHexString fromHexString amount

### debug_chat_formatter.dart  (260 Z.)

- `class DebugChatFormatter`  — Formats the full chat message list as a debug-friendly text string.
  - `_noop` `_countImages` `_truncateForExport` format

### desktop_drop_stub.dart  (36 Z.)

- `class DropTarget extends StatelessWidget`
  - child onDragDone onDragEntered onDragExited
- `class DropDoneDetails`
  - files
- `class DropEventDetails`
- `class XFile`
  - path

### exponential_backoff.dart  (205 Z.)

- `class BackoffConfig`  — Configuration for exponential backoff retry logic.
  - maxRetries initialDelay maxDelay multiplier jitter chat fileUpload critical
- `class BackoffResult<T>`  — Result of a backoff operation.
  - data success error attempts totalDuration
- `class ExponentialBackoff`  — Handles exponential backoff for failed API requests.
  - `_calculateDelay` shouldRetryError config

### file_upload_validator.dart  (461 Z.)

- `class FileValidationResult`  — File upload validation result.
  - isValid errorMessage fileSizeBytes mimeType
- `class FileUploadValidator`  — Utility for validating file uploads to prevent security issues.
  - validateFile `_detectMimeType` `_isLikelyTextFile` `_validateArchive` validateImageBytes `_detectImageMimeFromBytes` formatFileSize maxFileSizeBytes maxArchiveEntries maxArchiveUncompressedSize extensionToMimeTypes maxImageFileSizeBytes

### format_bytes.dart  (21 Z.)

- `String formatBytes(int bytes)`  — Formats a byte count for a reader: `842 B`, `1.5 KB`, `12 MB`.

### highlight_registry.dart  (98 Z.)

- const: allLanguages

### image_clipboard_service.dart  (37 Z.)

- `class ImageClipboardService`
  - copyImageBytes

### input_validator.dart  (374 Z.)

- `enum PasswordStrength`  — Password strength levels.
  - weak fair good strong
- `class PasswordValidationResult`  — Result of password validation with detailed feedback.
  - isValid strength errorMessage suggestions hasMinLength hasUppercase hasLowercase hasDigit hasSpecialChar
- `class InputValidator`  — Input validation and sanitization utilities for security.
  - validateEmail validateMessageLength sanitizeFileName escapeFileNameForDisplay validateAndSanitizeMessage `_getFileExtension` `_formatNumber` validatePasswordStrength validatePassword safeHttpUri safeTelUri safeGeoUri maxMessageLength maxEmailLength maxFileNameLength minPasswordLength

### io_helper.dart  (4 Z.)

- conditional export: 'io_helper_stub.dart' if (dart.library.io) 'io_helper_io.dart'

### io_helper_io.dart  (5 Z.)

- conditional export: 'dart:io' show File, Directory, Platform, Process, SocketException, HttpException

### io_helper_stub.dart  (79 Z.)

- `class File`  — Stub File class for web
  - exists existsSync length lengthSync readAsBytes readAsBytesSync readAsString readAsStringSync openRead path flush recursive
- `class Directory`  — Stub Directory class for web
  - exists existsSync path recursive
- `class Platform`  — Stub Platform class for web
  - operatingSystem isAndroid isIOS isMacOS isWindows isLinux pathSeparator environment
- `class ProcessResult`  — Stub ProcessResult for web
  - exitCode stdout stderr pid
- `class Process`  — Stub Process class for web
  - runSync
- `class SocketException implements Exception`  — Stub SocketException for web
  - message
- `class HttpException implements Exception`  — Stub HttpException for web
  - message

### json_helpers.dart  (72 Z.)

- `Map<String, dynamic>? tryDecodeJsonObject(String body)`  — Decodes [body] into a JSON object, or returns null when it is not one.
- `dynamic tryParseLenientJson(String raw)`  — Lenient JSON parse for model output, which makes two mistakes often
- `bool looksLikeEncryptedPayload(String raw)`  — True when [raw] is one of our AES-GCM envelopes rather than plaintext.

### lru_byte_cache.dart  (86 Z.)

- `class LruByteCache`  — LRU (Least Recently Used) cache with a maximum total byte size.
  - get containsKey put remove clear `_evictOldest` currentSizeBytes length maxSizeBytes

### map_geometry.dart  (30 Z.)

- `bool hasPointSpread(List<LatLng> points)`  — True when [points] cover more than one place on the map.
- `double _shortestLonDelta(double a, double b)`  — Degrees between two longitudes the short way round.

### path_provider_stub.dart  (8 Z.)

- `Future<Directory> getTemporaryDirectory()`
- `Future<Directory> getApplicationDocumentsDirectory()`
- `Future<Directory> getApplicationSupportDirectory()`

### permission_handler_stub.dart  (24 Z.)

- `class Permission`
  - request status microphone
- `enum PermissionStatus`
  - isGranted isPermanentlyDenied granted denied permanentlyDenied restricted limited provisional

### phone_linkify.dart  (95 Z.)

- const: `_scanPattern` `_minDigits` `_maxDigits`
- `String linkifyPhoneNumbers(String markdown)`  — Rewrites every bare phone number in [markdown] as `[display](tel:+…)`.
- `String? telUriForDisplay(String display)`  — Normalises a written number to a `tel:` URI, or returns `null` when the

### privacy_logger.dart  (73 Z.)

- `class PrivacyLogger`  — Privacy-aware logging utility.
  - call info success warning error custom
- `void pLog(String message)`  — Shorthand for PrivacyLogger.call()

### secure_token_handler.dart  (148 Z.)

- `class SecureTokenHandler`  — Utility for secure handling of authentication tokens.
  - maskToken isTokenValid maskAuthHeader createSafeErrorMessage logApiRequest context success

### service_error_handler.dart  (178 Z.)

- `class ServiceErrorHandler`  — Centralized error handling for service operations
  - handleDioException `_handleHttpStatusCode` handleGenericException Function isNetworkError isAuthError isRateLimitError isServerError getRetryDelay

### shift_key_tracker.dart  (6 Z.)

- conditional export: 'shift_key_tracker_native.dart' if (dart.library.js_interop) 'shift_key_tracker_web.dart'

### shift_key_tracker_native.dart  (10 Z.)

- `void initShiftKeyTracker()`

### shift_key_tracker_web.dart  (38 Z.)

- const: `_shiftDown` `_initialized`
- `void initShiftKeyTracker()`

### stream_error_sanitizer.dart  (38 Z.)

- `String sanitizeStreamError(Object error)`  — Turns a transport exception into something safe and readable to show.

### theme_extensions.dart  (271 Z.)

- const: `_kGlyphSaturationFloor`
- `extension ThemeDataIconColorX on ThemeData`
  - accentButtonForeground resolvedIconColor
- `double _saturationFloor(double base)`
- `Color? _shadeUntilReadable(Color from, Color on, {required bool up})`  — Walks [from]'s lightness towards white (or towards black) in HSL and
- `double _contrastRatio(Color a, Color b)`  — WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
- `@immutable class MaterialYouTokens extends ThemeExtension<MaterialYouTokens>`  — Material You extension tokens that aren't exposed on the default
  - copyWith lerp surfaceContainerLow surfaceContainer surfaceContainerHigh surfaceContainerHighest primaryContainer onPrimaryContainer secondaryContainer onSecondaryContainer tertiaryContainer onTertiaryContainer outline outlineVariant onSurfaceVariant success onSuccess successContainer onSuccessContainer warning warningContainer onWarningContainer
- `extension MaterialYouTokensX on ThemeData`
  - m3

### token_estimator.dart  (58 Z.)

- `class TokenEstimator`
  - estimateTokens estimatePromptTokens

### tool_detail_format.dart  (91 Z.)

- const: `_markdownMarkers`
- `enum ToolBodyKind`  — How a tool-detail body should be shown.
  - text json markdown
- `class ToolBody`  — A tool body together with how to show it.
  - kind text
- `ToolBody classifyToolBody(String raw)`  — Decide how [raw] should be shown, and hand back the text to show.
- `String? prettyJsonOrNull(String raw)`  — [raw] indented, or null when it is not a JSON object or array.

### tool_helpers.dart  (21 Z.)

- `double toDouble(dynamic v)`  — Safely parse a coordinate value that may be num or String.
- `String formatDuration(int ms)`  — Format milliseconds duration as mm:ss string.
- `String truncate(String text, int maxLength)`  — Truncate text with ellipsis if it exceeds maxLength.

### tool_history_formatter.dart  (100 Z.)

- const: `_maxResultChars` `_maxTotalChars`
- `String? formatAssistantContent( Map<String, String> message, { bool includeReasoning = false, bool includeToolResults = …)`  — Builds the assistant `content` string for one stored message, optionally
- `String _buildPreviousToolResultsBlock(String? toolCallsJson)`

### tool_parser.dart  (774 Z.)

- const: toolCallStart toolCallEnd `_xmlToolCallBlockPattern` `_xmlDirectToolTagBlockPattern` `_xmlToolCallStartPattern` `_kimiToolCallStartPattern` `_previousToolResultsBlockPattern` `_previousToolResultsStartPattern` `_foreignToolTagNames` `_foreignToolTagNamespace` `_notCanonicalToolCallTag` `_foreignToolProtocolBlockPattern` `_invokeToolCallPattern` `_invokeParameterPattern` `_foreignToolProtocolStartPattern` `_knownDirectXmlToolNames`
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
  - isUploadAllowed recordUpload getUploadsRemaining getTimeUntilReset clearUserHistory clearAllHistory maxUploadsPerWindow timeWindowMinutes

### url_launcher_helper.dart  (22 Z.)

- `Future<void> launchExternalUrl(String url)`  — Opens [url] in the system browser.

## lib/widgets

### accent_icon_button.dart  (70 Z.)

- `class AccentIconButton extends StatelessWidget`  — A round, accent-filled icon button — one shared widget so the "new chat"
  - icon onTap tooltip semanticsId accent diameter iconSize

### anchored_menu.dart  (361 Z.)

- const: `_kAnchorGap` `_kEdgeMargin` `_kMinRoomAbove` `_kMenuDuration`
- `Future<T?> showAnchoredMenu<T>( BuildContext anchorContext, { required List<Widget> items, required Color color, require …)`  — Show [items] as a dropdown anchored to the widget of [anchorContext].
- `class _AnchoredMenuRoute<T> extends PopupRoute<T>`
  - buildPage `_frame` buildTransitions transitionDuration barrierDismissible barrierColor barrierLabel anchor items color borderColor minWidth borderRadius preferAbove alignRight besideAnchor outlined usableTop usableBottom themes
- `class _AnchoredMenuLayout extends SingleChildLayoutDelegate`  — Puts the menu above the anchor when it does not fit below it. The child
  - getConstraintsForChild getPositionForChild shouldRelayout `_roomBelow` `_roomAbove` `_forceAbove` anchor usableTop usableBottom alignRight besideAnchor preferAbove
- `List<List<Widget>> _splitOnDividers(List<Widget> items)`  — Splits a flat item list into runs at every divider, so a divider becomes

### api_availability_polling.dart  (51 Z.)

- `mixin ApiAvailabilityPolling<T extends StatefulWidget> on State<T>`  — Retries a failed model fetch once the API answers again.
  - onApiReachable startApiAvailabilityPolling stopApiAvailabilityPolling apiPollBaseUrl

### app_notification.dart  (209 Z.)

- `enum AppNotificationKind`  — What kind of thing happened. Picks the glyph and the accent down the side.
  - info success error
- `class AppNotification extends StatelessWidget`  — The floating pill the app talks to the reader in.
  - `_glyphColor` `_glyph` message kind actionLabel onAction
- `SnackBar appNotificationSnackBar({ required String message, AppNotificationKind kind = AppNotificationKind.info, Duratio …)`  — The SnackBar an [AppNotification] travels in.
- `abstract final class AppNotifications`  — How a message reaches the screen.
  - kind duration

### artifact_panel.dart  (2165 Z.)

- `class ArtifactPanel extends StatefulWidget`
  - artifact onClose onOpenSourceChat showHeader
- `enum _ArtifactViewMode`
  - preview code
- `class _ArtifactPanelState extends State<ArtifactPanel>`
  - `_loadChatArtifacts` `_switchActiveArtifact` `_onPendingVersionChanged` `_loadVersions` `_applyPendingInitialVersion` `_copyContent` `_availableFormats` `_bytesForFormat` `_captureVisualAsPng` `_showDownloadMenu` `_downloadMenuPosition` `_downloadAs` `_fileExtensionForArtifact` `_selectVersion` `_isViewingHistory` `_hasDualView` `_codeLanguageHint` `_effectiveContent` `_effectiveType` `_effectiveAttachmentPath`
- `class ArtifactBottomSheet extends StatelessWidget`
  - onOpenSourceChat
- `class _TypeBadge extends StatelessWidget`
  - type
- `class _ArtifactRenderer extends StatelessWidget`
  - `_buildVisualView` `_buildCodeView` type content language attachmentPath artifactId title forceCodeView codeLanguageHint readOnly captureKey
- `class _ExcalidrawMarkdrawEditor extends StatefulWidget`  — Native cross-platform Excalidraw editor backed by the `markdraw`
  - jsonString artifactId title readOnly
- `class _ExcalidrawMarkdrawEditorState extends State<_ExcalidrawMarkdrawEditor>`
  - `_scheduleAutoCenter` `_loadIntoController` `_applyTitleToController` `_registerFlusher` `_onSceneChanged` `_safeSerialize` `_persistAsNewVersion` `_centerCanvas` `_buildStack`
- `class _TypstPdfRenderer extends StatefulWidget`  — Renders a Typst artifact's PDF. Prefers the persisted encrypted
  - source attachmentPath artifactId
- `class _TypstPdfRendererState extends State<_TypstPdfRenderer>`
  - `_onHardwareKey` `_zoomUp` `_zoomDown` `_zoomReset` `_load` `_compile` `_backfillAttachment`
- `class _ViewModeToggle extends StatelessWidget`  — Preview / Code toggle shown in the artifact header for types that support
  - mode onChanged compact
- `IconData _iconForType(ArtifactType type)`
- `class _ZoomableVisual extends StatefulWidget`  — Zoomable wrapper with +/- buttons for visual artifacts (SVG, drawings).
  - child
- `class _ZoomableVisualState extends State<_ZoomableVisual>`
  - `_zoom` `_resetZoom`
- `class _DownloadFormat`
  - label ext
- `class _HistoryReadOnlyBanner extends StatelessWidget`  — Thin banner shown above the renderer when the user has selected a
  - selectedVersion latestVersion onSwitchToLatest
- `class _ArtifactSwitcher extends StatelessWidget`  — Header title + switcher. When the current chat has more than one artifact,
  - current all onSelect fontSize
- `class _ZoomButton extends StatelessWidget`
  - icon onTap

### ask_user_card.dart  (101 Z.)

- `class AskUserCard extends StatelessWidget`  — Interactive option buttons shown below messages that used the ask_user tool.
  - options onSelect
- `class _OptionChip extends StatefulWidget`
  - index label accent onSurface onTap
- `class _OptionChipState extends State<_OptionChip>`

### attachment_preview_bar.dart  (1008 Z.)

- const: `_kMaxExtensionChars` `_kImageCardSize` `_kImageCardBorderWidth`
- `typedef AttachmentRemoveCallback = void Function(String fileId)`
- `typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file)`
- `typedef AttachmentContentChangedCallback = void Function(String fileId, String newContent)`
- `class AttachmentPreviewBar extends StatefulWidget`
  - files onRemove onCopy onContentChanged
- `class _AttachmentPreviewBarState extends State<AttachmentPreviewBar>`
  - `_onPointerSignal`
- `class _ImageAttachmentCard extends StatelessWidget`
  - `_buildThumbnail` `_openImageViewer` file onRemove
- `class _RemoveButton extends StatelessWidget`
  - onTap tooltip size
- `class _DocumentAttachmentTile extends StatelessWidget`
  - file onRemove onCopy onContentChanged textColor accentColor cardColor
- `void _showDocumentPreview( BuildContext context, AttachedFile file, Color textColor, { AttachmentContentChangedCallback? …)`
- `class _DocumentPreviewDialog extends StatefulWidget`
  - file onContentChanged
- `class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog>`
  - `_loadTextContent` `_loadPdfContent` `_startEditing` `_saveEdits` `_cancelEditing` `_buildContent` `_buildPdfViewer` `_buildTextViewer` `_buildEditor` `_buildEmptyState`
- `Future<String?> _loadPlainTextContent(AttachedFile file)`
- `bool _isImageFile(String fileName)`
- `bool _isPdfFile(String fileName)`
- `bool _isPlainTextFile(String fileName)`
- `String _extensionLabel(String fileName)`
- `String _extractExtension(String fileName)`

### auth_gate.dart  (92 Z.)

- `class AuthGate extends StatefulWidget`  — Switches between [signedInBuilder] and [signedOutBuilder] based on
  - signedInBuilder signedOutBuilder loadingBuilder
- `class _AuthGateState extends State<AuthGate>`
  - `_initializeAuthState`

### brand_wordmark.dart  (36 Z.)

- `class BrandWordmark extends StatelessWidget`  — Brand lockup rendered from the frozen brand SVG (assets/wordmark.svg,
  - color height

### chart_widget.dart  (720 Z.)

- const: `_defaultColors`
- `Color _parseColor(String hex)`  — Parse a hex color string like "#FF5722" or "FF5722" into a Color.
- `Color _colorAt(int index)`
- `class ChartRenderer extends StatelessWidget`  — Top-level widget: parses a JSON map and picks the right chart builder.
  - tryParse `_maxYFromDatasets` `_formatAxisValue` `_buildChart` `_buildBarChart` `_buildLineChart` `_buildPieChart` `_buildDatasetLegend` `_buildPieLegend` `_buildScatterChart` `_buildRadarChart` data targetTicks

### chat_mode_selector.dart  (573 Z.)

- `class ChatModeSelector extends StatelessWidget`
  - iconFor labelFor descriptionFor `_openModeMenu` `_openModelMenu` `_openReasoningMenu` `_headerRow` stripLabPrefix `_glyphSize` `_customPointLabel` `_hasDeeperMenu` mode onModeChanged onModelSelected onOpenModelScreen pickedModels selectedModelId modelLabel customModelLabel reasoningEffort reasoningLevels onReasoningEffortChanged showLabel height menuAbove kMaxModelsInMenu isSelected besideAnchor
- `String prettyModelId(String id)`  — A readable name for a model id the catalogue does not know, so the menu
- `class ChatModelChoice`  — A model the reader has picked, as shown in the second menu.
  - id name
- `class _MenuChoice`  — What a row in the first menu stands for: a mode, or the way one level
  - mode openModelMenu
- `class _DeeperChoice`  — What a row in the second menu stands for: a reasoning level, a model, or
  - modelId openScreen
- `class _SubmenuOpener<T> extends PopupMenuEntry<T>`  — A menu row that opens a cascading submenu on tap WITHOUT popping the menu
  - represents height rowHeight child onOpen
- `class _SubmenuOpenerState<T> extends State<_SubmenuOpener<T>>`

### chuk_table.dart  (490 Z.)

- const: `_delimiterCell`
- `class ParsedTable`  — One parsed markdown table plus the metadata needed to render it.
  - columnCount header rows alignments
- `List<String> _splitRow(String line)`  — Splits a single row of raw cell text on unescaped `|`, dropping the empty
- `List<String> splitTableRow(String line)`  — Public wrapper around row splitting, used by the markdown splitter to count
- `TextAlign _alignmentOf(String delimiter)`
- `bool isTableDelimiterRow(String line)`  — Returns true if [line] is a valid GFM delimiter row (`| --- | :-: |`).
- `ParsedTable? parseTable(List<String> lines)`  — Parses a block of lines (header, delimiter, body rows) into a [ParsedTable].
- `class ChukTable extends StatefulWidget`  — A rounded, scrollable, copyable rendering of a markdown table.
  - table textColor accentColor fontFamily fontSize
- `class _ChukTableState extends State<ChukTable>`
  - `_asMarkdown` `_copy` `_flexColumnWidths` `_visibleLen` `_estimatedNaturalWidth` `_cell` `_inlineSpans`
- `class _CopyButton extends StatelessWidget`
  - copied color accent onTap

### credit_display.dart  (871 Z.)

- const: `_supabase` `_kCachedCredits` `_kCachedHasSubscription` `_kCachedFreeMessagesRemaining` `_kCachedFreeMessagesTotal` `_kCachedTotalCreditsAllocated` `_kCachedRemainingCredits` `_kCachedBillingPeriodStart` `_kCachedBillingPeriodEnd`
- `class CreditBalances`
  - remainingRatio totalCredits usedCredits remainingCredits billingPeriodStart billingPeriodEnd
- `mixin _CreditListenerMixin<T extends StatefulWidget> on State<T>`
  - initCreditListener `_loadCreditsFromCacheThenRemote` `_loadCreditsFromCache` `_saveCreditsToCache` disposeCreditListener creditBalances creditLoading reloadSilently
- `class CreditDisplay extends StatefulWidget`
- `class _CreditDisplayState extends State<CreditDisplay> with _CreditListenerMixin<CreditDisplay>`
  - `_formatDate`
- `class CreditBadge extends StatefulWidget`
  - textStyle placeholderStyle padding
- `class _CreditBadgeState extends State<CreditBadge> with _CreditListenerMixin<CreditBadge>`
- `class BalanceBadge extends StatefulWidget`  — Smart badge that shows credits for subscribed users OR free messages for non-subscribed u…
  - textStyle placeholderStyle padding
- `class _BalanceBadgeState extends State<BalanceBadge>`
  - `_dropReadyListener` `_initListener` `_loadFromCacheThenRemote` `_loadFromCache` `_saveToCache` silent
- `class _MetaLine extends StatelessWidget`  — Two small captions on one line — the pattern used under both bars.
  - left right

### diff_widget.dart  (505 Z.)

- const: `_kContextLines`
- `enum _LineType`
  - added removed context
- `class _DiffLine`
  - type text counterpart oldNo newNo
- `class _Span`
  - text changed
- `class DiffWidget extends StatefulWidget`  — Renders a before/after comparison as a VS Code–style unified diff:
  - before after title type
- `class _DiffWidgetState extends State<DiffWidget>`
  - `_lcsOf` `_lineDiff` `_foldContext` `_tokenise` `_wordDiff` `_typeLabel` `_buildFold` `_buildLine`
- `class _Chip extends StatelessWidget`
  - label color

### document_viewer.dart  (119 Z.)

- `class DocumentViewer extends StatefulWidget`  — Document viewer for markdown-converted files
  - fileName markdownContent
- `class _DocumentViewerState extends State<DocumentViewer>`
  - `_copyToClipboard` `_buildMarkdownView` `_buildEditView`

### encrypted_image_widget.dart  (210 Z.)

- `class EncryptedImageWidget extends StatefulWidget`  — Widget that downloads, decrypts, and displays an encrypted image from storage
  - storagePath fit width height
- `class _EncryptedImageWidgetState extends State<EncryptedImageWidget>`
  - `_listenForDeletion` `_loadImage`

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
  - color width dash
- `_Stroke _resolveStroke(Map<String, dynamic> e)`
- `String? _resolveFill(Map<String, dynamic> e)`
- `String _svgFontFamily(dynamic raw)`
- `String _escapeXml(String s)`
- `String _escapeAttr(String s)`
- `String _fmt(num v)`
- `double _d(dynamic v)`

### expressive_settings.dart  (534 Z.)

- const: kExpressiveOuterRadius kExpressiveInnerRadius kExpressiveTileGap
- `class ExpressiveGroup extends StatelessWidget`  — A group of settings tiles. The first and last tile round outwards, the
  - children
- `class _ExpressiveTileShape extends InheritedWidget`  — Hands the radii of its place in the group down to the tile.
  - of updateShouldNotify top bottom
- `class ExpressiveRow extends StatefulWidget`  — One settings row: a tonal icon, a title, an optional line under it, and
  - title icon leading subtitle trailing onTap tone
- `class _ExpressiveRowState extends State<ExpressiveRow>`
- `class ExpressiveTile extends StatefulWidget`  — The filled tile every row in a group sits in. Anything can go inside —
  - child onTap padding
- `class _ExpressiveTileState extends State<ExpressiveTile>`
- `class ExpressiveSwitchRow extends StatelessWidget`  — A settings row that carries a switch. The whole tile is the target — the
  - title value onChanged icon subtitle tone
- `class ExpressiveCard extends StatelessWidget`  — A block that is not a row: a slider, a preview, an editor. It carries the
  - child padding
- `class ExpressiveInfoCard extends StatelessWidget`  — The quiet paragraph under a group: what the setting means, or why it is
  - text icon tone
- `class ExpressiveField extends StatelessWidget`  — A filled field that holds a dropdown, a text field or a picker, so that
  - child padding
- `class ExpressiveIconTile extends StatelessWidget`  — The rounded tile an icon sits in.
  - icon tone size
- `class ExpressiveSectionHeader extends StatelessWidget`  — The label above a group. Large and heavy, the way Expressive titles are
  - label trailing color
- `class ExpressiveBadge extends StatelessWidget`  — A trailing pill: a short state word on the right of a row.
  - label tone icon
- `class ExpressiveTitle extends StatelessWidget`  — The big page title Expressive puts above a settings list.
  - title subtitle

### floating_app_bar.dart  (172 Z.)

- const: kFloatingAppBarHeight kFloatingAppBarChip `_kTitleRadius`
- `class FloatingHeaderButton extends StatelessWidget`  — A round floating chip for the header — the back arrow, and whatever a
  - icon onPressed tooltip color
- `class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget`  — The header of a settings-style page: a floating back chip, a floating
  - preferredSize title actions leading automaticallyImplyLeading bottom

### floating_chrome_surface.dart  (68 Z.)

- `Color floatingChromeBase(BuildContext context)`  — One step off the page background — the colour a floating card takes so it
- `class FloatingChromeSurface extends StatelessWidget`  — The one surface every floating piece of chrome uses: the two bars of the
  - fillOf child radius padding shape baseColor

### html_artifact_view.dart  (8 Z.)

- conditional export: 'html_artifact_view_io.dart' if (dart.library.js_interop) 'html_artifact_view_web.dart'

### html_artifact_view_io.dart  (114 Z.)

- `bool shouldLoadInWebView(Uri? uri)`  — Returns true for schemes that are allowed to load inside the WebView
- `class HtmlArtifactView extends StatelessWidget`
  - html captureKey
- `class _HtmlWebView extends StatelessWidget`
  - html captureKey

### html_artifact_view_source_fallback.dart  (38 Z.)

- `class HtmlSourceFallback extends StatelessWidget`
  - html

### html_artifact_view_web.dart  (136 Z.)

- `bool shouldLoadInWebView(Uri? uri)`  — Matches the native predicate so the test surface is shared.
- `class HtmlArtifactView extends StatefulWidget`
  - html captureKey
- `class _HtmlArtifactViewState extends State<HtmlArtifactView>`
  - `_registerFactory` `_buildIframe`

### image_viewer.dart  (477 Z.)

- `class ImageViewer extends StatefulWidget`  — Full-screen image viewer with zoom and pan capabilities
  - imageDataUrl initialIndex allImages models
- `class _ImageViewerState extends State<ImageViewer>`
  - `_handleKeyEvent` `_futureFor` `_loadImageBytes` `_imageKeyForIndex` `_handleOutsideImageTap` `_buildImageView` `_downloadCurrentImage` `_copyCurrentImage` `_showSaveSnackBar` `_resetZoom` `_hasMultipleImages` `_currentModel`

### linux_webview.dart  (90 Z.)

- `class LinuxWebView extends StatelessWidget`
  - html `_openInBrowser` htmlContent captureKey

### map_block_renderer.dart  (993 Z.)

- const: mapBlockRegex `_kLightTilesUrl` `_kDarkTilesUrl` `_kTileSubdomains`
- `bool hasMapBlocks(String content)`  — Returns true if [content] contains at least one <map> block.
- `class MapContentSegment`  — A segment of message content — either plain text or a map block.
  - isMap content
- `class MapBlockWidget extends StatelessWidget`  — Renders a single <map> JSON block as a Flutter widget.
  - jsonString
- `String _tileUrlForBrightness(BuildContext context)`
- `double _toDouble(dynamic v)`
- `bool _isValidLatLon(dynamic latRaw, dynamic lonRaw)`
- `bool _isExplicitNumericZero(dynamic v)`
- `List<Map<String, dynamic>> _filterValidCoordItems( List<dynamic>? items, )`
- `List<Map<String, dynamic>> _dedupeCoordItems(List<Map<String, dynamic>> items)`  — Drops repeated places / markers from one block. A multi-pass answer often
- `@visibleForTesting List<Map<String, dynamic>> debugFilterAndDedupeCoordItems(List<dynamic>? items)`  — Test-only view of [`_filterValidCoordItems`] + [`_dedupeCoordItems`].
- `double _mapPreviewHeight(BuildContext context)`
- `double _calculateZoom(List<double> lats, List<double> lons)`
- `double _calculateRouteZoom( double fromLat, double fromLon, double toLat, double toLon, )`
- `MapOptions _buildMapOptions({ required LatLng center, required double zoom, List<LatLng>? fitPoints, })`
- `void _openFullscreenMap( BuildContext context, { required LatLng center, required double zoom, String? title, List<Map<S …)`
- `Widget _buildMapPreview( BuildContext context, { required LatLng center, required double zoom, required List<Widget> map …)`
- `class _MarkersMapBlock extends StatelessWidget`
  - data
- `class _PlacesMapBlock extends StatelessWidget`
  - `_buildLabeledPlaceMarkers` data
- `class _PlaceCard extends StatelessWidget`
  - `_buildInfoChip` place number onShowOnMap size
- `class _RouteMapBlock extends StatelessWidget`
  - data

### markdown_message.dart  (1762 Z.)

- const: `_latexTag`
- `class _MdSegment`  — One slice of a message: either plain markdown or a GFM table block.
  - text isTable table
- `List<_MdSegment> _splitMarkdownTables(String text)`  — Splits raw markdown into alternating plain-markdown and table segments so
- `class MarkdownMessage extends StatefulWidget`
  - text textColor backgroundColor wrapWithSelectionArea paragraphFontSize paragraphHeight fontFamily
- `class _MarkdownMessageState extends State<MarkdownMessage>`
  - `_onTapLink` `_rebuildCache` `_codeBackground` `_getSyntaxTheme`
- `class _AsyncCodeBlock extends StatefulWidget`  — Widget that handles async code highlighting to prevent UI jank
  - code language textStyle backgroundColor borderColor theme textColor
- `class _AsyncCodeBlockState extends State<_AsyncCodeBlock>`
  - `_prettifyIfJson` `_autoDetectJson` `_codeForDisplay` `_scheduleHighlight` `_highlightCode` `_isMostlyNonAscii`
- `List<hi.Node> _parseCode(Map<String, dynamic> args)`
- `bool _isMostlyNonAsciiCode(String text)`  — Top-level helper for checking if text is mostly non-ASCII (for isolate use)
- `List<TextSpan> _convertNodesSafely( List<hi.Node>? nodes, Map<String, TextStyle> theme, TextStyle baseStyle, )`
- `List<TextSpan> _collectSpans( hi.Node? node, Map<String, TextStyle> theme, TextStyle baseStyle, TextStyle? parentThemeSt …)`
- `class LatexSyntax extends m.InlineSyntax`  — LaTeX inline syntax parser - matches $$...$$ and \(...\) and \[...\].
  - onMatch
- `class LatexNode extends SpanNode`  — LaTeX node that renders math using flutter_math_fork
  - `_buildMathWidget` attributes textColor
- `class _CopyButton extends StatefulWidget`  — Copy button widget for code blocks
  - code textColor
- `class _CopyButtonState extends State<_CopyButton>`
  - `_copyToClipboard`
- `class _SafeCodeBlockNode extends ElementNode`  — Replacement for markdown_widget's CodeBlockNode that avoids noisy
  - `_extractLanguage` content style element preConfig visitor
- `class _MarkdownImage extends StatelessWidget`  — Polished markdown image: full-width on mobile bubbles (capped at 540px wide
  - `_errorTile` `_openFullscreen` url alt
- `class _NetworkImageViewer extends StatelessWidget`
  - url

### mcp_connect_card.dart  (199 Z.)

- `class McpConnectCard extends StatefulWidget`  — A single Connect button for one catalogue server, shown inline under an
  - entry onConnected
- `class _McpConnectCardState extends State<McpConnectCard>`
  - `_connect` `_isActivate` `_blockedOnWeb`

### measure_size.dart  (49 Z.)

- `typedef OnWidgetSizeChange = void Function(Size size)`  — Callback invoked whenever the measured child changes size.
- `class MeasureSize extends SingleChildRenderObjectWidget`  — Reports its child's laid-out size via [onChange] after every layout in which
  - createRenderObject updateRenderObject onChange
- `class _MeasureSizeRenderObject extends RenderProxyBox`
  - performLayout onChange

### menu_tile_group.dart  (87 Z.)

- const: kMenuOuterRadius kMenuInnerRadius kMenuTileGap kMenuGroupGap
- `class MenuTileGroup extends StatelessWidget`
  - groups color outerRadius

### message_bubble.dart  (375 Z.)

- part 'message_bubble/models.dart' · part 'message_bubble/layout.dart' · part 'message_bubble/chrome.dart' · part 'message_bubble/rich_blocks.dart' · part 'message_bubble/tools.dart' · part 'message_bubble/images.dart' · part 'message_bubble/cards.dart'
- const: `_kBlockGap` `_kArtifactGap` `_kCardStackGap` `_kInfoBarGap` `_kMobileBottomBarHeight` `_richBlockRegex` `_visualBlockStartRegex` `_diffBlockRegex` `_attachmentHeaderRe` `_kAiResponseFontFamilyDefault` `_cachedShowReasoningTokens` `_cachedShowModelInfo`
- `class MessageBubble extends StatefulWidget`
  - message isUser startsNewGroup endsGroup maxWidth actions reasoning isReasoningStreaming modelLabel modelProvider tps isEditing initialEditText onSubmitEdit onCancelEdit showReasoningTokens showModelInfo showTps toolCalls showToolCalls contentBlocks isStreamingMessage turnStartedAt workedFor images imageMetas attachments imageCostEur imageGeneratedAt onAskUserAnswer onConnectMcpServer userMessageActions useSharedSelectionArea status lastError onRetryPending onContinueGeneration variantIndex variantCount onPrevVariant +1
- `class _MessageBubbleState extends State<MessageBubble>`
  - `_loadPreferences`

### message_fly_in.dart  (73 Z.)

- `class MessageFlyIn extends StatefulWidget`  — A one-shot entrance for a just-sent message: the bubble starts a little
  - child rise duration
- `class _MessageFlyInState extends State<MessageFlyIn> with SingleTickerProviderStateMixin`

### model_selection_dropdown.dart  (1428 Z.)

- const: `_menuHorizontalPadding` `_menuTrailingAllowance` `_menuExtraAllowance` `_buttonHorizontalPadding` `_buttonTrailingAllowance` kAutoCheapestProviderSlug
- `class ModelProviderSummary`
  - slug name promptPrice completionPrice
- `class _WidthMetrics`
  - menuWidth buttonWidth
- `class ModelProviderLimits`
  - contextLength maxCompletionTokens
- `class _AuthRequiredException implements Exception`
- `class _FilteredModelResult`
  - models enabledProviders invalidModelIds providerLimits availableProviders
- `class ModelSelectionDropdown extends StatefulWidget`
  - `_registerState` `_unregisterState` `_initializeEventBus` `_disposeEventBus` refreshActiveDropdowns providerSlugForModel modelSupportsReasoning providerLimitsForModel availableProvidersForModel cheapestProviderForModel resolveProviderSlugForSend showModelSelectionSheet selectedModelListenable initialSelectedModelId onModelSelected textFieldFocusNode isCompactMode compactLabel transparentStyle mergedSegmentStyle selectedModelNotifier
- `class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> with ApiAvailabilityPolling<ModelSelectionDropd …)`
  - onApiReachable `_handleSelectedModelNotifierChange` `_initializeModelSelection` `_hydrateFromCache` `_filterModels` `_parseDouble` `_applyModels` providerSlugFor providerLimitsFor supportsReasoningFor refreshModels `_fetchModels` `_handleApiUnavailable` `_buildApiUnavailableMessage` `_updateSelectedModelNameSync` `_updateSelectedModelName` `_calculateWidthMetrics` `_measureTextWidth` `_menuWidthFromTextWidth` `_buttonWidthFromTextWidth` `_effectiveButtonWidth` `_buildDropdownButtonContent` `_parseNullableInt` apiPollBaseUrl `_apiBaseUrl`
- `String _stripLabPrefix(String name)`  — OpenRouter model names arrive as "Lab: Model Name" (e.g. "Qwen: Qwen3.5-9B").

### morph_spinner.dart  (106 Z.)

- `class MorphSpinner extends StatefulWidget`  — Material 3 Expressive "loading indicator" (the shape-morph spinner).
  - size color period
- `class _MorphSpinnerState extends State<MorphSpinner> with SingleTickerProviderStateMixin`
- `class _MorphBlobPainter extends CustomPainter`  — Paints a rounded n-lobe "blob" (cosine-lobe polar curve). [t] is the
  - paint shouldRepaint t color

### nice_snackbar.dart  (55 Z.)

- `class NiceSnackBar`  — The old name for [AppNotifications], kept so the call sites that already
  - duration

### password_strength_meter.dart  (145 Z.)

- `class PasswordStrengthMeter extends StatelessWidget`  — A widget that displays password strength with visual indicators.
  - `_buildStrengthBar` `_buildStrengthLabel` `_buildRequirementsList` `_buildRequirement` `_getStrengthVisuals` `_getStrengthLabel` password showRequirements

### per_model_system_prompt_sheet.dart  (288 Z.)

- `Future<bool?> showPerModelSystemPromptSheet({ required BuildContext context, required String modelId, required String mo …)`  — Bottom sheet for editing a per-model system prompt and merge mode.
- `class _PerModelSystemPromptEditor extends StatefulWidget`
  - modelId modelName initial
- `class _PerModelSystemPromptEditorState extends State<_PerModelSystemPromptEditor>`
  - `_save` `_delete` `_modeDescription`
- `class _ModeChips extends StatelessWidget`
  - mode onChanged

### route_map_widget.dart  (336 Z.)

- `class RouteMapWidget extends StatefulWidget`  — Displays a route map with OSRM polyline, start/end markers,
  - toLon zoom routeTitle steps mapHeight onTapFullscreen
- `class _RouteMapWidgetState extends State<RouteMapWidget>`
  - `_fetchRouteGeometry`

### sandbox_artifact_block.dart  (528 Z.)

- const: `_kInlineTextCharCap`
- `class SandboxArtifactBlock extends StatefulWidget`
  - payload
- `class _SandboxArtifactBlockState extends State<SandboxArtifactBlock>`
  - `_isTextLike` `_load` `_save` `_panelArtifactType` `_openInPanel` `_buildImage` `_buildPdf` `_buildTextPreview` `_buildFileChip` Function `_shouldEagerLoad` `_canOpenInPanel`
- `class _ArtifactCard extends StatelessWidget`
  - `_icon` payload onSave child onOpen
- `class _ArtifactErrorRow extends StatelessWidget`
  - message onSave

### selection_copy_area.dart  (243 Z.)

- `class SelectionCopyShortcut`  — Pure decision logic for the copy shortcut, kept out of the widget so it can
  - isCopyIntent
- `class SelectionCopyArea extends StatefulWidget`  — A [SelectionArea] whose Ctrl+C / Cmd+C does not depend on the focus tree.
  - child focusNode contextMenuBuilder onSelectionChanged
- `class SelectionCopyAreaState extends State<SelectionCopyArea>`
  - `_handleSelectionChanged` handleKeyEvent `_focusedEditableHasSelection` `_copy` `_fallbackContextMenuBuilder` selectedText

### settings_kit.dart  (271 Z.)

- `class SettingsSectionHeader extends StatelessWidget`  — Shared building blocks for the settings-style pages.
  - label padding
- `class SettingsGroupedCard extends StatelessWidget`  — Rounded surface that groups rows, with hairline dividers between them.
  - children dividers dividerIndent
- `class SettingsLeadingIcon extends StatelessWidget`  — Fixed-size leading slot so rows line up whatever their icon.
  - icon tint
- `class SettingsRow extends StatelessWidget`  — One tappable line inside a [SettingsGroupedCard].
  - icon iconColor leading title subtitle trailing onTap showChevron
- `enum SettingsInfoTone`  — Colour role of a [SettingsInfoCard].
  - neutral warn danger success
- `class SettingsInfoCard extends StatelessWidget`  — Short explanatory note under a settings group.
  - `_defaultIcon` text tone icon

### settings_list_view.dart  (95 Z.)

- `class SettingsListView extends StatefulWidget`  — Scroll container for settings-style pages with a bounded set of rows.
  - children padding controller physics scrollbarMargin crossAxisAlignment
- `class _SettingsListViewState extends State<SettingsListView>`
  - `_withHeaderInset` `_controller`

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
  - jsonString
- `class TechDrawData`
  - fromJson `_d` meta elements sheetW sheetH originX originY
- `class TechDrawPainter extends CustomPainter`
  - `_mm` `_pt` `_ptSheet` paint `_drawSheet` `_drawElements` `_elementPaint` `_fillPaint` `_thinPaint` `_parseColor` `_drawRect` `_drawCircle` `_drawLine` `_drawStyledLine` `_drawStyledCircle` `_drawDimension` `_drawDimLinearH` `_drawDimLinearV` `_drawDimDiameter` `_drawArrow` `_drawNote` `_drawTitleBlock` `_drawCellText` shouldRepaint `_d` data scale opaque
- `class _ErrorCard extends StatelessWidget`
  - message

### update_banner.dart  (97 Z.)

- `class UpdateBanner extends StatelessWidget`  — A compact banner shown in the sidebar when a new app version is available.
  - `_buildBanner`

### waveform.dart  (143 Z.)

- `class WaveformPainter extends CustomPainter`  — Paints [bars] (each 0..1) as rounded vertical bars, colouring everything
  - paint shouldRepaint bars progress playedColor restColor barWidth
- `class LiveWaveform extends StatelessWidget`  — The live level meter of an open microphone, in the waveform shape.
  - `_bars` levels color barCount height barWidth barSpacing

### weather_widget.dart  (530 Z.)

- `class WeatherBlockWidget extends StatelessWidget`  — Renders `<weather>` JSON blocks emitted by the AI as a polished weather card.
  - `_buildCurrent` `_stat` `_buildHourly` `_buildDaily` `_buildDailyRow` `_asMap` `_asList` `_asNum` `_asStr` `_asInt` `_fmtNum` `_normalizeTempUnit` `_shortTime` `_dayLabel` `_iconForCode` `_gradientForCode` data

### workspace_file_viewer.dart  (662 Z.)

- `class WorkspaceFileViewer extends StatefulWidget`  — Dialog to view and edit workspace files and their markdown summaries
  - show file workspaceId
- `class _WorkspaceFileViewerState extends State<WorkspaceFileViewer> with SingleTickerProviderStateMixin`
  - `_loadFileContent` `_saveContent` `_saveMarkdown` `_buildOriginalContent` `_buildMarkdownContent`

### workspace_panel.dart  (706 Z.)

- `class WorkspacePanel extends StatefulWidget`  — Right-side panel for workspace settings (Instructions + Files)
  - workspaceId onClose
- `class _WorkspacePanelState extends State<WorkspacePanel> with WorkspaceActionsMixin<WorkspacePanel>`
  - `_pickAvatarImage` `_loadProject` `_saveInstructions` `_buildSection` `_buildInstructionsContent` `_buildFilesContent` `_openFileViewer` `_buildFileItem` workspaceId

### workspace_selection_dropdown.dart  (283 Z.)

- `class WorkspaceSelectionDropdown extends StatefulWidget`
  - selectedWorkspaceId onWorkspaceSelected textFieldFocusNode
- `class _WorkspaceSelectionDropdownState extends State<WorkspaceSelectionDropdown>`
  - `_loadProjects` `_selectedProject` `_hasProject`

## lib/widgets/agent_activity

### agent_activity_model.dart  (454 Z.)

- const: `_subjectKeys` `_maxDetailChars` `_maxThinkingChars` maxSourcesPerStep
- `enum AgentActivityKind`  — What a timeline line represents. Drives the icon and the wording.
  - search page thinking other
- `class AgentActivitySource`  — A page a step pulled in, shown as a chip under that step.
  - url host title
- `class AgentActivityEntry`  — One line in the timeline.
  - isGroup hasBody kind label detail children hasError toolCall sources body
- `AgentActivityKind _kindOf(ToolCall call)`
- `String? _subjectOf(ToolCall call)`
- `String _clip(String value, int max)`
- `String _shortenUrl(String url)`  — Strip the scheme and any `www.` so a URL reads as a place, not a link.
- `String _humanizeToolName(String name)`  — Human wording for a tool name: `generate_image` → `generate image`.
- `String? runningActivityLabel(List<ToolCall> calls)`  — Present-tense name for what a running turn is doing RIGHT NOW, so the
- `String _runningVerbFor(String name)`  — Present-tense phrase for a non-search, non-page tool the turn is waiting on.
- `AgentActivityEntry _entryFor(ToolCall call)`
- `class AgentActivityStep`  — One thing that happened in a round, in the order it happened: either a
  - reasoning toolCall
- `List<AgentActivityEntry> buildAgentActivityEntriesFromSteps( List<AgentActivityStep> steps, )`  — Build the timeline lines for an ordered mix of reasoning and calls.
- `List<AgentActivityEntry> buildAgentActivityEntries( List<ToolCall> calls, { bool includeRoundThinking = true, })`  — Build the timeline lines for [calls].
- `List<AgentActivitySource> extractSourcesFor(ToolCall call)`  — The pages a call pulled in.
- `String _firstSentence(String text)`  — First sentence of [text], or the whole string when it has no break.
- `Duration? agentActivityDuration( List<ToolCall> calls, { required DateTime now, bool running = false, })`  — Total wall time of a round: first start to last completion.
- `String formatAgentDurationLive(Duration duration)`  — Compact duration wording: `4s`, `1m 3s`, `2h 5m`.
- `String formatAgentDuration(Duration duration)`

### agent_activity_timeline.dart  (514 Z.)

- `class AgentActivityTimeline extends StatefulWidget`
  - toolCalls steps isRunning clock initiallyExpanded onStepTap onSourceTap footer phase startedAt finalDuration
- `class _AgentActivityTimelineState extends State<AgentActivityTimeline>`
  - `_syncTicker` `_nonNegative` `_buildHeader` `_buildRail` `_buildEntryText` `_buildSourceChips` `_buildSourceChip` `_iconFor` `_isExpanded` `_now` soleStep

## lib/widgets/icons

### huge_icon.dart  (208 Z.)

- const: `_opticalInset`
- `@immutable class HugeIconData`  — One icon of the set. The name is the file stem, so `HugeIcons.message01`
  - asset name
- `abstract final class HugeIcons`
  - add01 aiBrain01 album01 album02 alertCircle alert01 alert02 arrowDown01 arrowLeft01 arrowLeft02 arrowRight01 arrowUpRight01 arrowUp01 attachment01 blockchain01 bookOpen01 bookmark01 braces bug01 calendar01 call02 cancel01 cancel02 chatting01 check checkmarkCircle01 checkmarkCircle02 circle clock01 comment01 computer copy01 database01 delete02 dollar01 download01 download04 edit02 fileCode fileEdit +72
- `class HugeIcon extends StatelessWidget`  — An icon of the set, drawn like a Material [Icon].
  - icon size color

### icon_map.dart  (262 Z.)

- const: `_map`
- `HugeIconData? hugeIconFor(IconData icon)`  — The app's icon for [icon], or null when the set has nothing for it.
- `class AppIcon extends StatelessWidget`  — An icon that prefers the app's set and falls back to Material.
  - icon size color semanticLabel

## lib/widgets/message_bubble

### cards.dart  (903 Z.)

- part of '../message_bubble.dart'
- `class _CachedImageThumbnail extends StatefulWidget`  — Cached image thumbnail that decodes once and caches the bytes
  - imageDataUrl width height borderRadius fit naturalAspect maxNaturalHeight onTap
- `class _CachedImageThumbnailState extends State<_CachedImageThumbnail> with AutomaticKeepAliveClientMixin`
  - `_loadImage` wantKeepAlive
- `class _ArtifactInlineCard extends StatefulWidget`  — Compact artifact card shown inline in chat after artifact_manager calls.
  - artifactId title type authoredVersion
- `class _ArtifactInlineCardState extends State<_ArtifactInlineCard>`
  - `_refresh` `_open` `_download` `_icon` `_typeLabel`
- `class _ArtifactErrorCard extends StatelessWidget`  — Visible error chip when an inline artifact tag (or artifact_manager tool
  - toolName message
- `class _NewsCard extends StatelessWidget`  — News article card: thumbnail (left, 96x96), title, publisher · age, summary,
  - `_openUrl` item colorScheme

### chrome.dart  (451 Z.)

- part of '../message_bubble.dart'
- `extension _MessageBubbleChrome on _MessageBubbleState`
  - `_buildBottomBar` `_buildVariantPager` `_collectAllToolCalls` `_allSources` `_buildSourcesBar` `_buildFavicon` `_showSourcesSheet` `_buildUserActionButtons` `_buildActionButtons` `_buildActionBar` `_buildStatusIndicator`

### images.dart  (644 Z.)

- part of '../message_bubble.dart'
- `extension _MessageBubbleImages on _MessageBubbleState`
  - `_modelFor` `_buildGeneratingImagesGrid` `_loaderTile` `_pendingImageSize` `_buildImagesGrid` `_showImageContextMenu` `_confirmDeleteImage` `_buildAttachmentsChips` fit resolveModels

### layout.dart  (785 Z.)

- part of '../message_bubble.dart'
- `extension _MessageBubbleLayout on _MessageBubbleState`
  - `_buildUserBubble` `_buildAiBubble` `_buildContinueButton` `_buildClassicLayout` `_buildFramedUserImageGrid` `_buildContentBlocksLayout` `_stripAttachmentHeaderForUser` `_buildMessageBody` `_chatFontFamily` `_hasReasoning` `_hasModelInfo` `_shouldShowTps` `_isQrImageMessage` `_strippedMessage`

### models.dart  (135 Z.)

- part of '../message_bubble.dart'
- `class ImageMeta`  — Per-image metadata describing how an image arrived in the chat and
  - decode isGenerated source caption model
- `class DocumentAttachment`  — Document attachment data
  - toJson fileName markdownContent
- `class MessageBubbleAction`
  - icon tooltip onPressed isEnabled label
- `class _RenderSegment`
  - reasoningTexts isText isSandboxArtifact hasContent text sandboxArtifact toolCalls timeline
- `class _ToolTimelineEntry`
  - isReasoning reasoning toolCall

### rich_blocks.dart  (544 Z.)

- part of '../message_bubble.dart'
- `extension _MessageBubbleRichBlocks on _MessageBubbleState`
  - `_hasVisualBlocks` `_buildVisualContent` `_buildDiffBlock` `_buildEmailBlock` `_emailField` `_openMailto` `_buildNewsBlock` `_buildImageBlock` `_buildBlockText` `_buildTextParagraphs`

### tools.dart  (779 Z.)

- part of '../message_bubble.dart'
- `extension _MessageBubbleTools on _MessageBubbleState`
  - `_buildBlockReasoning` `_buildInfoStatusBar` `_currentPhase` `_buildMetaFooter` `_buildArtifactCards` `_stackArtifactCards` `_openSourceUrl` `_showToolCallDetails` `_buildToolCallExpandedWidget` `_buildToolSectionFrame` `_buildToolResultSections` `_findAskUserToolCall` `_buildAskUserOptions` `_findRequestMcpToolCall` `_buildMcpConnectOptions` live mono

### web_search_sources.dart  (292 Z.)

- `class WebSearchSource`  — One parsed hit from a web_search result.
  - title url host snippet age
- `String _clean(String s)`  — Strip HTML tags + the handful of entities the search backend emits, and
- `String _hostOf(String url)`
- `List<WebSearchSource> parseWebSearchSources(String result)`  — Parse a `web_search` result into ordered source hits. Returns an empty
- `class WebSearchSourcesCard extends StatelessWidget`  — Renders parsed [WebSearchSource]s as tappable source cards.
  - `_open` sources textColor accentColor
- `class _SourceCard extends StatelessWidget`
  - source textColor accentColor onTap
- `class _Favicon extends StatelessWidget`  — Favicon for [host] via Google's public favicon service, with a globe
  - host accent muted

## lib/widgets/sidebar

### hover_marquee_text.dart  (218 Z.)

- `class HoverMarqueeText extends StatefulWidget`  — A single-line title that shows an ellipsis at rest and, when the pointer
  - text style velocity textAlign
- `class _HoverMarqueeTextState extends State<HoverMarqueeText> with SingleTickerProviderStateMixin`
  - `_start` `_stillRunning` `_stop`

### sidebar_chrome.dart  (1247 Z.)

- const: kSbCardGap kSbBlockInset kSbCardRadius kSbCardJointRadius kSbNavCardHeight
- `Color sbPanelBackground(BuildContext context)`  — The colour the sidebar panel is painted in — the same step off the page
- `class SidebarTokens`
  - iconFg accent bg surface surfaceHigh hairline muted isDark
- `class SbCard extends StatefulWidget`  — The filled, rounded card every sidebar row sits in.
  - child onTap onLongPress onLongPressAt onSecondaryTap selected outlined padding minHeight radius
- `class _SbCardState extends State<SbCard>`
- `class SbCardHoverScope extends InheritedWidget`  — Publishes the hover state of the enclosing [SbCard] to its content.
  - of updateShouldNotify hovered
- `class SbBlock extends StatelessWidget`  — A stack of cards that belong together — the navigation block, or the chats
  - children inset
- `BorderRadius sbBlockRadiusFor({required int index, required int length})`  — The corners of the card at [index] in a block of [length] cards: outward
- `class SbCardShape extends InheritedWidget`  — Carries the shape a card should take from its block down to the card.
  - of updateShouldNotify radius
- `class SbIconTile extends StatelessWidget`  — The rounded square an icon sits in, matching `ExpressiveIconTile` but
  - icon tone size
- `class SbNavCard extends StatelessWidget`  — One navigation entry: a full-width card with a tonal icon and a bold label.
  - icon label onTap tone trailing
- `class SbProfileCard extends StatelessWidget`  — The account card at the top: avatar, name, and the balance under it, with
  - name subtitle onTap onCollapse collapseTooltip
- `class SbAvatar extends StatelessWidget`  — Round avatar carrying the first letter of the display name.
  - name diameter
- `class SbRoundAction extends StatelessWidget`  — A round icon button on the card fill — the shape the bottom bar and the
  - icon onTap tooltip diameter iconSize fill
- `class SbGroupHeader extends StatelessWidget`  — The header above a block: a quiet label, the number of items in the group,
  - label collapsed count onToggle
- `class SbSearchField extends StatefulWidget`  — The pill-shaped search field of the bottom bar.
  - controller focusNode onClear hintText transparent
- `class _SbSearchFieldState extends State<SbSearchField>`
  - `_onControllerChanged`
- `class SbBottomBar extends StatelessWidget`  — The bar at the foot of the sidebar: the search pill, then the two round
  - leading onSettings onNewChat settingsTooltip newChatTooltip padding
- `class SbAccountLine extends StatelessWidget`  — The bottom bar of the phone sidebar: who is signed in, what is left on the
  - name balance onTap onSettings settingsTooltip
- `class SbChatTile extends StatelessWidget`  — One chat in a group block: the title, the date under it, and the actions
  - title dateLine selected locked streaming onTap onLongPress onLongPressAt onSecondaryTap trailing hoverTrailing
- `class _SbChatTileBody extends StatelessWidget`  — Split out so it can read the card's hover state, which the card publishes
  - title dateLine selected locked streaming trailing hoverTrailing
- `class SbChatGroup<T>`  — A time group: the header label and the chats that fall into it.
  - label items
- `List<SbChatGroup<T>> sbGroupByTime<T>( List<T> items, DateTime Function(T item) dateOf, { required String Function(DateT …)`  — Buckets chats into Today / This week / This month / one group per older
- `String sbChatDateLine(BuildContext context, DateTime? date)`  — The muted line under a chat title: the time for anything from today, the
- `class SbOfflineNotice extends StatelessWidget`  — The strip that says the list is stale because the device is offline, with
  - label onRetry retryTooltip
- `class SbFloatingBar extends StatelessWidget`  — A card that floats over the scrolling list — the app name at the top of
  - child

### sidebar_common.dart  (501 Z.)

- const: kSidebarPageSize
- `String normalizeSidebarTitle(String title)`  — Strips generated Markdown decoration from a chat title before display.
- `String deriveSidebarChatTitle(StoredChat chat)`
- `String sidebarDisplayName(ProfileRecord? profile)`
- `List<Widget> buildSidebarNavigationCards({ required BuildContext context, required bool showWorkspaces, required VoidCal …)`  — The destinations shared by both sidebars, with a platform-owned search
- `mixin SidebarStateCommon<T extends StatefulWidget> on State<T>`  — Common state, mutations, and grouped-list construction for both sidebars.
  - applyChatFilter initSidebarCommon disposeSidebarCommon handleSidebarWidgetUpdate onScrollForAutoLoad toggleSidebarGroup onSidebarNetworkStatusChanged loadSidebarProfile toggleSidebarChatStarred renameSidebarChat confirmAndDeleteSidebarChat `_refreshSidebarAfterMutation` `_showDebouncedDeleteNotification` showLockedSidebarChatDialog Function searchController scrollController searchFocus collapsedGroups searchQuery filteredRecentChats displayLimit profile isOfflineMode onChatDeletedCallback kind

## lib/widgets/workspace

### workspace_actions_mixin.dart  (274 Z.)

- `mixin WorkspaceActionsMixin<T extends StatefulWidget> on State<T>`  — Shared workspace actions for a [State] that manages a single workspace.
  - listenToWorkspaceChanges cancelWorkspaceChangesSubscription Function viewWorkspaceFile saveWorkspaceInstructions removeChatFromWorkspace workspaceId isUploadingFile uploadFileName uploadStatus uploadProgress

### workspace_common_widgets.dart  (348 Z.)

- `class WorkspaceCountBadge extends StatelessWidget`  — Small pill with a count, used in the workspace tab bars.
  - count color
- `class WorkspaceEmptyState extends StatelessWidget`  — Centered "nothing here yet" placeholder used by the files and chats tabs.
  - icon title subtitle
- `class WorkspaceUploadProgressCard extends StatelessWidget`  — Card that shows the running file upload (progress bar + status text).
  - fileName status progress displayColor
- `class WorkspaceFileTile extends StatelessWidget`  — One row in a workspace file list: icon, name, caller-supplied subtitle and
  - file workspaceId displayColor isDark subtitle onView onDelete
- `class WorkspaceChatsTab extends StatelessWidget`  — The "Chats" tab shared by the workspace detail and management pages.
  - chats displayColor onAddChat onRemoveChat showChatDate removeIconSize

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

## tool

### gen_skills.dart  (191 Z.)

- const: kSkillsDir kOutputPath
- `void main(List<String> args)`
- `List<Skill> loadSkillsFromDisk(Directory skillsDir)`  — Parses every `<dir>/<name>/SKILL.md`, validating each against the spec plus
- `void _validateBudgets(Skill skill, String path)`  — Budgets that are stricter than the spec, because built-in skills are
- `String renderBuiltinSkillsFile(List<Skill> skills)`  — Renders the generated Dart source for [skills].
- `String _dartString(String value)`  — Escapes [value] into a single-quoted Dart string literal.

### generate_hugeicons.py  (118 Z.)

- const: WANTED CAMEL
- `def parse(source: str) -> list`  — Read the module's array. Keys are bare identifiers, values are already
- `def attribute_name(key: str) -> str`  — `strokeLinecap` -> `stroke-linecap`.
- `def to_svg(nodes: list) -> str`
- `def file_stem(icon: str) -> str`  — `ArrowLeft02Icon` -> `arrow-left02`.
- `def main() -> int`

## Befunde

**Waisen (3)** — von keiner Datei importiert. Nicht wiederbeleben, ohne vorher zu prüfen, ob sie noch gebraucht werden.
- `lib/pages/fullscreen_text_editor_page.dart` — 217 Zeilen, von keiner Datei benutzt
- `lib/platform_specific/chat/widgets/desktop_chat_widgets.dart` — 64 Zeilen, von keiner Datei benutzt
- `lib/widgets/morph_spinner.dart` — 106 Zeilen, von keiner Datei benutzt

**Importzyklen (8)**
- 2 Dateien: lib/constants.dart → lib/utils/chat_font_resolver.dart
- 2 Dateien: lib/services/mcp/mcp_catalogue.dart → lib/services/mcp/mcp_connection.dart
- 2 Dateien: lib/services/mcp/mcp_service.dart → lib/services/mcp/mcp_sync_service.dart
- 7 Dateien: lib/services/chat_preload_service.dart → lib/services/chat_storage_crud.dart → lib/services/chat_storage_mutations.dart → lib/services/chat_storage_service.dart → lib/services/chat_storage_sidebar.dart → lib/services/chat_storage_sync.dart → lib/services/chat_sync_service.dart
- 2 Dateien: lib/services/skills/skill_registry.dart → lib/services/skills/user_skills_service.dart
- 3 Dateien: lib/services/tool_executor.dart → lib/services/tool_registry.dart → lib/tool_handlers/sandbox_tools.dart
- 8 Dateien: lib/widgets/message_bubble.dart → lib/widgets/message_bubble/cards.dart → lib/widgets/message_bubble/chrome.dart → lib/widgets/message_bubble/images.dart → lib/widgets/message_bubble/layout.dart → lib/widgets/message_bubble/models.dart → lib/widgets/message_bubble/rich_blocks.dart → lib/widgets/message_bubble/tools.dart
- 2 Dateien: lib/platform_specific/chat/chat_ui_desktop.dart → lib/platform_specific/chat/desktop_send_logic.dart

**Größte Dateien (48 über der Schwelle)**
- `lib/platform_specific/chat/chat_ui_mobile.dart` — 4013 Zeilen, 149 Symbole
- `lib/platform_specific/chat/chat_ui_desktop.dart` — 2824 Zeilen, 138 Symbole
- `lib/platform_specific/chat/desktop_send_logic.dart` — 2394 Zeilen, 24 Symbole
- `lib/widgets/artifact_panel.dart` — 2165 Zeilen, 159 Symbole
- `lib/model_selector_page.dart` — 2074 Zeilen, 172 Symbole

## Mehrfach vergebene Namen

144 Namen existieren in mehr als einer Datei. Meist kopierter Code. Bevor du so etwas neu schreibst, eine der Stellen wiederverwenden. Volle Liste: `pseudomap dupes`.

- `Function` — lib/pages/mcp_connectors_page.dart:867 · lib/platform_specific/chat/handlers/scanned_pdf_pages.dart:20 · lib/services/workspace_file_upload.dart:36 · lib/tool_handlers/find_tools_handler.dart:21 +2
- `_formatDate` — lib/pages/media_manager_page.dart:478 · lib/pages/usage_details_page.dart:917 · lib/pages/workspace_mobile_detail_page.dart:524 · lib/services/workspace_message_service.dart:256 +1
- `_load` — lib/pages/diagnostics_settings_page.dart:39 · lib/pages/workspace_files_page.dart:70 · lib/pages/workspace_mobile_detail_page.dart:68 · lib/widgets/artifact_panel.dart:1598 +1
- `_open` — lib/pages/assistant_settings_page.dart:152 · lib/pages/mcp_connectors_page.dart:288 · lib/services/offline_queue_service_native.dart:37 · lib/widgets/message_bubble/cards.dart:447 +1
- `_apiBaseUrl` — lib/platform_specific/chat/chat_api_service.dart:19 · lib/services/file_conversion_service.dart:22 · lib/services/streaming_chat_service.dart:12 · lib/widgets/model_selection_dropdown.dart:381
- `_coerceInt` — lib/services/tool_executor.dart:1367 · lib/tool_handlers/chat_search_tools.dart:720 · lib/tool_handlers/map_tools.dart:632 · lib/tool_handlers/web_tools.dart:24
- `_save` — lib/pages/skills_settings_page.dart:284 · lib/pages/workspace_instructions_page.dart:57 · lib/widgets/per_model_system_prompt_sheet.dart:77 · lib/widgets/sandbox_artifact_block.dart:122
- `_syncCacheToCurrentUser` — lib/services/per_model_system_prompt_service.dart:156 · lib/services/skills/user_skills_service.dart:63 · lib/services/title_generation_service.dart:101 · lib/services/user_preferences_service.dart:41
- `_accessToken` — lib/assistant/assistant_session.dart:383 · lib/pages/github_connection_page.dart:54 · lib/pages/sandbox_management_page.dart:43
- `_emit` — lib/services/offline_queue_service_native.dart:223 · lib/services/offline_queue_service_web.dart:151 · lib/services/offline_retry_manager.dart:194
- `_formatDuration` — lib/assistant/assistant_tools.dart:809 · lib/services/device_services.dart:518 · lib/utils/api_rate_limiter.dart:207
- `_isLinuxDesktop` — lib/main.dart:179 · lib/platform_specific/chat/chat_ui_desktop.dart:297 · lib/services/app_initialization_service.dart:32
- `_loadProject` — lib/pages/workspace_detail_page.dart:118 · lib/pages/workspace_management_page.dart:67 · lib/widgets/workspace_panel.dart:80
- `_refresh` — lib/pages/assistant_settings_page.dart:123 · lib/pages/sandbox_management_page.dart:68 · lib/widgets/message_bubble/cards.dart:382
- `_table` — lib/services/customization_preferences_service.dart:214 · lib/services/profile_service.dart:44 · lib/services/theme_settings_service.dart:83
- `_toDouble` — lib/assistant/assistant_tools.dart:109 · lib/pages/fullscreen_map_page.dart:1113 · lib/widgets/map_block_renderer.dart:102
- `ApiConfigService` — lib/services/api_config_service_io.dart:8 · lib/services/api_config_service_stub.dart:7
- `DiagnosticsLogService` — lib/services/diagnostics_log_service_io.dart:15 · lib/services/diagnostics_log_service_stub.dart:4
- `HtmlArtifactView` — lib/widgets/html_artifact_view_io.dart:37 · lib/widgets/html_artifact_view_web.dart:29
- `LocalChatCacheService` — lib/services/local_chat_cache_native.dart:18 · lib/services/local_chat_cache_web.dart:11
- `McpRedirectListener` — lib/services/mcp/mcp_redirect_io.dart:9 · lib/services/mcp/mcp_redirect_stub.dart:7
- `NotificationService` — lib/services/notification_service_io.dart:12 · lib/services/notification_service_stub.dart:7
- `OfflineQueueService` — lib/services/offline_queue_service_native.dart:17 · lib/services/offline_queue_service_web.dart:15
- `RootWrapper` — lib/platform_specific/root_wrapper_io.dart:30 · lib/platform_specific/root_wrapper_stub.dart:8
- `StreamingForegroundService` — lib/services/streaming_foreground_service_io.dart:9 · lib/services/streaming_foreground_service_stub.dart:6
- … +119 weitere
