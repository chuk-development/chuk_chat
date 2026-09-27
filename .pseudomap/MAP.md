# pseudomap · chuk_chat

573 Dateien · 2609 Typen/Funktionen · 14082 Member · 1158/1599 öffentliche Symbole mit Zweckzeile · Stand 2026-09-27

Diese Datei ist `.pseudomap/MAP.md` — Stufe 1: was es gibt und wo es liegt.

Vor dem Schreiben neuer Funktionen hier nachsehen, ob die Sache schon existiert. Tut sie es, wird sie wiederverwendet statt neu geschrieben.

- Lange Parameterlisten sind hier gekürzt (`…)`). Volle Signaturen mit Zeilennummern stehen in `.pseudomap/detail/<ordner>.md`, Pfad mit `__` statt `/` — `lib/services` liegt in `.pseudomap/detail/lib__services.md`.
- Suche über alles: `pseudomap find <begriff>`.
- Neu bauen: `pseudomap build` (läuft nach jedem Edit automatisch).

## lib
### constants.dart  (621 Z.)
- const: kDefaultBgColor kDefaultAccentColor kDefaultIconFgColor kDefaultThemeMode kDefaultDynamicColorEnabled kDefaultShowReasoningTokens kDefaultShowModelInfo kDefaultShowTps kDefaultUiLocale kDefaultToolCallingEnabled kDefaultToolDiscoveryMode kDefaultShowToolCalls kDefaultIncludeToolResultsInHistory kDefaultChatFontSize kMinChatFontSize kMaxChatFontSize kDefaultUiScale kMinUiScale kMaxUiScale kChatFontFamilySystem kChatFontFamilyArimo kChatFontFamilyMerriweather kChatFontFamilyJetBrainsMono kDefaultChatFontFamily kSupportedChatFontFamilies +16
- `double contrastFactor(double contrast)`  — Maps the [kMinContrast]..[kMaxContrast] slider value to the multiplier
- `ThemeData buildAppTheme({ required Color accent, required Color iconFg, required Color bg, required Brightness brightnes …)`
- `TextTheme _emphasizedTextTheme(TextTheme t)`  — Material 3 Expressive emphasis: the display and headline sizes carry real
- `Color _shiftHue(Color c, double degrees)`

### env_loader.dart  (158 Z.)
- `class EnvLoader`  — Loads environment variables from .env file at runtime.
  - load loadSync _parseEnvFile get has _isDesktop

### main.dart  (773 Z.)
- `void _installLogDeduper()`  — Collapse consecutive identical debug log lines into a single line with a
- `Future<void> main()`
- `class AgentsApp extends StatefulWidget`
- `class _AgentsAppState extends State<AgentsApp>`
  - _initializeDesktopTrayInBackground _onThemeChanged _pushServiceIntoController _onThemeControllerChanged _migrateLegacyThemeMode _onPasswordMismatch _syncSettingsInBackground _scheduleStartupSettingsSync _initializeNotificationsInBackground _initializeApp _buildHome _toFlutterScheme _buildShellConfig _isLinuxDesktop _isAssistantLaunch navigatorKey
- `class _OnboardingFirstLaunchGate extends StatefulWidget`  — Starts the interactive onboarding tour if the signed-in user has never
  - child shellConfig
- `class _OnboardingFirstLaunchGateState extends State<_OnboardingFirstLaunchGate>`
  - _maybeStart

### model_selector_page.dart  (1988 Z.)
- `class PricingDetails`
  - formatTokenPrice formatRequestPrice prompt completion request image webSearch internalReasoning
- `class ModelProviderInfo`
  - slug name pricing contextLength maxCompletionTokens isModerated iconUrl
- `class CustomModelInfo`
  - id name description providers iconUrl
- `enum _ModelListFilter`  — Which slice of the catalogue the model list shows.
  - all active inactive
- `class ModelSelectorPage extends StatefulWidget`
  - chatId
- `class _ModelSelectorPageState extends State<ModelSelectorPage> with ApiAvailabilityPolling<ModelSelectorPage>`
  - onApiReachable _loadModeConfigs _isFlashModelId _healFastToFlash _modelNameFor _pickModelForMode _modelById _setProviderForMode _reasoningLevelsForMode _setReasoningForMode _initializeModelSelections _fetchModels _handleApiUnavailable _buildApiUnavailableMessage _showSnackBar _onEditModelPrompt _onProviderSelect _onAutoSelect _cheapestProvider _formatContextLength _chatScoped apiPollBaseUrl _enabledModels _filteredModels _displayModels size
- `class ModelSelectionRow extends StatefulWidget`
  - model selectedProvider promptConfig isAutoSelected isFirstRow onProviderChanged onAutoSelected onEditPrompt formatContextLength buildIconWidget
- `class _ModelSelectionRowState extends State<ModelSelectionRow>`
  - _buildDescriptionBlock _buildStatsBlock
- `class _NameRow extends StatelessWidget`
  - model buildIconWidget trailing
- `class _ProviderPill extends StatelessWidget`
  - _openPicker _buildCollapsedFace _cheapestProvider _formatInOutPrice model selectedProvider isAutoSelected onProviderChanged onAutoSelected buildIconWidget maxWidth
- `class _AuthRequiredException implements Exception`
- `class _ModeRowData`  — One mode's data for the picker panel.
  - icon title modelId modelName reasoningEffort reasoningLevels providerSlug providers onPickModel onPickReasoning onPickProvider
- `class _ModePickerPanel extends StatelessWidget`  — The panel at the top of the model screen that assigns a model, a provider
  - _modeCard _labelledRow _staticValue _providerMenu _modelMenu _reasoningMenu models fast thinking buildIconWidget subtle
- `class _ListFilterBar extends StatelessWidget`  — A three-way pill toggle above the model list: All / Active / Inactive.
  - _labelFor _segment value onChanged
- `class _StatChip extends StatelessWidget`
  - label value

### platform_config.dart  (172 Z.)
- const: kPlatformMobile kPlatformDesktop kAutoDetectPlatform kFeatureVoiceMode kFeatureWorkspaces kFeatureArtifacts kFeatureImageGen kFeatureMediaManager kFeatureServerTools kFeatureMcp kFeatureArtifactHosting kFeatureSystemTray kFeatureLinuxKeyring kFeaturePaymentsDirect kFeatureAgents kFeatureAgentsDemo kFeatureSkills kFeatureSpotify kFeatureWhoop

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
  - _navigate place
- `class _RatingChip extends StatelessWidget`
  - rating reviewCount
- `class _LinksCardView extends StatelessWidget`
  - _host card
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
  - hasPermission start pause resume debugFeed _onChunk _finishUtterance _resetUtterance _pushPreRoll _trackNoiseFloor _setLevel _durationOf _bytesOf _rms isRunning isPaused level _activeRecorder onUtterance onLevel sampleRate channels
- `Uint8List pcmToWav( Uint8List pcm, { required int sampleRate, required int channels, })`  — Wraps raw 16-bit little-endian PCM in a 44-byte RIFF header.
- `void _writeAscii(ByteData buffer, int offset, String value)`

### assistant_overlay.dart  (674 Z.)
- const: assistantOverlayRouteName
- `Route<void> buildAssistantOverlayRoute()`  — Transparent, instant route for the assistant surface.
- `class AssistantOverlayPage extends StatefulWidget`
- `class _AssistantOverlayPageState extends State<AssistantOverlayPage>`
  - _startSession _close
- `@immutable class AssistantToolBadge`  — One tool call, as the surface shows it.
  - label done failed
- `class AssistantOverlayView extends StatelessWidget`  — Presentation separated from transport so the layout can be checked offline.
  - _hasError _showPanel onScreen errorText contextOpen level tools card
- `class AssistantToolRow extends StatelessWidget`  — One line per tool call, so the user sees what the assistant really does.
  - tool
- `class AssistantSurface extends StatelessWidget`  — One floating, blurred panel. The surface colour is the user's, only the
  - child padding
- `class AssistantAction extends StatelessWidget`  — Label and icon as one centred group with a 48 dp minimum target.
  - label icon onPressed iconOnly
- `class AssistantWaveform extends StatefulWidget`  — Microphone level as a symmetric bar field.
  - level busy
- `class _AssistantWaveformState extends State<AssistantWaveform> with SingleTickerProviderStateMixin`
  - _sync
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
  - start toggleMute attachScreenContext _onUtterance _runTurn _chatPass _describeScreenshot _trimHistory _accessToken _awaitAccessToken _systemPrompt _decodeArguments _humanError _set _fail _notify phase settings userText answer error level muted listening tools card busy statusLabel
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
  - _cb _toast _sidebar _toolbar _tabChip _segmented _stage _desktopFrame _mobileFrame _windowChrome _dot _mockChatArea _msgUser _msgAssistant _composer _description _chats

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
### app_localizations.dart  (809 Z.)
- `class AppLocalizations`  — Holds all translated UI strings for the current locale.
  - of _getDe _getEs _getFr _getPt _get skillsNoMatches skillDeleteBody savedToPath exportFailed uiScalePercentage editedAt disconnectCategory lockedChatsCount maintenanceCount emailUpdated failedToLoadProfile failedToSaveProfile failedToChangePassword verificationFailed failedToDeleteAccount versionText builtOn updateAvailable copyrightYear devOptionsTaps unexpectedError verifySignupBody verifyRecoveryBody resendCodeIn encryptedWithVersion lockedChatCount deleteLockedChatsBody confirmDeleteChats recoveredChats deletedChats failedFocusedDebug failedToShareLog failedToClearLog autoCheapestCurrently +562
- `class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations>`
  - isSupported load shouldReload

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
  - working waiting scheduled
- `@immutable class AgentsThreadInfo`  — One conversation with one agent. An agent can have many (§4).
  - copyWith key title lastActivity
- `@immutable class AgentsAgent`  — One coworker.
  - copyWith activity id name role brief schedule attachmentNames onHost running lastActivity threads

### agents_room.dart  (157 Z.)
- `@immutable class AgentsRoomMember`  — One coworker in a room: the agent id the app tracks and the handle it is
  - agentId handle operator
- `@immutable class AgentsRoom`  — A group room the app knows about: an id, a name, and its members in order.
  - copyWith handles id name members agentToAgent
- `@immutable class AgentsRoomDraft`  — What the create-room form produces: a name and the chosen members. It is not
  - name members agentToAgent
- `@immutable class AgentsRoomTurn`  — One agent turn in a room exchange, as the app shows it. Mirrors the manager's
  - round agentId handle text
- `enum AgentsRoomStop`  — Why a room exchange ended, as the host reported it. The strings match the
  - fromWire label noMoreMentions roundsExhausted messagesExhausted stopped turnFailed noSuchRoom agentToAgentOff

### app_shell_config.dart  (147 Z.)
- `class AppShellConfig`  — Bundles all theme, display, image-generation, and AI-context settings
  - currentThemeMode currentAccentColor currentIconFgColor currentBgColor setThemeMode setAccentColor setIconFgColor setBgColor dynamicColorEnabled setDynamicColorEnabled contrast setContrast uiFontFamily setUiFontFamily showReasoningTokens setShowReasoningTokens showModelInfo setShowModelInfo showTps setShowTps autoSendVoiceTranscription setAutoSendVoiceTranscription imageGenEnabled setImageGenEnabled imageGenDefaultSize setImageGenDefaultSize imageGenCustomWidth setImageGenCustomWidth imageGenCustomHeight setImageGenCustomHeight imageGenUseCustomSize setImageGenUseCustomSize includeRecentImagesInHistory setIncludeRecentImagesInHistory includeAllImagesInHistory setIncludeAllImagesInHistory includeReasoningInHistory setIncludeReasoningInHistory includeToolResultsInHistory setIncludeToolResultsInHistory +14

### artifact.dart  (219 Z.)
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

### chat_message.dart  (277 Z.)
- `enum ChatMessageStatus`  — Delivery status of a chat message in the local queue/UI.
  - sent pending failed interrupted
- `ChatMessageStatus? _statusFromString(String? raw)`
- `int? parseFlexibleInt(dynamic value)`  — Parse an int that may arrive as an int, a num, or a String — the UI map
- `String? _statusToString(ChatMessageStatus? status)`
- `class ChatMessage`  — Represents a single message in a chat.
  - copyWith toJson workedFor sender effectiveStatus statusString role text reasoning replyContext images imageMetas imageCostEur imageGeneratedAt attachments attachedFilesJson toolCalls contentBlocks modelId provider status queueId messageId sentAt startedAt generationMs variants activeVariant

### chat_model.dart  (122 Z.)
- `class ModelItem`
  - name value isToggle badge iconUrl supportsReasoning supportsReasoningEffort operator
- `class AttachedFile`
  - copyWith toJson id fileName markdownContent isUploading localPath fileSizeBytes encryptedImagePath isImage

### chat_reply.dart  (36 Z.)
- `class ChatReply`  — Reply context travels as ordinary quoted user text, so host history, offline
  - compose parse author text

### chat_stream_event.dart  (194 Z.)
- `sealed class ChatStreamEvent`  — Events that can be received from chat streaming services.
  - content finalContent reasoning usage meta tps toolCalls error heartbeat done
- `class NativeToolCall`  — A native OpenAI-format tool call assembled from the provider stream.
  - id name arguments
- `class ToolCallsEvent extends ChatStreamEvent`  — Event carrying one or more native tool calls the model requested this turn.
  - calls
- `class ContentEvent extends ChatStreamEvent`  — Event containing message content text.
  - text
- `class FinalContentEvent extends ChatStreamEvent`  — Authoritative completed answer. Replaces streamed provisional content;
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
- `class HeartbeatEvent extends ChatStreamEvent`  — Proof of life: the host says the run behind this stream is still running.
  - seq elapsedSeconds
- `class DoneEvent extends ChatStreamEvent`  — Event indicating the stream has completed.
- `typedef StreamErrorCallback = void Function(String error, {String? code})`  — Signature for stream error callbacks.
- `abstract final class StreamErrorCodes`  — Failure classes carried on [ErrorEvent.code].
  - upstreamNetwork upstreamStatus upstreamNoStream upstreamFirstByteTimeout connectionLost idleTimeout streamFailure retryable

### client_tool.dart  (70 Z.)
- `class ClientTool`  — Represents a tool that can be executed client-side.
  - toJson toOpenAiFunction id name description parameters type config tags
- `enum ToolType`  — Type of tool.
  - builtin mcp
- `enum ToolCategory`  — Tool categories for grouping and enabling/disabling.
  - basic search map device bash github slack google mcp

### content_block.dart  (173 Z.)
- `enum ContentBlockType`  — The type of a content block within an AI response.
  - text toolCalls reasoning sandboxArtifact
- `class SandboxArtifactPayload`  — Payload for a [ContentBlockType.sandboxArtifact] block.
  - toJson storagePath filename mime sizeBytes document
- `class ContentBlock`  — An ordered block of content within an AI response.
  - toJson legacySandboxArtifactNote decodesFileBlocks type text toolCalls sandboxArtifact

### queued_message.dart  (103 Z.)
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

### tool_call.dart  (94 Z.)
- `class ToolCall`  — Represents a single tool call made by the AI during a conversation.
  - toJson elapsed id name arguments result status roundThinking startedAt completedAt
- `enum ToolCallStatus`  — Status of a tool call in its lifecycle.
  - pending running completed error
- `bool finalizeStaleToolCalls(List<ToolCall> toolCalls)`  — Utility to finalize any stale (running/pending) tool calls.

### workspace_model.dart  (464 Z.)
- `class Workspace`  — Represents a workspace that combines AI persona, system prompts, files,
  - toJson copyWith _formatFileSize chatCount fileCount hasCustomPrompt totalFileSize totalFileSizeFormatted displayColor displayIcon hasCustomImage updatedAgo initials id name description customSystemPrompt createdAt updatedAt isArchived memoryEnabled modelId avatarColor avatarIcon avatarImagePath isPublic userId ownerDisplayName chatIds files kWorkspaceColors kWorkspaceIcons
- `class WorkspaceFile`  — Represents a file attached to a workspace
  - toJson copyWith hasMarkdownSummary fileSizeFormatted fileIcon isPreviewable isTextFile extension isImage isPdf estimatedTokens estimatedTokensFormatted id workspaceId fileName storagePath fileType fileSize uploadedAt markdownSummary

## lib/pages
### about_page.dart  (597 Z.)
- `class AboutPage extends StatefulWidget`
  - _openLicenses _formattedVersion
- `class _AboutPageState extends State<AboutPage>`
  - _handleVersionTap
- `class _ThemedLicensePage extends StatefulWidget`
  - applicationName applicationVersion applicationLegalese
- `class _ThemedLicensePageState extends State<_ThemedLicensePage>`
  - _loadLicenses
- `class _LicenseTile extends StatelessWidget`
  - package
- `class _LicenseHeader extends StatelessWidget`
  - applicationName applicationVersion applicationLegalese
- `class _LicensePackage`
  - name license
- `class _LicenseDetailPage extends StatelessWidget`
  - package
- `String? _inferLicenseName(String text)`

### account_settings_page.dart  (765 Z.)
- `class AccountSettingsPage extends StatefulWidget`
- `class _AccountSettingsPageState extends State<AccountSettingsPage>`
  - _loadProfile _saveAccountSettings _buildRecoverChatsSection _changePassword _deleteAccount
- `class _FieldLabel extends StatelessWidget`
  - label helper

### agent_profile_edit_page.dart  (604 Z.)
- `class AgentProfileEditPage extends StatefulWidget`
  - Function agent source onRename profiles imagePicker
- `class _AgentProfileEditPageState extends State<AgentProfileEditPage>`
  - _initialRole _initialBrief _pickPhoto _removePhoto _save _store
- `class _FacePreview extends StatelessWidget`  — The face as it will look, with the colour the user is trying out.
  - agent store overrideColor shape
- `class _SectionLabel extends StatelessWidget`
  - label
- `class _ColorRow extends StatelessWidget`  — The colour palette, plus a "back to the derived colour" target.
  - selected onPick onReset
- `class _ShapeRow extends StatelessWidget`  — The silhouettes a coworker can be given, drawn as themselves.
  - agentId colour selected onPick

### agent_profile_page.dart  (625 Z.)
- `class AgentProfilePage extends StatelessWidget`
  - Function _build _confirmDelete _roleOf _briefOf _store agentId source onRename onDelete onOpenControls onOpenBrowser onMessage profiles
- `class _StatePill extends StatelessWidget`  — The live-state pill under the name: what the coworker is doing right now.
  - agent accent
- `class _ActionRow extends StatelessWidget`  — The row of round targets under the header.
  - onMessage onOpenControls onOpenBrowser
- `class _Action extends StatelessWidget`
  - icon label onTap color onColor parked
- `class _InfoCard extends StatelessWidget`  — One labelled card in the profile body.
  - icon label value note

### agents_desktop_layout.dart  (634 Z.)
- part of 'messenger_shell.dart'
- `mixin _AgentsDesktopLayout on State<MessengerShell>, AgentsShellHost`  — The Agents desktop layout (docs/DESIGN.md §14): three docked panes, no
  - _openSettings _deskInit _deskDispose _deskLoad _deskSave _deskScheduleSave _deskToggleRoster _deskToggleRightPane _deskShowRightPane _deskCloseRightPane _deskOpenRoom _deskCloseRoom _deskOpenNth _deskOpenQuickSwitcher _deskOnKey _deskBarActions _deskMenuActions _buildDesktopBody _buildDeskDetailsPane _deskRefreshDetails _buildDeskRoomsPane _buildDeskRoom _deskAgentOrder

### agents_pairing_page.dart  (309 Z.)
- `typedef AgentsQrViewBuilder = Widget Function( BuildContext context, { required ValueChanged<String> onCode, required Va`  — Builds the live camera view. Injected so a widget test can drive the screen
- `bool agentsCameraIsDefault()`  — True on the platforms where opening a camera is the right default.
- `class AgentsPairingPage extends StatefulWidget`
  - show qrViewBuilder cameraAvailable
- `class _AgentsPairingPageState extends State<AgentsPairingPage>`
  - _accept _onScanned _onCameraUnavailable _submitCode _buildScanner _buildCodeForm _defaultQrView _cameraErrorText

### agents_shell_state.dart  (1028 Z.)
- part of 'messenger_shell.dart'
- `Future<AgentsRelayController> _buildRelayController( AgentsPairingStore store, AccountSessionSource sessionSource, )`  — Builds the default production relay controller: a real [AgentsRelayClient]
- `mixin AgentsShellHost on State<MessengerShell>`  — Everything the shell OWNS, as opposed to how it lays it out.
  - _openAgentProfile _select _hostInit _onHostInbound _loadLastSelection _rememberSelection _writeRememberedSelection _decodePick _flushPendingWrites _onRosterChanged _seedActivityFromHistory _autoSelect _hostDispose _threadLabel _onNotificationTap _restoreCloudPairing _onRestoreReason _agentIdForThread _onPaired _openModelScreen _openOnboarding _renameAgent _openAgentRename _openRoomCreate _openRoom _buildRoomBody _onRoomOpened _manageRoomMembers _onController _hostDeleteRoom _deleteRoom _renameRoom _deleteAgent _copyFullChat _pairedControllerOrExplain _openAgentScreenOrNull _threadIsOnScreen _selectedAgent _readMarks _agentProfiles +3
- `@visibleForTesting DateTime? newestMessageTime(List<ChatMessage>? messages)`  — The newest timestamp among [messages] (`sentAt`, else `startedAt`), or

### assistant_settings_page.dart  (410 Z.)
- `class AssistantSettingsPage extends StatefulWidget`  — One job: make Chuk Chat the assistant of this phone.
- `class _Grant`  — One freedom the assistant needs, and what it buys.
  - key icon title buys open required
- `class _AssistantSettingsPageState extends State<AssistantSettingsPage> with WidgetsBindingObserver`
  - _refresh _claimAssistantRole _open _granted
- `class _HowTo extends StatelessWidget`
  - isDefault
- `class _Step extends StatelessWidget`
  - number text
- `class _AllSet extends StatelessWidget`

### automations_page.dart  (198 Z.)
- `class AutomationsPage extends StatefulWidget`  — Every automation of the host, grouped by the coworker that owns it, with
  - sessionKey chatName
- `class _AutomationsPageState extends State<AutomationsPage>`
  - _onChanged _refresh _control

### coming_soon_page.dart  (95 Z.)
- `class ComingSoonPage extends StatelessWidget`
  - title message

### connector_detail_page.dart  (245 Z.)
- `class ConnectorDetailPage extends StatefulWidget`  — Full-screen detail page for a single tool, showing enable/disable,
  - tool toolExecutor displayName icon
- `class _ConnectorDetailPageState extends State<ConnectorDetailPage>`
  - _buildParameterRow _isEnabled _isAlwaysOn _hasCustomPrompt _currentDescription _promptChanged

### customization_page.dart  (867 Z.)
- `class CustomizationPage extends StatefulWidget`
  - config
- `class _CustomizationPageState extends State<CustomizationPage>`
  - _loadAutoTitleSetting _refreshAutoTitleSettingFromSupabase _saveSystemPrompt _resetSystemPrompt _pickLocale _pickChatFontFamily _fontFamilyLabel _systemPromptEditor
- `class _CardLabel extends StatelessWidget`  — Title and explanation at the top of a card that is not a row.
  - title subtitle

### desktop_media_modal.dart  (128 Z.)
- const: _kRadius
- `Future<void> showDesktopMediaModal(BuildContext context)`  — Opens the media library over the current page.
- `class DesktopMediaModal extends StatelessWidget`  — The panel itself: a header row, then the library.

### desktop_settings_modal.dart  (975 Z.)
- `Future<void> showDesktopSettingsModal( BuildContext context, { required AppShellConfig config, String? initialSectionId …)`  — Opens the desktop settings modal over the current chat UI.
- `class _SettingsDest`  — A settings destination: either a page shown in the right pane, or an
  - isPage id icon label keywords builder onAction tone
- `class _SettingsGroup`
  - title items
- `class DesktopSettingsModal extends StatefulWidget`
  - config initialSectionId
- `class _DesktopSettingsModalState extends State<DesktopSettingsModal>`
  - _onDevOptions _agentsGroups _groups _findPage _onSelect _buildWide _buildCompact _buildNavRail _navItem _tourSlotFor _buildRailFooter _logout _replayOnboarding _exportChats _snack

### diagnostics_settings_page.dart  (338 Z.)
- `class DeveloperOptionsPage extends StatefulWidget`
- `class _DeveloperOptionsPageState extends State<DeveloperOptionsPage>`
  - _load _setDeveloperOptionsEnabled _setEnabled _refreshLogs _copyRecentLogs _copyFocusedModelMenuDebug _shareLogFile _clearLogs

### download_settings_page.dart  (136 Z.)
- `class DownloadSettingsPage extends StatefulWidget`
- `class _DownloadSettingsPageState extends State<DownloadSettingsPage>`
  - _onPrefChanged _pickFolder _clearFolder

### forgot_password_page.dart  (208 Z.)
- `class ForgotPasswordPage extends StatefulWidget`  — Page for requesting a password reset code, then verifying it and setting
- `class _ForgotPasswordPageState extends State<ForgotPasswordPage>`
  - _handleSendResetCode _openRecoveryOtpVerification _buildFormView

### fullscreen_map_page.dart  (1145 Z.)
- `class FullscreenMapPage extends StatefulWidget`
  - center zoom title places markers fitPoints routeFromLat routeFromLon routeToLat routeToLon routeFromLabel routeToLabel initialSelectedPlaceIndex
- `class _FullscreenMapPageState extends State<FullscreenMapPage>`
  - _refreshLocationAvailability _buildMapWidget _buildFallbackMapOptions _applyInitialCamera _applyInitialSelection _fitToPoints _focusMarker _selectPlace _loadRouteForEndpoints _loadRoute _fetchRouteGeometry _animateTo _centerOnCurrentLocation _resolveExternalTarget _openCurrentViewInExternalMaps _launchExternalMaps _ensureCurrentLocation _buildStatusChip _buildPlacePopup _buildPopupAction _toDouble _hasPlaces _hasMarkers _hasRouteEndpoints _routeStart _routeEnd size
- `class _RouteGeometry`
  - points distanceMeters durationSeconds

### github_connection_page.dart  (470 Z.)
- `class GitHubConnectionPage extends StatefulWidget`
- `class _GitHubConnectionPageState extends State<GitHubConnectionPage>`
  - _accessToken _refreshStatus _startConnect _runPoll _disconnect _intro _disconnectedCard _connectedCard _deviceCodeCard _errorBanner

### login_page.dart  (578 Z.)
- `class LoginPage extends StatefulWidget`
  - auth
- `class _LoginPageState extends State<LoginPage>`
  - _handleSubmit _openSignupOtpVerification _toggleMode _validatePassword _authService

### mcp_connectors_page.dart  (1005 Z.)
- `class McpConnectorsPage extends StatefulWidget`
- `class _McpConnectorsPageState extends State<McpConnectorsPage>`
  - _searchRegistry _row _open _addByUrl _report _query
- `class McpConnectorDetailPage extends StatefulWidget`  — One connector: connect or disconnect it, and see what it can do.
  - id entry
- `class _McpConnectorDetailPageState extends State<McpConnectorDetailPage>`
  - _checkReachable _remember _legalNote _openLegal _cancelConnect _connect _disconnect
- `Future<Map<String, String>?> showMcpCredentialDialog( BuildContext context, List<McpCredentialField> fields, String name …)`  — Collect a reader's own credentials for an [McpAuth.apiKey] server. Returns
- `class McpConnectorIcon extends StatefulWidget`  — A connector logo. The bundled brand logo first (shipped in the binary for
  - assetPath url serverUrl name size fallback
- `class _McpConnectorIconState extends State<McpConnectorIcon>`
  - _loadFirstThatWorks _networkIcon _placeholder _candidates
- `Future<T> _withProgress<T>( BuildContext context, Future<T> Function() work, { McpConnectCanceler? canceler, })`

### media_manager_page.dart  (1513 Z.)
- const: kMediaFilterBarHeight
- `enum _MediaFilter`
  - images artifacts
- `class MediaManagerPage extends StatefulWidget`
  - embedded
- `class _MediaManagerPageState extends State<MediaManagerPage>`
  - _loadArtifacts _loadImages _thumb _downloadThumbnail _retryThumbnail _unsupportedImageLabel _thumbErrorLabel _deleteImage _deleteSelectedImages _toggleSelection _enterSelectionMode _exitSelectionMode _downloadImage _downloadSelectedImages _formatFileSize _formatDate _buildToolbar _buildBody _buildImagesEmpty _buildArtifactsView _showArtifactPreview _buildDesktopGrid _buildMobileList _showImagePreview compact
- `class _ThumbGate`  — What one thumbnail knows about itself.
  - Function maxInFlight
- `class _ThumbState`
  - isLoading bytes error
- `class _ImageTile extends StatefulWidget`  — One image in the grid: the picture, what it costs to keep, and — on hover
  - image thumb selected selectionMode compact onTap onLongPress onRetry onDelete onDownload dateLine sizeLine
- `class _ImageTileState extends State<_ImageTile>`
  - _buildPicture
- `class _ThumbError extends StatelessWidget`  — What a tile shows instead of a picture, with the reason and a way back.
  - label compact onRetry
- `class _Glass extends StatelessWidget`  — A dark round pad behind a glyph drawn on top of a picture.
  - child circle
- `class _TileAction extends StatelessWidget`  — One hover action on a tile.
  - icon tooltip onTap tone
- `class _MediaFilterBar extends StatelessWidget`  — Images / Artifacts, as one segmented track with the count in the label.
  - _segment value imageCount artifactCount onChanged
- `class _ArtifactTile extends StatelessWidget`
  - _relative _iconForType artifact onTap

### messenger_shell.dart  (816 Z.)
- part 'agents_shell_state.dart' · part 'agents_desktop_layout.dart'
- `class MessengerShell extends StatefulWidget`  — The messenger: coworkers down the left, the selected thread in the middle,
  - relayControllerBuilder sessionSource pairingStore rosterSource roomSource controlSource onSignOut themeController shellConfig chatDebugExport readMarks agentProfiles pairingRestoreBuilder
- `class _MessengerShellState extends State<MessengerShell> with AgentsShellHost, _AgentsDesktopLayout, SingleTickerProvide …)`
  - _onPushStatus _onControllerForBrowser _onBrowserPresenceChanged _explainNoScreen _select _openRooms _openBrowserView _openAgentProfile _openSettings _openModelScreen _openChatModel _openChatFiles _openControlDrawer _openRoom _drivePush _buildPhoneBody _browserOpen _threadIsOnScreen _openAgentScreenOrNull

### mobile_agents_settings_page.dart  (502 Z.)
- `class MobileAgentsSettingsPage extends StatefulWidget`  — The mobile contact page: everyday choices first, technical details second.
  - agentId chatId source profiles preferences onSettings onChat
- `class _MobileAgentsSettingsPageState extends State<MobileAgentsSettingsPage>`
  - _remove _actionRow _action _section _row Function _icon _preferences

### otp_verification_page.dart  (291 Z.)
- `class OtpVerificationPage extends StatefulWidget`  — Reusable page for entering a 6-digit email verification code.
  - email body onSubmit onResend
- `class _OtpVerificationPageState extends State<OtpVerificationPage>`
  - _startCooldown _messageForError _handleVerify _handleResend

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
  - _handleSubscribe _handleManageBilling _showError _openUsageDetails force
- `class _PlanCard extends StatelessWidget`
  - title price features badgeLabel badgeTone highlighted child

### recover_chats_page.dart  (400 Z.)
- `class RecoverChatsPage extends StatefulWidget`  — Page for recovering or deleting chats encrypted with old passwords.
- `class _RecoverChatsPageState extends State<RecoverChatsPage>`
  - _loadLockedInfo _recoverVersion _deleteVersion _showDeleteConfirmation _showTypeDeleteConfirmation _buildVersionCard

### secrets_settings_page.dart  (285 Z.)
- `class SecretsSettingsPage extends StatefulWidget`
- `class _SecretsSettingsPageState extends State<SecretsSettingsPage>`
  - _add _change _delete _openMenu _service
- `class _SecretDialog extends StatefulWidget`  — Name + value entry. With [fixedName] only the value is asked (change).
  - fixedName
- `class _SecretDialogState extends State<_SecretDialog>`
  - _submit

### set_new_password_page.dart  (269 Z.)
- `class SetNewPasswordPage extends StatefulWidget`  — Page shown after a user clicks a password reset link.
  - onComplete
- `class _SetNewPasswordPageState extends State<SetNewPasswordPage>`
  - _handleSetPassword

### settings_page.dart  (1317 Z.)
- `class SettingsPage extends StatefulWidget`
  - config
- `class _SettingsPageState extends State<SettingsPage>`
  - _onDeveloperOptions _refreshDeveloperOptions _replayOnboarding _exportChats _saveExportToLinux _linuxInitialDirectory _buildAgentsHub
- `class _PlanInfo`
  - heroLabel
- `class _AccountRow extends StatefulWidget`
  - onTap
- `class _AccountRowState extends State<_AccountRow>`
  - _loadProfile _loadPlan _planInfoFrom _identity
- `class _PlanBadge extends StatelessWidget`
  - label
- `class _SettingsRow extends StatelessWidget`
  - icon title subtitle onTap
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

### skills_settings_page.dart  (741 Z.)
- `class SkillsSettingsPage extends StatefulWidget`  — Lists built-in skills and lets the user author their own.
- `class _SkillsSettingsPageState extends State<SkillsSettingsPage>`
  - _match _openEditor _confirmDelete forceRefresh
- `class SkillEditorPage extends StatefulWidget`  — Edits one skill's SKILL.md source.
  - skill
- `class _SkillEditorPageState extends State<SkillEditorPage>`
  - _sourceOf _yamlScalar _quote _save
- `class _SkillsEmptyState extends StatelessWidget`  — Shown when the user has authored no skills of their own. A quiet centred
  - onCreate
- `class _NoSkillMatches extends StatelessWidget`  — What a section shows when the query matched nothing in it.
  - query
- `class _SkillRow extends StatelessWidget`
  - skill onTap onDelete
- `class AgentsSkillsSettingsPage extends StatefulWidget`  — The host's skills, one switch each (docs/WIRE_CONTRACT.md, "Skills").
- `class _AgentsSkillsSettingsPageState extends State<AgentsSkillsSettingsPage>`
  - _onChanged _refresh _toggle _row

### system_prompt_page.dart  (878 Z.)
- `class SystemPromptPage extends StatefulWidget`
- `class _SystemPromptPageState extends State<SystemPromptPage>`
  - _selectedTextOrAll _buildDesktopTextContextMenu _onTextChanged _loadAll _backgroundSyncIdentity _saveAll _importMemory _showSnackBar _isDesktopPlatform _hasPromptChanges _hasSoulChanges _hasUserInfoChanges _hasMemoryChanges _hasIdentityToggleChanged _hasAnyChanges or
- `class _MaterialTextField extends StatelessWidget`
  - _openFullscreen controller hintText minLines maxLines fullscreenTitle fontFamily contextMenuBuilder

### theme_page.dart  (1242 Z.)
- `class ThemePage extends StatefulWidget`
  - config
- `class _ThemePageState extends State<ThemePage>`
  - _applyThemeChanges _updateThemeMode _updateDynamicColorEnabled _selectPresetVariant _applyPreset _updateUiFont _updateChatFont _fontLabel _dynamicColorNote _matchedPreset commit
- `class _ColorCard extends StatelessWidget`
  - description hexLabel currentColor options hexController gridColumns onColorSelected onHexChanged
- `class _ColorPickerDialog extends StatefulWidget`
  - initial
- `class _ColorPickerDialogState extends State<_ColorPickerDialog>`
  - _setHsv _onHexSubmit
- `class _GradientSlider extends StatelessWidget`
  - colors value onChanged
- `class _Swatch extends StatelessWidget`
  - color selected size onTap
- `class _PresetPicker extends StatelessWidget`
  - _pick presets selected brightness onSelected title subtitle customLabel
- `class _PresetDots extends StatelessWidget`
  - preset brightness
- `class _FontCard extends StatelessWidget`
  - _pick title subtitle sample value options labelFor onChanged

### tool_calling_settings_page.dart  (759 Z.)
- `class ToolCallingSettingsPage extends StatefulWidget`
  - config
- `class _ToolCallingSettingsPageState extends State<ToolCallingSettingsPage>`
  - _toolDisplayNames _onDevOptionsChanged _loadToolPreferences _categoryOrder _categoryLabel _categoryIcon _categoryDescription _categoryServiceName _isCategoryConnectable _isCategoryConnected _connectService _disconnectService _displayName _isCategoryDevOnly _anyRegistered _visibleTools _buildToolSections _appendCollapsedInfraRows _openToolDetail _resetAllToolPreferences maxChars
- `class _ToolRow extends StatelessWidget`  — One tool: the switch turns it off, the tile itself opens its detail.
  - icon iconEnabled title subtitle value onChanged onTap alwaysOn
- `class _CategoryLabel extends StatelessWidget`  — A light category label under the single "Tools" section header. Smaller and
  - label

### usage_details_page.dart  (1340 Z.)
- const: _kMonthNames
- `class UsageDetailsPage extends StatefulWidget`
- `class _UsageDetailsPageState extends State<UsageDetailsPage>`
  - _loadUsageOverview _syncSelectedScope _appBar _hasCreditProgress _buildScopeSelector _buildSummaryCard _buildTokenActivitySection _buildHeatmapModeSelector _buildHeatmapLegend _heatmapCaption _buildBillingCard _buildModelSummaryCard _buildRequestCard _buildInlineWarning _buildScopeOptions _selectedScope _firstScopeByType _buildSlice _matchesScope _formatMonthYear _formatCount _formatDate _formatDateTime _twoDigits _formatEurSmart decimals
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
  - _cell3 _buildWeekdayLabels _tooltipFor _formatDay _formatTokens series values mode
- `int _heatmapLevel(int value, int maxValue)`  — Quartile of [value] against [maxValue]: 0 (none) then 1–4 (light→dark).
- `Color _heatmapCellColor(BuildContext context, int level)`  — Cell colour for a heat level, from theme tokens so both themes read well:

### workspace_detail_page.dart  (1031 Z.)
- `class WorkspaceDetailPage extends StatelessWidget`
  - _isMobileForm workspaceId onStartNewChat
- `class _WorkspaceDetailDesktop extends StatefulWidget`
  - workspaceId onStartNewChat
- `class _WorkspaceDetailPageState extends State<_WorkspaceDetailDesktop> with SingleTickerProviderStateMixin, WorkspaceAct …)`
  - _loadModelId _loadProject _saveSettings _addChat _confirmContextBudget _buildFilesTab _formatTokenCount _contextChipColor _buildChatsTab _buildSettingsTab workspaceId
- `class _ContextUsageBar extends StatelessWidget`
  - ratio totalTokens contextWindow displayColor isOverBudget
- `class _ChatSelectorDialog extends StatefulWidget`
  - chats
- `class _ChatSelectorDialogState extends State<_ChatSelectorDialog>`
  - _filter

### workspace_files_page.dart  (778 Z.)
- `class WorkspaceFilesPage extends StatefulWidget`
  - workspaceId
- `class _WorkspaceFilesPageState extends State<WorkspaceFilesPage> with WorkspaceActionsMixin<WorkspaceFilesPage>`
  - _load _loadModel _uploadBytes _pickFromDevice _takePhoto _pickImage _createDocument _timestampedName _showAddSheet _deleteFile workspaceId
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

### workspace_instructions_page.dart  (225 Z.)
- `class WorkspaceInstructionsPage extends StatefulWidget`
  - workspaceId
- `class _WorkspaceInstructionsPageState extends State<WorkspaceInstructionsPage>`
  - _onChanged _save _confirmDiscard _hasChanges

### workspace_management_page.dart  (758 Z.)
- `class WorkspaceManagementPage extends StatefulWidget`  — Mobile-friendly workspace management page
  - workspaceId onStartNewChat
- `class _WorkspaceManagementPageState extends State<WorkspaceManagementPage> with SingleTickerProviderStateMixin, Workspac …)`
  - _loadProject _saveInstructions _addChat _startNewChatWithProject _buildFilesTab _buildFileCard _buildChatsTab _buildSettingsTab _showEditProjectDialog _showDeleteProjectDialog workspaceId
- `class _ChatSelectorSheet extends StatelessWidget`  — Bottom sheet for selecting a chat to add to workspace
  - chats

### workspace_mobile_detail_page.dart  (567 Z.)
- `class WorkspaceMobileDetailPage extends StatefulWidget`
  - workspaceId onStartNewChat
- `class _WorkspaceMobileDetailPageState extends State<WorkspaceMobileDetailPage>`
  - _load _openFiles _openInstructions _confirmDelete _editNameDescription
- `class _PrivacyChip extends StatelessWidget`
  - isPublic theme
- `class _InfoCard extends StatelessWidget`
  - title bodyText bodyIsPlaceholder footer onTap
- `String _formatDate(DateTime date, BuildContext context)`
- `class _ChatRow extends StatelessWidget`
  - chat theme

### workspaces_page.dart  (859 Z.)
- `enum ProjectSortMode`  — Sort options for workspace list
  - recentlyUpdated name mostFiles mostChats
- `class WorkspacesPage extends StatefulWidget`
  - onOpenWorkspace embedded
- `class _WorkspacesPageState extends State<WorkspacesPage>`
  - _onSearchChanged _loadProjects _filterProjects _createProject _deleteProject _archiveProject _buildEmptyState _buildDesktopGrid _buildMobileList _buildFlatList _openProjectDetail
- `class _SortButton extends StatelessWidget`
  - _sortItem sortMode onChanged
- `class _ProjectRow extends StatelessWidget`
  - _showRowMenu _editedLabel workspace onTap onDelete onArchive
- `class _CreateProjectDialog extends StatefulWidget`
- `class _CreateProjectDialogState extends State<_CreateProjectDialog>`
  - _submit

## lib/pages/settings
### developer_settings_page.dart  (124 Z.)
- `class DeveloperSettingsPage extends StatefulWidget`  — Developer options: the endpoints the app talks to, and a couple of local
- `class _DeveloperSettingsPageState extends State<DeveloperSettingsPage>`
  - _load _setCaptureContext

### embedding_settings_page.dart  (93 Z.)
- `class EmbeddingSettingsPage extends StatefulWidget`  — Picks the embedding model the host uses for semantic memory.
- `class _EmbeddingSettingsPageState extends State<EmbeddingSettingsPage>`
  - _load _pick

### herenow_settings_page.dart  (151 Z.)
- `class HereNowSettingsPage extends StatefulWidget`  — The here.now publishing connector: let a coworker put a file or a folder on
- `class _HereNowSettingsPageState extends State<HereNowSettingsPage>`
  - _reload _update

### mcp_connectors_page.dart  (960 Z.)
- `class McpConnectorsPage extends StatefulWidget`
- `class _McpConnectorsPageState extends State<McpConnectorsPage>`
  - _statusOf _searchRegistry _searchField _row _open _addByUrl _report _query
- `class McpConnectorDetailPage extends StatefulWidget`  — One connector: connect or disconnect it, and see what it can do.
  - id entry
- `class _McpConnectorDetailPageState extends State<McpConnectorDetailPage>`
  - _legalNote _openLegal _cancelConnect _connect _disconnect
- `Future<Map<String, String>?> showMcpCredentialDialog( BuildContext context, List<McpCredentialField> fields, String name …)`  — Collect a reader's own credentials for an [McpAuth.apiKey] server. Returns
- `class McpConnectorIcon extends StatefulWidget`  — A connector logo. The bundled brand logo first (shipped in the binary for
  - assetPath url serverUrl name size fallback
- `class _McpConnectorIconState extends State<McpConnectorIcon>`
  - _loadFirstThatWorks _networkIcon _placeholder _candidates
- `Future<T> _withProgress<T>( BuildContext context, Future<T> Function() work, { McpConnectCanceler? canceler, })`
- `class _AddByUrlDialog extends StatefulWidget`  — The "Add a connector" dialog. It owns its text controller so the controller
- `class _AddByUrlDialogState extends State<_AddByUrlDialog>`

## lib/platform_specific
### root_wrapper.dart  (5 Z.)
- reicht weiter: 'root_wrapper_stub.dart' if (dart.library.io) 'root_wrapper_io.dart'

### root_wrapper_desktop.dart  (717 Z.)
- `class RootWrapperDesktop extends StatefulWidget`
  - config
- `class _RootWrapperDesktopState extends State<RootWrapperDesktop>`
  - _onArtifactChanged _onPanelOpenChanged _onArtifactOpenRequested _closeArtifactPanel _openSourceChatForArtifact _openSettingsPage _openWorkspacesPage _openWorkspace _startWorkspaceChat _exitProject _openMediaPage _handleChatSelected _toggleSidebar _copyDebugChat _buildMiniRail _onTrayNewChat _handleNewChatFromSidebar _handleChatDeleted

### root_wrapper_io.dart  (76 Z.)
- `class RootWrapper extends StatelessWidget`
  - _isMobilePhone config

### root_wrapper_mobile.dart  (784 Z.)
- `class RootWrapperMobile extends StatefulWidget`
  - config
- `class _RootWrapperMobileState extends State<RootWrapperMobile> with WidgetsBindingObserver, SingleTickerProviderStateMix …)`
  - _onPanelOpenRequested _onArtifactChanged _maybeOpenArtifactSheet _refreshSessionOnResume _ensurePermissions _ensureBatteryOptimizationDisabled _showPermissionBlockedSnackBar _toggleSidebar _openSettingsPage _openWorkspacesPage _openMediaPage _handleChatSelected _handleChatDeleted _newChatFromAppBar _currentChatTitle _buildFloatingTopBar _floatIconChip _newChatFromSidebar _openArtifactSheet _copyDebugChat

### root_wrapper_stub.dart  (19 Z.)
- `class RootWrapper extends StatelessWidget`  — Web wrapper - renders desktop UI since web is a desktop-like environment
  - config

### sidebar_desktop.dart  (586 Z.)
- `class SidebarDesktop extends StatefulWidget`
  - onChatSelected onSettingsTapped onWorkspacesTapped onMediaTapped onNewChatTapped onChatDeleted selectedChatId isCompactMode showWorkspacesButton
- `class _SidebarDesktopState extends State<SidebarDesktop> with SidebarStateCommon<SidebarDesktop>`
  - applyChatFilter _focusDesktopSearch _onSearchFocusChanged _onDesktopSearchChanged _clearDesktopSearch _refreshDesktopChats _filterDesktopChats _buildDesktopSlivers _buildDesktopNavigationCards _selectDesktopChat _buildDesktopChatItem _openChatActionsMenu _handleMenuSelection _buildMenuItems _showChatContextMenu onChatDeletedCallback

### sidebar_mobile.dart  (694 Z.)
- `class SidebarMobile extends StatefulWidget`
  - onChatSelected onSettingsTapped onWorkspacesTapped onMediaTapped onNewChatTapped onChatDeleted onCollapseTapped selectedChatId isCompactMode
- `class _SidebarMobileState extends State<SidebarMobile> with SidebarStateCommon<SidebarMobile>`
  - applyChatFilter _focusMobileSearch _onSearchFocusChanged _onMobileSearchChanged _clearMobileSearch _refreshMobileChatsFromGesture _refreshChats _performRefresh _filterMobileChats _filterChatsLocally _buildMobileSlivers _buildMobileNavigationCards _selectMobileChat _buildMobileChatItem _showChatOptionsMenu _chatOptionRow onChatDeletedCallback
- `List<String> _filterChatsIsolate(Map<String, dynamic> params)`

## lib/platform_specific/chat
### chat_api_service.dart  (400 Z.)
- `class ChatApiService`  — A service for handling chat-related API interactions,
  - performFileUpload performFileUploadFromBytes transcribeAudioFile transcribeAudioBytes _messageFromErrorPayload _apiBaseUrl onUploadStatusUpdate
- `class TranscriptionResult`
  - text metadata
- `class TranscriptionException implements Exception`
  - message statusCode

### chat_debug_snapshot.dart  (56 Z.)
- `abstract class ChatDebugSnapshot`  — What the "copy debug chat" action reads out of a running chat screen.
  - debugMessages debugModelId debugProviderSlug debugWorkspaceId debugReasoningEffort debugActiveChatId
- `Map<String, String> chatDebugContext( ChatDebugSnapshot? state, { required String platform, })`  — The context block that rides along with a copied debug chat.

### chat_message_edit_mixin.dart  (346 Z.)
- `mixin ChatMessageEditMixin<W extends StatefulWidget> on State<W>, ChatScrollMixin<W>`
  - deleteComposerAttachment sendMessage onEditStarted onComposerAttachmentRemoved isValidMessageIndex showSnackBar reconstructAttachedFilesForResend editMessageAt cancelEditMessage removeComposerAttachment sendOrSubmitEdit resendMessageAt branchFromIndex captureRegenSeed switchVariantAt updateAiMessage messages activeChatId messageActionsHandler persistenceHandler composerController composerFocusNode restoredAttachmentIds composerAttachedFiles nothingToResendMessage removeFollowingAssistant waitForCompletion

### chat_metrics_observer.dart  (15 Z.)
- `class ChatMetricsObserver with WidgetsBindingObserver`  — Calls back on every view-metrics change — the soft keyboard opening or
  - didChangeMetrics onMetrics

### chat_model_selection_mixin.dart  (323 Z.)
- `mixin ChatModelSelectionMixin<W extends StatefulWidget> on State<W>, ModelProviderResolutionMixin<W>`
  - presentModelScreen refreshSelectedModelName refreshCustomModelName refreshPickedModels applyPickedModels openModelScreen setChatMode setReasoningEffort clampedReasoningEffort applyModelSelection restoreChatMode applyModeConfig loadSavedModelPreference selectedModelId selectedProviderSlug chatMode reasoningEffort selectedModelName pickedModels customModelName

### chat_scroll_mixin.dart  (538 Z.)
- const: _kTranscriptCenterKey
- `mixin ChatScrollMixin<T extends StatefulWidget> on State<T>`  — Shared message-list scroll behaviour for the desktop and mobile chat UIs.
  - resolveTranscriptSplit _transcriptLooksLong _anchorTranscriptAtBottom _collapseShortTranscript buildAnchoredTranscript pinMessageToTop clearTopPin onScrollChanged onComposerHeightChanged pinToBottomDuringStream settleScrollToBottomIfSticky anchoredTranscript transcriptRows transcriptStreaming transcriptPxPerChar transcriptInitialOffset showScrollButtonDistance hideScrollButtonDistance scrollController transcriptBottomInset transcriptEpoch showScrollToBottom isStickyBottom pinnedTopKey hasTopPin pinnedExtraSpace composerHeight animate lastExtent
- `class _TranscriptScrollController extends ScrollController`  — A [ScrollController] whose initial offset is read when a position is
  - initialScrollOffset

### chat_ui_desktop.dart  (3006 Z.)
- part 'desktop_send_logic.dart'
- `class ChukChatUIDesktop extends StatefulWidget`
  - onToggleSidebar selectedChatId onChatIdChanged isSidebarExpanded isCompactMode showReasoningTokens showModelInfo showTps workspaceId onExitProject imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls autoSendVoiceTranscription onOpenModelSettings agentsThread agentsTitle topInset
- `class ChukChatUIDesktopState extends State<ChukChatUIDesktop> with SingleTickerProviderStateMixin, ChatScrollMixin, Mode …)`
  - deleteComposerAttachment onComposerAttachmentRemoved sendMessage _buildComposerContextMenu _buildMessageContextMenu _resetThreadTransientState _loadChatById _applyLoadedChat _loadChatByIdAsync _populateMessagesFromStoredChat _messageToRawMap newChat newChatWithWorkspace _openComingSoonFeature _loadSystemPrompt _resolveWorkspaceForCurrentChat _resolveSystemPromptForSend _stopAudioRecordingForNavigation _handleMicTap _handleAudioSend _askUserCallbackForIndex _connectMcpCallbackForIndex _continueGenerationAt _buildMessageActionsForIndex _buildUserMessageActionsForIndex _wrapWithSmartPasteActions _buildMessageList _buildScreen _buildSearchBar _agentsDock _buildAgentsComposer presentModelScreen messages activeChatId composerAttachedFiles _isSending _isStreaming anchoredTranscript transcriptRows transcriptStreaming +20

### chat_ui_helpers.dart  (1417 Z.)
- const: _kRowTimeCacheCap _rowTimeCache _rowLocalDayCache
- `class MessageRenderData`  — Data class holding pre-parsed render information for a single chat message.
  - isUser sender displayText reasoning isReasoningStreaming modelLabel modelProvider tps images imageMetas imageCostEur imageGeneratedAt attachments toolCalls contentBlocks isStreamingMessage turnStartedAt workedFor status queueId lastError variantIndex variantCount
- `class MessageRenderCache`  — Owns decoded message payloads for one visible chat and builds render data.
  - debugClearShared clear
- `class _MessageRenderMaps`  — The four decode maps behind a [MessageRenderCache].
  - clear images attachments toolCalls contentBlocks
- `class ChatContinuationRequest`  — Immutable input for resuming the latest interrupted assistant message.
  - messageIndex historyMessages priorText priorContentBlocksJson modelId provider
- `class ChatUiHelpers`  — Static utility functions shared between the desktop and mobile chat UIs.
  - prepareContinuation hasCompletedTool encodeToolCalls replaceMessageField appendDebugRequest stableUiKey formatModelInfo modelSupportsImageInput showSnackBar openComingSoonFeature loadProviderSlugForModel ensureProviderSlug loadSystemPrompt resolveSystemPromptForSend messageToRawMap variantSnapshotOf decodeVariants writeVariants switchVariant finalizeStaleToolCallsInRawMessage _knownWithoutStaleCalls _rememberWithoutStaleCalls _finalizeStaleToolCallsForRecovery decodeImages decodeAttachments decodeToolCalls decodeContentBlocks extractArtifactIdsFromRawMessage trimCachesIfNeeded reconstructAttachedFilesForResend writeAttachmentsToMessage extractResendUserQuery _looksLikeGeneratedAttachmentHeader buildResendUserPrompt _buildMarkdownFence detectImageMimeType buildMessageRenderData kUiKeyField continueGenerationPrompt kVariantContentKeys +1
- `DateTime? messageRowTime(Map<String, String> raw)`  — Message grouping — the one place that decides which rows form a run.
- `DateTime? _rowTimeFor(String stamp)`
- `int? _rowLocalDay(Map<String, String> raw)`  — The local calendar day of a row's stamp as `yyyymmdd`, or null when the
- `bool messageOpensDay(Map<String, String>? previous, Map<String, String> row)`  — Whether a day divider is drawn above [row]. An undated row gets none — an
- `bool messageStartsRun(List<Map<String, String>> messages, int index)`  — Whether the row at [index] opens a new run: it is the first row, the sender
- `bool messageEndsRun(List<Map<String, String>> messages, int index)`  — Whether the row at [index] closes its run: the last row, or the next row

### chat_ui_mobile.dart  (4166 Z.)
- `enum _AttachChoice`  — What the plus menu can start.
  - camera photos files workspace
- `class _WorkspaceChoice`  — A row in the workspace menu: a workspace to switch to (null clears it),
  - workspaceId create
- `@visibleForTesting String queuedMessagesForComposer(String pending, List<String> followUps)`  — The text a cancelled queue puts back into the composer: the pending
- `class ChukChatUIMobile extends StatefulWidget`
  - onToggleSidebar selectedChatId onChatIdChanged isSidebarExpanded showReasoningTokens showModelInfo showTps autoSendVoiceTranscription topInset imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls messengerMode hostRunActive
- `class ChukChatUIMobileState extends State<ChukChatUIMobile> with ChatScrollMixin, ModelProviderResolutionMixin, ChatMode …)`  — Serialize a [ChatMessageStatus] into the wire-format string used inside
  - deleteComposerAttachment onEditStarted _onComposerFocusChanged _onMessengerStoreChanged _loadReactions _reactionKeyAt _toggleReaction _replyToMessage _onChatModelChanged _hydrateChatModel restoreChatMode _initializeHandlers _persistStreamTick _markAssistantMessageInterrupted _handleAppResumed _handleAppPaused _showPaymentRequiredDialog _initializeListeners _onControllerChanged _loadInitialData _loadChatById _applyLoadedChat _loadChatByIdAsync newChat _handleMicTap _handleAudioSend _handleAddAttachmentTap _showAnchoredComposerMenu _buildWorkspaceChip _openWorkspaceMenu _openProjectManagement startNewChatWithWorkspace _startNewChatWithProject _handleFileUploadUpdate _updateToolCallsForMessage _handleToolImagesProcessed _updateContentBlocksForMessage _updateRequestPayloadForMessage _finalizeAiMessage _resetThreadTransientState +51

### composer_menu.dart  (59 Z.)
- `PopupMenuItem<T> composerMenuRow<T>({ required T value, required Color iconFg, required IconData icon, required String l …)`  — One row of a composer menu — same metrics as the mode menu.
- `Future<T?> showAnchoredComposerMenu<T>({ required BuildContext anchorContext, required List<PopupMenuEntry<T>> items, })`  — Open a menu anchored to a composer button. It leaves the focus and

### composer_menu_choices.dart  (18 Z.)
- `enum AttachChoice`  — What the attach menu offers.
  - camera photos files workspace
- `class WorkspaceChoice`  — A row in the workspace menu: a workspace to switch to (null clears it),
  - workspaceId create

### composer_metrics.dart  (18 Z.)
- `class ComposerMetrics`  — The numbers that make the mobile composer's action row read as one family.
  - targetSize targetGap

### desktop_send_logic.dart  (2540 Z.)
- part of 'chat_ui_desktop.dart'
- `extension DesktopSendLogic on ChukChatUIDesktopState`  — Extension on [ChukChatUIDesktopState] containing the large send/streaming
  - _extractResendUserQueryFromDisplayText _buildResendUserPrompt _beginSendOperation _isSendOperationCancelled _clearSendOperation _markLastAssistantMessageCancelled _cancelPendingSendOperation _cancelStream _cancelCurrentOperation _isSendingForChat _showPaymentRequiredDialog _sendMessage _detectImageMimeType _buildApiHistoryWithPendingMessage _updateToolCallsForMessage _appendDebugRequestForMessage _processToolImages _cancelPendingMessage _drainPendingMessage _enqueueOfflineSend removeFollowingAssistant foldVariant commit

### model_provider_resolution_mixin.dart  (186 Z.)
- `mixin ModelProviderResolutionMixin<T extends StatefulWidget> on State<T>`  — Shared model → provider-slug resolution for the desktop and mobile chat UIs.
  - modeProviderSlugFor ensureProviderSlugForCurrentModel selectedModelId selectedProviderSlug chatMode modelSelectionChatId modelSupportsImageInput forceFromPrefs

### regen_variant_seed.dart  (150 Z.)
- `mixin RegenVariantSeedMixin<W extends StatefulWidget> on State<W>`
  - armVariantSeed clearVariantSeed stashVariantSeedForBackground restoreVariantSeedForChat foldRegenVariantOnto foldBackgroundVariantOnto variantActiveChatId

## lib/platform_specific/chat/handlers
### audio_recording_handler.dart  (567 Z.)
- `enum AudioRecordingChange`
  - started stopped failed busy
- `class AudioRecordingHandler`  — Handles microphone recording + transcription.
  - _startRecording toggleRecording _transcribeLastRecording Function _handlePcmChunk _tryConnectStreaming _transcribeStreaming _transcribeBufferedPcm _retryTranscribeAfterRefresh _pcmToWav _writeAscii _computeAmplitudeFromPcm _resetAudioLevels _ensureMicPermission isMicActive isTranscribingAudio audioLevels isStreamingMode onLevelsChanged keepFile
- `class TranscriptionResult`  — Result of audio transcription.
  - success text error

### chat_persistence_handler.dart  (467 Z.)
- `@visibleForTesting bool keepsMoreThanPatch(String? stored, String? patch)`  — Handles chat persistence and storage
- `class ChatPersistenceHandler`
  - flushPending stampWorkedFor _reportSaveError _flushBackgroundUpdate waitForCompletion silent immediate
- `class _PendingBackgroundUpdate`
  - chatId messageIndex content reasoning toolCallsJson contentBlocksJson images imageMetas imageCostEur imageGeneratedAt tps attempts status commit

### desktop_clipboard_handler.dart  (265 Z.)
- `class DesktopClipboardHandler`  — Handles desktop-specific clipboard operations and context menus.
  - selectedTextOrAll buildComposerContextMenu buildMessageContextMenu sanitizeClipboardInPlace handleSmartPaste cleanupOldPasteTempDirectories kLongPasteThreshold kPasteTempRetention onProcessFilePaths

### desktop_file_handler.dart  (444 Z.)
- `class ValidatedFile`  — Temporary container for validated files before upload.
  - file fileName fileSize isImage id
- `class DesktopFileHandler`  — Handles desktop-specific file attachment processing including:
  - initialize getUploadedFiles processFilePaths _uploadEncryptedImage uploadFiles processWebFiles _uploadEncryptedImageFromBytes handleDroppedFiles removeAttachedFile handleFileUploadUpdate clearAll hasAttachments hasUploading attachedFiles onShowSnackBar onUpdate onScrollToBottom modelSupportsImageInput

### file_attachment_handler.dart  (438 Z.)
- `class FileAttachmentHandler`  — Handles file and image attachments
  - initialize pickImageFromSource pickImagesFromGallery uploadFiles _handleFileAttachment Function _uploadEncryptedImageFromBytes _isImageExtension handleUploadStatusUpdate removeFile clearAll getUploadedFiles attachedFiles hasAttachments hasUploading onUpdate

### message_actions_handler.dart  (195 Z.)
- `class MessageActionsHandler`  — Handles message-related actions (copy, edit, resend)
  - _forExport copyToClipboard startEdit cancelEdit submitEdit resend Function editingMessageIndex isEditing canRetryToolPass

### mobile_workspace_handler.dart  (153 Z.)
- `class MobileWorkspaceHandler`  — Handles mobile-specific workspace selection UI and workspace–chat linking.
  - Function addChatToProject removeChatFromProject

### scanned_pdf_pages.dart  (89 Z.)
- `Future<void> replaceWithScannedPages({ required List<String> dataUrls, required String fileId, required String fileName …)`  — Replaces a scanned PDF in [attachedFiles] with its rendered pages.
- `void discardScannedPages(List<String> paths)`  — Deletes pages that were uploaded before the replacement failed, so a

### streaming_message_handler.dart  (1657 Z.)
- `class StreamingMessageHandler`  — Handles message streaming and sending
  - cancelStream _processToolImages _acquireForegroundKeepAlive _releaseForegroundKeepAlive _updateForegroundNotification resetState isChatStreaming getBufferedContent getBufferedReasoning getStreamingMessageIndex hasCompletedStream consumeCompletedStream setBackgroundMessages getBackgroundMessages hasBackgroundMessages getSessionSafely _markStreamFinalized _recordSnapshot _clearSnapshot _handleAppPaused _markInterruptedIfStreaming isStreaming isSending activeToolLoopFuture includeRecentImagesInHistory includeRecentImages forceImmediate
- `class _StreamingSnapshot`
  - chatId index content reasoning contentBlocksJson

## lib/platform_specific/chat/widgets
### chat_message_list_item.dart  (237 Z.)
- `class ChatMessageListItem extends StatelessWidget`  — One message row shared by the desktop and mobile chat lists.
  - _withHoverActions hoverActions messages index data uuid maxWidth activeChatId flyInKey showToolCalls showReasoningTokens showModelInfo showTps isEditing actions userMessageActions onSwitchVariant onAskUserAnswer onConnectMcpServer onContinueGeneration messengerMode agentsRuns reaction onReaction onReply onEditRequested

### mobile_chat_widgets.dart  (209 Z.)
- `Widget buildTinyIconButton({ IconData? icon, String? svgAssetPath, required VoidCallback? onTap, required bool isActive …)`  — Build a tiny icon button widget
- `Widget buildTinyActionButton({ IconData? icon, String? svgAssetPath, required VoidCallback onTap, required Color color …)`  — Build a tiny action button widget (for send, etc.)
- `Widget buildAttachmentSheetOption({ required BuildContext context, required IconData icon, required String label, requir …)`  — Build attachment sheet option (for bottom sheet)
- `Widget buildKeyboardListener({ required FocusNode focusNode, required TextEditingController controller, required VoidCal …)`  — Build keyboard listener for text field (handles Enter/Shift+Enter)

## lib/platform_specific/mobile
### mobile_agent_list.dart  (1240 Z.)
- `String accountMonogram(String? label)`  — The account monogram: "alex.smith@…" → "A", "Alex Smith" → "AS".
- `class MobileAgentList extends StatefulWidget`
  - source emptyState rooms onOpenRoom onCreateRoom onSelect selectedAgentId selectedThreadKey onAddAgent onOpenAccount onOpenProfile onRenameAgent onDeleteAgent accountLabel now readMarks profiles onOpenFrom hiddenAgentId
- `class _MobileAgentListState extends State<MobileAgentList>`
  - _now _openSearch _closeSearch _visibleRooms _openAddMenu _visible _roleOf _openRowMenu _buildList _marks _profiles
- `class _SearchField extends StatelessWidget`  — The roster's search input: one rounded, filled field that carries its own
  - controller focusNode height onClear
- `class MobileAgentRow extends StatelessWidget`
  - previewOf agent now selected unread unreadThreads role onTap onLongPress profiles padded height
- `class MobileRoomRow extends StatelessWidget`  — One ROOM, in the inbox's own row grammar.
  - previewOf room onTap onLongPress profiles padded
- `class _RoleTag extends StatelessWidget`  — The small grey tag next to the name (the coworker's role).
  - role
- `class _MenuRow extends StatelessWidget`
  - icon label color
- `class _EmptyState extends StatelessWidget`
  - filter query onAddAgent
- `String mobileTimeLabel(DateTime? when, {required DateTime now})`  — The time column of an inbox row, like a messenger: a clock time today,
- `class _UnreadBadge extends StatelessWidget`  — The number of new threads on a coworker, in that coworker's colour.
  - count colour

### mobile_agent_sheet.dart  (189 Z.)
- `class MobileAgentSheet extends StatelessWidget`
  - show menuGroups agent onProfile onControls onRename onRooms onCopyChat onSettings onSignOut

### mobile_chat_chrome.dart  (391 Z.)
- const: _kPillFaceSize _kPillStatusFontSize
- `class MobileChatChrome extends StatelessWidget`
  - agent onBack onOpenProfile onOpenBrowser browserAvailable onOpenFiles onReconnect onMore profiles
- `class _AgentPill extends StatelessWidget`  — The coworker pill: face, name, live state. As tall as a chip, so the whole
  - _surface _statusLine _roleOf agent onTap onReconnect profiles

### mobile_chat_screen.dart  (226 Z.)
- `typedef MobileChatBodyBuilder = Widget Function(BuildContext context, double topInset)`  — Builds the chat body. [topInset] is the space the body must leave at the
- `class MobileChatScreen extends StatefulWidget`
  - agent onBack bodyBuilder onOpenProfile onOpenBrowser browserAvailable onOpenFiles onReconnect onMore active
- `class _MobileChatScreenState extends State<MobileChatScreen> with TickerProviderStateMixin`
  - _onDragStart _onDragEnd

### mobile_chips.dart  (63 Z.)
- `List<BoxShadow> mobileChipShadow(ThemeData theme)`  — The soft shadow under a chip or pill. Lighter in dark mode, where a hard
- `class MobileBarFade extends StatelessWidget`  — The fade behind a floating bar: solid at the top, transparent at the
  - child

### mobile_container_transform.dart  (178 Z.)
- `@immutable class ContainerTransformSource`  — One tapped roster row, as the container transform needs it: where the row
  - rect child
- `class MobileContainerTransform extends StatelessWidget`  — The container transform: [closed] grows into [open] over [progress].
  - duration closedRadius progress reverse openSize open openColor closed

### mobile_home.dart  (306 Z.)
- `class MobileHome extends StatefulWidget`
  - roster chats settings controller readMarks profiles
- `class _MobileHomeState extends State<MobileHome>`
  - _openPanel _picker _marks
- `class _FadeThroughTabs extends StatefulWidget`  — An [IndexedStack] that fades through instead of cutting.
  - index children duration
- `class _FadeThroughTabsState extends State<_FadeThroughTabs> with SingleTickerProviderStateMixin`
  - _onStatus

### mobile_layout.dart  (96 Z.)
- `class MobileLayout`
  - headerContentHeight isPhone isPhoneWidth chromeInset phoneBreakpoint minTouchTarget chipDiameter controlHeight barHeight barFade edgeSwipeWidth swipeVelocity

### mobile_media_page.dart  (225 Z.)
- `class MobileMediaPage extends StatefulWidget`
  - index threadKeys
- `class _MobileMediaPageState extends State<MobileMediaPage>`
  - _payloadOf _index
- `class _Thumbnail extends StatelessWidget`
  - entry
- `class _Empty extends StatelessWidget`
  - topSpace message hint

### mobile_nav_bar.dart  (171 Z.)
- `@immutable class MobileNavDestination`  — One destination of [MobileNavBar].
  - icon label badge
- `class MobileNavBar extends StatelessWidget`
  - destinations index onSelected height
- `class _NavTarget extends StatelessWidget`
  - destination selected onTap

## lib/services
### account_session.dart  (198 Z.)
- `class AccountSession`  — Immutable snapshot of the account's authenticated session.
  - accessToken refreshToken userId expiresAt
- `abstract interface class AccountSessionSource`  — Reads the current [AccountSession] and refreshes it on demand.
  - current refresh
- `class SupabaseAccountSession implements AccountSessionSource`  — [AccountSessionSource] backed by the live Supabase session.
  - _readCurrent _doRefresh _doRestore _clock _secondsLeft needsRefresh _stillValid current refresh refreshHeadroom

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
  - apiBaseUrl artifactsBaseUrl environment platform isConfigured configurationDescription

### api_config_service_stub.dart  (27 Z.)
- `class ApiConfigService`  — Service for managing API configuration across different environments and platforms.
  - apiBaseUrl artifactsBaseUrl environment platform isConfigured configurationDescription

### api_status_service.dart  (59 Z.)
- `class ApiStatusService`  — Utility helpers for checking the availability of the primary API.
  - _buildUri _defaultBaseUrl timeout method

### app_initialization_service.dart  (420 Z.)
- `class AppInitializationService`  — Callback for initialization events
  - initializeCoreServices _preloadEncryptionKey initializeUserSession _startSyncWhenKeyReady _tryLoadKeyWithTimeout _loadUserData _startSyncAfterKey _startSyncAfterSidebarLoad _onLinuxKeyReady _startDeferredPreload instance _isLinuxDesktop timeout

### app_lifecycle_service.dart  (165 Z.)
- `class AppLifecycleService extends ChangeNotifier`  — Callback when app state changes
  - addOnResumeCallback removeOnResumeCallback addOnPauseCallback removeOnPauseCallback handleLifecycleState _handleResumed _checkNetworkThenResume _handlePaused instance _isDesktopPlatform

### app_theme_service.dart  (877 Z.)
- `typedef ThemeChangedCallback = void Function()`  — Callback type for theme changes
- `class AppThemeService extends ChangeNotifier`  — Service for managing application theme state, persistence, and Supabase sync
  - _onboardingKeyFor _getPrefs loadFromPrefs _readLocalOnboarding _clampChatFontSize _clampUiScale _clampContrast _sanitizeChatFontFamily _sanitizeUiFontFamily _loadFromSupabase _reconcileOnboarding _persistToPrefs _debouncedSyncTheme _debouncedSyncCustomization _syncThemeToSupabase _syncCustomizationToSupabase setThemeMode setAccentColor setIconFgColor setBgColor setDynamicColorEnabled setShowReasoningTokens setShowModelInfo setShowTps setAutoSendVoiceTranscription setImageGenEnabled setImageGenDefaultSize setImageGenCustomWidth setImageGenCustomHeight setImageGenUseCustomSize setIncludeRecentImagesInHistory setIncludeAllImagesInHistory setIncludeReasoningInHistory setIncludeToolResultsInHistory setToolCallingEnabled setToolDiscoveryMode setShowToolCalls setUiLocale setChatFontSize setChatFontFamily +40

### approval_config.dart  (140 Z.)
- `enum ApprovalCategory`  — Categories of actions that may require approval
  - bash gmail slack github calendar
- `class ApprovalAction`  — Specific actions within each category that can require approval
  - category action description riskLevel riskDescription
- `class ApprovalConfig`  — Universal Approval Configuration
  - load isApprovalRequired allActions

### artifact_context_service.dart  (12 Z.)
- `class ArtifactContextService`
  - buildArtifactsSystemMessage

### artifact_diff_engine.dart  (134 Z.)
- `class ArtifactDiffEngine`
  - applyEdits _findOccurrences _buildMatchError _trimPreview _escapeForMessage _extractContext maxEditsPerUpdate

### artifact_storage_service.dart  (1893 Z.)
- `class ArtifactStorageService`
  - Function flushPendingEdits requestOpen listAllUserArtifacts loadArtifactById createArtifact updateArtifactWithEdits overwriteCurrentArtifact repairVersionChain _insertVersion rollbackArtifactsForMessages _rollbackOneArtifact _loadLatestRemainingSnapshot latestRemainingVersion computeOrphanBrackets filterOrphanSnapshotsInBrackets _findOrphanSnapshotsForMessages _removeArtifactFromCache deleteArtifactsByIds setAttachmentPath _emitChange _insertIntoCache _requireUser _ensureCacheForUser _validateArtifactId _validateContentSize _isDuplicateArtifactError _handleMissingArtifactSchema _isMissingArtifactSchemaError _encryptOrThrow _decryptMaybe changes activeChatId maxContentBytes activeArtifactNotifier panelOpenNotifier openRequestNotifier pendingInitialOpen currentMessageId forceRefresh +1

### artifact_tag_processor.dart  (142 Z.)
- `class ArtifactTagProcessor`  — Processes inline `<artifact>` tags emitted by the assistant. For each tag:
  - processTags _processOne _errorCall

### auth_service.dart  (205 Z.)
- `class AuthService`
  - signInWithPassword signUpWithPassword verifySignupOtp verifyRecoveryOtp _verifyEmailOtp resendSignupOtp _mapOtpException signOut
- `class AuthServiceException implements Exception`
  - message code codeEmailAlreadyRegistered codeOtpInvalidOrExpired codeOtpRateLimited

### auth_trace.dart  (84 Z.)
- `class AuthTrace`  — Why the app last stopped being signed in.
  - _append read clear settled prefsKey keep detail
- `void unawaited(Future<void> future)`  — Local `unawaited`, so this file pulls in nothing but what it uses.

### bash_sandbox.dart  (457 Z.)
- `typedef ApprovalCallback = Future<bool> Function(String command, String reason)`  — Callback type for approval dialogs
- `class BashSandbox`  — Sandboxed Bash Command Executor
  - loadSavedFolder setSandboxFolder clearSandboxFolder isSafeCommand getUnsafeReason _metaCharLabel isWithinSandbox _resolvedSandboxRoot _resolveThroughExistingParents _extractPathCandidates _isPathInsideSandbox execute _executeDirectly isConfigured sandboxFolder safeCommands dangerousPatterns forbiddenMetaCharacters

### chat_cache_search_text.dart  (41 Z.)
- `String? buildChatSearchText(String payload)`  — Build the searchable text of a chat payload: message text only.

### chat_dirty_store.dart  (197 Z.)
- `class ChatDirtyStore`
  - _key isDirty isPendingInsert revision load markDirty markSynced forget Function _persist reset ids readKv writeKv

### chat_history_builder.dart  (295 Z.)
- `class ChatHistoryBuilder`
  - foldAttachmentsIntoText _foldAttachmentsIntoText _dropPendingUserTurn entryText resolveHistoryImages includeRecentImages

### chat_mode_service.dart  (568 Z.)
- `enum ChatMode`
  - fast thinking custom
- `@immutable class ModeConfig`  — One mode's independent settings: which model, on which provider, at which
  - copyWith toJson reasoningOn modelId providerSlug reasoningEffort operator
- `class ChatModeService`
  - isDeepThinking defaultConfig isFireworksProvider reasoningLevelsForModel sanitizeReasoningForModel _clampToAllowed reasoningLabel _configKey loadConfig saveConfig hasStoredConfig setModelForMode setReasoningForMode setProviderForMode load save parse defaultModelId defaultProviderSlug reasoningOff reasoningOn reasoningLevelsGraded reasoningLevelsAll reasoningLevelsFireworks fallbackMode supportsReasoning

### chat_model_selection_service.dart  (118 Z.)
- `@immutable class ChatModelSelection`
  - toJson fromJson modelId providerSlug
- `class ChatModelSelectionService extends ChangeNotifier`  — A model AND provider belong to one account/chat, never just to a model ID.
  - clearMemoryForTesting _account _key peek load _loadKey save resolveForSend instance

### chat_payload_codec.dart  (561 Z.)
- const: kChatPayloadVersion kChatPayloadVersionV2 _jsonFields _refKey _refToolCalls _refRoundThinking _versionPrefix _canonicalStringKeys
- `class DecodedChatPayload`  — A decoded chat payload: message maps in the v2 shape (the input of
  - messages customName version
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

### chat_payload_migration_service.dart  (938 Z.)
- `String bumpTimestampByOneMicrosecond(String timestamp)`  — `updated_at` + 1 µs, as Postgres wants it. Works on the web too, where a
- `@immutable class ChatMaintenanceProgress`  — Progress of a run, for the two bars of the maintenance screen.
  - copyWith migrated verified total
- `@immutable class ChatMaintenancePlan`  — What needs rewriting for one account.
  - total hasWork userId localIds cloud cloudKnown
- `enum ChatStartupCheck`  — What a normal start has to wait for, from local state only.
  - done background blocking
- `enum ChatMaintenanceOutcome`  — How a run ended.
  - complete cloudPending
- `class ChatMaintenanceFailure implements Exception`  — A run that failed. [restored] tells whether the cache backup was put back.
  - stage cause restored
- `abstract class ChatMigrationCloud`  — The cloud half, behind an interface so tests run it without Supabase.
  - listPlainEnvelopeChats readRow writeRow convert fingerprint ensureKey currentKeyVersion
- `class SupabaseChatMigrationCloud implements ChatMigrationCloud`  — [ChatMigrationCloud] over Supabase and [EncryptionService].
  - listPlainEnvelopeChats readRow writeRow convert fingerprint ensureKey currentKeyVersion
- `class ChatPayloadMigrationService`
  - _stateKey startupCheck checkCloudInBackground Function _migrateLocalRow _verifyLocalRow _migrateCloudChat _loadState _saveState _logIncompleteCheck isDone isCloudPending parallelism cloud readKv writeKv debugBeforeLocalVerify hasLocalDatabase needsKey
- `enum _CloudResult`
  - done skipped pending
- `class _MigrationState`  — Persisted progress of one account: the done flag, whether a check found
  - toJson done cloudPending skip
- `class ChatMaintenanceController extends ChangeNotifier`  — Drives the maintenance screen: plans, runs, and holds the app until the
  - noteRestoredSession ensureReady _check _run retry continueAnyway _release _set reset phase progress failure showsSyncHint holdsApp instance
- `enum ChatMaintenancePhase`
  - idle checking running failed done

### chat_preload_service.dart  (402 Z.)
- `class ChatPreloadService`  — Service for background preloading all chat messages.
  - startBackgroundPreload _fetchFromRemote _decryptAndStoreRows awaitPreload preloadNewChats reset isPreloading isPreloadComplete failureCount progress progressStream loadedCount totalCount fullyLoadedCount

### chat_reaction_service.dart  (91 Z.)
- `class ChatReactionService extends ChangeNotifier`  — Personal, device-local reactions. They are never sent as model feedback.
  - clearMemoryForTesting messageKey _key peek load _loadKey toggle instance

### chat_runtime.dart  (189 Z.)
- `@immutable class StreamingLive`  — Immutable snapshot of the assistant placeholder's live streaming body,
  - index text reasoning operator
- `class ChatRuntime`  — Per-chat in-memory live state.
  - touch setMessages appendMessage updateMessage removeMessageAt beginStream pushStreamingText endStream isIdle chatId messages isSending isStreaming streamingLive placeholderIndex modelId provider cancelHandler lastTouchedAt

### chat_runtime_registry.dart  (95 Z.)
- `class ChatRuntimeRegistry`  — Singleton registry of per-chat [ChatRuntime]s.
  - get lookup release clear _evictIdleIfNeeded isAnyStreaming streamingChatIds instance maxIdleRuntimes

### chat_storage_crud.dart  (1644 Z.)
- `class ChatStorageCrud`  — Handles CRUD operations for chat storage: save, update, delete, load.
  - extractTitleFromMessages _resolveStoredTitle _repairEncryptedTitleIfNeeded loadFullChat _syncChatFromRemote _loadFullChatFromCache loadFromCache _sidebarChatFromCacheRow _decryptChatRowsBatch loadChats _buildAndCachePlaintextRows _extractImagePaths _mapToChatMessages _writeLocalRow _customNameOf _payloadJson _digest saveLocal flushDirty _pushLocalCopy saveChat _doSaveChat _applyCloudWrite updateChat _queueUpdate _doUpdateChat deleteChat

### chat_storage_mutations.dart  (295 Z.)
- const: _kTitlesEncodeInBackgroundAt
- `class ChatStorageMutations`  — Handles chat mutations: star, rename, re-encrypt, export
  - setChatStarred renameChat reencryptChats exportChats exportChatsAsJson
- `String _encodeTitles(List<Map<String, Object>> data)`
- `Future<void> saveTitlesToCache(String userId, List<StoredChat> chats)`

### chat_storage_service.dart  (360 Z.)
- reicht weiter: 'package:chuk_chat/models/chat_message.dart' · 'package:chuk_chat/models/stored_chat.dart' · 'package:chuk_chat/services/chat_storage_state.dart' show initChatStorageCache
- `class ChatStorageService`  — Facade class providing backward-compatible API for chat storage.
  - getChatById getChatTimestamps loadFullChat hasLocalThread loadFromCache loadChats saveChat updateChat saveLocal syncChat flushDirty deleteChat loadSavedChatsForSidebar syncTitlesFromNetwork setChatStarred renameChat reencryptChats exportChats exportChatsAsJson mergeSyncedChat mergeSyncedChatsBatch removeChatLocally _isAgentsRow reset initialSyncComplete selectedChatIdNotifier selectedChatId isMessageOperationInProgress activeMessageChatId isLoadingChat savedChats changes debugCrudSave debugCrudUpdate debugCrudSaveLocal debugFlushDirty

### chat_storage_sidebar.dart  (558 Z.)
- const: _kSidebarApplyChunkSize _kSidebarIsolateParseThresholdChars
- `List<Map<String, Object?>> _parseSidebarTitleCache(String raw)`  — Parse cached sidebar title JSON into a typed list.
- `class ChatStorageSidebar`  — Handles sidebar-specific chat loading and title caching.
  - loadSavedChatsForSidebar syncTitlesFromNetwork _loadTitlesFromCache idsGoneFromServer _syncTitlesFromNetwork _decryptTitlesBatch _loadSidebarFromCache

### chat_storage_state.dart  (311 Z.)
- const: sharedPrefsInstance _legacyPrefsCleanupScheduled _kLegacyPrefsCleanupDelay
- `Future<void> initChatStorageCache()`  — Pre-initialize SharedPreferences at app startup for instant cache access
- `void _scheduleLegacyPrefsCleanup()`  — Move the two big blobs that used to live in SharedPreferences into the
- `String chatTitlesCacheKey(String userId)`  — kv_cache key holding the sidebar title list for [userId].
- `class ChatStorageState`  — Central state management for chat storage.
  - nextUpdateSeq markDeleted wasRecentlyDeleted getChatById notifyChanges notifyChangesImmediate checkNetworkStatus getChatTimestamps reset selectedChatId isMessageOperationInProgress isLoading savedChats changes chatsById changesController initialSyncComplete selectedChatIdNotifier activeMessageChatId isLoadingChat uuid savingChats pendingSaves latestUpdate lastWrite localDigest recentlyDeletedChats cacheLoaded loadingCompleter

### chat_storage_sync.dart  (482 Z.)
- const: _backgroundEncodeMinChars
- `class DeserializeResult`  — Internal class for deserialize results from isolate
  - messages customName
- `DeserializeResult deserializePayloadIsolate(String json)`  — Top-level function for background JSON deserialization
- `class ChatPayload`  — Internal class for chat payload
  - messages customName
- `Future<ChatPayload> deserializePayloadAsync(String json)`  — Deserialize chat payload in background isolate to avoid UI blocking
- `List<ChatPayload?> _deserializeBatchIsolate(List<String> jsonPayloads)`  — Top-level function for batch deserialization in a single isolate.
- `Future<List<ChatPayload?>> deserializePayloadBatchAsync( List<String> jsonPayloads, )`  — Batch deserialize multiple payloads in a single isolate (much faster
- `String chatTitleFromMessages(List<ChatMessage> messages)`  — The title a chat gets when nobody named it: its first user message,
- `String _encodeChatPayloadIsolate(_EncodeArgs args)`
- `class _EncodeArgs`
  - messages customName
- `Future<String> encodeChatPayloadAsync( List<ChatMessage> messages, String? customName, )`  — The v3 payload JSON of [messages], encoded off the UI isolate when the
- `Future<String> toChatPayloadV3Async(String json)`  — [json] (a payload of any version) as a v3 payload JSON. A v3 input is
- `class ChatStorageSync`  — Handles chat synchronization from cloud to local state.
  - mergeSyncedChat _upsertPlaintextCache mergeSyncedChatsBatch removeChatLocally

### chat_sync_service.dart  (446 Z.)
- `class ChatSyncService`  — Service for syncing chats between local state and Supabase.
  - start stop pause resume _syncTitlesOnResume syncNow _performAgentsSync _performSync isEnabled isSyncing hasCompletedFirstSync lastSyncAt lastSyncOutcome firstSyncComplete _initialSyncDelay

### chat_titles_prefs_cleanup.dart  (86 Z.)
- `class ChatTitlesPrefsCleanup`
  - run _runOnce keyPrefix putIfAbsent

### current_user.dart  (49 Z.)
- `abstract final class CurrentUser`  — Who is signed in, for the static caches that are keyed on it.
  - stillOwns id debugIdOverride

### customization_preferences_service.dart  (249 Z.)
- `class CustomizationPreferences`
  - copyWith toMap defaults fromMap userId autoSendVoiceTranscription showReasoningTokens showModelInfo showTps imageGenEnabled imageGenDefaultSize imageGenCustomWidth imageGenCustomHeight imageGenUseCustomSize includeRecentImagesInHistory includeAllImagesInHistory includeReasoningInHistory includeToolResultsInHistory toolCallingEnabled toolDiscoveryMode showToolCalls uiLocale chatFontSize chatFontFamily onboardingCompleted
- `String _sanitizeFontFamily(String? id)`
- `class CustomizationPreferencesService`
  - loadOrCreate save _table
- `class CustomizationPreferencesServiceException implements Exception`
  - message

### developer_options_service.dart  (206 Z.)
- `class DeveloperOptionsService`  — Cross-device developer options toggle.
  - initialize isEnabled setEnabled _saveRemote _extractPreferencesMap _extractRemoteFlag _coerceBool enabledNotifier forceRefresh

### device_services.dart  (728 Z.)
- `class DeviceServices`  — Singleton service providing access to native device features.
  - _ensureTimezones _getNotificationsPlugin getCurrentLocation getLastKnownLocation calculateDistance _createCalendarUrl _icsDateTime _googleDateTime _icsEscape _pad setAlarm setTimer cancelAlarm listAlarms _fireAlarmNotification _persistAlarms _formatDuration createSmsDraft createEmailDraft showNotification getPlatformCapabilities allDay

### diagnostics_log_service.dart  (5 Z.)
- reicht weiter: 'diagnostics_log_service_stub.dart' if (dart.library.io) 'diagnostics_log_service_io.dart'

### diagnostics_log_service_io.dart  (566 Z.)
- `class DiagnosticsLogService`  — Opt-in diagnostics logger that also works in release builds.
  - setAppInForeground initialize isEnabled setEnabled info warning error timing getLogFilePath clearLogs _parseLogLine _parseTimestamp _formatCompactEntry _write _ensureLogFile _appendRaw _rotateIfNeeded _encodeLine _sanitizeData _setFrameMonitoring _onFrameTimings maxLines lookbackMinutes

### diagnostics_log_service_stub.dart  (53 Z.)
- `class DiagnosticsLogService`
  - setAppInForeground initialize isEnabled setEnabled info warning error timing getLogFilePath clearLogs maxLines lookbackMinutes

### download_preferences_service.dart  (72 Z.)
- `class DownloadPreferencesService`  — User preferences for how downloaded files are saved across the app.
  - ensureLoaded _loadFromPrefs setAlwaysAsk setDefaultFolder shouldSkipPrompt defaultFolder alwaysAsk alwaysAskNotifier defaultFolderNotifier

### encryption_service.dart  (1237 Z.)
- const: kPlainEnvelopeVersion kCompressedEnvelopeVersion
- `String _cleartextToString(List<int> cleartext, Object? version)`  — The text of a decrypted envelope of [version].
- `void _checkEnvelopeVersion(Object? version)`
- `Future<String> sealChatPayload({ required String json, required List<int> keyBytes, required int keyVersion, bool allowB …)`  — Seal a chat payload JSON: compress it into a frame, encrypt the frame
- `Future<String> openEnvelopeText(String encrypted, List<int> keyBytes)`  — Decrypt an envelope of either version to its text. Pure, see
- `String? envelopeVersionOf(String encrypted)`  — The envelope version of [encrypted] without decrypting it, or null when
- `class _SealParams`  — Parameters for sealing a chat payload in the background.
  - json keyBytes keyVersion allowBzip2
- `typedef ChatEnvelopeV3 = ({ String envelope, String payloadJson, String fingerprint, })`  — The result of [convertChatEnvelopeToV3]: the new envelope, the v3
- `Future<ChatEnvelopeV3?> convertChatEnvelopeToV3({ required String encrypted, required List<int> keyBytes, required int k …)`  — Convert the chat payload envelope [encrypted] (any version) to a v3
- `Future<String> chatEnvelopeFingerprint( String encrypted, List<int> keyBytes, )`  — Decrypt a chat envelope and return the fingerprint of its messages.
- `class _FingerprintParams`
  - encrypted keyBytes
- `Future<String> _fingerprintInBackground(_FingerprintParams params)`
- `class _ConvertParams`
  - encrypted keyBytes keyVersion
- `Future<ChatEnvelopeV3?> _convertChatEnvelopeInBackground( _ConvertParams params, )`
- `Future<String> _sealChatPayloadInBackground(_SealParams params)`
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
  - _prefs _readLocalSecret _writeLocalSecret _deleteLocalSecret initializeForPassword initializeForPasswordReset tryLoadKey _syncMetadataInBackground Function clearKey encrypt decrypt encryptChatPayload convertChatPayloadToV3 chatPayloadFingerprintOf encryptBytes encryptInBackground decryptBytes decryptInBackground decryptBatchInBackground tryDecryptWithKey tryDecryptBatchWithKey deriveKeyFromPasswordAndSalt _ensureKey _deriveKey _randomNonce _constantTimeEquals _requireAuthenticatedUser _resolveCanonicalSalt _decodeBase64OrThrow _parseKeyVersion extractKeyVersion _updateUserMetadata currentKeyVersion hasKey _usePrefsBackend

### executor_provisioning.dart  (111 Z.)
- `class ExecutorHandle`  — Identifies one executor the app can hand its session to.
  - deviceId label
- `abstract interface class ExecutorTransport`  — The encrypted connect channel the app uses to reach an executor.
  - sendAuthentication
- `class UnimplementedExecutorTransport implements ExecutorTransport`  — Placeholder transport used until the encrypted relay is built. It throws so
  - sendAuthentication
- `class ExecutorProvisioning`  — Hands an executor the account authentication so it can spend the account's
  - provision provisionHostSession

### file_conversion_service.dart  (425 Z.)
- `class FileConversionService`  — Service for converting files to markdown using the /v1/ai/convert-file endpoint.
  - extractPageImages convertFile convertFileFromBytes _apiBaseUrl maxTokensPerFile maxCharsPerFile

### file_save_service.dart  (142 Z.)
- `class SaveResult`  — Outcome of a save attempt. Callers use this to drive snackbars or follow-up
  - success outcome path
- `enum SaveOutcome`
  - savedToFolder savedViaPicker savedViaShare cancelled failed
- `class FileSaveService`  — Centralised file-save entry point. Every download in the app should funnel
  - save _writeWithCollisionSuffix

### github_connection_service.dart  (251 Z.)
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
  - _headers _uri status startConnect poll disconnect Function _detail

### github_oauth.dart  (465 Z.)
- `class GitHubOAuth`  — GitHub OAuth Service - Supports both OAuth App and Personal Access Token
  - loadSavedToken setPersonalToken setClientId startAuth completeAuth _saveToken logout getAccessToken getUser getRepo createIssue addComment redirectUri isAuthenticated isPersonalToken _authHeaders callbackPort authEndpoint tokenEndpoint apiBase scopes perPage state

### google_oauth.dart  (807 Z.)
- `class GoogleOAuth`  — Google OAuth Service - Backend-assisted flow for Gmail & Calendar APIs
  - startAuth completeAuth refreshAccessToken getAccessToken logout _getMessageDetail readMessage sendEmail getLabels listCalendars _fetchUserInfo _extractBody _decodeBase64Url _saveTokens _loadTokens redirectUri isAuthenticated userEmail _authHeaders callbackPort scopes maxResults calendarId

### image_compression_service.dart  (243 Z.)
- `Future<Uint8List> _compressImageInBackground(_CompressionParams params)`  — Top-level function for background image compression
- `class _CompressionParams`  — Parameters for background image compression
  - imageBytes maxDimension targetFileSizeBytes initialQuality minQuality
- `class ImageCompressionService`  — Service for compressing images with no size limit
  - compressImage detectImageFormat getFileSizeMB maxDimension targetFileSizeBytes initialQuality minQuality maxInputSizeBytes maxDecodedDimension

### image_storage_service.dart  (476 Z.)
- `class StoredImage`  — Represents a stored image with metadata
  - path name createdAt size
- `class ChatUsingImage`  — Represents a chat that uses a specific image
  - chatId chatName
- `String _utf8DecodeInBackground(Uint8List bytes)`  — Top-level function for UTF-8 decoding in background isolate
- `class ImageStorageService`  — Service for storing and retrieving encrypted images in Supabase Storage
  - _isLocalBlob clearFromCache clearCache getCached uploadEncryptedImage _downloadAndDecryptImageInternal deleteEncryptedImage listUserImages findChatsUsingImage uploadLocalBlob _deleteLocalBlob getImageSize imageExists _idOf _blobDir _fileFor onImageDeleted bucketName scheme bypassCache

### key_version_service.dart  (146 Z.)
- `class PreviousKeyInfo`  — Represents a previous encryption key's metadata.
  - toJson salt version
- `class KeyVersionService`  — Manages encryption key versions for password reset recovery.
  - getPreviousKeys promoteCurrentToPrevious removePreviousKey hasPreviousKeys getSaltForVersion deriveKeyForVersion _parseVersion _updateMetadata

### local_chat_cache_native.dart  (1124 Z.)
- `class LocalChatCacheService`
  - _getDb _compressExistingPayloads debugReset kvGet kvSet kvSetIfAbsent kvDelete _createSkillsTable skillRows upsertSkill deleteSkill replaceSkills buildPlaintextRow replaceAll upsert replacePayloadIfUnchanged _dbPath _backupPath idsNeedingPayloadUpgrade backupDatabase restoreBackup deleteBackup hasBackup updateUpdatedAtIfEqual loadRawById _toDbRows delete updateStarred loadMeta _fetchBatched count loadById ensureMigrated _cleanupOldPrefsData clear hasOldEncryptedCache migrateFromEncrypted _runMigrations _migrateV3File _migrateV2Prefs +8
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
  - debugReset kvGet kvSet kvSetIfAbsent kvDelete skillRows upsertSkill deleteSkill replaceSkills _loadSkills _persistSkills buildPlaintextRow replaceAll upsert delete updateStarred loadMeta count loadById ensureMigrated loadRawById idsNeedingPayloadUpgrade backupDatabase restoreBackup deleteBackup hasBackup updateUpdatedAtIfEqual replacePayloadIfUnchanged clear hasOldEncryptedCache migrateFromEncrypted _loadChats _persist _sanitizeRow limit

### message_composition_service.dart  (412 Z.)
- `class MessageCompositionResult`  — Result of message composition preparation
  - isValid errorMessage displayMessageText aiPromptContent accessToken providerSlug maxResponseTokens effectiveSystemPrompt images
- `class MessageCompositionService`  — Service for composing and validating chat messages before sending
  - Function _buildMessageContent resolveResponseTokenBudget _calculateTokenLimits
- `class _MessageContent`  — Internal class for message content
  - displayText aiPromptContent images
- `class _TokenLimits`  — Internal class for token limits
  - isValid errorMessage maxResponseTokens

### model_cache_service.dart  (228 Z.)
- `class ModelCacheService`
  - _migrateFromPrefs _runMigration debugClearMemo saveAvailableModels isCacheValid loadAvailableModels _copyOf displayNameFor saveSelectedModel loadSelectedModel saveProviderPreferences loadProviderPreferences updateProviderPreference clearProviderPreference clearAllForUser _selectedModelKey _providerPrefsKey

### model_capabilities_service.dart  (209 Z.)
- `class ModelCapabilitiesService`  — Service for determining model capabilities like vision and reasoning.
  - initialize _enqueueLoad _loadIntoMaps supportsImageInputSync supportsReasoningSync supportsReasoningEffortSync isReasoningMandatorySync supportedEffortsSync reasoningDefaultEffortSync refresh revision

### model_prefetch_service.dart  (113 Z.)
- `class ModelPrefetchService`
  - prefetch

### multiplex_connection.dart  (1054 Z.)
- const: _uuid
- `class MultiplexException implements Exception`  — Error surfaced by [MultiplexConnection.tool] (and the chat stream's
  - detail code
- `String _newReqId()`  — Generate a fresh request id. ≤ 32 hex chars — comfortably under the
- `class MultiplexConnection`  — Multiplexed WebSocket client.
  - holdsAuthToken ensureReady _openAndAuthenticate updateAuthToken _flushQueuedAuthToken _onAuthRefreshed _onAuthRefreshFailed _onAuthRefreshNeeded _refreshAuthNow _sharedTokenFetch _scheduleAuthRefreshRetry _cancelAuthRefreshTimers _resolveWsUrl _startHeartbeat _onFrame _dispatchChat _dispatchTool chat tool cancel _sendCancel _send _handleTransportFailure _teardown hasActiveAuthToken hasPendingAuthRefresh hasQueuedAuthRefresh hasAuthRefreshRetryScheduled authRefreshFailures sinceLastInbound hasInFlight accessTokenProvider freshTokenProvider authRefreshFetchTimeout authRefreshReplyTimeout authRefreshRetryDelay baseUrl

### multiplex_session.dart  (527 Z.)
- const: _idleCloseDelay _staleReconnectThreshold
- `class MultiplexSession`
  - openForChat prewarm ensureCurrent closeForChat _scheduleIdleClose shutdown chatForChat _tokenProvider _freshTokenProvider _ensureAuthBridge pushAuthToken current currentChatId _hasActiveStreams timeout
- `class _ActiveChatStream`  — Per-chatId book-keeping for the single in-flight chat stream
  - controller subscription

### multiplex_tool_proxy.dart  (76 Z.)
- `class MultiplexToolOutcome`  — Result of [tryToolViaMultiplex]. Either holds a decoded body (when
  - isOk isError body fallback error
- `Future<MultiplexToolOutcome> tryToolViaMultiplex({ required String tool, required Map<String, dynamic> payload, })`  — Attempt to send a tool call over the multiplex socket. Designed so

### network_status_service.dart  (203 Z.)
- `class NetworkStatusService`  — Provides utilities for checking general internet reachability.
  - _checkWithParallelProbes _checkSingleProbe quickCheck _updateStatus resetFailureCount setOffline setOnline isNetworkError isOnlineListenable isOnline timeout
- `class _ConnectivityProbe`
  - uri headers expectedStatusCodes

### notification_service.dart  (46 Z.)
- `class NotificationService`
  - initialize requestPermission requestPermissions showCompletionNotification checkLaunchNotification cancelAll isInitialized

### notification_service_io.dart  (250 Z.)
- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)
  - initialize _createCompletionChannel showCompletionNotification _onNotificationTapped checkLaunchNotification requestPermission isInitialized maxLength

### notification_service_stub.dart  (38 Z.)
- `class NotificationService`  — Service for handling local notifications (completion notifications with deep linking)
  - initialize showCompletionNotification checkLaunchNotification requestPermission isInitialized

### oauth_loopback_server.dart  (158 Z.)
- `class OAuthResultPageTheme`  — Colours of the small page the browser shows after the redirect.
  - successColor errorColor background card border text
- `class OAuthLoopbackServer`  — Loopback HTTP server for the desktop OAuth redirect.
  - generateState start stop _handle _fail _respond _page redirectUri code port successTitle theme

### offline_queue_service.dart  (9 Z.)
- reicht weiter: 'offline_queue_service_web.dart' if (dart.library.io) 'offline_queue_service_native.dart'

### offline_queue_service_native.dart  (249 Z.)
- `class OfflineQueueService`  — Persistent offline send queue. Used by [OfflineRetryManager] to replay
  - _open init enqueue markFailed incrementAttempts remove listForChat listAll getById count watch _emit debugClearAll debugReset instance debugDatabasePath debugDatabaseFactory

### offline_queue_service_web.dart  (171 Z.)
- `class OfflineQueueService`  — SharedPreferences-backed persistent queue used on web where SQLite is not
  - _read _write init enqueue markFailed incrementAttempts remove listForChat listAll getById count watch _emit debugClearAll debugReset instance debugDatabasePath debugDatabaseFactory

### offline_retry_manager.dart  (372 Z.)
- `class SendExecutorResult`  — Outcome of a send executor call.
  - success error
- `typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg)`  — Performs the actual send for one queued message. Returns success or a
- `typedef OutboxFlush = Future<int> Function()`  — Agents: sends everything queued for the thread it was registered for, and
- `typedef HostReconnect = Future<void> Function()`  — Agents: gets the transport to try the host again, from scratch.
- `enum OfflineRetryEventType`  — Lifecycle event for retry attempts. Mostly useful for diagnostics + UI
  - started success failedNonRetryable failedDeferred noExecutor succeeded failed exhausted
- `class OfflineRetryEvent`
  - type queueId chatId error
- `class OfflineRetryManager`  — Watches connectivity and drains the offline queue when the device returns
  - init registerExecutor registerFlush registerReconnect retryNow _retryAgentsThread _hasQueuedMessages _emitThreadEvent _retryAll _retryOne _emit debugRetryAll debugReset events instance
- `class _RetryableError implements Exception`
  - message

### offline_send_coordinator.dart  (153 Z.)
- `class OfflineSendPayload`
  - toJson images chatId messageText modelId providerSlug systemPrompt imagesJson attachmentsJson attachedFilesJson maxTokens reasoningEffort
- `class OfflineSendCoordinator`  — Convenience wrapper around [OfflineQueueService] + [OfflineRetryManager].
  - enqueue _enqueueAgentsPrompt retryNow payloadFrom

### offline_send_executor.dart  (173 Z.)
- `class OfflineSendExecutor`
  - register _execute

### onboarding_tour_controller.dart  (1204 Z.)
- `enum _Step`  — Step in the interactive tour state machine.
  - welcome pointerMenu pointerSettings settingsPage pointerSettingsModelSelection pointerProviderPill pointerSettingsPricing pointerSettingsAiIdentity pointerSettingsAssistant finale
- `class TourNavigatorObserver extends NavigatorObserver`  — Navigator observer the controller installs on the root navigator. It
  - Function detach didPush didPop
- `class OnboardingTourController`  — Singleton controller for the interactive onboarding tour.
  - start cancel _finish _teardown notifySettingsSection _handleRoutePushed _handleRoutePopped _goTo _startMountWatch _stopMountWatch _onContinuePressed _onSkipPressed _onEndTourPressed _showOverlay _refreshOverlay _disposeOverlay _buildOverlayContent _slotFor _bodyKindFor isActive _stepAfterAiIdentity instance navigatorObserver
- `enum _BodyKind`  — Marker for which copy block the banner should show.
  - welcome settingsPage finale pointerProviderPill pointerMenu pointerSettings pointerSettingsModelSelection pointerSettingsPricing pointerSettingsAiIdentity pointerSettingsAssistant
- `class _TourModalCard extends StatelessWidget`  — Welcome / finale full-screen card with a scrim.
  - showLogo onPrimary onSkip bodyKind
- `class _TourBannerOverlay extends StatefulWidget`  — Overlay shown for pointer + page-banner steps. Reads the target slot's
  - slot bodyKind showContinue onContinue onSkip onEndTour useScrim absorbTargetTap
- `class _TourBannerOverlayState extends State<_TourBannerOverlay> with SingleTickerProviderStateMixin`
  - _onTick _headlineFor _bodyFor
- `class _PulsingRing extends StatefulWidget`  — Animated pulsing ring rendered at the target position. Never receives
- `class _PulsingRingState extends State<_PulsingRing> with SingleTickerProviderStateMixin`

### password_change_service.dart  (227 Z.)
- `class PasswordChangeService`
  - changePassword _rotateEncryptionForPasswordChange _tryRestoreEncryption
- `class PasswordChangeException implements Exception`
  - message

### password_reset_service.dart  (269 Z.)
- `class RecoveryException implements Exception`  — Exception thrown by password reset recovery operations.
  - message
- `class PasswordResetService`  — Service for recovering or deleting chats encrypted with old keys
  - getLockedChatInfo getRecoverableVersions recoverChatsWithOldPassword deleteLockedChats lockedChatCount

### password_revision_service.dart  (171 Z.)
- `class PasswordRevisionService`  — Keeps track of a password revision marker so that other sessions can detect
  - hasRevisionMismatch ensureRevisionSeeded bumpRevision clearCachedRevision _updateRemoteRevision _readRemoteRevision _cacheRevision _storageKey _prefs _readLocalValue _writeLocalValue _deleteLocalValue _usePrefsBackend

### payload_compression.dart  (146 Z.)
- const: _frameMarker _headerLength _bzip2MinBytes
- `class PayloadCodec`  — Codec ids of the frame. Never reuse a number: stored data carries it.
  - deflate bzip2
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
  - getCached clearFromCache clearCache upload delete bucketName bypassCache

### per_model_system_prompt_service.dart  (555 Z.)
- const: _kModelPromptSeparator
- `enum ModelPromptMode`  — How a per-model system prompt combines with the base (global + workspace)
  - off replace append prepend
- `ModelPromptMode _modeFromString(String? raw)`
- `String _modeToString(ModelPromptMode mode)`
- `@immutable class ModelPromptConfig`  — Per-model system prompt configuration.
  - copyWith isActive prompt mode
- `String? mergeModelPrompt({ required String? base, required String? modelPrompt, required ModelPromptMode mode, })`  — Pure helper: merge a per-model prompt into a base system prompt according
- `class PerModelSystemPromptService`  — Manages per-model system prompts.
  - _localKey _syncCacheToCurrentUser _dropLegacyLocalCache loadAll get save delete _loadFromLocal _decryptMap _persistAll _syncFromRemote _saveRemote debugReset debugStillOwns debugPrimeCacheForUser debugSyncCacheToUser localCacheKeyForUser debugCache legacyLocalCacheKey

### profile_service.dart  (85 Z.)
- `class ProfileRecord`
  - copyWith toMap fromMap id email displayName
- `class ProfileService`
  - loadOrCreateProfile saveProfile _table
- `class ProfileServiceException implements Exception`
  - message

### round_content_block_service.dart  (326 Z.)
- `class RoundContentBlockResult`
  - blocks interimOutputText
- `class RoundContentBlockService`
  - _lastReasoningMatches _tailMatches _blocksEqual _toolCallEqual isDuplicateOfEarlierTextBlock normalizeTextForCompare _mergeReasoning foldInterimIntoReasoning interimBeforeToolCalls

### service_credentials_service.dart  (212 Z.)
- `class ServiceCredentialsService`  — Syncs encrypted OAuth tokens (Google, GitHub, MCP connectors, etc.) to
  - save load throwOnError

### session_manager_service.dart  (256 Z.)
- `typedef SessionEventCallback = void Function()`  — Callback for session-related events
- `class SessionManagerService extends ChangeNotifier`  — Service for managing user authentication sessions and security
  - initialize _handleAuthStateChange _handleSessionActive _initializeUserSessionAsync _verifyPasswordRevisionInBackground _handleSessionInactive _handlePasswordRevisionMismatch _checkNetworkStatus _performLogoutCleanup performFullLogout instance isInitialized

### session_recovery.dart  (559 Z.)
- `@immutable class SessionStash`  — Session recovery through the paired host (bead cowork-2n1).
  - persistedSessionKey toAccountSession toJson fromJson fromPersistedSession _jwtExp secondsLeft clearPersisted accessToken refreshToken userId expiresAt prefsKey pending headroom
- `enum RecoveryOutcome`  — Why a recovery ended the way it did.
  - recovered tokenRejected unreachable
- `@immutable class RecoveryResult`  — What a recovery came back with.
  - isRecovered keepStash outcome session
- `bool isTransportFailure(Object? error)`  — True when [error] means the request never got an answer from GoTrue.
- `abstract interface class RecoveryLink`  — The relay side of a recovery, behind a small seam so the procedure is
  - Function provision
- `class AgentsRelayRecoveryLink implements RecoveryLink`  — [RecoveryLink] over a real [AgentsRelayClient] built from the app's stored
  - Function provision
- `class SessionRecovery`  — Runs one recovery: host first, own refresh token second, login page last.
  - _live _exchange _awaitLive _adopt _spendStash _refreshForHost _currentForHost run _sessionSource inFlight stash
- `class _RecoverySessionSource implements AccountSessionSource`
  - current refresh

### session_refresh_scheduler.dart  (144 Z.)
- `class SessionRefreshScheduler with WidgetsBindingObserver`  — The app's own access-token refresh, replacing gotrue's auto refresh
  - start stop _secondsLeft refreshIfDue isRunning instance defaultTick defaultReconnectGrace hostAttached reconnectHost refreshes

### settings_sync_service.dart  (65 Z.)
- `class SettingsSyncService`  — Central coordinator for cross-device settings sync.
  - forceRefresh

### slack_oauth.dart  (476 Z.)
- `class SlackOAuth`  — Slack OAuth Service
  - setCredentials _generateRandomString startAuth _startCallbackServer _buildCallbackHtml completeAuth getAccessToken _saveTokens _loadTokens isAuthenticated logout _apiGet _apiPost testAuth sendMessage findChannel redirectUri hasToken teamName teamId userId callbackPort authEndpoint tokenEndpoint apiBase userScopes types limit count

### streaming_chat_service.dart  (39 Z.)
- `class StreamingChatService`  — Service for handling streaming chat responses with Server-Sent Events (SSE).
  - maxTokens
- `class StreamingChatException implements Exception`  — Exception thrown when streaming chat fails.
  - message statusCode

### streaming_foreground_service.dart  (43 Z.)
- `class StreamingForegroundService`
  - initialize startService releaseKeepAliveLock updateNotification canStart isIgnoringBatteryOptimizations requestIgnoreBatteryOptimization isRunning hasKeepAliveLock startIfNeeded force

### streaming_foreground_service_io.dart  (307 Z.)
- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.
  - initialize startService releaseKeepAliveLock updateNotification canStart isIgnoringBatteryOptimizations requestIgnoreBatteryOptimization _stripMarkdown isRunning hasKeepAliveLock startIfNeeded force
- `@pragma('vm:entry-point') void _foregroundTaskCallback()`  — Callback for foreground task - we don't need to do anything here
- `class _StreamingTaskHandler extends TaskHandler`  — Minimal task handler - just keeps the service running
  - onStart onRepeatEvent onDestroy onReceiveData onNotificationButtonPressed onNotificationPressed onNotificationDismissed

### streaming_foreground_service_stub.dart  (71 Z.)
- `class StreamingForegroundService`  — Service to keep AI streaming alive when app is backgrounded or screen locked.
  - initialize startService releaseKeepAliveLock updateNotification canStart isIgnoringBatteryOptimizations requestIgnoreBatteryOptimization isRunning hasKeepAliveLock startIfNeeded force

### streaming_manager.dart  (5 Z.)
- reicht weiter: 'streaming_manager_stub.dart' if (dart.library.io) 'streaming_manager_io.dart'

### streaming_manager_base.dart  (702 Z.)
- `abstract class StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats.
  - Function beforeCompletion completionNotification onAllStreamsCancelled stopBackgroundServiceIfIdle onAppBackgroundChanged contentForSnapshot isStreaming phaseOf startedAtOf cancelStream cancelAllStreams cleanupStream completeStream evictStaleCompletedStreams onAppLifecycleChanged getActiveStreamsInfo getBufferedContent getBufferedReasoning getStreamingMessageIndex getTps getLatestMeta getNativeToolCalls hasCompletedStream consumeCompletedStream setBackgroundMessages getBackgroundMessages hasBackgroundMessages isAppInBackground hasActiveStreams activeStreams
- `class ActiveStream`  — One tracked stream: its subscription, buffers and bookkeeping.
  - cancelIdleTimer cancelUiThrottle subscription messageIndex chatId chatTitle contentBuffer reasoningBuffer isActive tps latestMeta nativeToolCalls startedAt firstTokenAt firstEventAt phase completedAt idleTimer silenceTimer lastEventAt eventCount heartbeatCount lastHeartbeatSeq uiThrottleTimer uiUpdatePending backgroundMessages modelId provider

### streaming_manager_io.dart  (403 Z.)
- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats
  - Function _armSilenceWatch _reportSilence beforeCompletion completionNotification onAllStreamsCancelled stopBackgroundServiceIfIdle contentForSnapshot _updateNotificationThrottled onAppBackgroundChanged _shouldShowCompletionNotification idleTimeoutEnabled silenceReportInterval

### streaming_manager_stub.dart  (54 Z.)
- `class StreamingManager extends StreamingManagerBase`  — Manages multiple concurrent chat streams across different chats
  - getNativeToolCalls Function

### streaming_transcription_service.dart  (244 Z.)
- `class StreamingTranscriptionService`  — Manages a WebSocket connection for streaming audio chunks to the
  - sendAudioChunk finishAndTranscribe abort _onMessage _onError _onDone _completeWithError _cleanup _wsUrl sampleRate

### supabase_schema_errors.dart  (22 Z.)
- `bool isMissingPreferencesColumn(PostgrestException error)`  — True when [error] says the `preferences` JSONB column is not there.

### supabase_service.dart  (232 Z.)
- `class SupabaseService`
  - initialize sessionNeedsRefresh forceRefreshSession signOut client auth isInitialized initializedListenable force

### system_tray_service.dart  (5 Z.)
- reicht weiter: 'system_tray_service_stub.dart' if (dart.library.io) 'system_tray_service_io.dart'

### system_tray_service_io.dart  (421 Z.)
- `class SystemTrayService with WindowListener`  — Desktop system tray integration for Linux, Windows, and macOS.
  - initialize _scheduleRetry _setTrayIconWithFallback _resolveTrayIconCandidates _materializeBundledTrayIcon _syncWindowVisibility _installMenu _destroyTray _toggleWindowVisibility showWindow hideWindow _startNewChat _quitApplication _rollbackInitialization _onTrayIconEvent onWindowClose _isDesktop _supportsTooltip _linuxTrayFallbackCandidates instance resetQuitFlag

### system_tray_service_stub.dart  (16 Z.)
- `class SystemTrayService`
  - initialize showWindow hideWindow instance resetQuitFlag

### theme_settings_service.dart  (162 Z.)
- `class ThemeSettings`  — The synced look. A theme pack is the three colours *plus* the contrast and
  - copyWith toMap defaults fromMap userId themeMode accentColor iconColor backgroundColor contrast uiFont dynamicColor
- `double? _clampContrast(Object? raw)`  — Null stays null — "never stored" is not the same as "stored as default".
- `String? _sanitizeUiFont(String? raw)`
- `class ThemeSettingsService`
  - loadOrCreate save _table
- `class ThemeSettingsServiceException implements Exception`
  - message

### title_generation_service.dart  (870 Z.)
- `class TitleGenerationService`  — Service for automatically generating chat titles using AI.
  - _settingsKey _systemPromptKey _syncCacheToCurrentUser _dropLegacyKeys isEnabled setEnabled getSystemPrompt setSystemPrompt resetSystemPrompt _isMissingTitleColumnsError _decryptRemotePrompt _resolveTitleProvider hasCustomSystemPrompt generateTitle generateAndApplyTitle _hasCustomName _stripWrappingMarkdown _normalizeGeneratedTitle _waitUntilChatAvailable _applyTitleWithRetry debugStillOwns debugPrimeCachesForUser debugSyncCacheToUser settingsKeyForUser systemPromptKeyForUser debugDropLegacyKeys _remoteSyncTtl debugCustomSystemPrompt debugAutoGenerateTitlesEnabled defaultSystemPrompt forceRefresh legacySettingsKey legacySystemPromptKey

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

### tool_call_handler.dart  (2162 Z.)
- const: _readOnlyToolNames repeatableLookupToolNames kRepeatedToolCallNote kToolsClosedNote kMaxToolRoundsPerTurn _kMalformedArgumentsKey
- `@visibleForTesting String toolCallIdentityKey(String name, Map<String, dynamic> arguments)`  — A key that is equal for two calls with the same name and the same
- `Object? _canonicalJson(Object? value)`
- `class ToolLoopSession`
  - latestUserMessage history accessToken enforcer toolCallingEnabled discoveryMode baseSystemPrompt discoveryContextKey modelId skipIdentity nativeToolCalling discoveredTools discoveredToolNames activeSkillNames toolCalls producedBlocks emptyFinalRecoveryAttempts malformedToolProtocolRecoveryAttempts truncatedCompletionRecoveryAttempts deferredActionRecoveryAttempts nonFinalTurnRecoveryAttempts factCheckRecoveryAttempts repeatedLookupRounds toolsClosed factCheckCandidate factCheckCandidateReasoning
- `class ToolLoopStep`
  - message history systemPrompt
- `class RoundSegment`  — One segment in the model's interleaved output for a single round.
  - isText isToolCall text toolCall
- `class ToolLoopResult`
  - shouldContinue nextStep finalContent finalReasoning interimContent interimBeforeToolCalls toolCalls interleavedSegments producedBlocks
- `class ToolTurnSignals`  — Provider/tool-loop hints extracted from stream metadata.
  - fromMeta _firstLowercasedString _readPath indicatesToolUse indicatesFinalStop indicatesTruncated stopReason finishReason rawMeta
- `class ToolCallHandler`
  - buildInitialSystemPrompt nativeToolDefinitions _buildSafetyLimitMessage _splitInterleavedSegments _countToolGroups _nativeCallsToParsed _appendRoundToHistory _updateDiscoveredTools _updateActiveSkills _applyPerModelPrompt _stripToolCallBlocks _extractPreToolText _extractRoundThinking _stripThinkingTags trailingToolCallBlockStart _trailingToolCallBlockStart _trailingToolCallBlockStartImpl _indexOfFirstToolCallBlock _hasInterimTextBeforeToolCalls looksLikeDeferredActionWithoutToolCall _looksLikeDeferredActionWithoutToolCall _lastSentence _isDeferredIntentSentence _cloneHistory _cloneToolCalls _restoreDiscoveryContext _storeDiscoveryContext _refreshDiscoveredToolDefinitions _pruneDiscoveryContextsIfNeeded toolExecutor toolCallingEnabled nativeToolCalls activeSkillNames
- `class _DiscoveryContextState`  — Per-chat context that survives across user turns (in memory only — it does
  - lastUsedAt discoveredToolNames activeSkillNames

### tool_enforcer.dart  (420 Z.)
- `class ToolEnforcer`  — Client-side Tool Call Enforcer (inspired by Kimi K2's Enforcer).
  - setDeclaredTools resetIteration reset checkForHallucination enforce _validateFindToolsArgs buildResultMessage _coerceMap alwaysAllowedTools maxIterations discoveryMode discoveredToolNames
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

### tool_executor.dart  (1472 Z.)
- const: _excalidrawSchemaText _technicalDrawingSchemaText _typstSchemaText _mermaidSchemaText _svgSchemaText
- `class ToolExecutionResult`
  - output isError producedBlocks
- `class ToolExecutor`  — Service to execute tools client-side.
  - _serverHeaders registerTool unregisterTool loadPreferences _loadPreferencesInternal _deferredSupabaseSync _safeCurrentUserId _syncToolEnabledPreferencesFromSupabase _syncSingleToolEnabledToSupabase _syncAllToolEnabledToSupabase isAlwaysOnTool setToolEnabled isToolEnabled getDefaultToolDescription getToolDescription hasCustomDescription setToolDescription resetToolDescription resetAllToolPreferences isToolAvailable isServiceConnected execute _executeBuiltin _executeArtifactManager _executeArtifactSchema _executeSkill _executeUpdateProject _executeAskUser _executeRequestMcpServer _placesResult looksLikeToolFailure _coerceInt serverHttpUrl tools allRegisteredTools allTools asserts currentChatId toolCategories sniff +1

### tool_image_result_service.dart  (510 Z.)
- `class ToolImageUpdateResult`
  - toolCalls imagePaths imageMetas imageCostEur imageGeneratedAt
- `class _ExtractionResult`
  - storagePath updatedPayload
- `class ToolImageResultService`
  - processToolCalls _ensureStoragePath _uploadFromDataUri _isPrivateHost _uploadFromUrl _currentUserId _downloadHeaders Function _tryDecodeMap _decodeMap _extractLeadingJsonObject _nonEmptyString _coerceDouble _coerceDateTimeIso

### tool_prompt_builder.dart  (1367 Z.)
- `class ToolPromptBuilder`  — Builds system prompts with tool calling protocol for LLM.
  - _migratedToSkill _buildNativeToolGuidance _buildActiveSkillSection _buildIdentitySection _buildAlwaysAvailableSection _dedupeToolsByName _appendAlwaysOnVisualTags _appendWeatherProtocol _appendNewsProtocol _answerFormatSection _visualOutputProtocol toolCallStart toolCallEnd discoveryMode isToolResult native allToolNames undiscoveredToolNames

### tool_registry.dart  (1814 Z.)
- const: _serverBackedToolNames toolCategoryMap discoveryCatalog builtinTools
- `bool _isMobileRuntime()`  — Whether the current platform is a mobile device (Android/iOS).
- `void registerBuiltinTools(ToolExecutor executor)`  — Register all built-in tools from [builtinTools] into a [ToolExecutor].

### tool_result_cache_registry.dart  (139 Z.)
- const: _uuid kCacheMissErrorCode
- `class _RegistryEntry`
  - id expiresAt
- `class ToolResultCacheRegistry`  — Process-wide registry mapping a previously-uploaded message string to the
  - shouldCache register refFor clear handleMiss _purgeExpired _evictIfNeeded _refsPaused length instance minContentLength now

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
  - _isNewerVersion _findDownloadUrl _getAssetPatterns launchDownload dismiss _isLinuxFull updateAvailable force
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
  - loadOverview _loadUsageEntries _loadBillingSnapshot _buildModelSummaries
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

### user_model_prefs_realtime_service.dart  (118 Z.)
- `class UserModelPrefsRealtimeService`
  - start stop _handleProviderChange _handleSelectedModelChange instance

### user_preferences_service.dart  (975 Z.)
- `class UserPreferencesService`
  - _syncCacheToCurrentUser saveSelectedModel refreshModelSelections loadSelectedModel forceLoadSelectedModel _fetchModelFromNetwork _syncModelFromNetwork clearSelectedModel saveSelectedProvider clearSelectedProvider loadSelectedProvider loadAllProviderPreferences invalidateProviderPreferencesCache noteRemoteSelectedModel invalidateSelectedModelCache _systemPromptCacheKey _dropLegacySystemPromptCache loadSystemPromptFast loadSystemPromptLocal _loadSystemPromptLocalForUser saveSystemPrompt loadSystemPromptForMount loadSystemPrompt clearSystemPrompt debugStillOwns debugPrimeCachesForUser debugSyncCacheToUser systemPromptCacheKeyForUser debugLoadSystemPromptLocalForUser debugSystemPromptMemCache debugSelectedModelCache debugProviderPreferencesCache debugCacheOwnerUserId legacySystemPromptCacheKey

### user_status_service.dart  (177 Z.)
- `class UserStatusService`
  - refresh clear _reset _fetch _readCache _writeCache _userId status forceRefresh

### websocket_chat_service.dart  (354 Z.)
- `class WebSocketChatService`  — Service for handling streaming chat responses.
  - declareStopIntent withdrawStopIntent _foldHistoryRefs _convertImagesToBase64 maxTokens

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
  - onWindowClose

### window_close_service_stub.dart  (5 Z.)
- `Future<void> initializeWindowCloseHandler()`

### workspace_file_upload.dart  (88 Z.)
- `class WorkspaceUploadOutcome`  — What came out of [pickAndUploadWorkspaceFile].
  - fileName error
- `Future<WorkspaceUploadOutcome> pickAndUploadWorkspaceFile({ required String workspaceId, required void Function(String f …)`  — Asks for a file and uploads it to [workspaceId].

### workspace_message_service.dart  (388 Z.)
- `class WorkspaceMessageService`  — Service for composing AI messages with workspace context
  - _estimateContentLength buildProjectSystemMessage _buildChatSummary _formatDate getProjectContextSummary hasContext estimateTotalFileTokens estimateProjectContextTokens getModelContextWindow contextUsageRatio fileContextRatio remainingFileTokenBudget maxTotalContentLength maxChatHistoryContentLength

### workspace_storage_service.dart  (1065 Z.)
- `class WorkspaceStorageService`  — Service for managing workspace workspaces, chat assignments, and file attachments
  - _notifyChangesImmediate loadFromCache _saveToCache loadProjects createProject updateProject deleteProject archiveProject getWorkspace getWorkspaceForChat linkChatToWorkspace addChatToProject removeChatFromProject getProjectChats uploadAvatar deleteFile decryptFile downloadFile updateFileContent updateFileMarkdown reset _isLoading projects activeProjects archivedProjects changes bucketName selectedWorkspaceId updateCache generateMarkdown

## lib/services/agents
### agent_control_source.dart  (496 Z.)
- `@immutable sealed class ControlValue<T>`  — One block of the control surface: known, loading, or not connected.
  - valueOrNull
- `@immutable class ControlAvailable<T> extends ControlValue<T>`  — The host reported a real value.
  - value
- `@immutable class ControlLoading<T> extends ControlValue<T>`  — A request is in flight.
- `@immutable class ControlUnavailable<T> extends ControlValue<T>`  — Nothing on the other side reports this yet. [reason] is shown to the user.
  - reason
- `@immutable class AgentSkill`  — One skill the agent can load on demand (§11).
  - copyWith name description enabled
- `@immutable class AgentModelChoice`  — The model this coworker's last run really used.
  - fromPayload detail id provider reasoningEffort
- `@immutable class AgentTokenUsage`  — What this coworker has spent, summed over the runs it really made.
  - fromPayload total runs lastRun
- `@immutable class AgentSessionRuntime`  — The coworker's clock: when it first ran, and how long it has been working.
  - _seconds fromPayload active runs running startedAt current
- `@immutable class AgentSandbox`  — The box this coworker works in (§6, bead cowork-jo2).
  - fromPayload isContainer kind container containerId workspace
- `@immutable class AgentControlSnapshot`  — Everything the control surface shows, one [ControlValue] per block.
  - copyWith model tokens runtime sandbox skills
- `abstract interface class AgentControlSource`  — The control surface's data source. One instance for the app; every call
  - snapshotFor refresh setSkillEnabled
- `class RelayAgentControlSource implements AgentControlSource`  — The production source: the host's own figures, over the relay.
  - snapshotFor _notifier refresh setSkillEnabled _unavailable _onController _onStatus _onSkills
- `class HostUnavailableControlSource extends RelayAgentControlSource`  — The name the shell constructs. It **is** [RelayAgentControlSource].
- `@visibleForTesting class FakeAgentControlSource implements AgentControlSource`  — A stand-in source with values in it.
  - snapshotFor _notifier refresh setSkillEnabled refreshed skillSwitches

### agent_file_saver.dart  (11 Z.)
- reicht weiter: 'agent_file_saver_base.dart' · 'agent_file_saver_stub.dart' if (dart.library.io) 'agent_file_saver_io.dart'

### agent_file_saver_base.dart  (29 Z.)
- `abstract interface class AgentFileSaver`  — Writes a received file somewhere the user can find it.
  - save
- `String sanitizeAgentFileName(String raw)`  — Reduces a name from the wire to a plain, single-segment file name.

### agent_file_saver_io.dart  (38 Z.)
- `class DownloadsAgentFileSaver implements AgentFileSaver`
  - save

### agent_file_saver_stub.dart  (18 Z.)
- `class DownloadsAgentFileSaver implements AgentFileSaver`
  - save

### agent_profile_store.dart  (281 Z.)
- `enum AgentAvatarShape`  — One coworker's display profile. Every field is optional: an agent with no
  - round oval roundedSquare square expressive cookie clover flower diamond gem triangle burst
- `@immutable class AgentProfile`
  - toJson fromJson _readShape isEmpty shape photoPath colorValue role brief clearPhoto
- `class AgentProfileStore extends ChangeNotifier`
  - profileOf load forget setPhotoFromFile _persist loaded instance clearPhoto

### agent_read_marks.dart  (175 Z.)
- `class AgentReadMarks extends ChangeNotifier`
  - lastRead isUnread isThreadUnread unreadCount unreadThreads load markRead forget flush _schedulePersist _runPersist _persist loaded instance persistDelay

### agent_roster_source.dart  (517 Z.)
- `abstract class AgentRosterSource extends ChangeNotifier`  — Read/write access to the roster, as a [ChangeNotifier] the UI listens to.
  - load hideAgent unhideAgent byId ensureHostAgent addAgent renameAgent markRunning markActivity setSchedule removeAgent flushPendingPersist agents deletedIds hiddenIds visibleAgents hiddenAgents ignore
- `class LocalAgentRosterSource extends AgentRosterSource`  — The roster the app ships with, kept in memory and cached on disk.
  - load _persist _schedulePersistActivity flushPendingPersist hideAgent unhideAgent byId ensureHostAgent renameAgent markRunning markActivity _withStoredActivity setSchedule removeAgent deletedIds agents hiddenIds attachmentNames ignore orNull
- `class AgentNameGenerator`  — Auto-assigned coworker names (§4): adjective-noun, the same shape the
  - adjectives nouns taken

### agent_roster_store.dart  (258 Z.)
- const: kAgentRosterPrefsKey
- `@immutable class AgentRosterSnapshot`  — What one launch reads back off disk.
  - isEmpty agents hidden deleted
- `class AgentRosterStore`
  - load saveRoster saveDeleted flush clear _schedule _persist _readAgent _readTime _readIds loaded instance

### agents_approved_devices.dart  (126 Z.)
- `class AgentsApprovedDevices`  — The executor's **local** set of device public keys it will accept frames
  - lookup isApproved approve revoke revokeAll toBase64Map base64EncodePublicKey _sameKey isEmpty isNotEmpty length deviceIds

### agents_backoff.dart  (59 Z.)
- `class AgentsBackoff`  — The delay curve for one kind of work.
  - delayAfter chat maxAttempts initialDelay maxDelay multiplier jitter

### agents_chat_core.dart  (20 Z.)
- const: debugAgentsChatCoreOverride

### agents_chat_transport.dart  (822 Z.)
- const: _taskSeq
- `class AgentsChatTransport`  — Service for handling streaming chat responses.
  - declareStopIntent withdrawStopIntent _takeStopIntent hasStopIntent _isReplay _toolOutcomeLine maxTokens
- `PendingTask _unrecorded(String sessionKey, String taskId)`  — The value a failed [AgentsPendingTasks.record] falls back to.
- `String mintTaskId()`  — Mints the id that names ONE send on the wire.
- `String _taskRejectionText(String? reason)`  — One plain sentence for a `task_ack` rejection.
- `Future<OutboxTask?> _queueForLater( String message, String sessionKey, Future<ChatModelSelection> selectedRoute, { Strin …)`  — Puts a prompt the socket would not take into the per-thread outbox.
- `Future<void> _queueAndMark( String message, String sessionKey, Future<ChatModelSelection> selectedRoute, { String? reaso …)`  — Queues the prompt, then marks the bubble it came from.

### agents_cloud_relay.dart  (767 Z.)
- const: kAgentsRelayPath kAgentsPairChannelParam kAgentsTargetDeviceParam kAgentsHealChannelParam
- `@immutable class AgentsCloudRelayAddress`  — A dial address for the cloud relay, expressed as a [Uri] so it fits the
  - toUri tryParse forRestoredTrust dialUri base pairingChannel targetDeviceId healChannel operator
- `class AgentsCloudRelayException implements Exception`  — Raised when the relay refuses the handshake or the pairing claim. The
  - message code
- `RelaySocketConnector agentsCloudRelayConnector({ required String deviceId, required AccountSessionSource sessionSource …)`  — Builds the app's production connector: cloud for `…/v2/relay/ws`, the plain
- `class AgentsCloudRelaySocket implements RelaySocket`  — A [RelaySocket] that speaks the cloud relay downward and the local blind
  - resetClaimCache learnedTarget _resolveSession _handshake _claimPairingChannel _healIfOffline _onlineExecutors _deviceIdFrom send _forward close _onTransportFrame _onTransportError _onTransportDone Function _authErrorText healInProgress targetDeviceId incoming debugHealInProgress address inner

### agents_controller_session.dart  (97 Z.)
- `class AgentsControllerSession`
  - resume _mac challenge ready deviceId identity trust nonce connection trafficKey authenticated

### agents_device_keys.dart  (115 Z.)
- `class AgentsDeviceKeys`  — Per-device Ed25519 identity helpers.
  - generate fromSeed fromSeedBase64 exportPrivateKeySeed exportPrivateKeySeedBase64 exportPublicKeyBase64 publicKeyFromBase64 fingerprint _decodeBase64 algorithm seedLength publicKeyLength fingerprintBytes

### agents_frame.dart  (334 Z.)
- const: kAgentsFrameVersion kAgentsFrameNonceLength kAgentsFrameSignatureLength kAgentsFrameMacLength _kDomain
- `enum AgentsFrameRejection`  — Why a frame was refused.
  - malformed unsupportedVersion deviceNotApproved badSignature keyVersionMismatch timestampOutOfWindow replayedSequence decryptionFailed
- `class AgentsFrameRejectedException implements Exception`  — Thrown whenever a frame is refused. Carries a machine-readable [rejection]
  - rejection detail
- `class AgentsFrame`  — A sealed Agents frame, as it travels over the relay.
  - buildHeaderBytes buildSignedBytes _addField toJson toJsonString _decodeBase64 headerBytes signedBytes version keyVersion deviceId seq ts nonce ciphertext sig

### agents_frame_codec.dart  (350 Z.)
- const: _cipher kAgentsChannelKeyLength
- `class AgentsFrameSealer`  — Seals outgoing Agents frames: AES-256-GCM under the account key, then an
  - seal sealText nextSeq deviceId
- `class AgentsFrameOpener`  — Opens incoming Agents frames, in this order:
  - open openText _logReject approvedDevices lastSeqByDevice

### agents_heal_channel.dart  (48 Z.)
- const: kAgentsHealChannelLabel
- `Future<String> deriveAgentsHealChannel( List<int> channelKey, String channelId, )`  — HMAC-SHA256(channelKey, label + channelId), url-safe base64, no padding:

### agents_host_session.dart  (109 Z.)
- const: kAgentsHostSessionPath
- `class AgentsHostSession`  — A session minted for the host. Key material: never logged, never stored.
  - fromJson accessToken refreshToken userId expiresAt
- `typedef AgentsHostSessionMinter = Future<AgentsHostSession?> Function(AccountSession appSession)`  — Mints a host session for the signed-in account. Null when it could not.
- `Future<AgentsHostSession?> mintAgentsHostSession( AccountSession appSession, { http.Client? client, String? baseUrl, Dur …)`  — The production minter: one POST with the app's own bearer token.

### agents_pairing.dart  (933 Z.)
- `enum AgentsPairingRole`  — Which side of the ceremony a session drives.
  - initiator joiner
- `enum AgentsPairingState`  — Ordered lifecycle. Illegal transitions and any use after a terminal state
  - created commitSent commitReceived pubkeySent keyEstablished confirmed completed aborted
- `enum AgentsPairingRejection`  — Why a pairing step was refused. Every value is a hard stop.
  - wrongState expired consumed malformed channelMismatch commitmentMismatch sasMismatch macMismatch badDeviceProof
- `class AgentsPairingException implements Exception`  — Thrown whenever a pairing step is refused, carrying a machine-readable
  - rejection detail
- `class AgentsPairingCrypto`  — Byte-exact protocol constants + pure crypto helpers, shared by both roles and
  - hkdf commitment transcript deriveSas deriveConfirmMac deviceMac deviceProofMessage deriveChannelKey constantTimeEquals x25519 ed25519 sasLabel confirmDLabel confirmCLabel deviceDLabel deviceCLabel deviceProofLabel commitLabel channelKeyInfo x25519PublicLength commitmentLength macLength channelKeyLength sasHkdfBytes defaultSasDigits defaultExpiryMs
- `class AgentsPairing`  — A single-use pairing session state machine for one role.
  - Function _require _checkNotExpired _abort createCommit onPubkey onConfirmD onCommit createPubkey onReveal onConfirmC confirmPeerSas createDeviceKey onPeerDeviceKey _maybeComplete _currentTranscript _establishKey _verifyConfirm _decodeKey _decodeBytes role state pairingCode channelId sas approvedDevices peerDeviceId channelKey sasDigits
- `int _wallClock()`
- `String _randomChannelId()`
- `String _randomDigits(int n)`
- `bool _isAllDigits(String s)`

### agents_pairing_restore.dart  (354 Z.)
- `enum AgentsPairingRestoreReason`  — Why the last restore pass ended the way it did. The shell reads it to say
  - mayStillRestore checking paired noSession keyLocked network localStoreFailed noCloudRecord decryptFailed noCloudRoute
- `class AgentsPairingRestore`  — Restores the account's pairing onto this device, and keeps trying until it
  - start nudge _end _listenForAuth _loop _attempt _waitBeforeRetry _defaultHasKey _hasCloudRoute _defaultLoadKey _defaultAuthChanges reason attempts isSettled kDefaultBackoff

### agents_pairing_store.dart  (226 Z.)
- `abstract interface class AgentsSecureKeyValueStore`  — The minimal secure key/value surface the store needs. Backed by
  - read write delete
- `class FlutterSecureKeyValueStore implements AgentsSecureKeyValueStore`  — Production backend over `flutter_secure_storage`.
  - read write delete
- `class AgentsDeviceIdentity`  — The app's stable long-term device identity.
  - deviceId keyPair
- `class AgentsStoredPairing`  — A persisted pairing: everything the app needs to reconnect with no code.
  - toJson tryParse hostUrl channelId channelKey peerDeviceId peerPublicKey
- `class AgentsPairingStore`  — Loads and saves the app's stable identity and single trust record.
  - loadOrCreateIdentity loadPairing savePairing loadPairingFromCloud readPairingFromCloud publishPairing clearPairing backend

### agents_pairing_uri.dart  (195 Z.)
- const: kDefaultAgentsRelayBase kAgentsPairingUriScheme kAgentsPairingUriHost
- `class AgentsPairingInvite`  — A parsed pairing invite: what to claim, what to prove, where to dial.
  - toUri tryParse _extractLink _fromUri _fromBareCode _resolveCode _relayBaseFrom codeDigits pairingChannel pairingCode relayBase operator

### agents_queued_marks.dart  (168 Z.)
- `typedef QueuedMarkReader = List<Map<String, dynamic>>? Function(String sessionKey)`  — Reads and writes the transcript. Tests replace both.
- `typedef QueuedMarkWriter = Future<void> Function(String sessionKey, List<Map<String, dynamic>> rows)`
- `class AgentsQueuedMarks`
  - markQueued clearMark marksIn isUserRole _statusName _lastUserRow Function _readFromStore _writeToStore readRows writeRows

### agents_reconnect.dart  (453 Z.)
- `enum AgentsReconnectRole`  — Which side of the reconnect a session drives. Same naming as §15 pairing.
  - initiator joiner
- `enum AgentsReconnectState`  — Ordered lifecycle. Any use after [authenticated] / [aborted] is refused.
  - created helloSent responseSent authenticated aborted
- `enum AgentsReconnectRejection`  — Why a reconnect step was refused. Every value is a hard stop.
  - wrongState malformed channelMismatch wrongPeer badSignature
- `class AgentsReconnectException implements Exception`  — Thrown whenever a reconnect step is refused, carrying a machine-readable
  - rejection detail
- `class AgentsReconnectCrypto`  — Byte-exact protocol constants + pure helpers, shared by both roles and the
  - transcript signedBytes randomNonce ed25519 proofILabel proofJLabel nonceLength
- `class AgentsReconnect`  — A single-use, code-free reconnect handshake state machine for one role.
  - initiator joiner _resolveNonce _require _abort _currentTranscript _sign _verifyPeer _checkPeerDevice createHello onResponse onHello onConfirm _decodeNonce _decodeBytes _constantTimeStringEquals role state channelId peerDeviceId authenticated
- `SimplePublicKey agentsReconnectPeerKeyFromBase64(String encoded)`  — Parses a peer public key stored in a trust record. Delegates the length +

### agents_relay_client.dart  (3267 Z.)
- const: kReplayPageSize
- `abstract interface class RelaySocket`  — A minimal duplex socket seam: an inbound stream of text frames and a way to
  - send close incoming
- `typedef RelaySocketConnector = Future<RelaySocket> Function(Uri url)`  — Opens a [RelaySocket] to [url]. Default is [defaultRelaySocketConnector];
- `Future<RelaySocket> defaultRelaySocketConnector(Uri url)`  — Production connector.
- `class _WebSocketRelaySocket implements RelaySocket`
  - send close incoming
- `enum AgentsRelayPhase`  — Where the relay client is in its lifecycle. Drives the UI directly.
  - idle connecting pairing paired error closed
- `@immutable class AgentsRelayState`  — Immutable snapshot of the relay client state, exposed as a [ValueListenable].
  - isPaired phase detail sas peerDeviceId operator
- `sealed class AgentsRelayInbound`  — A decoded, opened frame delivered from the executor into the thread.
- `class AgentsRelayHeartbeat extends AgentsRelayInbound`  — The host says the run for [sessionKey] is still running (wire `heartbeat`).
  - runId sessionKey seq elapsedSeconds
- `class AgentsRelayTaskAck extends AgentsRelayInbound`  — The host says what it did with one `task` frame (wire `task_ack`).
  - fromPayload isHeld isDuplicate isRejected isRetryable taskId status sessionKey runId reason
- `class AgentsRelayDelta extends AgentsRelayInbound`  — An assistant text delta.
  - text sentAt replay mid
- `class AgentsRelayUser extends AgentsRelayInbound`  — A user turn, only ever produced by a transcript replay (the server is the
  - text sentAt replay mid
- `class AgentsRelayReasoning extends AgentsRelayInbound`  — A reasoning delta — the model's thinking, which is a separate channel from
  - text sentAt replay mid
- `DateTime? epochSecondsToDateTime(Object? value)`  — A host clock value (unix seconds, float) as a local [DateTime]. Null for
- `class AgentsRelayTool extends AgentsRelayInbound`  — One tool call that ran, as reported by the executor.
  - _asText _asInt _asDuration name status arguments result detail exitCode timedOut duration failed replay mid argumentMap callId startedAt completedAt raw
- `class AgentsRelayFile extends AgentsRelayInbound`  — A file the agent produced and pushed into the thread (§9,
  - isImage isValid name mimeType declaredSize bytes error document replay mid
- `class AgentsRelayDone extends AgentsRelayInbound`  — The run finished. The executor reports why, and how many rounds it took.
  - workedFor wasStopped isReplay isHistoryEnd finalAnswer sessionKey hostNotified startedAt finishedAt firstMid lastMid hasMore oldestMid pageBeforeId reason iterations tokensSpent replay runId whileAway
- `class AgentsRelayRunState extends AgentsRelayInbound`  — The host's answer to a `replay`: is a run for this session in flight right
  - fromPayload isRunning sessionKey state runId startedAt prompt browserOpen vncAvailable
- `class AgentsRelaySubagent extends AgentsRelayInbound`  — A child agent's lifecycle step (§7.6). Only state transitions surface here —
  - isTerminal replay mid subagentId title state result error tokensSpent
- `class AgentsRelayAutomation extends AgentsRelayInbound`  — One state change of an automation (docs/WIRE_CONTRACT.md, "Automations"):
  - fromPayload event automation runId reason at replay mid
- `class AgentsRelayAutomationList extends AgentsRelayInbound`  — The host's answer to an `automation_list` request: every automation of
  - fromPayload automations sessionKey
- `class AgentsRelaySkillsList extends AgentsRelayInbound`  — The host's answer to a `skills_list` request or a `skill_control`
  - fromPayload skills errors
- `@immutable class AgentsRelayAgentStatus`  — What one coworker runs on, has spent and how long it has worked
  - _block fromPayload sessionKey model tokens runtime sandbox
- `@immutable class AgentsHostAgentName`  — One coworker name the host keeps for this pairing (bead cowork-817,
  - agentId name host operator
- `class AgentsRelayAgentList extends AgentsRelayInbound`  — The host's `agent_list`: every coworker name it keeps, sent once per attach
  - fromPayload agents
- `class AgentsRelayRoomTurn extends AgentsRelayInbound`  — One member's turn in a group room (§16.1). Streamed live as the room talks.
  - roomId round agentId handle text
- `class AgentsRelayRoomDone extends AgentsRelayInbound`  — A group-room exchange ended. [reason] is a raw stop string from the host
  - roomId reason messagesSent rounds
- `class AgentsRelayRoomHistory extends AgentsRelayInbound`  — A room's stored transcript, replayed on request (§16.1). Replaces whatever
  - roomId turns
- `class AgentsRelayRunError extends AgentsRelayInbound`  — The executor reported an error.
  - message
- `class AgentsRelayDebugContext extends AgentsRelayInbound`  — The raw context the executor sent to the model for one round, echoed back
  - sessionKey round payload
- `class AgentsRelayBrowserData extends AgentsRelayInbound`  — One raw RFB byte chunk of the live browser view (§9.1). Opaque on purpose —
  - bytes
- `class AgentsRelayBrowserView extends AgentsRelayInbound`  — Status of the live browser view: `started`, `stopped`, or `error` (§9.1).
  - status message reason password vncAvailable
- `class AgentsRelayApprovalRequest extends AgentsRelayInbound`  — The executor is asking the user to approve one here.now publish before it
  - fromPayload isDecided isApproved sessionKey replay mid decision decisionReason approvalId action path name fileCount totalBytes baseUrl public
- `class AgentsRelaySecretRequest extends AgentsRelayInbound`  — The model asked for secrets by name (`request_secrets`) and the run is
  - fromPayload requestId names purpose sessionKey
- `abstract interface class AgentsRelayController`
  - connect reconnect provisionAccount sendTask createRoom setRoomAgentToAgent sendRoomTask deleteRoom renameRoom createAgent renameAgent requestAgentList addRoomMember removeRoomMember requestRoomHistory requestStop requestReplay sendRunAck startBrowserView stopBrowserView sendBrowserData sendApprovalDecision sendSecrets state inbound establishedTrust
- `class AgentsRelayDocuments extends AgentsRelayInbound`  — The real transport. Also an [ExecutorTransport]: [provisionAccount] shapes
  - payload
- `abstract interface class AgentsDocumentsControl`
  - requestDocuments
- `abstract interface class AgentsAgentStatusControl`  — Asks the host what a coworker runs on and what it has spent
  - requestAgentStatus agentStatus
- `class AgentsRelayClient implements AgentsRelayController, ExecutorTransport, AgentsAutomationControl, AgentsDocumentsCon …)`
  - _effectiveSessionAdopter _reattach _publishAttachment channelIdOf connect reconnect provisionAccount _startAuthWatch _onAuthChange _reprovision _answerReprovisionRequest _adoptRotatedSession _answerHostSessionRequest _mintAndSendHostSession _reconnectDialUrl sendAuthentication setRoomAgentToAgent sendRoomTask deleteRoom renameRoom createAgent renameAgent requestAgentList addRoomMember removeRoomMember requestRoomHistory _openProvisionGate _awaitProvisionGate sendRunAck _maybeAutoReplay startBrowserView stopBrowserView sendBrowserData sendApprovalDecision sendAutomationControl requestAutomationList sendSkillControl requestSkillsList probeMcpServers requestAgentStatus +36

### agents_relay_link.dart  (89 Z.)
- `class AgentsRelayLink`  — Process-wide singleton joining the relay transport to the imported chat UI.
  - bind unbind reset inbound instance controller sessionKey

### agents_replay_guard.dart  (89 Z.)
- `class AgentsReplayGuard`  — Replay protection for one peer device: a strictly monotonic `seq` inside a
  - check commit _checkTimestamp _checkSeq lastSeq window

### agents_replay_loader.dart  (950 Z.)
- const: kReplayCursorPrefix kReplayTimestampCursorPrefix kReplayRepeatRepairKey
- `class _Draft`  — One session's in-progress replay fold.
  - sessionKey rows aiRow aiText aiReasoning aiToolCalls aiBlocks afterId beforeId hasMore oldestMid started next minMid maxMid
- `class AgentsReplayLoader extends ChangeNotifier`  — Folds the host's replay stream into the local instant-paint cache.
  - attach _enqueue detach load cursorFor revisionFor answerReadyFor answerReadyRunFor clearAnswerReady takeReplayWanted hostRunning hostPrompt reset _handle _draftFor _openAiRow _closeAiRow _noteMid appendWithoutRepeats _longestOverlap _rowKey _sameRow _commit _requestOlderPage appendNotice _cachedRows invalidateCursor advanceCursor _advanceCursor _persistCursor _blockForFile instance afterId repeatWindow

### agents_run_ledger.dart  (955 Z.)
- `ToolCall toolCallFromRelay(AgentsRelayTool event, {DateTime? now})`  — The renderer's shape of one host `tool` frame.
- `enum AgentsRunOutcome`  — How a run ended, once it is over.
  - answered stopped failed lost notDelivered
- `AgentsRunOutcome agentsRunOutcomeFor({String? reason, String? finalAnswer})`  — What a run terminal means for the thread, from the two fields that say it.
- `String? agentsRunEndNotice(AgentsRunOutcome outcome)`  — The one quiet line a run that produced nothing leaves in the thread. Null
- `class AgentsRun`  — Everything one run produced, in renderer shapes.
  - workedFor stopRequested taskUnproven endedWithoutAnswer sessionKey toolCalls blocks modelReasoning finalAnswer reason iterations tokensSpent runId debugContext running hostObserved startedAt finishedAt hostStamped firstMid lastMid detachedPrompt outcome stopRequestedAt probedAt lastActivity producedOutput taskId taskSentAt taskWaits taskAcknowledged sawHeartbeat
- `ToolCall subagentCallFromRelay( ToolCall? existing, { required String subagentId, required String title, required String …)`  — Process-wide ledger of host runs, keyed by session key.
- `ContentBlock artifactBlockFromFile(String storagePath, AgentsRelayFile file)`  — The renderer's shape of one relayed file, once its bytes are in the local
- `ToolCall approvalCallFromRelay( AgentsRelayApprovalRequest request, { bool decided = false, DateTime? now, })`  — The renderer's shape of a here.now publish approval, as a completed
- `class AgentsRunLedger extends ChangeNotifier`
  - sweep _sweepUnproven taskSent taskAcknowledged taskRejected runFor isRunning begin touch heartbeat stopRequested _endWithoutAnswer markLost reconcile adoptRunning reconcileIdle openTool recordTool subagent automation file approval reasoning debugContext finish take reset _ensure _live runningSessions instance ceiling ceilingGrace stopGrace storeFileBytes idleHeaderGrace taskAckCeiling maxTaskAttempts onTaskUnacknowledged onRunSilent +1

### agents_shell_status.dart  (129 Z.)
- `enum AgentsLinkState`  — The link as the thread view sees it.
  - starting unpaired connecting offline connected
- `@immutable class AgentsLinkReport`  — One snapshot of the link, published by the thread view for the shell.
  - initial state busy message operator
- `enum AgentsShellStatus`  — What the shell shows in place of a conversation.
  - starting notPaired lookingForComputer connecting healing offline noAgents ready
- `AgentsShellStatus resolveAgentsShellStatus({ required AgentsLinkReport link, required AgentsPairingRestoreReason restore …)`  — Resolves the one status the shell shows.

### agents_task_outbox.dart  (637 Z.)
- const: kTaskOutboxPrefix kPendingTaskPrefix
- `@immutable class OutboxTask`  — One prompt waiting for a socket.
  - isDue copyWith toJson fromJson localId sessionKey prompt createdAt modelId providerSlug reasoningEffort attempts lastError nextAttemptAt
- `class AgentsTaskOutbox`  — Reads and writes the per-thread queue. Static because there is one queue
  - _key Function _load _save enqueue pendingFor hasPending remove markAttempt clearForTest resetForTest maxAttempts backoff now read write delete
- `@immutable class PendingTask`  — One task the socket took, still waiting for the host's `task_ack`.
  - copyWith toJson fromJson taskId sessionKey prompt sentAt modelId providerSlug reasoningEffort attempts
- `class AgentsPendingTasks`  — Tasks the socket accepted but the host has not acknowledged.
  - _key _load _save record pendingFor clear Function mayRetry maxAttempts

### agents_tool_call_handler.dart  (158 Z.)
- `class AgentsToolCallHandler implements ToolCallHandler`  — The Agents fold: one pass per turn, no client-side tool dispatch.
  - buildInitialSystemPrompt nativeToolDefinitions toolExecutor instance toolCallingEnabled nativeToolCalls

### browser_presence.dart  (269 Z.)
- const: kBrowserPresenceFreshness
- `class BrowserPresence extends ValueNotifier<bool>`  — Whether the host explicitly offers a viewable sandbox browser.
  - toolPart effectiveName isBrowserTool stateFromTool stateFromView _onInbound _keep _onConnectionChanged reset value _isFresh parkedBecause controller freshFor playwrightPrefix toolCallWrapper closeTool openingReason staleReason because

### chat_debug_export.dart  (307 Z.)
- `abstract final class ChatDebugExport`  — Builds and copies the structured debug export for one thread.
  - _cap _toolCallJson _blockJson buildJson copyToClipboard plainTranscript _rowsFor _decodeToolCalls _decodeBlocks kind

### media_index.dart  (236 Z.)
- `enum MediaKind`  — What kind of thing an entry points at.
  - image file
- `@immutable class MediaEntry`  — One thing a coworker handed over.
  - toJson fromJson kind reference name threadKey mime sizeBytes at
- `List<Object?> contentBlocksOf(Map<String, dynamic> row)`  — The content blocks of a stored row.
- `class MediaIndex extends ChangeNotifier`
  - entries load ensureFor noteRows _persist clearForTest loaded instance

### room_source.dart  (214 Z.)
- `abstract class RoomSource extends ChangeNotifier`  — Read/write access to the app's rooms, as a [ChangeNotifier] the UI listens to.
  - byId renameRoom setAgentToAgent addMemberToRoom removeMemberFromRoom removeAgentFromRooms addRoom removeRoom rooms
- `class LocalRoomSource extends RoomSource`  — In-memory room source.
  - byId addRoom renameRoom setAgentToAgent removeAgentFromRooms addMemberToRoom removeMemberFromRoom removeRoom rooms

### schedule_spec.dart  (504 Z.)
- `enum ScheduleKind`  — The four schedule shapes Agents accepts.
  - interval cron oneShotAt oneShotIn
- `class ScheduleFormatException implements Exception`  — Thrown when a schedule string cannot be read.
  - message
- `@immutable class ScheduleSpec`  — A parsed schedule, plus the calculation of when it fires next.
  - parse tryParse describe _parseDuration _prettyDuration _plural _prettyDateTime _pad cron kind source interval at count
- `@immutable class _CronField`  — One field of a cron expression, expanded into the values it matches.
  - matches Function _positiveInt _boundedInt _plainInt values restricted
- `@immutable class _CronSchedule`  — A parsed 5-field cron expression and the forward scan over it.
  - parse _matchesDay nextRuns text minutes hours daysOfMonth months daysOfWeek

### supabase_pairing_sync.dart  (215 Z.)
- `class SupabasePairingSync`  — Reads and writes the encrypted trust-record mirror in Supabase.
  - saveEncryptedPairing publishEncryptedPairing loadEncryptedPairing readEncryptedPairing clearEncryptedPairing _ensureEncryptionKey table columnUserId columnCiphertext columnUpdatedAt
- `enum AgentsCloudPairingOutcome`  — How a read of the encrypted mirror ended.
  - found noSession noRecord keyLocked network decryptFailed
- `@immutable class AgentsCloudPairingRead`  — One read of the encrypted mirror: the record, or why there is none.
  - outcome pairing

### thread_preview_store.dart  (267 Z.)
- `@immutable class ThreadPreview`  — One thread's last line.
  - toJson fromJson text fromUser at
- `List<Object?> contentBlocksOf(Map<String, dynamic> row)`  — The content blocks of a stored row.
- `class ThreadPreviewStore extends ChangeNotifier`
  - of newestOf load ensureFor noteRows _lineOf _flatten _persist loaded instance

## lib/services/automations
### agents_automation.dart  (203 Z.)
- `@immutable class AgentsAutomation`  — One automation of a coworker: a schedule (cron / every / at) or a watcher
  - fromPayload toJson _int _epoch _stamp isSchedule isWatcher isActive isPaused isOver specLabel id sessionKey kind name state spec prompt nextFireAt lastFiredAt fireCount suppressedCount lastError logPath createdAt operator
- `abstract interface class AgentsAutomationControl`  — The two frames the app sends about automations. Kept apart from
  - sendAutomationControl requestAutomationList

### automation_ledger.dart  (74 Z.)
- `ToolCall automationCallFromRelay( ToolCall? existing, AgentsRelayAutomation event, { DateTime? now, })`  — The transcript line of one automation: ONE [ToolCall] per automation id,
- `String automationEventText(AgentsRelayAutomation event)`  — One line of English for an automation event, for the transcript card.

### automations_source.dart  (190 Z.)
- `class AutomationsSource extends ChangeNotifier`  — The app's copy of the host's automations, kept current from the relay.
  - attach identityOf _better forSession coworkerName liveForSession byId listed refresh control _onInbound _newestFirst reset all distinct instance

## lib/services/herenow
### herenow_store.dart  (104 Z.)
- `enum HereNowApproval`  — Whether a public publish must be approved each time (`ask`, the default and
  - fromWire wire ask auto
- `@immutable class HereNowSettings`  — The connector's settings: on/off and the approval mode.
  - copyWith toJson enabled approval
- `class HereNowStore`
  - load save forwardPayload prefsKey

## lib/services/mcp
### chuk_mcp_mirror.dart  (187 Z.)
- `@immutable class ChukMcpRow`  — One chuk row, decrypted: the connection as JSON and its secrets, if any.
  - toBlob fromBlob id connection secrets
- `abstract interface class ChukMcpMirror`
  - load save delete
- `class NoopChukMcpMirror implements ChukMcpMirror`
  - load save delete
- `class ChukMcpSync implements ChukMcpMirror`
  - serviceName load save delete _ensureEncryptionKey table columnUserId columnServiceName columnEncryptedData servicePrefix

### mcp_availability.dart  (33 Z.)
- `List<McpCatalogueEntry> unconnectedCatalogueEntries()`  — Every catalogue server the reader has NOT connected yet, in catalogue
- `McpCatalogueEntry? catalogueEntryById(String id)`  — The catalogue entry with this [id]. Null when no catalogue entry uses the

### mcp_catalogue.dart  (982 Z.)
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
  - initialize listTools callTool close _headers _notify _request _readSseReply _firstIcon sessionId endpoint accessToken timeout

### mcp_connection.dart  (216 Z.)
- `enum McpAuth`  — How a connection proves who it is.
  - parse oauth appSession apiKey
- `class McpTool`  — One tool a server offers. Kept minimal because Agents discovers the live
  - toJson fromJson name description inputSchema
- `class McpConnection`  — A configured MCP server. The non-secret config; the token or the API
  - toJson fromJson toolNameFor toForwardJson icon id name url description iconUrl tools checkedAt lastError addedByHand auth clearError

### mcp_connector_sync.dart  (142 Z.)
- `class McpConnectorSync`  — Reads and writes the encrypted connector mirror in Supabase.
  - save load clear _ensureEncryptionKey table columnUserId columnCiphertext columnUpdatedAt

### mcp_icon_cache.dart  (122 Z.)
- `class McpIconCache`
  - load _download _fileFor _openDirectory clear httpClient

### mcp_oauth.dart  (511 Z.)
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
  - canonicalResource resourceMetadataUrl challengeScopes resourceMetadataCandidates authServerMetadataCandidates discover register exchange refresh _token _getJson _uriOrNull _randomString clientName clientUri scopes

### mcp_probe_control.dart  (17 Z.)
- `abstract interface class McpProbeControl`
  - probeMcpServers

### mcp_redirect.dart  (12 Z.)
- reicht weiter: 'mcp_redirect_stub.dart' if (dart.library.io) 'mcp_redirect_io.dart'

### mcp_redirect_io.dart  (62 Z.)
- `class McpRedirectListener`  — A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
  - start _listen close _page redirectUri callback

### mcp_redirect_stub.dart  (23 Z.)
- `class McpRedirectListener`
  - start close redirectUri callback

### mcp_service.dart  (1312 Z.)
- const: kMcpProtocolVersion
- `enum McpConnectStatus`  — What a connect attempt ended in, for the UI to show.
  - connected cancelled failed
- `class McpConnectCanceler`  — A handle the screen keeps so it can stop a connect. On Agents the connect
  - cancel isCanceled whenCanceled
- `class _ConnectCanceled implements Exception`  — Thrown inside [McpService] when the user cancels the sign-in. Private: it
- `class McpConnectResult`
  - status message connection
- `class McpService`
  - resetForTest load pullRemoteForTest pushRemoteForTest _isAdoptDue _adoptOnce _pullOwnMirror _pullChukMirror _pushRemote _pushChukRows _chukRowFor _deleteChukRow _hasUsableRecord _isUsable connectByUrl disconnect _challengeFor _launch _closeBrowser _recordFromMirror applyRotatedCredentials verifyReachable verifyAllReachable _recordReachable _answersInitialize probe applyToolsFrame _applyOneCredential _connectionFromFrame connectionFor _isAcceptableEndpoint resolve call _clientFor _appSessionToken _endpointWithCredentials endpointWithCredentialsForTest hasAdopted store sync +14

### mcp_store.dart  (592 Z.)
- `class McpSecrets`  — Everything secret about one connection: the client this device registered
  - withTokens toJson _tokensJson fromJson isEmpty authServer credentials tokens issuer authorizationEndpoint tokenEndpoint scope
- `class McpListBackend`  — Where [McpStore] keeps the connection list: the SQLite kv_cache by
  - read write
- `class McpStore`
  - Function secretKey apiCredsKey load _loadUnlocked _decode _readRaw _moveToKv _saveAll upsert remove secretsFor setSecrets setToken tokenFor setApiCredentials apiCredentialsFor forwardPayloads _refreshedSecrets _refreshOnce _oauthBlock _urlWithCredentials prefsKey secretPrefix apiCredsPrefix list

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
  - pullAndReconcile

### mcp_tool_bridge.dart  (59 Z.)
- `void syncMcpTools(ToolExecutor executor)`  — Register the tools of every connected server, replacing whatever was
- `void watchMcpConnections(ToolExecutor executor)`  — Keep an executor in step with the connections for as long as it lives.
- `List<String> _tagsFor(String serverName, String id, String toolName)`  — What `find_tools` matches on: the server, and the words of the tool name.

## lib/services/notifications
### agents_notifications.dart  (106 Z.)
- `typedef ThreadLabelResolver = String Function(String sessionKey)`  — Resolves the label a toast carries for a thread — the coworker's name.
- `class AgentsNotifications`
  - onLiveDone onAnswerReplayed onOpenedFromNotification reset _inForeground instance threadLabel lifecycleOverride startPush

### local_notifications.dart  (327 Z.)
- const: kAgentsNotificationChannelId kAgentsNotificationChannelName kAgentsNotificationChannelDescription kAgentsNotificationIconAsset
- `abstract class LocalNotificationsBackend`  — What the service needs from the platform. The real one wraps
  - Function show cancel launchPayload requestPermission
- `class LocalNotifications`
  - initialize idFor payloadFor cancelForSession checkLaunchNotification requestPermission _onTap reset isInitialized instance brandColorValue body
- `class _PluginBackend implements LocalNotificationsBackend`  — The real backend: `flutter_local_notifications` on Android, iOS, macOS
  - Function show cancel launchPayload requestPermission _supported

### notification_router.dart  (79 Z.)
- `@immutable class NotificationTarget`
  - fromData sessionKey runId operator
- `class NotificationRouter`
  - open take reset instance pending

### push_service.dart  (353 Z.)
- `@immutable class PushMessage`  — A push message as the service sees it: only the `data` map matters.
  - target data
- `abstract class PushTransport`  — What the service needs from the push provider. [FirebasePushTransport]
  - initialize token initialMessage requestPermission onTokenRefresh onMessageOpenedApp
- `abstract class DeviceTokenStore`  — The `cowork_device_tokens` row.
  - upsert delete
- `class PushService`
  - Function _register _syncToken _unregister _route _defaultDeviceId _defaultUserId _defaultAuthStates _defaultPlatform reset isStarted registeredUserId instance
- `class SupabaseDeviceTokenStore implements DeviceTokenStore`  — `cowork_device_tokens` over the Supabase client (RLS: own rows only).
  - upsert delete table
- `class FirebasePushTransport implements PushTransport`  — Firebase Cloud Messaging. Only Android and iOS carry a push; everywhere
  - initialize token initialMessage requestPermission _pushPlatform onTokenRefresh onMessageOpenedApp
- `@pragma('vm:entry-point') Future<void> agentsPushBackgroundHandler(RemoteMessage message)`  — Runs in a background isolate when a push arrives while the app is not

### run_notifications.dart  (98 Z.)
- `typedef RunNotificationsWriter = Future<void> Function({ required String userId, String? sessionKey, String? runId, requ`  — Test seam: how a consume is written. The default talks to Supabase.
- `class RunNotifications`
  - Function consumeForSession consumeRun _consume _defaultUserId _defaultWriter instance table

## lib/services/secrets
### secrets_service.dart  (171 Z.)
- `typedef SecretsHostSink = Future<void> Function(SecretsSet set, {String? requestId})`  — Where a `secrets` frame goes. Defaults to the link's bound controller.
- `class SecretsService`
  - resetForTest _defaultHostSink load _loadOnce _publish set setMany remove answerUnchanged forwardToHost _forward instance revision isLoaded names forwarded

### secrets_store.dart  (162 Z.)
- `@immutable class SecretsSet`  — A snapshot of the set: the values and the revision they belong to.
  - has toJson fromJson names isEmpty values revision
- `class SecretsStore`
  - validName load _save replaceAll setMany set remove clear forwardPayload storageKey redactMinLength

### secrets_sync.dart  (127 Z.)
- `abstract interface class SecretsMirror`  — The pluggable half, so a test and a signed-out app can swap it out.
  - save delete load
- `class NoopSecretsMirror implements SecretsMirror`  — A mirror that does nothing. The default before sign-in and in tests.
  - save delete load
- `class SecretsSync implements SecretsMirror`
  - save delete load _ensureEncryptionKey table columnUserId columnName columnCiphertext columnUpdatedAt

## lib/services/settings
### debug_settings.dart  (41 Z.)
- `abstract final class DebugSettings`  — Reads and writes the developer debug toggles, so the settings page and the
  - captureContext setCaptureContext captureContextKey

### embedding_model_service.dart  (90 Z.)
- `class EmbeddingModelService`  — The embedding model the host uses for semantic memory (Mem0).
  - load save nameFor defaultModelId options
- `@immutable class EmbeddingModelOption`  — One embedding-model choice: an id, a display name, and its vector size.
  - id name dimensions

### mobile_chat_preferences.dart  (64 Z.)
- `class MobileChatPreferences extends ChangeNotifier`  — Mobile presentation only. Never changes the model's reasoning effort or
  - load _load setThinking setActivity setMessengerTypography _save instance reasoningKey activityKey typographyKey showThinking showActivity messengerTypography

### theme_controller.dart  (60 Z.)
- `class ThemeController extends ValueNotifier<ThemeMode>`  — The app's theme mode, persisted so the choice survives a restart.
  - load setMode _parse label

### verbose_service.dart  (82 Z.)
- `class VerboseService extends ChangeNotifier`  — The persisted verbose-view switch, as a [ChangeNotifier] singleton.
  - load setEnabled enabled loaded instance

## lib/services/skills
### agents_skill.dart  (94 Z.)
- `@immutable class AgentsSkill`  — One skill as the host lists it (docs/WIRE_CONTRACT.md, "Skills").
  - fromPayload copyWith isBuiltin name description source enabled path kSourceBuiltin kSourceWorkspace operator
- `abstract interface class AgentsSkillsControl`  — The two frames the app sends about skills. Kept apart from
  - sendSkillControl requestSkillsList

### skill_frontmatter_parser.dart  (241 Z.)
- const: _kSpecFields _kNamePattern _kFrontmatterPattern
- `class SkillParseException implements Exception`  — Thrown when a SKILL.md violates the spec.
  - message field
- `Skill parseSkillMarkdown( String source, { String? expectedName, SkillSource skillSource = SkillSource.builtin, })`  — Parses [source] (the full contents of a SKILL.md) into a [Skill].
- `Map<String, String> _parseMetadata(YamlMap parsed)`
- `List<String> _parseAllowedTools(YamlMap parsed)`
- `String _requireString(YamlMap parsed, String field)`
- `String? _optionalString(YamlMap parsed, String field)`

### skill_registry.dart  (115 Z.)
- `class SkillRegistry`
  - byName exists bySource setUserSkills _invalidate resetForTest all _index names builtinNames forceRefresh

### skill_settings_sync.dart  (88 Z.)
- `abstract interface class SkillSettingsMirror`
  - save load
- `class NoopSkillSettingsMirror implements SkillSettingsMirror`
  - save load
- `class SkillSettingsSync implements SkillSettingsMirror`
  - save load table columnUserId columnName columnEnabled columnUpdatedAt

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
  - hashOf _manifestUri _bodyUri _cacheFresh _readCachedManifest _parseManifest _fetchBody _applyCatalogSkill acceptSuggestion resetForTest suggestions forceRefresh

### skills_source.dart  (152 Z.)
- `class SkillsSource extends ChangeNotifier`  — The app's copy of the host's skill list, kept current from the relay.
  - attach byName refresh setEnabled _onInbound _reconcileMirror reset all builtin workspace errors listed instance

### user_skills_service.dart  (412 Z.)
- `class UserSkillException implements Exception`  — Thrown for storage-level failures. Spec violations surface as
  - message
- `class UserSkillsService`
  - _syncCacheToCurrentUser _nowIso _encodeEnvelope _decodeEnvelope _loadLocal _rowToSkill _refreshFromServer _decodeRows save delete resetForTest kMaxUserSkills forceRefresh

## lib/services/storage
### agents_chat_cache_migration.dart  (224 Z.)
- const: kReplayCursorPrefsPrefix kMigratedSuffix
- `typedef AgentsThreadWriter = Future<StoredChat?> Function( String sessionKey, List<Map<String, dynamic>> rows, { DateTim`
- `class AgentsChatCacheMigration`
  - reset migrateJsonCache dropOrphanCursors _hasLocalCopy _chatDir _jsonFiles _fileNameOf _markMigrated chatDirProvider hasLocalCopy writer

### agents_chat_storage_bootstrap.dart  (257 Z.)
- `class AgentsChatStorageBootstrap`
  - start stop flushNow _startFlushing _stopFlushing reset _onAuthState _signedIn _repair _signedOut _userId _supabaseAuthStream activeUserId flushInterval flushHook migrationHook authStream currentUserId onSignedInHook onSignedOutHook

### agents_chat_store.dart  (1479 Z.)
- const: kAgentsChatsTable _kReplayCursorPrefix kCloudOutboxPrefix kLastCacheUserKey _kFullColumns
- `typedef AgentsCloudUpsert = Future<Map<String, dynamic>?> Function( String userId, Map<String, dynamic> row, )`  — Signature of the cloud upsert. Injectable so the store is testable with no
- `typedef AgentsCloudSelect = Future<List<Map<String, dynamic>>> Function( String userId, { List<String>? ids, required St`  — Signature of a cloud read of [kAgentsChatsTable]. [ids] null reads every
- `@immutable class AgentsCloudThread`  — One Agents thread of the cloud, decrypted: what a password change re-seals.
  - id payloadJson title
- `class AgentsChatStore`
  - replaceThread saveDocumentSnapshot _retainQueueMarks _documentVersion _documentSnapshots _documentRow resolveCacheUserId rememberUser _loadRememberedUser loadThread _loadFromCloud pullFromCloud _skipPull _localTimestamps _decodeCloudRow deleteThread _supabaseDelete snapshotCloudThreads reencryptCloudThreads _supabaseUpdate pauseCloudWrites resumeCloudWrites _selectIdList _select _loadFromLocalCache hasThread isDirty flushOutbox pending reset Function _writeLocalCache _pushToCloud _supabaseUpsert _adoptServerTimestamps _saveTitles _outboxKey _loadOutbox _persistOutbox _markDirty +29
- `class _LocalCopy`
  - payloadJson title updatedAt
- `class _CloudRow`  — One decrypted `cowork_chats` row.
  - chat id row payloadJson messages customName

### chat_origin.dart  (72 Z.)
- `class ChatOrigin`
  - isAgentsThread claimAgentsThread reset agentsEnabled

## lib/theme
### theme_presets.dart  (365 Z.)
- const: kThemePresets
- `@immutable class ThemeVariant`  — One complete look: palette + contrast + font, for a single brightness.
  - accent iconFg bg contrast uiFont
- `@immutable class ThemePreset`  — A named pack with a light and a dark variant.
  - variantFor matches applyTo name light dark

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
  - parseExpression parseTerm parsePower parseUnary parsePrimary parseNumber _match _matchWord _evalFunction input pos
- `String _formatNum(num value)`  — Format a number: strip trailing .0 for integers.
- `num _toNum(dynamic v)`  — Safely convert dynamic to num.

### chat_search_tools.dart  (807 Z.)
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
- const: _networkTimeout _nominatimBaseUrl _osrmBaseUrl _defaultHeaders kMaxPlacesOnMap
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
  - url content truncated error
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
  - getOuterPath getInnerPath paint scale dimensions
- `Color agentAccent( BuildContext context, String agentId, { AgentProfileStore? store, })`  — The accent colour of a coworker: the picked colour, else the stable hue from
- `int _paletteIndex(String agentId)`  — A stable index into [kAgentAccents] from the agent id. Its own hash, so a
- `class ExpressiveFace extends StatelessWidget`  — A face for an identity the caller only knows as an id and a label — a room
  - id label size store dimmed
- `class AgentFace extends StatelessWidget`
  - presenceColor _build agent size showPresence store dimmed profileOverride

### agent_status.dart  (256 Z.)
- const: kStatusDotSizeFactor kStatusDotGap
- `String humanToolLabel(String rawName)`  — What one running tool is called, in words a reader recognises. The host's
- `String? workInProgressLabel(AgentsAgent agent, AgentsRun? run)`  — The words for the status line, or null while the coworker is simply idle
- `class StatusDot extends StatelessWidget`  — The presence dot of a status line, on ONE optical line with its words.
  - sizeIn color fontSize
- `class _BaselinedBox extends SingleChildRenderObjectWidget`  — A box whose baseline is its own bottom edge.
  - createRenderObject
- `class _RenderBaselinedBox extends RenderProxyBox`
  - computeDistanceToActualBaseline computeDryBaseline
- `class AgentStatusLine extends StatelessWidget`  — The line itself: the dot, and the words next to it.
  - _line _defaultSessionKey agent sessionKey ledger fontSize link

### agent_theme.dart  (77 Z.)
- `ThemeData agentTintedTheme( BuildContext context, String agentId, { AgentProfileStore? store, })`  — The app theme with the accent roles re-seeded from [agentId]'s colour.
- `class AgentTheme extends StatelessWidget`  — [child] under the colour of [agentId], rebuilt when the user edits that
  - agentId child store

### bubble_kind.dart  (68 Z.)
- `enum AgentBubbleKind`
  - answer work delivery problem
- `@immutable class AgentBubbleColors`  — The fill and the foreground for a coworker's bubble.
  - fill onFill
- `AgentBubbleColors agentBubbleColors(ColorScheme scheme, AgentBubbleKind kind)`
- `AgentBubbleKind agentBubbleKindFor({ required bool hasProblem, required bool hasMedia, required bool hasToolRuns, requir …)`  — Picks the kind from the facts a bubble has.

### bubble_shape.dart  (99 Z.)
- const: kBubbleRadiusBig kBubbleRadiusSmall kBubbleGapInGroup kBubbleGapBetweenGroups kBubbleGroupPause
- `enum BubblePosition`  — Where a bubble sits inside a run of consecutive same-sender messages.
  - single first middle last
- `double bubbleGapAbove({required bool startsNewGroup})`  — The gap above a block, from the flag the chat screens already carry.
- `BubblePosition bubblePositionFor(int index, int length)`  — The position of item [index] in a run of [length].
- `BubblePosition bubblePositionFromFlags({ required bool startsNewGroup, required bool endsGroup, })`  — The position derived from the two flags the chat screens already carry.
- `BubblePosition bubblePositionInStack({ required int index, required int length, required bool startsNewGroup, required b …)`  — Where one block of a message sits in the run, when the message draws more
- `BorderRadius bubbleRadius( bool isMine, BubblePosition pos, { double big = kBubbleRadiusBig, double small = kBubbleRadiu …)`  — The corner radii for a bubble at [pos]. [isMine] flips which side carries
- `String formatClock(int seconds)`  — Formats seconds as `m:ss` (75 → "1:15"). Used for voice clips.

### connected_group.dart  (187 Z.)
- `class ConnectedGroup extends StatelessWidget`
  - labels selected onSelected badges margin height outerRadius selectedRadius
- `class _Segment extends StatelessWidget`
  - label count selected height slop onTap

### day_divider.dart  (76 Z.)
- `bool sameCalendarDay(DateTime a, DateTime b)`  — True when [a] and [b] fall on the same calendar day.
- `String dayLabel(DateTime when, {DateTime? now})`  — The label for a day: "Today", "Yesterday", a weekday inside the last week,
- `class ChatDayDivider extends StatelessWidget`
  - when now

### expressive_screen.dart  (150 Z.)
- `class ExpressiveScreen extends StatelessWidget`
  - builder title titleWidget actions onBack showBack bottomBar backgroundColor barHeight

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
  - icon label subtitle color onTap enabled

### huge_icon.dart  (8 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/huge_icon.dart'

### icon_map.dart  (14 Z.)
- reicht weiter: 'package:chuk_chat/widgets/icons/icon_map.dart'

### message_stamp.dart  (115 Z.)
- `enum QueueMark`  — What the stamp adds next to the time.
  - none waiting failed
- `QueueMark queueMarkFor(ChatMessageStatus? status)`  — Maps the local delivery status onto the mark. `null` and `sent` are the
- `class MessageStamp extends StatelessWidget`  — The time, plus the queue mark when there is one.
  - time fg mark edited errorColor

### motion.dart  (530 Z.)
- const: kExpressiveDecelerate kExpressiveShort kSpatialSpring kEffectSpring
- `class MorphTap extends StatefulWidget`  — A surface that springs and morphs on press. Wrap ANY tappable element.
  - child onTap onLongPress color pressedColor shape pressedShape pressedOutline pressedOutlineWidth padding pressedScale instant hitPadding
- `class _MorphTapState extends State<MorphTap> with SingleTickerProviderStateMixin`
  - _instantDown _instantRelease _press _pressed
- `class _PressOutlinePainter extends CustomPainter`  — Draws [MorphTap.pressedOutline] along the shape the surface currently has.
  - paint shouldRepaint shape color width
- `class ExpressiveButton extends StatelessWidget`  — A fully rounded button that springs and morphs on press.
  - icon label onTap color onColor tonal dense
- `class ExpressiveIconButton extends StatelessWidget`  — The expressive icon target: a soft squircle that squashes a touch more
  - icon hugeIcon onTap color onColor size width tooltip semanticsId parked
- `class ExpressiveLoader extends StatefulWidget`  — The expressive spinner: a cookie blob that turns while its scallop depth
  - size color
- `class _ExpressiveLoaderState extends State<ExpressiveLoader> with SingleTickerProviderStateMixin`
- `class _BlobPainter extends CustomPainter`
  - paint shouldRepaint t color

### pill_geometry.dart  (102 Z.)
- `abstract final class PillGeometry`
  - inset segmentHeight tapSlop tapHeight height shellPadding segmentRadius radius filterInset filterSegmentHeight filterTapSlop filterTapHeight filterHeight filterSegmentRadius filterRadius filterShellPadding

### shapes.dart  (244 Z.)
- `class CookieShape extends ShapeBorder`  — A scalloped blob. [softness] 0 is a circle; about 0.2 is a deep scallop.
  - _build getOuterPath getInnerPath paint scale dimensions lobes softness rotation
- `int shapeIndexFor(String key)`  — A stable shape index from an identity [key] (an agent id). Same key, same
- `ShapeBorder expressiveShapeFor(String key)`  — [expressiveShape] keyed by identity instead of list position.
- `ShapeBorder expressiveShape(int i)`  — One curated silhouette per index.
- `class PolygonShape extends ShapeBorder`  — A regular polygon with rounded corners, inscribed in the box.
  - _build _towards getOuterPath getInnerPath paint scale dimensions sides cornerFactor rotation
- `double monogramDrop(ShapeBorder shape)`  — How far the monogram of a face has to sit below the middle of its box for

### staggered.dart  (90 Z.)
- `class StaggeredItem extends StatefulWidget`
  - delayFor index child motion
- `class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin`

### top_veil.dart  (94 Z.)
- `BoxDecoration topVeilDecoration(ColorScheme scheme)`  — The gradient itself, for surfaces that place their own bar (a pinned
- `class TopVeil extends StatelessWidget`
  - child fadeBelow
- `BoxDecoration bottomVeilDecoration(ColorScheme scheme)`  — The veil under a floating bottom bar: nothing at the top, heaviest at the
- `class BottomVeil extends StatelessWidget`  — [child] on the bottom veil, with room above it for the gradient to fade in.
  - child fadeAbove

### waveform.dart  (9 Z.)
- reicht weiter: 'package:chuk_chat/widgets/waveform.dart'

### working_dots.dart  (75 Z.)
- `class WorkingDots extends StatefulWidget`
  - color label
- `class _WorkingDotsState extends State<WorkingDots> with SingleTickerProviderStateMixin`

## lib/utils
### answer_blocks_parser.dart  (480 Z.)
- const: _kBlockNames _openRe _closeRe _partialCloseRe _alertRe _stepNumRe _stepLetterRe _lettersArgRe _numRe _rangeRe
- `enum AnswerBlockKind`  — The block kinds the renderer draws natively.
  - steps timeline scale alert
- `sealed class AnswerSegment`  — One slice of a message: Markdown text or a parsed block.
- `class AnswerTextSegment extends AnswerSegment`  — Markdown between the blocks, verbatim.
  - text
- `class AnswerBlockSegment extends AnswerSegment`  — A block with its raw body lines.
  - kind arg lines closed
- `bool _isFence(String line)`
- `List<AnswerSegment> splitAnswerBlocks(String text)`  — Splits [text] into Markdown and block segments.
- `enum StepPartKind`
  - text command warning
- `class StepPart`  — One piece of a step body. A [StepPartKind.command] part holds one or more
  - kind text
- `class StepItem`
  - label title parts
- `class StepsSpec`
  - title steps
- `String _letter(int index)`
- `StepsSpec parseSteps(String arg, List<String> lines)`
- `class TimelineEntry`
  - label text highlight
- `(String, String) splitKeyValue(String line)`  — Splits at the first `: ` (colon and space), so `12:30: Lunch` keeps its
- `List<TimelineEntry> parseTimeline(List<String> lines)`
- `class ScalePoint`
  - value raw label
- `class ScaleSpec`
  - fraction isKelvin min max unit ticks markers
- `double? parseLooseNumber(String s)`  — Reads the first number in [s]. Accepts `2700`, `2.700` and `2,700`
- `ScaleSpec? parseScale(String arg, List<String> lines)`  — Returns null when the block cannot be drawn (no range and fewer than two

### api_rate_limiter.dart  (248 Z.)
- `class RateLimitConfig`  — API rate limiting configuration for different endpoint types.
  - maxRequests timeWindow minRequestInterval chat fileConversion general
- `class RateLimitResult`  — Result of a rate limit check.
  - allowed errorMessage retryAfter requestsRemaining
- `class ApiRateLimiter`  — Manages API rate limiting with per-endpoint and per-user tracking.
  - checkRateLimit recordRequest getRequestsRemaining getTimeUntilReset clearUserHistory clearAllHistory _formatDuration logRateLimitStatus

### arch_helper.dart  (4 Z.)
- reicht weiter: 'arch_helper_stub.dart' if (dart.library.ffi) 'arch_helper_native.dart'

### arch_helper_native.dart  (43 Z.)
- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### arch_helper_stub.dart  (7 Z.)
- `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

### artifact_tag_parser.dart  (140 Z.)
- const: _artifactBlockPattern _artifactStartPattern _attrPattern _leadingCodeFence _trailingCodeFence
- `class ParsedArtifactTag`  — A single `<artifact>` tag parsed out of assistant text.
  - id type title content language matchStart matchEnd
- `List<ParsedArtifactTag> parseArtifactTags(String text)`  — Returns all complete `<artifact>` blocks found in [text]. Partial
- `String _stripWrappingFence(String content)`  — Strip a single surrounding "```lang\n … \n```" fence if present. Leaves
- `String stripArtifactTagsForDisplay( String content, { bool stripIncomplete = true, })`  — Strips complete `<artifact>...</artifact>` blocks from [content]. When

### automation_message.dart  (55 Z.)
- const: _headerPattern
- `class AutomationWake`  — A user turn that a fired automation produced, not a person.
  - id name operator
- `AutomationWake? parseAutomationWake(String text)`  — Reads the automation header off [text], or returns null when this is an

### build_info.dart  (50 Z.)
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
- reicht weiter: 'certificate_pinning_register_stub.dart' if (dart.library.io) 'certificate_pinning_register_io.dart'

### certificate_pinning_register_io.dart  (80 Z.)
- const: _trustedToolApiHosts
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

### debug_chat_formatter.dart  (276 Z.)
- `class DebugChatFormatter`  — Formats the full chat message list as a debug-friendly text string.
  - truncateForExport _noop _countImages _truncateForExport format maxContextValueChars maxReasoningChars maxMessageTextChars maxToolArgsChars maxToolResultChars maxAttachmentsChars

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
  - _calculateDelay shouldRetryError config

### favicon.dart  (97 Z.)
- `List<String> faviconUrls(String host, {int size = 64})`  — Where a site logo is fetched from, best source first.
- `class FaviconImage extends StatefulWidget`  — The logo of [host], falling back through [faviconUrls] and ending on a
  - host size fallbackColor borderRadius fallbackIcon
- `class _FaviconImageState extends State<FaviconImage>`

### file_upload_validator.dart  (461 Z.)
- `class FileValidationResult`  — File upload validation result.
  - isValid errorMessage fileSizeBytes mimeType
- `class FileUploadValidator`  — Utility for validating file uploads to prevent security issues.
  - validateFile _detectMimeType _isLikelyTextFile _validateArchive validateImageBytes _detectImageMimeFromBytes formatFileSize maxFileSizeBytes maxArchiveEntries maxArchiveUncompressedSize extensionToMimeTypes maxImageFileSizeBytes

### format_bytes.dart  (21 Z.)
- `String formatBytes(int bytes)`  — Formats a byte count for a reader: `842 B`, `1.5 KB`, `12 MB`.

### highlight_registry.dart  (98 Z.)
- const: allLanguages

### image_clipboard_service.dart  (37 Z.)
- `class ImageClipboardService`
  - copyImageBytes

### incomplete_markdown_links.dart  (21 Z.)
- `String presentIncompleteMarkdownLinks(String text, {required bool streaming})`  — Keep a partial streamed URL from filling the bubble with encoded bytes.

### input_validator.dart  (372 Z.)
- `enum PasswordStrength`  — Password strength levels.
  - weak fair good strong
- `class PasswordValidationResult`  — Result of password validation with detailed feedback.
  - isValid strength errorMessage suggestions hasMinLength hasUppercase hasLowercase hasDigit hasSpecialChar
- `class InputValidator`  — Input validation and sanitization utilities for security.
  - validateEmail validateMessageLength sanitizeFileName escapeFileNameForDisplay validateAndSanitizeMessage _getFileExtension _formatNumber validatePasswordStrength validatePassword safeHttpUri safeTelUri safeGeoUri maxMessageLength maxEmailLength maxFileNameLength minPasswordLength

### io_helper.dart  (4 Z.)
- reicht weiter: 'io_helper_stub.dart' if (dart.library.io) 'io_helper_io.dart'

### io_helper_io.dart  (5 Z.)
- reicht weiter: 'dart:io' show File, Directory, Platform, Process, SocketException, HttpException

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

### lenient_json.dart  (84 Z.)
- `String stripTrailingCommas(String source)`  — Remove commas that sit directly before `}` or `]`, outside of any string.
- `String stripCodeFence(String source)`  — Strip a markdown fence (```json … ```) around a JSON body.
- `Object? tryDecodeLenientJson(String source)`  — Decode a JSON value a model wrote, repairing only a fence and a trailing
- `Map<String, dynamic>? tryDecodeLenientJsonObject(String source)`  — The same, narrowed to a JSON object.

### lru_byte_cache.dart  (86 Z.)
- `class LruByteCache`  — LRU (Least Recently Used) cache with a maximum total byte size.
  - get containsKey put remove clear _evictOldest currentSizeBytes length maxSizeBytes

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
- const: _scanPattern _minDigits _maxDigits
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
  - handleDioException _handleHttpStatusCode handleGenericException Function isNetworkError isAuthError isRateLimitError isServerError getRetryDelay

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
  - accentButtonForeground resolvedIconColor
- `@immutable class MaterialYouTokens extends ThemeExtension<MaterialYouTokens>`  — Material You extension tokens that aren't exposed on the default
  - copyWith lerp surfaceContainerLow surfaceContainer surfaceContainerHigh surfaceContainerHighest primaryContainer onPrimaryContainer secondaryContainer onSecondaryContainer tertiaryContainer onTertiaryContainer outline outlineVariant onSurfaceVariant success onSuccess successContainer onSuccessContainer warning warningContainer onWarningContainer
- `extension MaterialYouTokensX on ThemeData`
  - m3

### token_estimator.dart  (58 Z.)
- `class TokenEstimator`
  - estimateTokens estimatePromptTokens

### tool_detail_format.dart  (91 Z.)
- const: _markdownMarkers
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
  - isUploadAllowed recordUpload getUploadsRemaining getTimeUntilReset clearUserHistory clearAllHistory maxUploadsPerWindow timeWindowMinutes

### url_launcher_helper.dart  (22 Z.)
- `Future<void> launchExternalUrl(String url)`  — Opens [url] in the system browser.

## lib/widgets
### accent_icon_button.dart  (70 Z.)
- `class AccentIconButton extends StatelessWidget`  — A round, accent-filled icon button — one shared widget so the "new chat"
  - icon onTap tooltip semanticsId accent diameter iconSize

### agent_avatar.dart  (88 Z.)
- `class AgentAvatar extends StatelessWidget`
  - monogramOf hueOf seed label radius dimmed

### agent_control_panel.dart  (413 Z.)
- `class AgentControlPanel extends StatefulWidget`
  - showHeader showRefresh agent source onScheduleSubmitted
- `class _AgentControlPanelState extends State<AgentControlPanel>`
  - _buildModel _buildTokens _buildRuntime _buildSandbox _buildSkills Function _section _notReported _loading _sessionKey
- `String formatRuntime(Duration d)`  — `1h 04m` / `4m 12s` / `12s`.
- `String formatCount(int value)`  — `1 234 567` — grouped, so a six-figure token count is readable at a glance.
- `String formatTimestamp(DateTime when)`  — `2026-02-03 14:00` — stable and unambiguous, no locale guessing.

### agent_markdown.dart  (153 Z.)
- const: _chartBlock _chartStart _chartEnd
- `sealed class AgentSegment`  — One piece of an agent reply: prose, or a chart the agent asked for.
- `class AgentTextSegment extends AgentSegment`  — Markdown prose between the visual blocks.
  - text
- `class AgentChartSegment extends AgentSegment`  — A parsed `<chart>` block, already decoded to its JSON map.
  - data
- `Map<String, dynamic>? decodeChartBody(String body)`  — Decode a chart body, tolerating the two things a model gets wrong: a fenced
- `List<AgentSegment> splitAgentSegments(String data)`  — Split an agent reply into prose and `<chart>` blocks.
- `class AgentMarkdown extends StatelessWidget`  — Renders an agent reply as Markdown, with `<chart>` blocks drawn as charts.
  - _markdown data fontSize height selectable

### agent_roster_view.dart  (1534 Z.)
- reicht weiter: 'package:chuk_chat/widgets/coworker_name_dialog.dart'
- const: kSidebarBrandWordmarkSize
- `class DesktopRosterPins extends ChangeNotifier`  — Which coworkers the user pinned to the top of the desktop roster. Local to
  - isPinned load toggle _save reset ids instance
- `List<AgentsAgent> desktopRosterOrder( List<AgentsAgent> agents, Set<String> pinned, )`  — The agents in the order the desktop roster shows them: pinned first, then
- `class AgentRosterView extends StatefulWidget`
  - source onSelect selectedAgentId selectedThreadKey selectedRoomId onAddAgent onDeleteAgent onRenameAgent onOpenProfile onOpenRooms rooms onOpenRoom onCreateRoom onRenameRoom onDeleteRoom onManageRoomMembers onOpenSettings onOpenQuickSwitcher collapsed onToggleCollapsed accountLabel now readMarks profiles pins
- `class _AgentRosterViewState extends State<AgentRosterView>`
  - _onSearch _loadProfile _displayNameFor _now _isSelected _pick _renameAgent _deleteAgent _renameRoom _deleteRoom _item _openAgentMenu _openRoomMenu _openNewMenu _buildPane _header _searchField _sectionHeader _hiddenHeader _quietLine _emptyState _accountRow _buildRail _hosted _pins _marks _profiles _orderedAgents _rooms
- `class _SectionHeader extends StatefulWidget`  — A section label: small caps in the quiet colour, and a "+" that shows
  - label onAdd addTooltip
- `class _SectionHeaderState extends State<_SectionHeader>`
- `class _HoverTile extends StatefulWidget`  — The hover fill and the rounded row shape every roster row shares.
  - child height onTap selected onSecondaryTapUp onHover onContextMenu
- `class _HoverTileState extends State<_HoverTile>`
  - _setHover
- `class _AgentRow extends StatefulWidget`  — One coworker: 36 px, face 24, name; on the right the unread dot, the
  - agent selected unread pinned now profiles onTap onMenu shortcutIndex
- `class _AgentRowState extends State<_AgentRow>`
- `class _RoomRow extends StatefulWidget`  — One room: 32 px, the members' faces, the name, the "…" on hover.
  - room selected profiles onTap onMenu
- `class _RoomRowState extends State<_RoomRow>`
- `class _HiddenRow extends StatelessWidget`  — A hidden coworker, dimmed, with Unhide.
  - agent profiles onUnhide
- `class _RailFace extends StatelessWidget`  — A face in the folded rail: a 40 px target, the selected fill and bar, an
  - child tooltip selected unread onTap
- `class _KeyCap extends StatelessWidget`  — A key in a hint: "Ctrl+K" in a small outlined box.
  - label
- `String activityLabel(AgentActivity activity)`  — The word for a coworker's state, as shown in the roster.
- `String lastActivityLabel(DateTime? when, {required DateTime now})`  — "just now" / "5m ago" / "2h ago" / "3d ago", or a plain statement that
- `String compactAgeLabel(DateTime? when, {required DateTime now})`  — The roster row's time: "now", "5m", "2h", "3d" — or nothing when nothing

### agent_run_views.dart  (389 Z.)
- `class AgentToolLine extends StatefulWidget`  — One tool call, as a single quiet line that opens on tap.
  - call initiallyExpanded
- `class _AgentToolLineState extends State<AgentToolLine>`
  - _buildDetail _shortResult _oneLine _failureTag _formatDuration
- `class AgentReasoningBlock extends StatefulWidget`  — The model's thinking, kept apart from the answer.
  - text initiallyExpanded
- `class _AgentReasoningBlockState extends State<AgentReasoningBlock>`
- `class AgentFileCard extends StatefulWidget`  — A file the agent produced: a preview for an image, a save action otherwise.
  - file saver
- `class _AgentFileCardState extends State<AgentFileCard>`
  - _save _subtitle
- `String formatBytes(int bytes)`  — Formats a byte count the way a file manager does.

### agents_status_panel.dart  (276 Z.)
- `class AgentsStatusPanel extends StatelessWidget`
  - titleFor bodyFor _actions status message busy onAddComputer onReconnect onAddAgent footer topInset addComputerKey reconnectKey addAgentKey
- `class _Primary extends StatelessWidget`  — The one filled action. While [busy] it says what it is doing and ignores
  - label icon busy busyLabel onTap

### agents_thread_header.dart  (838 Z.)
- `enum AgentsThreadConnection`  — How the relay looks to the reader. Not the phase enum: the header only
  - live connecting down
- `@immutable class AgentsThreadAction`  — One button in the header's trailing group.
  - selected icon tooltip onPressed
- `class AgentsThreadHeader extends StatelessWidget`  — The one bar above a Agents thread: who you are talking to on the left, what
  - _buildDesktopBar _buildDesktopRow _buildDesktopSubject _buildDeskCall _buildDeskScreen _buildDeskMenu _buildRow _buildTitle _buildParkedCall _buildScreenTarget _buildAction _buildOverflow menuActions floating barHeight veilFade title subtitle connection automationLabel automationPaused automationExpanded onToggleAutomations actions leadingInset topInset dense agent onOpenProfile showCallTargets onOpenScreen
- `class _HeaderButton extends StatelessWidget`  — One header button: a 40 px round ink target with a tooltip.
  - icon tooltip onTap
- `class _AutomationChip extends StatelessWidget`  — The running automation, as small as it can be and still be read: a state
  - label paused expanded onTap
- `class _DeskSubjectTarget extends StatefulWidget`  — The title bar's subject as one hover target: a quiet fill under the
  - child onTap tooltip
- `class _DeskSubjectTargetState extends State<_DeskSubjectTarget>`

### agents_thread_view.dart  (2286 Z.)
- const: kAgentsDevHostUrl
- `class AgentsThreadView extends StatefulWidget`
  - controllerBuilder sessionSource onController pairingStore devHostUrl threadKey fileSaver onRunStateChanged onActivity onPaired onOpenModelScreen shellConfig title subtitle headerAgent onOpenAgentProfile onOpenAgentScreen actions menuActions leadingInset topInset phoneLayout linkReport emptyState
- `class AgentsThreadViewState extends State<AgentsThreadView> with WidgetsBindingObserver`
  - _readSwitchedThread _bootstrap _tryBuildController _warmCache _buildController _rebuildController _onStateChanged _flushOutbox _resendUnacknowledged _onTaskUnacknowledged _requestReplay _watchdogTick _scheduleAutoReconnect _reconnect openPairing _connect _persistTrust _pairFromInvite _pairingFailureText _connectionFailureText _connectionBanner _openPairingScreen _confirmForget _forget _loadVerbose _onVerboseChanged _onThemeChanged _onInbound _clearSecretRequest _submitSecretRequest _skipSecretRequest _decideApproval copyFullChat _onLedgerChanged _onRunClosed _releaseStaleComposer _onRunSilent _reconcileOnOpen _onLoaderChanged _onChatStoreChanged +23

### anchored_menu.dart  (405 Z.)
- const: _kAnchorGap _kEdgeMargin _kMinRoomAbove _kMenuDuration
- `Future<T?> showAnchoredMenu<T>( BuildContext anchorContext, { required List<Widget> items, required Color color, // Kept …)`  — Show [items] as a dropdown anchored to the widget of [anchorContext].
- `class _AnchoredMenuRoute<T> extends PopupRoute<T>`
  - buildPage _frame buildTransitions transitionDuration barrierDismissible barrierColor barrierLabel anchor items color borderColor minWidth maxWidth borderRadius preferAbove alignRight besideAnchor outlined usableTop usableBottom themes
- `class _AnchoredMenuLayout extends SingleChildLayoutDelegate`  — Puts the menu above the anchor when it does not fit below it. The child
  - getConstraintsForChild getPositionForChild shouldRelayout _roomBelow _roomAbove _forceAbove anchor maxWidth usableTop usableBottom alignRight besideAnchor preferAbove
- `List<List<Widget>> _splitOnDividers(List<Widget> items)`  — Splits a flat item list into runs at every divider, so a divider becomes

### answer_blocks.dart  (728 Z.)
- part of 'markdown_message.dart'
- `class _AnswerBlockStyle`  — Colours and type the blocks share, taken from the surrounding message.
  - markdown muted secondary hairline warn warnSoft bad termBg termDim textColor backgroundColor accent fontFamily baseFontSize dark termText
- `Widget _buildAnswerBlock(AnswerBlockSegment block, _AnswerBlockStyle s)`  — Builds the widget for one block. Throws only on a programming error; the
- `class _BlockFrame extends StatelessWidget`  — The frame of a block: a rule on top and an optional small-caps title.
  - title s child
- `class _StepsBlock extends StatelessWidget`
  - _step _part spec s
- `class _TerminalLines extends StatelessWidget`  — Command lines on a dark terminal card, with the code block's copy button.
  - commands s
- `class _WarningLine extends StatelessWidget`
  - text s
- `class _TimelineBlock extends StatelessWidget`
  - _entry title entries s
- `class _ScaleBlock extends StatelessWidget`  — A labelled band with ticks and a marker. Experimental: the prompt offers
  - _gradient _withUnit _marker _tick spec s
- `class _AlertBlock extends StatelessWidget`
  - type lines s

### api_availability_polling.dart  (51 Z.)
- `mixin ApiAvailabilityPolling<T extends StatefulWidget> on State<T>`  — Retries a failed model fetch once the API answers again.
  - onApiReachable startApiAvailabilityPolling stopApiAvailabilityPolling apiPollBaseUrl

### app_lifecycle_observer.dart  (59 Z.)
- `class AppLifecycleObserver extends StatefulWidget`
  - child onState
- `class _AppLifecycleObserverState extends State<AppLifecycleObserver> with WidgetsBindingObserver`

### app_notification.dart  (209 Z.)
- `enum AppNotificationKind`  — What kind of thing happened. Picks the glyph and the accent down the side.
  - info success error
- `class AppNotification extends StatelessWidget`  — The floating pill the app talks to the reader in.
  - _glyphColor _glyph message kind actionLabel onAction
- `SnackBar appNotificationSnackBar({ required String message, AppNotificationKind kind = AppNotificationKind.info, Duratio …)`  — The SnackBar an [AppNotification] travels in.
- `abstract final class AppNotifications`  — How a message reaches the screen.
  - kind duration

### artifact_panel.dart  (2169 Z.)
- `class ArtifactPanel extends StatefulWidget`
  - artifact onClose onOpenSourceChat showHeader
- `enum _ArtifactViewMode`
  - preview code
- `class _ArtifactPanelState extends State<ArtifactPanel>`
  - _loadChatArtifacts _switchActiveArtifact _onPendingVersionChanged _loadVersions _applyPendingInitialVersion _copyContent _availableFormats _bytesForFormat _captureVisualAsPng _showDownloadMenu _downloadMenuPosition _downloadAs _fileExtensionForArtifact _selectVersion _isViewingHistory _hasDualView _codeLanguageHint _effectiveContent _effectiveType _effectiveAttachmentPath
- `class ArtifactBottomSheet extends StatelessWidget`
  - onOpenSourceChat
- `class _TypeBadge extends StatelessWidget`
  - type
- `class _ArtifactRenderer extends StatelessWidget`
  - _buildVisualView _buildCodeView type content language attachmentPath artifactId title forceCodeView codeLanguageHint readOnly captureKey
- `class _ExcalidrawMarkdrawEditor extends StatefulWidget`  — Native cross-platform Excalidraw editor backed by the `markdraw`
  - jsonString artifactId title readOnly
- `class _ExcalidrawMarkdrawEditorState extends State<_ExcalidrawMarkdrawEditor>`
  - _scheduleAutoCenter _loadIntoController _applyTitleToController _registerFlusher _onSceneChanged _safeSerialize _persistAsNewVersion _centerCanvas _buildStack
- `class _TypstPdfRenderer extends StatefulWidget`  — Renders a Typst artifact's PDF. Prefers the persisted encrypted
  - source attachmentPath artifactId
- `class _TypstPdfRendererState extends State<_TypstPdfRenderer>`
  - _onHardwareKey _zoomUp _zoomDown _zoomReset _load _compile _backfillAttachment
- `class _ViewModeToggle extends StatelessWidget`  — Preview / Code toggle shown in the artifact header for types that support
  - mode onChanged compact
- `IconData _iconForType(ArtifactType type)`
- `class _ZoomableVisual extends StatefulWidget`  — Zoomable wrapper with +/- buttons for visual artifacts (SVG, drawings).
  - child
- `class _ZoomableVisualState extends State<_ZoomableVisual>`
  - _zoom _resetZoom
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

### attachment_preview_bar.dart  (1015 Z.)
- const: _kMaxExtensionChars _kImageCardSize _kImageCardBorderWidth
- `typedef AttachmentRemoveCallback = void Function(String fileId)`
- `typedef AttachmentCopyCallback = Future<void> Function(AttachedFile file)`
- `typedef AttachmentContentChangedCallback = void Function(String fileId, String newContent)`
- `class AttachmentPreviewBar extends StatefulWidget`
  - files onRemove onCopy onContentChanged
- `class _AttachmentPreviewBarState extends State<AttachmentPreviewBar>`
  - _onPointerSignal
- `class _ImageAttachmentCard extends StatelessWidget`
  - _buildThumbnail _openImageViewer file onRemove
- `class _RemoveButton extends StatelessWidget`  — The remove target on an attachment card.
  - onTap tooltip
- `class _DocumentAttachmentTile extends StatelessWidget`
  - file onRemove onCopy onContentChanged textColor accentColor cardColor
- `void _showDocumentPreview( BuildContext context, AttachedFile file, Color textColor, { AttachmentContentChangedCallback? …)`
- `class _DocumentPreviewDialog extends StatefulWidget`
  - file onContentChanged
- `class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog>`
  - _loadTextContent _loadPdfContent _startEditing _saveEdits _cancelEditing _buildContent _buildPdfViewer _buildTextViewer _buildEditor _buildEmptyState
- `Future<String?> _loadPlainTextContent(AttachedFile file)`
- `bool _isImageFile(String fileName)`
- `bool _isPdfFile(String fileName)`
- `bool _isPlainTextFile(String fileName)`
- `String _extensionLabel(String fileName)`
- `String _extractExtension(String fileName)`

### auth_gate.dart  (347 Z.)
- `class AuthGate extends StatefulWidget`  — The auth gate: swaps between the login screen and the messenger shell on
  - themeController stash authChanges currentSession recover retryDelay maxAttempts sleep pairingStore buildShell buildLogin
- `class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver`
  - _readCurrent _changes _onAuth _recoverThroughHost _startRecovery _sleep
- `class _RecoveringView extends StatelessWidget`  — Shown while the host is asked for the live session: a quiet wait, not a

### automation_card.dart  (226 Z.)
- `class AutomationCard extends StatefulWidget`  — One automation as a settings row: what it is, when it runs, what state it
  - automation onPause onResume onCancel compact
- `class _AutomationCardState extends State<AutomationCard>`
  - _actions _action _relative

### brand_wordmark.dart  (57 Z.)
- `class BrandWordmark extends StatelessWidget`  — Brand lockup rendered from the frozen brand SVG (assets/wordmark.svg,
  - color height

### browser_view_page.dart  (676 Z.)
- `class BrowserViewPage extends StatefulWidget`  — The live browser view (§9.1): watch and control the agent's sandbox
  - open controller sessionKey
- `class _BrowserViewPageState extends State<BrowserViewPage>`
  - _start _startLocalServer _restartStream _startLoopbackSocket _onRfbClient _resetBridge _safeAdd _onStreamStateChanged _onInbound _teardownBridge _toggleFullscreen _toggleKeyboard _webViewChrome _buildFrame _buildStream _hasPicture
- `class _StatusBanner extends StatelessWidget`
  - status message

### chart_widget.dart  (939 Z.)
- const: _defaultColors
- `Color? _tryParseColor(Object? raw)`  — Parse a hex color like "#FF5722", "FF5722" or "#CCFF5722" into a Color.
- `Color _colorAt(int index)`
- `Map<String, dynamic> normalizeChartData(Map<String, dynamic> raw)`  — Normalize the shorthand chart shapes the model may emit into the canonical
- `class ChartRenderer extends StatelessWidget`  — Top-level widget: parses a JSON map and picks the right chart builder.
  - tryParse _buildFooter _numField _labelsOf _pieItemsOf _datasetsOf _valuesOf hasPlottableData _maxYFromDatasets _formatAxisValue _buildChart _buildBarChart _buildLineChart _buildPieChart _buildDatasetLegend _buildPieLegend _buildScatterChart _buildRadarChart data targetTicks

### chat_composer_box.dart  (151 Z.)
- `class ChatComposerBox extends StatelessWidget`
  - field actions notices borderColor
- `class ChatComposerField extends StatelessWidget`  — The composer's text field, with the chat's typography and its borderless
  - controller hintText focusNode enabled minLines maxLines onSubmitted semanticsIdentifier

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
  - isCut countLabel spec total shown
- `DocumentChart documentChart( Map<String, dynamic> document, { int? maxPoints, bool withSource = true, })`  — Reads the chart out of [document].
- `DocumentChart _documentChart( Map<String, dynamic> document, { int? maxPoints, bool withSource = true, })`
- `String documentCellText(Object? raw)`  — One cell as [ChukTable] reads it. A bare URL becomes a markdown link
- `ParsedTable documentParsedTable(Map<String, dynamic> document, {int? maxRows})`  — A table document in the shape [ChukTable] draws.
- `ParsedTable _documentParsedTable( Map<String, dynamic> document, { int? maxRows, })`
- `Future<void> openDocumentLink(BuildContext context, String href)`  — Open a link out of a document cell, in the platform browser.
- `class InlineChatDocument extends StatefulWidget`  — A document, drawn in the thread in the coworker's bubble.
  - document borderRadius onOpen
- `class _InlineChatDocumentState extends State<InlineChatDocument>`
  - _open _meta _glyph
- `class _OpenAction extends StatelessWidget`  — The one action a cut document offers, in the app's button family: a tonal
  - label onTap
- `class _CutAtHeight extends StatelessWidget`  — Shows the top [maxHeight] of its child and fades the cut into the bubble.
  - maxHeight fade cut onCut child
- `class _HeightCap extends SingleChildRenderObjectWidget`
  - createRenderObject updateRenderObject maxHeight onOverflow
- `class _RenderHeightCap extends RenderProxyBox`
  - performLayout paint maxHeight onOverflow

### chat_document_view.dart  (680 Z.)
- `DateTime? documentUpdatedAt(Map<String, dynamic> document)`  — The agent stamps `updated_at` in epoch seconds — a float for chat documents,
- `String? documentFreshness(Map<String, dynamic> document, {DateTime? now})`  — How fresh a document is, as one short line: `v17 · 00:06`.
- `String documentFileStem(Object? title)`  — A file name for a document, from its title.
- `class ChatDocumentView extends StatefulWidget`
  - open _fileOf save share document showActions topInset
- `class _ChatDocumentViewState extends State<ChatDocumentView>`
  - _prose _table _chart
- `class _UpdatedMark extends StatelessWidget`  — The quiet end of "make an update legible": a mark, not a message. It never
- `class _DocumentCell extends StatelessWidget`
  - value expanded
- `class _DocumentScreen extends StatelessWidget`  — The phone presentation of a document: its own screen, a bar that floats on
  - document
- `class _MiddleEllipsis extends StatelessWidget`  — One line that loses its middle, not its end.
  - text style

### chat_documents_explorer.dart  (706 Z.)
- part of 'chat_documents_panel.dart'
- const: _kScopes _kScopeLabels
- `class _ExplorerOptions`
  - query scope folder grid
- `class _DocumentExplorer extends StatefulWidget`  — A view of the real catalog, never a second filesystem or fabricated tree.
  - documents owner selectedId onSelect options phone topInset banner
- `class _DocumentExplorerState extends State<_DocumentExplorer>`
  - _parts _setScope _buildPhone _buildCrumbs _buildWide _listItem _gridItem options grid
- `class _Crumb extends StatelessWidget`  — One step of the workspace path. It is a target, so it is the app's own
  - label icon onTap
- `class _SearchField extends StatelessWidget`  — The list's search input, in the shape the roster uses: one rounded filled
  - controller onChanged onClear
- `class _FileGridTile extends StatelessWidget`
  - document onTap

### chat_documents_panel.dart  (1237 Z.)
- part 'chat_documents_explorer.dart'
- const: _kTwoPaneWidth _kListWidth
- `class ChatDocumentsPanel extends StatefulWidget`
  - sessionKey controller fullPage coworkerName
- `class _ChatDocumentsPanelState extends State<ChatDocumentsPanel>`
  - _clean _connectionChanged _load _hasContent _adopt _request _requestCoworkerName _receive _persist _select _deselect _openFile _buildScreen _buildScreenList _buildScreenReader _buildHeader _buildScopeFooter _buildErrorBanner _buildErrorCard _buildTwoPane _buildOnePane _buildList _buildReader _owner _rows
- `class _GroupHeading extends StatelessWidget`  — A group heading with its count, in the shape the house uses for the sections
  - title count topInset
- `class _DocumentRow extends StatelessWidget`  — One list row, in the shape every other list in the app uses (the roster, the
  - document selected onTap
- `class _KindTile extends StatelessWidget`  — The square that carries a row's type glyph: the corner of the icon targets
  - document selected size
- `class _PillAction extends StatelessWidget`  — The app's labelled button, with an icon from the app's own set.
  - icon label onTap
- `String? _folderLabel(String path)`  — Where a workspace file sits, short enough for one line. Twenty skills all
- `String? _sizeLabel(Map<String, dynamic> document)`  — The house file-size wording, byte for byte the one the workspace file tiles
- `String _kindLabel(Map<String, dynamic> document)`
- `HugeIconData _documentIcon(Map<String, dynamic> document)`  — The glyph for a row, from the app's own set: the kind first, then the file
- `class _EmptyBlock extends StatelessWidget`  — The panel's one empty state, in the house shape: a large quiet icon, the
  - icon title detail action topInset
- `class _MiddleEllipsis extends StatelessWidget`  — A screen title that loses its middle, not its end.
  - text

### chat_maintenance_gate.dart  (303 Z.)
- `class ChatMaintenanceGate extends StatefulWidget`
  - child controller syncingHintDelay
- `class _ChatMaintenanceGateState extends State<ChatMaintenanceGate>`
  - _onChange _start _controller
- `class _Checking extends StatefulWidget`  — The app surface while the check runs. On a normal start that is a few
  - hintDelay showHint
- `class _CheckingState extends State<_Checking>`
  - _hint
- `class ChatMaintenanceScreen extends StatelessWidget`
  - _running _failure controller
- `class _ProgressRow extends StatelessWidget`
  - label count value

### chat_mode_selector.dart  (622 Z.)
- `class ChatModeSelector extends StatelessWidget`
  - iconFor labelFor descriptionFor _openModeMenu _openModelMenu _openReasoningMenu _headerRow _labelColor stripLabPrefix _agentsLook _glyphSize _customPointLabel _hasDeeperMenu agentsMenus flat mode onModeChanged onModelSelected onOpenModelScreen pickedModels selectedModelId modelLabel customModelLabel reasoningEffort reasoningLevels onReasoningEffortChanged showLabel height menuAbove kMaxModelsInMenu isSelected besideAnchor
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

### chat_reply_preview.dart  (113 Z.)
- `class ChatEditNotice extends StatelessWidget`
  - onCancel
- `class ChatReplyPreview extends StatelessWidget`  — A quiet quote above the composer, not a transport/status notification.
  - reply onCancel

### chat_theme.dart  (150 Z.)
- `abstract final class ChatMetrics`  — Shared look tokens for the Agents chat surface.
  - maxColumnWidth turnGap tightGap listPadding userBubbleRadius userBubblePadding userMaxWidthFactor assistantFontSize assistantLineHeight
- `class ChatPalette`  — Role-based colours for the transcript, derived from the active theme so the
  - assistantParagraph userBubble userText assistantText muted hairline copyIcon
- `class ChatAssistantTextTheme extends StatelessWidget`  — Wraps [child] so any Markdown inside it reads at the chat's paragraph size.
  - child
- `class ChatColumn extends StatelessWidget`  — Centres its [child] in the reading column: horizontally capped at
  - child

### chuk_table.dart  (1202 Z.)
- const: _delimiterCell _wholeCellLink _kEdgePad _kGutter _kMinTextWidth _kActionGlyph _kRowsSampled _kActionHeader _kMaxTextWidth _kRowPadY _kPinnedShare
- `class ParsedTable`  — One parsed markdown table plus the metadata needed to render it.
  - columnCount header rows alignments
- `List<String> _splitRow(String line)`  — Splits a single row of raw cell text on unescaped `|`, dropping the empty
- `List<String> splitTableRow(String line)`  — Public wrapper around row splitting, used by the markdown splitter to count
- `TextAlign _alignmentOf(String delimiter)`
- `bool isTableDelimiterRow(String line)`  — Returns true if [line] is a valid GFM delimiter row (`| --- | :-: |`).
- `ParsedTable? parseTable(List<String> lines)`  — Parses a block of lines (header, delimiter, body rows) into a [ParsedTable].
- `({String label, String href})? chukCellLink(String raw)`  — The label and target of a cell that is exactly one link, else null.
- `int chukVisibleLength(String raw)`  — The text a cell actually PAINTS, with the inline markdown taken off.
- `String chukVisibleText(String raw)`  — The same thing as a string: markers dropped, a link reduced to its label.
- `class ChukTable extends StatefulWidget`  — A rounded, dense, copyable rendering of a markdown table.
  - table textColor accentColor fontFamily fontSize surfaceColor onTapLink
- `class _Plan`  — The geometry of one drawn table: what each column gets, how tall a row is,
  - total widths collapsed natural scrolls rowHeight headerHeight
- `class _ChukTableState extends State<ChukTable>`
  - _releaseLinkTaps _readColumns _findLinkColumns _hostLabel _findHostLinkColumns _findCollapsedLinkColumns _asMarkdown _copy _bodyStyle _padLeft _padRight _paintedText _plan _computePlan _measurePlan _measuredLine _fitting _panning _pane _alignOf _boxAlign _cell _openAction _inlineSpans _headerStyle _rule _headerRule
- `class _CopyButton extends StatelessWidget`  — The copy control under a table.
  - copied color accent onTap

### chuk_table_classic.dart  (399 Z.)
- const: _kScrollbarLane
- `class ChukTableClassic extends StatefulWidget`  — Upstream's rounded-card table: a shaded, bold header row, thin row
  - table textColor accentColor fontFamily fontSize
- `class _ChukTableClassicState extends State<ChukTableClassic>`
  - _asMarkdown _copy _flexColumnWidths _visibleLen _estimatedNaturalWidth _cell _inlineSpans
- `class _CopyButton extends StatelessWidget`
  - copied color accent onTap

### composer_recording.dart  (184 Z.)
- `class ComposerInputRow extends StatelessWidget`  — Row one of the mobile composer: the text field, and — while the microphone
  - isRecording audioLevels accentColor timeColor child
- `class RecordingWaveformBar extends StatefulWidget`  — The open microphone: the live waveform, and the elapsed time beside it.
  - audioLevels color timeColor
- `class _RecordingWaveformBarState extends State<RecordingWaveformBar>`
  - _format
- `class ComposerSelectionControls extends MaterialTextSelectionControls`  — Selection controls for the composer that leave out the collapsed cursor
  - buildHandle instance

### coworker_name_dialog.dart  (179 Z.)
- const: _fieldBorder
- `Future<String?> showCoworkerNameDialog( BuildContext context, { required String title, required String submitLabel, Stri …)`  — Asks for a coworker's name. Returns the trimmed text, or null on Cancel.
- `class CoworkerNameDialog extends StatefulWidget`
  - title submitLabel initialName
- `class _CoworkerNameDialogState extends State<CoworkerNameDialog>`
  - _submit

### credit_display.dart  (897 Z.)
- const: _supabase _kCachedCredits _kCachedHasSubscription _kCachedFreeMessagesRemaining _kCachedFreeMessagesTotal _kCachedTotalCreditsAllocated _kCachedRemainingCredits _kCachedBillingPeriodStart _kCachedBillingPeriodEnd
- `class CreditBalances`
  - remainingRatio totalCredits usedCredits remainingCredits billingPeriodStart billingPeriodEnd
- `mixin _CreditListenerMixin<T extends StatefulWidget> on State<T>`
  - initCreditListener _loadCreditsFromCacheThenRemote _loadCreditsFromCache _saveCreditsToCache disposeCreditListener creditBalances creditLoading reloadSilently
- `class CreditDisplay extends StatefulWidget`
- `class _CreditDisplayState extends State<CreditDisplay> with _CreditListenerMixin<CreditDisplay>`
  - _formatDate
- `class CreditBadge extends StatefulWidget`
  - textStyle placeholderStyle padding
- `class _CreditBadgeState extends State<CreditBadge> with _CreditListenerMixin<CreditBadge>`
- `class BalanceBadge extends StatefulWidget`  — Smart badge that shows credits for subscribed users OR free messages for non-subscribed u…
  - textStyle placeholderStyle padding
- `class _BalanceBadgeState extends State<BalanceBadge>`
  - _dropReadyListener _initListener _loadFromCacheThenRemote _loadFromCache _saveToCache silent
- `class _MetaLine extends StatelessWidget`  — Two small captions on one line — the pattern used under both bars.
  - left right

### diff_widget.dart  (515 Z.)
- const: _kContextLines
- `enum _LineType`
  - added removed context
- `class _DiffLine`
  - type text counterpart oldNo newNo
- `class _Span`
  - text changed
- `class DiffWidget extends StatefulWidget`  — Renders a before/after comparison as a VS Code–style unified diff:
  - before after title type
- `class _DiffWidgetState extends State<DiffWidget>`
  - _lcsOf _lineDiff _foldContext _tokenise _wordDiff _typeLabel _buildFold _buildLine
- `class _Chip extends StatelessWidget`
  - label color

### document_viewer.dart  (120 Z.)
- `class DocumentViewer extends StatefulWidget`  — Document viewer for markdown-converted files
  - fileName markdownContent
- `class _DocumentViewerState extends State<DocumentViewer>`
  - _copyToClipboard _buildMarkdownView _buildEditView

### encrypted_image_widget.dart  (211 Z.)
- `class EncryptedImageWidget extends StatefulWidget`  — Widget that downloads, decrypts, and displays an encrypted image from storage
  - storagePath fit width height
- `class _EncryptedImageWidgetState extends State<EncryptedImageWidget>`
  - _listenForDeletion _loadImage

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

### expressive_settings.dart  (604 Z.)
- const: kExpressiveOuterRadius kExpressivePressedRadius kExpressiveInnerRadius kExpressiveTileGap
- `extension ExpressiveOnColor on ColorScheme`  — Picks the contrast colour of a tone from the scheme.
  - onColorFor
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

### floating_app_bar.dart  (254 Z.)
- const: kFloatingAppBarHeight kFloatingAppBarChip _kTitleRadius
- `EdgeInsets floatingHeaderInset(BuildContext context, {double extra = 0})`  — The room a scroll view has to leave above its first item so the floating
- `class FloatingHeaderButton extends StatelessWidget`  — A round floating chip for the header — the back arrow, and whatever a
  - icon onPressed tooltip color
- `class FloatingAppBar extends StatelessWidget implements PreferredSizeWidget`  — The header of a settings-style page: a floating back chip, a floating
  - _styledTitle preferredSize title actions leading automaticallyImplyLeading bottom

### floating_chrome_surface.dart  (84 Z.)
- `Color floatingChromeBase(BuildContext context)`  — One step off the page background — the colour a floating card takes so it
- `class FloatingChromeSurface extends StatelessWidget`  — The one surface every floating piece of chrome uses: the two bars of the
  - child radius borderRadius padding shape baseColor fillAlpha alpha

### fullscreen_text_editor.dart  (181 Z.)
- `Future<String?> showFullscreenComposer( BuildContext context, { required String initialText, String title = 'Compose', S …)`  — Opens the message being written on a screen of its own.
- `class _FullscreenComposerPage extends StatefulWidget`
  - initialText title hintText closeTooltip
- `class _FullscreenComposerPageState extends State<_FullscreenComposerPage>`
  - _close

### html_artifact_view.dart  (8 Z.)
- reicht weiter: 'html_artifact_view_io.dart' if (dart.library.js_interop) 'html_artifact_view_web.dart'

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
  - _registerFactory _buildIframe

### image_viewer.dart  (472 Z.)
- `class ImageViewer extends StatefulWidget`  — Full-screen image viewer with zoom and pan capabilities
  - imageDataUrl initialIndex allImages models
- `class _ImageViewerState extends State<ImageViewer>`
  - _handleKeyEvent _futureFor _loadImageBytes _imageKeyForIndex _handleOutsideImageTap _buildImageView _downloadCurrentImage _copyCurrentImage _showSaveSnackBar _resetZoom _hasMultipleImages _currentModel

### linux_webview.dart  (92 Z.)
- `class LinuxWebView extends StatelessWidget`
  - html _openInBrowser htmlContent captureKey

### map_block_renderer.dart  (992 Z.)
- const: mapBlockRegex _kLightTilesUrl _kDarkTilesUrl _kTileSubdomains
- `bool hasMapBlocks(String content)`  — Returns true if [content] contains at least one <map> block.
- `class MapContentSegment`  — A segment of message content — either plain text or a map block.
  - isMap content
- `class MapBlockWidget extends StatelessWidget`  — Renders a single <map> JSON block as a Flutter widget.
  - jsonString
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
  - data
- `class _PlacesMapBlock extends StatelessWidget`
  - _buildLabeledPlaceMarkers data
- `class _PlaceCard extends StatelessWidget`
  - _buildInfoChip place number onShowOnMap size
- `class _RouteMapBlock extends StatelessWidget`
  - data

### markdown_message.dart  (2252 Z.)
- part 'answer_blocks.dart'
- const: _kBulletSize _latexTag
- `TextStyle _overlayStyle(TextStyle? base, TextStyle overlay)`  — Lays [overlay] on top of [base] field by field.
- `class InlineCodeNode extends SpanNode`  — Inline `` `code` `` that keeps its monospace font, its own colour and its
  - style text codeStyle
- `class AccentLinkNode extends LinkNode`  — A link that reads as a link: the accent colour plus an underline in that
  - style accentColor
- `BoxDecoration _bulletDecoration(int depth, Color color)`  — Bullet shape per nesting level: filled disc, hollow disc, then square —
- `class _MdSegment`  — One slice of a message: plain markdown, a GFM table block, or an answer
  - text isTable table block
- `class _MdParseCache`  — Splits raw markdown into alternating plain-markdown and table segments so
  - _syncOwner clear _put segmentsFor nodesFor
- `List<Widget> _buildMarkdownWidgets( MarkdownGenerator generator, String data, MarkdownConfig config, { required bool kee …)`  — `MarkdownGenerator.buildWidgets` of markdown_widget 2.3, with the parse
- `List<_MdSegment> _splitSegments(String text)`  — Answer blocks first, then the tables inside the Markdown between them.
- `List<_MdSegment> _splitMarkdownTables(String text)`
- `class MarkdownMessage extends StatefulWidget`
  - clearCaches debugCachedParseCount debugCachedHighlightCount text textColor backgroundColor wrapWithSelectionArea paragraphFontSize paragraphHeight paragraphFontWeight fontFamily
- `class _MarkdownMessageState extends State<MarkdownMessage>`
  - _onTapLink _codeBackground _getSyntaxTheme keepParse
- `class _AsyncCodeBlock extends StatefulWidget`  — Widget that handles async code highlighting to prevent UI jank
  - code language textStyle backgroundColor borderColor theme textColor
- `class _AsyncCodeBlockState extends State<_AsyncCodeBlock>`
  - _syncParsedOwner clearParsed _parsedKey _applyParsedFromCache _keepParsed _prettifyIfJson _autoDetectJson _codeForDisplay _scheduleHighlight _highlightCode _isMostlyNonAscii
- `List<hi.Node> _parseCode(Map<String, dynamic> args)`
- `bool _isMostlyNonAsciiCode(String text)`  — Top-level helper for checking if text is mostly non-ASCII (for isolate use)
- `List<TextSpan> _convertNodesSafely( List<hi.Node>? nodes, Map<String, TextStyle> theme, TextStyle baseStyle, )`
- `List<TextSpan> _collectSpans( hi.Node? node, Map<String, TextStyle> theme, TextStyle baseStyle, TextStyle? parentThemeSt …)`
- `class LatexSyntax extends m.InlineSyntax`  — LaTeX inline syntax parser - matches $$...$$ and \(...\) and \[...\].
  - onMatch
- `class LatexNode extends SpanNode`  — LaTeX node that renders math using flutter_math_fork
  - _buildMathWidget attributes textColor
- `class _CopyButton extends StatefulWidget`  — Copy button widget for code blocks
  - code textColor
- `class _CopyButtonState extends State<_CopyButton>`
  - _copyToClipboard
- `class _SafeCodeBlockNode extends ElementNode`  — Replacement for markdown_widget's CodeBlockNode that avoids noisy
  - _extractLanguage content style element preConfig visitor
- `class _MarkdownImage extends StatelessWidget`  — Polished markdown image: full-width on mobile bubbles (capped at 540px wide
  - _errorTile _openFullscreen url alt
- `class _NetworkImageViewer extends StatelessWidget`
  - url

### mcp_connect_card.dart  (207 Z.)
- `class McpConnectCard extends StatefulWidget`  — A single Connect button for one catalogue server, shown inline under an
  - entry onConnected
- `class _McpConnectCardState extends State<McpConnectCard>`
  - _connect _isActivate _blockedOnWeb

### measure_size.dart  (49 Z.)
- `typedef OnWidgetSizeChange = void Function(Size size)`  — Callback invoked whenever the measured child changes size.
- `class MeasureSize extends SingleChildRenderObjectWidget`  — Reports its child's laid-out size via [onChange] after every layout in which
  - createRenderObject updateRenderObject onChange
- `class _MeasureSizeRenderObject extends RenderProxyBox`
  - performLayout onChange

### menu_tile_group.dart  (439 Z.)
- const: kMenuOuterRadius kMenuInnerRadius kMenuTileGap kMenuGroupGap kMenuDenseOuterRadius kMenuDenseInnerRadius kMenuDenseTileGap kMenuDenseGroupGap kMenuDenseRowHeight
- `class MenuDensity extends InheritedTheme`  — Marks a subtree as the Agents desktop layout, so every menu opened from it
  - isDense wrap updateShouldNotify dense
- `class MenuTileGroup extends StatelessWidget`  — A menu drawn as a run of filled tiles instead of one boxed card.
  - _buildDense groups color outerRadius
- `class MenuActionRow extends StatelessWidget`  — One row of a menu: an icon, a label, an optional line under it and
  - label shortcut icon leading subtitle trailing onTap tone selected enabled maxLines
- `Future<T?> showMenuSheet<T>( BuildContext context, { required List<List<Widget>> groups, Widget? header, Color? color, } …)`  — A menu as a bottom sheet: the house sheet chrome, then the same tiles a
- `class MenuAnchorButton extends StatelessWidget`  — The control a menu hangs off: the current value, an arrow, and the tap
  - label onTap leading labelStyle expand

### message_bubble.dart  (492 Z.)
- part 'message_bubble/models.dart' · part 'message_bubble/layout.dart' · part 'message_bubble/chrome.dart' · part 'message_bubble/rich_blocks.dart' · part 'message_bubble/tools.dart' · part 'message_bubble/images.dart' · part 'message_bubble/cards.dart'
- const: _kBlockGap _kArtifactGap _kCardStackGap _kInfoBarGap _kMobileBottomBarHeight _richBlockRegex _visualBlockStartRegex _diffBlockRegex _attachmentHeaderRe _kAiResponseFontFamilyDefault _cachedShowReasoningTokens _cachedShowModelInfo
- `class MessageBubble extends StatefulWidget`
  - message onReply onEditRequested reaction onReaction senderLabel messengerMode isUser startsNewGroup endsGroup maxWidth actions reasoning isReasoningStreaming modelLabel modelProvider tps isEditing initialEditText onSubmitEdit onCancelEdit showReasoningTokens showModelInfo showTps toolCalls showToolCalls contentBlocks isStreamingMessage chatId turnStartedAt sentAt workedFor images imageMetas attachments imageCostEur imageGeneratedAt onAskUserAnswer onConnectMcpServer userMessageActions +9
- `class _MessageBubbleState extends State<MessageBubble>`
  - _loadPreferences

### message_fly_in.dart  (70 Z.)
- `class MessageFlyIn extends StatefulWidget`  — A one-shot entrance for a just-sent message: the bubble starts a little
  - child rise duration
- `class _MessageFlyInState extends State<MessageFlyIn> with SingleTickerProviderStateMixin`

### messenger_context_menu.dart  (211 Z.)
- `Future<String?> showMessengerContextMenu({ required BuildContext context, required Rect anchor, required Widget preview …)`  — A focused message above a separate action sheet, like a messenger's

### messenger_typing_indicator.dart  (96 Z.)
- `class MessengerTypingIndicator extends StatefulWidget`  — A local presentation of a real in-flight turn; never a synthetic message.
  - connectedAbove
- `class _MessengerTypingIndicatorState extends State<MessengerTypingIndicator> with SingleTickerProviderStateMixin`

### model_selection_dropdown.dart  (1432 Z.)
- const: _menuHorizontalPadding _menuTrailingAllowance _menuExtraAllowance _buttonHorizontalPadding _buttonTrailingAllowance kAutoCheapestProviderSlug
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
  - _registerState _unregisterState _initializeEventBus _disposeEventBus refreshActiveDropdowns providerSlugForModel modelSupportsReasoning providerLimitsForModel availableProvidersForModel cheapestProviderForModel resolveProviderSlugForSend showModelSelectionSheet selectedModelListenable initialSelectedModelId onModelSelected textFieldFocusNode isCompactMode compactLabel transparentStyle mergedSegmentStyle selectedModelNotifier
- `class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> with ApiAvailabilityPolling<ModelSelectionDropd …)`
  - onApiReachable _handleSelectedModelNotifierChange _initializeModelSelection _hydrateFromCache _filterModels _parseDouble _applyModels providerSlugFor providerLimitsFor supportsReasoningFor refreshModels _fetchModels _handleApiUnavailable _buildApiUnavailableMessage _updateSelectedModelNameSync _updateSelectedModelName _calculateWidthMetrics _measureTextWidth _menuWidthFromTextWidth _buttonWidthFromTextWidth _effectiveButtonWidth _buildDropdownButtonContent _parseNullableInt apiPollBaseUrl _apiBaseUrl
- `String _stripLabPrefix(String name)`  — OpenRouter model names arrive as "Lab: Model Name" (e.g. "Qwen: Qwen3.5-9B").

### nice_snackbar.dart  (55 Z.)
- `class NiceSnackBar`  — The old name for [AppNotifications], kept so the call sites that already
  - duration

### password_strength_meter.dart  (145 Z.)
- `class PasswordStrengthMeter extends StatelessWidget`  — A widget that displays password strength with visual indicators.
  - _buildStrengthBar _buildStrengthLabel _buildRequirementsList _buildRequirement _getStrengthVisuals _getStrengthLabel password showRequirements

### per_model_system_prompt_sheet.dart  (285 Z.)
- `Future<bool?> showPerModelSystemPromptSheet({ required BuildContext context, required String modelId, required String mo …)`  — Bottom sheet for editing a per-model system prompt and merge mode.
- `class _PerModelSystemPromptEditor extends StatefulWidget`
  - modelId modelName initial
- `class _PerModelSystemPromptEditorState extends State<_PerModelSystemPromptEditor>`
  - _save _delete _modeDescription
- `class _ModeChips extends StatelessWidget`
  - mode onChanged

### room_create_sheet.dart  (234 Z.)
- const: kRoomSearchThreshold
- `class RoomCreateSheet extends StatefulWidget`
  - agents onSubmit onCancel
- `class _RoomCreateSheetState extends State<RoomCreateSheet>`
  - _toggle _submit _memberTile _canCreate _searchable _visible

### room_faces.dart  (190 Z.)
- const: kRoomFacesMax _kFaceOfSlot _kFaceGap kRoomFacesInbox kRoomFacesRail
- `String roomMembersLabel(AgentsRoom room)`  — Who is in a room, by the handle they are mentioned with. This is the line
- `typedef RoomFacePlacement = ({double left, double top, double size})`  — One geometry entry: where a face sits in the slot, and how big it is.
- `class RoomFaces extends StatelessWidget`
  - placements members size store ringColor
- `class _RingedFace extends StatelessWidget`  — One member's face with the gap that lifts it off the face beneath it.
  - id label box ring ringColor store

### room_list_view.dart  (295 Z.)
- `class RoomListView extends StatelessWidget`
  - _header _emptyState _roomTile _promptRename _memberStack source onSelect onCreate onDelete onRename onManageMembers selectedRoomId showHeader
- `class _RenameDialog extends StatefulWidget`  — The rename dialog. A StatefulWidget so it owns and disposes its own text
  - initial
- `class _RenameDialogState extends State<_RenameDialog>`

### room_members_sheet.dart  (177 Z.)
- `class RoomMembersSheet extends StatelessWidget`
  - _atMinimum room candidates onAdd onRemove onAgentToAgentChanged

### room_mention_picker.dart  (421 Z.)
- const: kBroadcastHandle kBroadcastAliases
- `bool _isHandleChar(int code)`  — A character that may sit inside a handle. Mirrors the manager's `_MENTION`
- `bool _isSpace(int code)`
- `@immutable class MentionToken`  — The `@token` the caret is inside, as a range over the text.
  - start end query operator
- `MentionToken? activeMentionToken(String text, int caret)`  — The `@token` [caret] sits in, or null when it sits nowhere near one.
- `@immutable class MentionEdit`  — The text and caret after a pick.
  - text caret operator
- `MentionEdit applyMention({ required String text, required MentionToken token, required String handle, })`  — Replace [token] with `@handle ` and say where the caret goes.
- `@immutable class MentionEntry`  — One row of the picker: a member of the room, or the broadcast row.
  - handle label agentId role trailing aliases broadcast
- `List<MentionEntry> mentionEntriesFor({ required List<AgentsRoomMember> members, List<AgentsAgent> agents = const <Agents …)`  — The room's members as picker rows, with `@all` first.
- `bool _prefix(String value, String query)`
- `List<MentionEntry> filterMentions(List<MentionEntry> entries, String query)`  — The rows that match what is typed: the broadcast row first, then the ones
- `class RoomMentionPicker extends StatefulWidget`  — The list that floats over the composer while a token is open.
  - entries selected onPick maxHeight
- `class _RoomMentionPickerState extends State<RoomMentionPicker>`
  - _revealSelected
- `class _MentionRow extends StatelessWidget`  — One compact line: the face, the name, the handle in the quiet colour, and
  - entry selected onTap

### room_thread_page.dart  (508 Z.)
- `class RoomThreadPage extends StatefulWidget`
  - roomId roomName members agents userMessage inbound rebind onSend onReady
- `class _RoomThreadPageState extends State<RoomThreadPage>`
  - _currentInbound _fromRebind _subscribe _onRebind _reconnectBanner _send _syncMention _clearMentionState _closeMention _moveMention _acceptMention _onComposerKey _onSubmitted _onInbound _onStreamClosed _mentionOpen _mentionEntries

### room_thread_view.dart  (280 Z.)
- const: _kFaceSize _kFaceGap
- `class RoomThreadView extends StatelessWidget`
  - _startsRun _endsRun _roomIntro _memberStrip _userMessage _turn _runningRow _stopLine roomName members userMessage turns stop running

### route_map_widget.dart  (345 Z.)
- `class RouteMapWidget extends StatefulWidget`  — Displays a route map with OSRM polyline, start/end markers,
  - toLon zoom routeTitle steps mapHeight onTapFullscreen
- `class _RouteMapWidgetState extends State<RouteMapWidget>`
  - _fetchRouteGeometry

### sandbox_artifact_block.dart  (765 Z.)
- `class SandboxArtifactBlock extends StatefulWidget`
  - payload borderRadius
- `class _SandboxArtifactBlockState extends State<SandboxArtifactBlock>`
  - _isTextLike _load _save _panelArtifactType _openAction _openInViewer _openInPanel _documentRow _buildImage _buildPdf _buildFileChip Function _shouldEagerLoad _canOpenInPanel
- `class _ArtifactCard extends StatelessWidget`
  - _icon payload borderRadius onSave child onOpen
- `class _FileName extends StatelessWidget`  — The file name, with the extension in the quieter colour.
  - filename scheme
- `String _kindLabel(String mime)`  — A short, readable name for a mime type. `text/markdown` says nothing to a
- `class _ArtifactErrorRow extends StatelessWidget`
  - message onSave

### searchable_picker.dart  (311 Z.)
- `class PickerOption<T>`  — One row of a picker.
  - _haystack value label subtitle leading selected searchText
- `Future<T?> showSearchablePicker<T>( BuildContext anchorContext, { required List<PickerOption<T>> options, String? hintTe …)`  — Opens the picker at [anchorContext]'s widget and returns the chosen value,
- `Future<T?> _showPickerSheet<T>( BuildContext context, { required List<PickerOption<T>> options, required String hintText …)`
- `class _PickerPanel<T> extends StatefulWidget`
  - options hintText width maxHeight searchable
- `class _PickerPanelState<T> extends State<_PickerPanel<T>>`
  - _row _matches

### selection_copy_area.dart  (243 Z.)
- `class SelectionCopyShortcut`  — Pure decision logic for the copy shortcut, kept out of the widget so it can
  - isCopyIntent
- `class SelectionCopyArea extends StatefulWidget`  — A [SelectionArea] whose Ctrl+C / Cmd+C does not depend on the focus tree.
  - child focusNode contextMenuBuilder onSelectionChanged
- `class SelectionCopyAreaState extends State<SelectionCopyArea>`
  - _handleSelectionChanged handleKeyEvent _focusedEditableHasSelection _copy _fallbackContextMenuBuilder selectedText

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
  - _defaultIcon text tone icon

### settings_list_view.dart  (122 Z.)
- `class SettingsListView extends StatefulWidget`  — Scroll container for settings-style pages with a bounded set of rows.
  - children padding controller physics scrollbarMargin headerInset extraHeaderInset crossAxisAlignment
- `class _SettingsListViewState extends State<SettingsListView>`
  - _withHeaderInset _controller

### settings_search_bar.dart  (211 Z.)
- const: kSettingsSearchBarHeight _kFieldHeight
- `class SettingsSearchBar extends StatefulWidget`  — The search field of a settings page: a floating pill with the magnifier on
  - controller hintText focusNode onChanged onSubmitted textInputAction
- `class _SettingsSearchBarState extends State<SettingsSearchBar>`
  - _onControllerChanged _clear
- `class PinnedSettingsSearchBar extends StatelessWidget implements PreferredSizeWidget`  — The same bar, sized to sit in a [FloatingAppBar]'s `bottom` slot so it
  - preferredSize controller hintText focusNode onChanged onSubmitted textInputAction

### stamped_text.dart  (132 Z.)
- const: _kMarkupMarker _kDialable
- `class StampedText extends StatelessWidget`  — Text plus an optional bottom-end [stamp], laid out by the messenger rule.
  - text style stamp gap fillWidth
- `bool isPlainStampableText(String text)`  — Whether [text] renders the same as a plain [Text] does — so the stamp can

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
  - fromJson _d meta elements sheetW sheetH originX originY
- `class TechDrawPainter extends CustomPainter`
  - _mm _pt _ptSheet paint _drawSheet _drawElements _elementPaint _fillPaint _thinPaint _parseColor _drawRect _drawCircle _drawLine _drawStyledLine _drawStyledCircle _drawDimension _drawDimLinearH _drawDimLinearV _drawDimDiameter _drawArrow _drawNote _drawTitleBlock _drawCellText shouldRepaint _d data scale opaque
- `class _ErrorCard extends StatelessWidget`
  - message

### update_banner.dart  (97 Z.)
- `class UpdateBanner extends StatelessWidget`  — A compact banner shown in the sidebar when a new app version is available.
  - _buildBanner

### vnc_local_server.dart  (353 Z.)
- `typedef VncAssetReader = Future<Uint8List> Function(String assetKey)`  — Reads one app asset. Injected so the server can be tested without a bundle.
- `Future<Uint8List> _bundleAsset(String assetKey)`
- `class VncLocalServer`  — The loopback server that feeds the noVNC viewer page.
  - Function _mintToken send resetStream close _tokensMatch _handle _route _serveAsset _upgrade _dropSocket _notFound port token viewerUrl _origin fromPage hasClient onStreamRestartNeeded

### vnc_trackpad_overlay.dart  (999 Z.)
- `class VncTrackpadOverlay extends StatefulWidget`  — A touch trackpad over the agent's browser view, for phones and tablets.
  - controller child enabled
- `enum _TwoFingerMode`  — What a two-finger gesture turned out to be. It starts undecided: the same
  - undecided scrolling zooming
- `class _VncTrackpadOverlayState extends State<VncTrackpadOverlay>`
  - _maybeShowHelp _dismissHelp _onControllerChanged _seedCursor _recomputeFit _clampCursor _moveCursorBy _followCursor _setZoom _fitToScreen _centroid _spread _reanchor _emitScroll _onPointerDown _onPointerMove _handleTwoFingerMove _onPointerUp _onKeyFocusChanged _resetKeyField _toggleKeyboard _onKeyFieldChanged _sendRune _sendKeySym _buildPicture _frameBuffer _cursorFb _ix _iy
- `class _VncCursor extends StatelessWidget`  — The virtual mouse cursor: an arrow you can actually see.
  - box hotspot
- `class _VncCursorPainter extends CustomPainter`
  - paint shouldRepaint
- `class _ZoomChip extends StatelessWidget`  — The zoom readout. It says how far in the picture is and takes it back to
  - zoom color onColor onTap
- `class _SpecialKeyBar extends StatelessWidget`  — The keys a phone keyboard does not give you, and a browser needs: escape a
  - color onColor onKey escape tab enter left right up down
- `class _TrackpadHelpCard extends StatelessWidget`  — The gesture cheat-sheet shown on first use and behind the "?" button.
  - onDismiss remoteSize
- `class _HelpRow extends StatelessWidget`
  - icon title body

### vnc_view_fit.dart  (195 Z.)
- `@immutable class VncViewFit`  — Where the remote framebuffer sits on the screen, and how to convert between
  - toScreen toFrameBuffer baseScale panFor _axisOrigin rect empty minZoom maxZoom scale origin size zoom margin operator

### vnc_webview_controls.dart  (356 Z.)
- `class VncLoadingSteps extends StatelessWidget`  — What the view is still waiting for, as named steps rather than a spinner.
  - machineReady screenReady
- `class _VncStep extends StatelessWidget`
  - label done active
- `class VncReconnectingNote extends StatefulWidget`  — The note over a frozen picture while the socket re-handshakes.
  - since
- `class _VncReconnectingNoteState extends State<VncReconnectingNote>`
- `class VncControlBar extends StatelessWidget`  — The row of controls under the agent's screen.
  - _paste controller onToggleKeyboard keyboardOpen
- `class VncKeyboardField extends StatelessWidget`  — The invisible field that takes the soft keyboard.
  - reset _onChanged sentinel controller focusNode text

### vnc_webview_screen.dart  (268 Z.)
- `enum VncPhase`  — What the viewer page says about its socket.
  - loading connecting reconnecting connected disconnected
- `class VncWebViewController extends ChangeNotifier`  — The host side of the noVNC viewer page.
  - attach _maybeStart _call handleBridgeMessage zoomToFit reconnect setTrackpad recenterPointer typeText sendKeysym paste copySelection screenshot phase zoomed trackpad frameAsOf clipboard screenshots password keysymBackspace keysymReturn keysymTab keysymEscape
- `class VncWebView extends StatefulWidget`  — The WebView that runs the viewer page.
  - viewerUrl controller
- `class _VncWebViewState extends State<VncWebView>`

### waveform.dart  (143 Z.)
- `class WaveformPainter extends CustomPainter`  — Paints [bars] (each 0..1) as rounded vertical bars, colouring everything
  - paint shouldRepaint bars progress playedColor restColor barWidth
- `class LiveWaveform extends StatelessWidget`  — The live level meter of an open microphone, in the waveform shape.
  - _bars levels color barCount height barWidth barSpacing

### weather_widget.dart  (519 Z.)
- `class WeatherBlockWidget extends StatelessWidget`  — Renders `<weather>` JSON blocks emitted by the AI as a polished weather card.
  - _buildCurrent _stat _buildHourly _buildDaily _buildDailyRow _asMap _asList _asNum _asStr _asInt _fmtNum _normalizeTempUnit _shortTime _dayLabel _iconForCode _gradientForCode data

### workspace_file_viewer.dart  (666 Z.)
- `class WorkspaceFileViewer extends StatefulWidget`  — Dialog to view and edit workspace files and their markdown summaries
  - show file workspaceId
- `class _WorkspaceFileViewerState extends State<WorkspaceFileViewer> with SingleTickerProviderStateMixin`
  - _loadFileContent _saveContent _saveMarkdown _buildOriginalContent _buildMarkdownContent

### workspace_panel.dart  (706 Z.)
- `class WorkspacePanel extends StatefulWidget`  — Right-side panel for workspace settings (Instructions + Files)
  - workspaceId onClose
- `class _WorkspacePanelState extends State<WorkspacePanel> with WorkspaceActionsMixin<WorkspacePanel>`
  - _pickAvatarImage _loadProject _saveInstructions _buildSection _buildInstructionsContent _buildFilesContent _openFileViewer _buildFileItem workspaceId

### workspace_selection_dropdown.dart  (283 Z.)
- `class WorkspaceSelectionDropdown extends StatefulWidget`
  - selectedWorkspaceId onWorkspaceSelected textFieldFocusNode
- `class _WorkspaceSelectionDropdownState extends State<WorkspaceSelectionDropdown>`
  - _loadProjects _selectedProject _hasProject

## lib/widgets/agent_activity
### agent_activity_model.dart  (462 Z.)
- const: _subjectKeys _maxDetailChars _maxThinkingChars maxSourcesPerStep
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
  - toolCalls steps isRunning clock initiallyExpanded onStepTap onSourceTap footer phase startedAt finalDuration
- `class _AgentActivityTimelineState extends State<AgentActivityTimeline>`
  - _syncTicker _nonNegative _buildHeader _buildRail _buildEntryText _buildSourceChips _buildSourceChip _iconFor _isExpanded _now soleStep

### turn_status.dart  (124 Z.)
- `class TurnStatus`  — The status of one assistant turn, as the header above it reports it.
  - verb showsDuration label isRunning hasToolCalls hasSteps phase runningToolLabel elapsed
- `bool hasRunningToolCall(List<ToolCall> calls)`  — True while any call in [calls] is still pending or running.
- `Duration? resolveTurnElapsed({ Duration? finalDuration, DateTime? startedAt, required DateTime now, required bool isRunn …)`  — How long the turn has taken, from the most trustworthy source available.

## lib/widgets/agents_desktop
### desktop_controls.dart  (328 Z.)
- `class DeskIconButton extends StatefulWidget`  — One icon button in a desktop bar: a 32 px square with a 20 px glyph.
  - icon tooltip onPressed selected parked color size glyph semanticsId
- `class _DeskIconButtonState extends State<DeskIconButton>`
- `class DeskContextMenuIntent extends Intent`  — Opens a context menu from the keyboard (the Menu key, Shift+F10).
- `class DeskFocusable extends StatelessWidget`  — The keyboard half of a desktop control: a focus stop that Enter and Space
  - child onActivate onFocusHighlight onContextMenu
- `class DeskHairline extends StatelessWidget`  — A 1 px hairline in `outlineVariant`, horizontal or vertical.
  - vertical
- `class PaneResizeHandle extends StatefulWidget`  — The drag target on a pane border. It paints nothing of its own — the
  - onDrag onDragEnd onDoubleTap hitWidth semanticLabel
- `class _PaneResizeHandleState extends State<PaneResizeHandle>`
- `class DeskPaneHeader extends StatelessWidget`  — The 48 px header row of a side pane, lined up with the thread's title bar:
  - title leading actions padding
- `String deskShortcutLabel(String keys)`  — The platform's name for the primary modifier: Cmd on a Mac, Ctrl
- `bool deskPrimaryModifierPressed()`  — Whether the platform's primary modifier is down (Cmd on a Mac).

### desktop_dialog.dart  (132 Z.)
- `bool isAgentsDesktop(BuildContext context)`  — Whether [context] is laid out as the desktop (not the phone).
- `Future<T?> showAgentsSheetOrDialog<T>({ required BuildContext context, required WidgetBuilder builder, })`  — A form that is a bottom sheet on the phone and a centred dialog, at most
- `class AgentsDesktopDialog extends StatelessWidget`  — The dialog frame itself: the app's dialog surface and radius, centred,
  - child
- `Future<bool> showAgentsConfirmDialog( BuildContext context, { required String title, required String message, String con …)`  — Asks before something is deleted. Returns true when the user confirms.

### desktop_metrics.dart  (62 Z.)
- const: kDeskRosterMin kDeskRosterMax kDeskRosterDefault kDeskRailWidth kDeskDetailsMin kDeskDetailsMax kDeskDetailsDefault kDeskThreadMin kDeskBarHeight kDeskButton kDeskGlyph kDeskButtonGap kDeskAgentRow kDeskRoomRow kDeskRowFace kDeskRowPadH kDeskSelectedBar kDeskControlRadius kDeskMenuRadius kDeskMenuRow kDeskComposerRadius kDeskComposerButton kDeskReadingMeasure kDeskDialogMaxWidth kDeskDialogRadius

### message_hover_actions.dart  (152 Z.)
- `class MessageHoverActions extends StatefulWidget`
  - actions child
- `class _MessageHoverActionsState extends State<MessageHoverActions>`
  - _onHighlightMode _onFocus

### quick_switcher.dart  (329 Z.)
- `sealed class QuickSwitcherPick`  — What the user picked.
- `class QuickSwitcherAgent extends QuickSwitcherPick`
  - agent
- `class QuickSwitcherRoom extends QuickSwitcherPick`
  - room
- `Future<QuickSwitcherPick?> showQuickSwitcher( BuildContext context, { required List<AgentsAgent> agents, required List<A …)`  — Opens the switcher near the top of the window. Returns the pick, or null
- `class QuickSwitcher extends StatefulWidget`
  - agents rooms profiles readMarks
- `class _QuickSwitcherState extends State<QuickSwitcher>`
  - _move _onKey _open _row _matches

## lib/widgets/charts
### chart_painter.dart  (1458 Z.)
- const: _kMinLabelFontSize _kAxisFontSize _kLabelFontSize _kValueFontSize
- `enum ChartLabelLayout`  — How the category labels under the plot are laid out, once measured.
  - flat wrapped tilted
- `class ChartGeometry`  — Everything the painter worked out from the spec and the box it was given.
  - slotWidth totalHeight axisWidth valueBand plotHeight labelBand min max step labelLayout labelStride categoryCount operator
- `enum ChartBoxKind`  — What a measured box belongs to. The reference label dodges all of them;
  - bar value category tick
- `@immutable class ChartBox`  — One box the painter put down, kept so the reference label can step around
  - kind rect
- `class ChukChartPainter extends CustomPainter`
  - measure paint _paintSeries _measureBoxes _paintUnitCaption _y _paintGrid _paintBars _paintStacked _paintLines _lastX _trim _lineColor _placeReferenceLabel _leastBadReferenceLabel _shortReferenceText _referenceBands _referencePainter _fitReferenceLabel _emptierEndIsLeft _totalWidth _freeSpans _paintReference _paintCategories shouldRepaint _t debugReferenceLabelBox debugReferenceLabelPlated debugReferenceLabelText debugBoxes _hasReferenceLabel _referenceColor spec palette geometry textScaler progress fontFamily chip
- `TextStyle _axisStyle()`
- `TextStyle _labelStyle()`
- `TextStyle _valueStyle()`
- `TextPainter _paint( String text, TextStyle style, TextScaler scaler, String? fontFamily, { double maxWidth = double.infi …)`
- `class _RefLabel`  — The reference line's label once it has found a spot: what it says, laid
  - text painter box plate plateAlpha
- `class _Span`  — A stretch of a strip, in x.
  - width start end
- `class _Range`
  - min max step
- `_Range _rangeFor(ChartSpec spec)`  — The value range and the gridline step.
- `double _niceStep(double range, int target)`
- `int _decimalsFor(double step)`
- `String _tickText(double v, ChartSpec spec, int decimals)`  — An axis tick. Big numbers are abbreviated (62k, 1.2M) so the axis column
- `String _trimZeros(String s)`

### chart_palette.dart  (149 Z.)
- `@immutable class ChartPalette`  — The resolved colours for one chart in one theme.
  - seriesColor barColor legible _fixed _legible ink _contrast onFill text muted faint grid baseline border surface accent up down series isDark

### chart_spec.dart  (888 Z.)
- `enum ChartKind`  — What the chart draws.
  - parse isBarFamily isMultiSeries bar columnDelta line grouped stacked
- `enum ChartSort`  — How the points are ordered before they are drawn.
  - parse given descending ascending
- `enum ChartDirection`  — Whether a series is a good thing going up or a bad thing going down. Used
  - parse auto up down neutral
- `@immutable class ChartPoint`  — One category and its value.
  - label value color note operator
- `@immutable class ChartSeries`  — One line or one bar family.
  - risesOverall resolvedDirection points name color direction
- `@immutable class ChartAxis`  — The optional min/max the agent asked for.
  - isEmpty min max
- `@immutable class ChartReferenceLine`  — One horizontal rule across the plot — the 5 % threshold.
  - value label color
- `@immutable class ChartSpec`  — A parsed, validated chart.
  - sorted copyWith _preview unusable categories values hasNegative drawsValueLabels unitOverAxis effectiveDecimals kind series title subtitle unit sort axis referenceLine source retrievedAt decimals decimalSeparator showValues height problems rawFallbackText withUnit
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
  - spec accentColor fontFamily animate
- `class _ChukChartState extends State<ChukChart> with SingleTickerProviderStateMixin`
  - _family _legendEntries _notes _footer
- `String chartSourceLine(ChartSpec spec)`  — "Source · 2026-09-12 20:15", or an empty string when neither is known.
- `String _stamp(DateTime d)`
- `String _semanticLabel(ChartSpec spec)`  — A one-sentence description for a screen reader.
- `class _Heading extends StatelessWidget`  — The heading of a chart card: title, then subtitle.
  - spec palette fontFamily
- `class ChukChartFallback extends StatelessWidget`  — What a chart that could not be drawn shows instead.
  - _sentence spec palette fontFamily

## lib/widgets/icons
### huge_icon.dart  (211 Z.)
- const: _opticalInset
- `@immutable class HugeIconData`  — One icon of the set. The name is the file stem, so `HugeIcons.message01`
  - asset name
- `abstract final class HugeIcons`
  - add01 aiBrain01 album01 album02 alertCircle alert01 alert02 arrowDown01 arrowLeft01 arrowLeft02 arrowRight01 arrowUpRight01 arrowUp01 attachment01 blockchain01 bookOpen01 bookmark01 braces bug01 calendar01 call02 cancel01 cancel02 chatting01 check checkmarkCircle01 checkmarkCircle02 circle clock01 comment01 computer copy01 database01 delete02 dollar01 download01 download04 edit02 fileCode fileEdit +73
- `class HugeIcon extends StatelessWidget`  — An icon of the set, drawn like a Material [Icon].
  - icon size color

### icon_map.dart  (266 Z.)
- const: _map
- `HugeIconData? hugeIconFor(IconData icon)`  — The app's icon for [icon], or null when the set has nothing for it.
- `class AppIcon extends StatelessWidget`  — An icon that prefers the app's set and falls back to Material.
  - icon size color semanticLabel

### model_logo.dart  (84 Z.)
- const: kModelLogoByLab
- `String? modelLogoAsset(String modelId)`  — The bundled logo for [modelId], or null when its lab has no logo.
- `class ModelLogo extends StatelessWidget`  — A model row's leading glyph: the lab logo at [logoSize] inside a
  - modelId color size logoSize

## lib/widgets/message_bubble
### cards.dart  (905 Z.)
- part of '../message_bubble.dart'
- `class _CachedImageThumbnail extends StatefulWidget`  — Cached image thumbnail that decodes once and caches the bytes
  - imageDataUrl width height borderRadius fit naturalAspect maxNaturalHeight onTap
- `class _CachedImageThumbnailState extends State<_CachedImageThumbnail> with AutomaticKeepAliveClientMixin`
  - _loadImage wantKeepAlive
- `class _ArtifactInlineCard extends StatefulWidget`  — Compact artifact card shown inline in chat after artifact_manager calls.
  - artifactId title type authoredVersion
- `class _ArtifactInlineCardState extends State<_ArtifactInlineCard>`
  - _refresh _open _download _icon _typeLabel
- `class _ArtifactErrorCard extends StatelessWidget`  — Visible error chip when an inline artifact tag (or artifact_manager tool
  - toolName message
- `class _NewsCard extends StatelessWidget`  — News article card: thumbnail (left, 96x96), title, publisher · age, summary,
  - _openUrl item colorScheme

### chrome.dart  (412 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleChrome on _MessageBubbleState`
  - _buildBottomBar _buildVariantPager _collectAllToolCalls _allSources _buildFavicon _showSourcesSheet _buildUserActionButtons _buildActionButtons _buildActionBar _buildStatusIndicator maxIcons

### images.dart  (642 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleImages on _MessageBubbleState`
  - _modelFor _buildGeneratingImagesGrid _loaderTile _pendingImageSize _buildImagesGrid _showImageContextMenu _confirmDeleteImage _buildAttachmentsChips fit resolveModels

### layout.dart  (1564 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleLayout on _MessageBubbleState`
  - _showMessengerMenu _withMessengerMenu _stripForPresentation _buildBubbleFooter _buildAutomationWakeLine _buildQuietWorkLine _buildUserBubble _buildAiBubble _buildContinueButton _buildClassicLayout _buildFramedUserImageGrid _buildContentBlocksLayout _stripAttachmentHeaderForUser _agentProseStyle _buildMessageBody _chatFontFamily _chatFontSize _hasReasoning _hasModelInfo _shouldShowTps _isQrImageMessage _strippedMessage _agentsLook _bubblePosition _clockLabel _agentBubbleKind _isPlainMessengerText _stampRidesInText _isPlainAgentText fillWidth

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

### rich_blocks.dart  (562 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleRichBlocks on _MessageBubbleState`
  - _hasVisualBlocks _tryParseJson _buildVisualContent _buildDiffBlock _buildEmailBlock _emailField _openMailto _buildNewsBlock _buildImageBlock _buildBlockText _buildTextParagraphs

### tools.dart  (826 Z.)
- part of '../message_bubble.dart'
- `extension _MessageBubbleTools on _MessageBubbleState`
  - _buildTurnStatusOnly _buildInfoStatusBar _currentPhase _buildMetaFooter _buildArtifactCards _stackArtifactCards _openSourceUrl _showToolCallDetails _buildToolCallExpandedWidget _buildToolSectionFrame _buildToolResultSections _findAskUserToolCall _buildAskUserOptions _findRequestMcpToolCall _buildMcpConnectOptions live mono

### web_search_sources.dart  (289 Z.)
- `class WebSearchSource`  — One parsed hit from a web_search result.
  - title url host snippet age
- `String _clean(String s)`  — Strip HTML tags + the handful of entities the search backend emits, and
- `String _hostOf(String url)`
- `List<WebSearchSource> parseWebSearchSources(String result)`  — Parse a `web_search` result into ordered source hits. Returns an empty
- `class WebSearchSourcesCard extends StatelessWidget`  — Renders parsed [WebSearchSource]s as tappable source cards.
  - _open sources textColor accentColor
- `class _SourceCard extends StatelessWidget`
  - source textColor accentColor onTap
- `class _Favicon extends StatelessWidget`  — Favicon for [host] via Google's public favicon service, with a globe
  - host accent muted

## lib/widgets/sidebar
### hover_marquee_text.dart  (215 Z.)
- `class HoverMarqueeText extends StatefulWidget`  — A single-line title that shows an ellipsis at rest and, when the pointer
  - text style velocity textAlign
- `class _HoverMarqueeTextState extends State<HoverMarqueeText> with SingleTickerProviderStateMixin`
  - _start _stillRunning _stop

### sidebar_chrome.dart  (1670 Z.)
- const: kSbCardGap kSbBlockInset kSbCardRadius kSbCardJointRadius kSbNavCardHeight kSbNavRowStep _kSbMenuCentre kSbNavBlockTop kSbNavIconLeft kSbNavIconTile kSbNavIconTop kSbNavIconCentre
- `Color sbPanelBackground(BuildContext context)`  — The colour the sidebar panel is painted in — the same step off the page
- `double sbNavRowTop(int index)`  — Top of row [index] of the navigation block — the cards when the panel is
- `class SidebarTokens`
  - iconFg accent bg surface surfaceHigh hairline muted isDark
- `class SbCard extends StatefulWidget`  — The filled, rounded card every sidebar row sits in.
  - child onTap onLongPress onLongPressAt onSecondaryTap selected outlined padding minHeight radius
- `class _SbCardState extends State<SbCard>`
- `class SbCardHoverScope extends InheritedWidget`  — Publishes the hover state of the enclosing [SbCard] to its content.
  - of updateShouldNotify hovered
- `class SbBlock extends StatelessWidget`  — A stack of cards that belong together — the navigation block, or the chats
  - children inset joinTop
- `BorderRadius sbBlockRadiusFor({ required int index, required int length, bool joinTop = false, })`  — The corners of the card at [index] in a block of [length] cards: outward
- `class SbCardShape extends InheritedWidget`  — Carries the shape a card should take from its block down to the card.
  - of updateShouldNotify radius
- `class SbNavIcon extends StatelessWidget`  — The glyph of a navigation entry: the bare icon in the accent colour, in a
  - icon tone size
- `class SbNavCard extends StatelessWidget`  — One navigation entry: a full-width card with a coloured icon and a bold
  - icon label onTap tone trailing
- `class SbRoundAction extends StatelessWidget`  — A round icon button on the card fill — the shape the head bar and the
  - icon onTap tooltip diameter iconSize fill
- `class SbGroupHeader extends StatelessWidget`  — The header above a block: a quiet label, the number of items in the group,
  - label collapsed count onToggle
- `class SbSearchField extends StatefulWidget`  — The pill-shaped search field of the bottom bar.
  - controller focusNode onClear hintText transparent
- `class _SbSearchFieldState extends State<SbSearchField>`
  - _onControllerChanged
- `class SbAccountLine extends StatelessWidget`  — The bottom bar of the phone sidebar: who is signed in, what is left on the
  - name balance onTap onSettings settingsTooltip onNewChat newChatTooltip
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
  - child borderRadius
- `class SbBrand extends StatelessWidget`  — Brand row: optional logo square + text. Trailing widget on the right.
  - trailing padding label showLogo fontSize fontWeight
- `class SbSearchTrigger extends StatelessWidget`  — Subtle search trigger — rounded icon button with "Search" label.
  - onTap label
- `class SbNewChatPill extends StatelessWidget`  — Compact accent pill — used for mobile top-right "New chat".
  - onTap label icon
- `class SbNavItem extends StatelessWidget`  — Sidebar nav row (icon + label, stacked vertically). Primary highlights accent.
  - icon label onTap primary
- `class SbRailRow extends StatelessWidget`  — Rail-aligned nav row. 48 px tall, icon centred inside a 48x48 square at
  - icon label onTap primary leftPadding rowHeight iconBoxWidth iconSize
- `class SbSectionLabel extends StatelessWidget`  — Mixed-case section label with optional count. Claude.ai style.
  - label count padding color
- `class SbPinnedBento extends StatelessWidget`  — Accent-tinted "Pinned" bento card. Caller supplies the row widgets.
  - count children margin
- `class SbStickyLabelDelegate extends SliverPersistentHeaderDelegate`  — Sliver delegate that renders an SbSectionLabel as a pinned header. The
  - shouldRebuild maxExtent minExtent label background color height
- `class SbHairline extends StatelessWidget`  — Hairline divider matching app palette.
  - margin

### sidebar_common.dart  (512 Z.)
- const: kSidebarPageSize
- `String normalizeSidebarTitle(String title)`  — Strips generated Markdown decoration from a chat title before display.
- `String deriveSidebarChatTitle(StoredChat chat)`
- `String sidebarDisplayName(ProfileRecord? profile)`
- `List<Widget> buildSidebarNavigationCards({ required BuildContext context, required bool showWorkspaces, required VoidCal …)`  — The destinations shared by both sidebars, with a platform-owned search
- `mixin SidebarStateCommon<T extends StatefulWidget> on State<T>`  — Common state, mutations, and grouped-list construction for both sidebars.
  - applyChatFilter initSidebarCommon disposeSidebarCommon handleSidebarWidgetUpdate onScrollForAutoLoad toggleSidebarGroup onSidebarNetworkStatusChanged loadSidebarProfile toggleSidebarChatStarred renameSidebarChat confirmAndDeleteSidebarChat _refreshSidebarAfterMutation _showDebouncedDeleteNotification showLockedSidebarChatDialog Function searchController scrollController searchFocus collapsedGroups searchQuery filteredRecentChats displayLimit profile isOfflineMode onChatDeletedCallback kind

## lib/widgets/workspace
### workspace_actions_mixin.dart  (277 Z.)
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

**Waisen (10)** — von keiner Datei importiert. Nicht wiederbeleben, ohne vorher zu prüfen, ob sie noch gebraucht werden.
- `lib/platform_specific/chat/composer_menu.dart` — 59 Zeilen, von keiner Datei benutzt
- `lib/platform_specific/chat/composer_menu_choices.dart` — 18 Zeilen, von keiner Datei benutzt
- `lib/platform_specific/mobile/mobile_chips.dart` — 63 Zeilen, von keiner Datei benutzt
- `lib/services/notification_service_io.dart` — 250 Zeilen, von keiner Datei benutzt
- `lib/services/notification_service_stub.dart` — 38 Zeilen, von keiner Datei benutzt
- `lib/services/service_credentials_service.dart` — 212 Zeilen, von keiner Datei benutzt
- `lib/services/streaming_foreground_service_io.dart` — 307 Zeilen, von keiner Datei benutzt
- `lib/services/streaming_foreground_service_stub.dart` — 71 Zeilen, von keiner Datei benutzt
- `lib/ui/expressive/waveform.dart` — 9 Zeilen, von keiner Datei benutzt
- `lib/widgets/chat_theme.dart` — 150 Zeilen, von keiner Datei benutzt

**Importzyklen (15)**
- 3 Dateien: lib/services/account_session.dart → lib/services/session_refresh_scheduler.dart → lib/services/supabase_service.dart
- 2 Dateien: lib/services/agents/agents_pairing_store.dart → lib/services/agents/supabase_pairing_sync.dart
- 2 Dateien: lib/services/mcp/mcp_catalogue.dart → lib/services/mcp/mcp_connection.dart
- 5 Dateien: lib/services/agents/agents_cloud_relay.dart → lib/services/agents/agents_relay_client.dart → lib/services/agents/agents_relay_link.dart → lib/services/mcp/mcp_service.dart → lib/services/mcp/mcp_store
- 9 Dateien: lib/services/agents/agents_queued_marks.dart → lib/services/chat_preload_service.dart → lib/services/chat_storage_crud.dart → lib/services/chat_storage_mutations.dart → lib/services/chat_storage_servi

**Größte Dateien (74 über der Schwelle)**
- `lib/platform_specific/chat/chat_ui_mobile.dart` — 4166 Zeilen, 165 Symbole
- `lib/services/agents/agents_relay_client.dart` — 3267 Zeilen, 404 Symbole
- `lib/platform_specific/chat/chat_ui_desktop.dart` — 3006 Zeilen, 136 Symbole
- `lib/platform_specific/chat/desktop_send_logic.dart` — 2540 Zeilen, 24 Symbole
- `lib/widgets/agents_thread_view.dart` — 2286 Zeilen, 139 Symbole

## Mehrfach vergebene Namen

267 Namen existieren in mehr als einer Datei. Meist kopierter Code. Bevor du so etwas neu schreibst, eine der Stellen wiederverwenden. Volle Liste: `pseudomap dupes`.

- `_load` — lib/pages/diagnostics_settings_page.dart:39 · lib/pages/settings/developer_settings_page.dart:32 · lib/pages/settings/embedding_settings_page.dart:31 · lib/pages/workspace_files_page.dart:70 +7
- `_save` — lib/pages/agent_profile_edit_page.dart:149 · lib/pages/skills_settings_page.dart:326 · lib/pages/workspace_instructions_page.dart:57 · lib/services/agents/agents_task_outbox.dart:229 +7
- `_persist` — lib/services/agents/agent_profile_store.dart:264 · lib/services/agents/agent_read_marks.dart:156 · lib/services/agents/agent_roster_source.dart:184 · lib/services/agents/agent_roster_store.dart:169 +5
- `Function` — lib/pages/mcp_connectors_page.dart:985 · lib/pages/settings/mcp_connectors_page.dart:891 · lib/platform_specific/chat/handlers/scanned_pdf_pages.dart:20 · lib/services/chat_payload_codec.dart:488 +4
- `_open` — lib/pages/assistant_settings_page.dart:153 · lib/pages/mcp_connectors_page.dart:308 · lib/pages/settings/mcp_connectors_page.dart:315 · lib/services/offline_queue_service_native.dart:37 +4
- `_onInbound` — lib/services/agents/browser_presence.dart:177 · lib/services/automations/automations_source.dart:139 · lib/services/skills/skills_source.dart:104 · lib/widgets/agents_thread_view.dart:1167 +2
- `_row` — lib/pages/mcp_connectors_page.dart:284 · lib/pages/mobile_agents_settings_page.dart:395 · lib/pages/settings/mcp_connectors_page.dart:291 · lib/pages/skills_settings_page.dart:732 +2
- `_formatDate` — lib/pages/media_manager_page.dart:580 · lib/pages/usage_details_page.dart:920 · lib/pages/workspace_mobile_detail_page.dart:526 · lib/services/workspace_message_service.dart:260 +1
- `_key` — lib/services/agents/agents_task_outbox.dart:192 · lib/services/agents/agents_task_outbox.dart:472 · lib/services/chat_dirty_store.dart:50 · lib/services/chat_model_selection_service.dart:52 +1
- `_build` — lib/pages/agent_profile_page.dart:117 · lib/ui/expressive/agent_face.dart:235 · lib/ui/expressive/shapes.dart:29 · lib/ui/expressive/shapes.dart:140
- `_coerceInt` — lib/services/tool_executor.dart:1288 · lib/tool_handlers/chat_search_tools.dart:720 · lib/tool_handlers/map_tools.dart:632 · lib/tool_handlers/web_tools.dart:24
- `_connect` — lib/pages/mcp_connectors_page.dart:689 · lib/pages/settings/mcp_connectors_page.dart:602 · lib/widgets/agents_thread_view.dart:960 · lib/widgets/mcp_connect_card.dart:54
- `_ensureEncryptionKey` — lib/services/agents/supabase_pairing_sync.dart:178 · lib/services/mcp/chuk_mcp_mirror.dart:182 · lib/services/mcp/mcp_connector_sync.dart:137 · lib/services/secrets/secrets_sync.dart:122
- `_formatDuration` — lib/assistant/assistant_tools.dart:809 · lib/services/device_services.dart:518 · lib/utils/api_rate_limiter.dart:207 · lib/widgets/agent_run_views.dart:150
- `_onChanged` — lib/pages/automations_page.dart:62 · lib/pages/skills_settings_page.dart:593 · lib/pages/workspace_instructions_page.dart:53 · lib/widgets/vnc_webview_controls.dart:310
- `_onControllerChanged` — lib/platform_specific/chat/chat_ui_mobile.dart:833 · lib/widgets/settings_search_bar.dart:81 · lib/widgets/sidebar/sidebar_chrome.dart:676 · lib/widgets/vnc_trackpad_overlay.dart:188
- `_pick` — lib/pages/settings/embedding_settings_page.dart:40 · lib/pages/theme_page.dart:1059 · lib/pages/theme_page.dart:1220 · lib/widgets/agent_roster_view.dart:284
- `_refresh` — lib/pages/assistant_settings_page.dart:123 · lib/pages/automations_page.dart:66 · lib/pages/skills_settings_page.dart:597 · lib/widgets/message_bubble/cards.dart:384
- `_select` — lib/pages/agents_shell_state.dart:173 · lib/pages/messenger_shell.dart:355 · lib/services/storage/agents_chat_store.dart:904 · lib/widgets/chat_documents_panel.dart:254
- `_submit` — lib/pages/secrets_settings_page.dart:225 · lib/pages/workspaces_page.dart:619 · lib/widgets/coworker_name_dialog.dart:69 · lib/widgets/room_create_sheet.dart:85
- `_syncCacheToCurrentUser` — lib/services/per_model_system_prompt_service.dart:153 · lib/services/skills/user_skills_service.dart:63 · lib/services/title_generation_service.dart:104 · lib/services/user_preferences_service.dart:46
- `_table` — lib/services/customization_preferences_service.dart:214 · lib/services/profile_service.dart:44 · lib/services/theme_settings_service.dart:129 · lib/widgets/chat_document_view.dart:364
- `Duration` — lib/services/agents/agents_cloud_relay.dart:249 · lib/services/agents/agents_host_session.dart:74 · lib/widgets/app_notification.dart:115
- `NotificationService` — lib/services/notification_service.dart:16 · lib/services/notification_service_io.dart:12 · lib/services/notification_service_stub.dart:7
- `StreamingForegroundService` — lib/services/streaming_foreground_service.dart:10 · lib/services/streaming_foreground_service_io.dart:9 · lib/services/streaming_foreground_service_stub.dart:6
- … +242 weitere
