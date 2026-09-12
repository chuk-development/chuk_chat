# lib/platform_specific/chat/handlers · Signatures

## lib/platform_specific/chat/handlers/audio_recording_handler.dart  (517 Z.)

- L16 `enum AudioRecordingChange`
  - L16 `started`
  - L16 `stopped`
  - L16 `failed`
  - L16 `busy`
- L28 `class AudioRecordingHandler`  — Handles microphone recording + transcription.
  - L29 `static const int _sampleRate = 16000`
  - L30 `static const int _channels = 1`
  - L32 `final AudioRecorder _audioRecorder = AudioRecorder()`
  - L33 `final List<double> _audioLevels = List<double>.filled( 32, 0.0, growable: true, )`
  - L40 `bool _isMicActive = false`
  - L41 `bool _isTranscribingAudio = false`
  - L42 `bool _isChangingRecordingState = false`
  - L45 `VoidCallback? onLevelsChanged`  — Called whenever audio levels update, so the UI can rebuild.
  - L48 `StreamSubscription<Uint8List>? _pcmStreamSub`
  - L49 `final BytesBuilder _pcmBuffer = BytesBuilder(copy: false)`
  - L52 `StreamingTranscriptionService? _streamingService`
  - L53 `bool _isStreamingMode = false`
  - L55 `bool get isMicActive`
  - L56 `bool get isTranscribingAudio`
  - L57 `List<double> get audioLevels`
  - L60 `bool get isStreamingMode`  — Whether a WebSocket streaming session is active.
  - L69 `Future<bool> _startRecording({String? accessToken})`  — Start microphone recording.
  - L114 `Future<AudioRecordingChange> toggleRecording({ required String? accessToken, required VoidCallback handleLevelsChanged, })`  — Toggles recording while keeping recorder state transitions identical on
  - L144 `Future<void> stopRecording({bool keepFile = false})`  — Stop microphone recording.
  - L174 `Future<TranscriptionResult> _transcribeLastRecording({ required ChatApiService apiService, required String accessToken, })`  — Transcribe the last recorded audio.
  - L194 `Future<TranscriptionResult?> stopAndTranscribe({ required ChatApiService apiService, required Future<String?> Function() getAccessToken, VoidCallback? onStateChanged, })`  — Stops the active recording, resolves authentication, and transcribes it.
  - L233 `Future<void> dispose()`
  - L244 `void _handlePcmChunk(Uint8List data)`
  - L258 `Future<void> _tryConnectStreaming(String accessToken)`  — Connect the WebSocket in the background. On success, flush any PCM
  - L302 `Future<TranscriptionResult> _transcribeStreaming()`
  - L341 `Future<TranscriptionResult> _transcribeBufferedPcm({ required ChatApiService apiService, required String accessToken, })`
  - L403 `static Uint8List _pcmToWav( Uint8List pcm, { required int sampleRate, required int channels, })`  — Wrap raw PCM-16 LE mono samples in a minimal WAV (RIFF) container so
  - L441 `static void _writeAscii(ByteData buf, int offset, String value)`
  - L448 `void _computeAmplitudeFromPcm(Uint8List data)`
  - L465 `void _resetAudioLevels()`
  - L471 `Future<bool> _ensureMicPermission()`
- L504 `class TranscriptionResult`  — Result of audio transcription.
  - L505 `final bool success`
  - L506 `final String? text`
  - L507 `final String? error`
  - L508 `final bool requiresLogout`
  - L510 `TranscriptionResult({ required this.success, this.text, this.error, this.requiresLogout = false, })`

## lib/platform_specific/chat/handlers/chat_persistence_handler.dart  (447 Z.)

- L15 `@visibleForTesting bool keepsMoreThanPatch(String? stored, String? patch)`  — Handles chat persistence and storage
- L22 `class ChatPersistenceHandler`
  - L23 `static const Duration _backgroundUpdateDebounce = Duration(milliseconds: 700)`
  - L27 `static const Duration _backgroundRetryDelay = Duration(seconds: 1)`  — How often a patch that could not be written yet is retried, and how
  - L28 `static const int _maxBackgroundRetries = 5`
  - L31 `Function(String)? onShowSnackBar`
  - L32 `Function(String chatId)? onChatIdAssigned`
  - L34 `final Map<String, _PendingBackgroundUpdate> _pendingBackgroundUpdates = <String, _PendingBackgroundUpdate>{}`
  - L36 `final Map<String, Timer> _backgroundUpdateTimers = <String, Timer>{}`
  - L38 `void dispose()`
  - L50 `Future<void> flushPending({String? chatId})`  — Write every pending patch now. With [chatId] only that chat's patches.
  - L64 `Future<StoredChat?> persistChat({ required List<Map<String, String>> messages, String? chatId, bool waitForCompletion = false, bool isOffline = false, bool silent = false, })`  — Save or update chat in storage
  - L128 `static void stampWorkedFor(List<Map<String, String>> messages)`  — Write down how long each answer took, so a reopened chat shows the
  - L154 `Future<StoredChat?> _persistChatInternal( List<Map<String, String>> messagesCopy, String? chatId, { required bool isOffline, bool silent = false, })`
  - L266 `Future<void> updateBackgroundChatMessage({ required String chatId, required int messageIndex, String? content, String? reasoning, String? toolCallsJson, String? contentBlocksJson, String? images, String? imageMetas, String? imageCostEur, String? imageGeneratedAt, String? tps, String? status, bool immediate = false, })`  — Update a specific message in storage for a background chat
  - L312 `Future<void> _flushBackgroundUpdate(String key)`
- L430 `class _PendingBackgroundUpdate`
  - L431 `_PendingBackgroundUpdate({required this.chatId, required this.messageIndex})`
  - L433 `final String chatId`
  - L434 `final int messageIndex`
  - L435 `String? content`
  - L436 `String? reasoning`
  - L437 `String? toolCallsJson`
  - L438 `String? contentBlocksJson`
  - L439 `String? images`
  - L440 `String? imageMetas`
  - L441 `String? imageCostEur`
  - L442 `String? imageGeneratedAt`
  - L443 `String? tps`
  - L444 `int attempts = 0`
  - L445 `String? status`

## lib/platform_specific/chat/handlers/desktop_clipboard_handler.dart  (265 Z.)

- L20 `class DesktopClipboardHandler`  — Handles desktop-specific clipboard operations and context menus.
  - L23 `static const int kLongPasteThreshold = 3000`  — Threshold (characters) above which pasted text is auto-converted to an
  - L26 `static const Duration kPasteTempRetention = Duration(hours: 24)`  — How long paste temp directories are kept before cleanup removes them.
  - L30 `final Future<void> Function(List<String> paths) onProcessFilePaths`  — Callback invoked to process one or more file paths (e.g. after pasting an
  - L36 `const DesktopClipboardHandler({required this.onProcessFilePaths})`  — Creates a [DesktopClipboardHandler].
  - L44 `String selectedTextOrAll(TextEditingValue value)`  — Returns the selected text within [value], or the full text if nothing is
  - L60 `Widget buildComposerContextMenu( BuildContext context, EditableTextState editableTextState, )`  — Builds a right-click context menu for the text composer.
  - L113 `Widget buildMessageContextMenu( BuildContext context, SelectableRegionState selectableRegionState, )`  — Builds a right-click context menu for the message selection area.
  - L146 `Future<void> sanitizeClipboardInPlace()`  — Reads the current clipboard text and, if it contains embedded base64 image
  - L161 `Future<void> handleSmartPaste(TextEditingController controller)`  — Handles a Ctrl+V paste.
  - L230 `Future<void> cleanupOldPasteTempDirectories()`  — Removes paste temp directories older than [kPasteTempRetention].

## lib/platform_specific/chat/handlers/desktop_file_handler.dart  (439 Z.)

- L17 `class ValidatedFile`  — Temporary container for validated files before upload.
  - L18 `ValidatedFile({ required this.file, required this.fileName, required this.fileSize, required this.isImage, })`
  - L25 `final File file`
  - L26 `final String fileName`
  - L27 `final int fileSize`
  - L28 `final bool isImage`
  - L29 `late String id`
- L38 `class DesktopFileHandler`  — Handles desktop-specific file attachment processing including:
  - L39 `final List<AttachedFile> attachedFiles = []`
  - L40 `final Uuid _uuid = const Uuid()`
  - L41 `late ChatApiService _chatApiService`
  - L44 `void Function(String)? onShowSnackBar`
  - L45 `VoidCallback? onUpdate`
  - L46 `VoidCallback? onScrollToBottom`
  - L50 `bool modelSupportsImageInput = false`  — Whether the current model supports image input.
  - L55 `bool _isPicking = false`  — Guards against opening a second native picker while one is already open.
  - L57 `void initialize(ChatApiService apiService)`
  - L61 `bool get hasAttachments`
  - L62 `bool get hasUploading`
  - L64 `List<AttachedFile> getUploadedFiles()`
  - L68 `Future<void> processFilePaths(List<String> filePaths)`  — Processes a list of file paths (from drag and drop or file picker)
  - L168 `Future<void> _uploadEncryptedImage( File file, String fileName, String fileId, )`  — Upload image with compression and encryption
  - L211 `Future<void> uploadFiles()`  — Opens file picker and processes selected files.
  - L245 `Future<void> processWebFiles(List<PlatformFile> platformFiles)`  — Process files on web where we only have bytes, not file paths
  - L317 `Future<void> _uploadEncryptedImageFromBytes( Uint8List imageBytes, String fileName, String fileId, )`  — Upload image from bytes (web)
  - L354 `Future<void> handleDroppedFiles(List<String> filePaths)`  — Handles files dropped via drag and drop
  - L359 `void removeAttachedFile(String fileId)`  — Remove an attached file by ID. Cleans up encrypted images from storage.
  - L377 `void handleFileUploadUpdate( String fileId, String? markdownContent, bool isUploading, String? snackBarMessage, { List<String>? pageImages, })`  — Callback for upload status updates from ChatApiService.
  - L426 `void clearAll()`  — Clear all attachments.

## lib/platform_specific/chat/handlers/file_attachment_handler.dart  (429 Z.)

- L18 `class FileAttachmentHandler`  — Handles file and image attachments
  - L19 `final List<AttachedFile> _attachedFiles = []`
  - L20 `final Uuid _uuid = const Uuid()`
  - L21 `final ImagePicker _imagePicker = ImagePicker()`
  - L22 `late final ChatApiService _chatApiService`
  - L25 `Function(String)? onError`
  - L26 `VoidCallback? onUpdate`
  - L31 `bool _isPicking = false`  — Guards against opening a second native picker (files, camera or gallery)
  - L33 `List<AttachedFile> get attachedFiles`
  - L34 `bool get hasAttachments`
  - L35 `bool get hasUploading`
  - L37 `void initialize(ChatApiService apiService)`
  - L42 `Future<void> pickImageFromSource( ImageSource source, { required bool supportsImages, })`  — Pick image from camera or gallery
  - L92 `Future<void> pickImagesFromGallery({required bool supportsImages})`  — Pick multiple images from gallery
  - L136 `Future<void> uploadFiles({required bool supportsImages})`  — Upload files using file picker
  - L189 `Future<void> _handleFileAttachment({ required File file, required String fileName, required int fileSizeBytes, required bool supportsImages, })`
  - L265 `Future<void> _handleWebFileAttachment({ required Future<Uint8List> Function() readBytes, required String fileName, required int fileSizeBytes, required bool supportsImages, })`  — Handle file attachment from bytes (web).
  - L328 `Future<void> _uploadEncryptedImageFromBytes( Uint8List imageBytes, String fileName, String fileId, )`  — Upload image from bytes (web)
  - L356 `bool _isImageExtension(String extension)`
  - L361 `void handleUploadStatusUpdate( String fileId, String? markdownContent, bool isUploading, { List<String>? pageImages, })`  — Handle file upload status update from ChatApiService
  - L405 `void removeFile(String fileId)`  — Remove an attached file.
  - L419 `void clearAll()`  — Clear all attachments
  - L425 `List<AttachedFile> getUploadedFiles()`  — Get files with markdown content (successfully uploaded)

## lib/platform_specific/chat/handlers/message_actions_handler.dart  (196 Z.)

- L12 `class MessageActionsHandler`  — Handles message-related actions (copy, edit, resend)
  - L14 `Function(String)? onShowSnackBar`
  - L15 `Function(int, String)? onSubmitEdit`
  - L16 `Function(int)? onResend`
  - L18 `int? _editingMessageIndex`
  - L20 `int? get editingMessageIndex`
  - L21 `bool get isEditing`
  - L29 `static String _forExport(String text)`  — Strips tool-call protocol from text that is about to leave the app.
  - L33 `Future<void> copyToClipboard(String rawText, {String? label})`  — Copy text to clipboard
  - L57 `void startEdit(int index)`  — Start editing a message at the given index
  - L62 `void cancelEdit()`  — Cancel editing
  - L67 `Future<void> submitEdit(int index, String newText)`  — Submit edited message
  - L79 `Future<void> resend(int index, String text)`  — Resend message at index
  - L88 `List<MessageBubbleAction> buildActionsForMessage({ required int index, required String messageText, required bool isUser, required bool isStreaming, required Function(int) onEdit, required Function(int) onResendMessage, Future<void> Function(int)? onRetryToolPass, bool canRetryToolPass = false, void Function(int)? onBranch, })`  — Build actions for AI messages (shown below the bubble).
  - L156 `List<MessageBubbleAction> buildUserMessageActions({ required int index, required String messageText, required Function(int) onEdit, required Function(int) onResendMessage, })`  — Build actions for user messages (shown in long-press popup).

## lib/platform_specific/chat/handlers/mobile_workspace_handler.dart  (155 Z.)

- L12 `class MobileWorkspaceHandler`  — Handles mobile-specific workspace selection UI and workspace–chat linking.
  - L13 `const MobileWorkspaceHandler._()`
  - L24 `static Future<void> createNewProject({ required BuildContext context, required ValueChanged<String> onShowSnackBar, required void Function(String workspaceId) onOpenWorkspaceManagement, })`  — Shows a dialog that lets the user create a new workspace.
  - L90 `static Future<void> addChatToProject({ required String workspaceId, required String? activeChatId, required ValueChanged<String> onShowSnackBar, required VoidCallback onStateChanged, })`  — Adds the chat identified by [activeChatId] to the given workspace.
  - L110 `static Future<void> removeChatFromProject({ required String workspaceId, required String? activeChatId, required ValueChanged<String> onShowSnackBar, required VoidCallback onStateChanged, })`  — Removes the chat identified by [activeChatId] from the given workspace.
  - L137 `static void openProjectManagement({ required BuildContext context, required String workspaceId, required void Function(String? workspaceId) onStartNewChat, })`  — Pushes the [WorkspaceManagementPage] for the given [workspaceId].

## lib/platform_specific/chat/handlers/scanned_pdf_pages.dart  (89 Z.)

- L20 `Future<void> replaceWithScannedPages({ required List<String> dataUrls, required String fileId, required String fileName, required String? note, required List<AttachedFile> attachedFiles, void Function()? onUpdate, void Function(String message)? onError, })`  — Replaces a scanned PDF in [attachedFiles] with its rendered pages.
- L82 `void discardScannedPages(List<String> paths)`  — Deletes pages that were uploaded before the replacement failed, so a

## lib/platform_specific/chat/handlers/streaming_message_handler.dart  (1571 Z.)

- L25 `class StreamingMessageHandler`  — Handles message streaming and sending
  - L26 `StreamingMessageHandler()`
  - L33 `final StreamingManager _streamingManager = StreamingManager()`
  - L34 `final ToolCallHandler _toolCallHandler = ToolCallHandler()`
  - L37 `Function(String)? onShowSnackBar`
  - L38 `Function()? onUpdateUI`
  - L39 `Function(int index, String content, String reasoning, String chatId)? onMessageUpdate`
  - L41 `Function( int index, String content, String reasoning, String chatId, double? tps, )? onMessageFinalize`
  - L49 `Function(int index, List<ToolCall> toolCalls, String chatId)? onToolCallsUpdate`
  - L51 `Function( int index, List<String> imagePaths, String imageMetasJson, String? imageCostEur, String? imageGeneratedAt, String toolCallsJson, String chatId, )? onToolImagesProcessed`
  - L64 `Function(int index, String contentBlocksJson, String chatId)? onContentBlocksUpdate`  — Called when content blocks are updated during or after the tool loop.
  - L69 `Function(int index, String requestPayloadJson, String chatId)? onRequestPayloadUpdate`  — Called when an outbound request payload is prepared for a streaming pass.
  - L72 `Function(String chatId, int index, String content, String reasoning)? onBackgroundUpdate`
  - L80 `Function(String chatId, int index)? onStreamInterrupted`  — Called when the active stream is torn down (dispose / cancel /
  - L92 `Function( String chatId, int index, String content, String reasoning, String? contentBlocksJson, bool forceImmediate, )? onStreamTick`  — Fires on a periodic timer (and immediately on lifecycle pause /
  - L102 `Function()? onPaymentRequired`
  - L104 `bool _isStreaming = false`
  - L105 `bool _isSending = false`
  - L106 `bool _isDisposed = false`
  - L111 `bool _cancelRequested = false`
  - L112 `bool _hasForegroundKeepAliveLock = false`
  - L113 `Future<void>? _activeToolLoopFuture`
  - L123 `static const Duration _snapshotInterval = Duration(milliseconds: 500)`
  - L124 `Timer? _snapshotTimer`
  - L125 `_StreamingSnapshot? _currentSnapshot`
  - L126 `bool _streamFinalized = false`
  - L128 `bool get isStreaming`
  - L129 `bool get isSending`
  - L130 `Future<void>? get activeToolLoopFuture`
  - L135 `Future<void> sendMessage({ required String userInput, required List<AttachedFile> attachedFiles, required String selectedModelId, required String? selectedProviderSlug, required List<Map<String, String>> messages, required String? systemPrompt, required String? activeChatId, required int placeholderIndex, required Future<String?> Function() getProviderSlug, required bool isOffline, bool includeRecentImagesInHistory = true, bool includeAllImagesInHistory = false, bool includeReasoningInHistory = false, bool includeToolResultsInHistory = true, bool toolCallingEnabled = true, bool toolDiscoveryMode = true, String? reasoningEffort, String? continuePriorText, String? continuePriorContentBlocksJson, })`  — Send a message with streaming response
  - L1189 `Future<void> cancelStream(String? chatId)`  — Cancel active stream
  - L1213 `Future<void> _processToolImages( List<ToolCall> toolCalls, int index, String chatId, )`  — Download tool-generated images, encrypt, and persist to Supabase storage.
  - L1256 `Future<void> _acquireForegroundKeepAlive()`
  - L1275 `Future<void> _releaseForegroundKeepAlive()`
  - L1290 `Future<void> _updateForegroundNotification({ required String title, required String content, })`
  - L1311 `void resetState()`  — Reset state (use when stuck in invalid state)
  - L1326 `bool isChatStreaming(String chatId)`  — Check if a specific chat is streaming
  - L1331 `String? getBufferedContent(String chatId)`  — Get buffered content for a streaming chat
  - L1336 `String? getBufferedReasoning(String chatId)`  — Get buffered reasoning for a streaming chat
  - L1341 `int? getStreamingMessageIndex(String chatId)`  — Get the streaming message index for a chat
  - L1346 `bool hasCompletedStream(String chatId)`  — Check if a chat has a completed stream with buffered content
  - L1351 `void consumeCompletedStream(String chatId)`  — Remove a completed stream entry after its content has been consumed
  - L1356 `void setBackgroundMessages( String chatId, List<Map<String, dynamic>> messages, )`  — Store background messages for a streaming chat when user switches away
  - L1367 `List<Map<String, dynamic>>? getBackgroundMessages(String chatId)`  — Get the most recent background snapshot for a chat, with the live buffer
  - L1372 `bool hasBackgroundMessages(String chatId)`  — Whether a background snapshot exists for this chat.
  - L1378 `Future<List<Map<String, dynamic>>> _buildApiHistory( List<Map<String, String>> messages, String pendingUserText, { bool includeRecentImages = true, bool includeAllImages = false, bool includeReasoning = false, bool includeToolResults = true, })`  — Delegates to [ChatHistoryBuilder] — see that file for why this must not
  - L1397 `Future<dynamic> getSessionSafely()`  — Get session safely with network error handling
  - L1440 `void _markStreamFinalized()`  — Mark the active stream as cleanly finished (a final-answer event ran).
  - L1454 `void _recordSnapshot({ required String chatId, required int index, required String content, required String reasoning, String? contentBlocksJson, })`
  - L1474 `void _flushSnapshot({bool forceImmediate = false})`
  - L1509 `void _clearSnapshot()`
  - L1518 `void _handleAppPaused()`  — Called by the lifecycle service when the app moves to background.
  - L1524 `void _markInterruptedIfStreaming()`
  - L1540 `void dispose()`  — Dispose resources
- L1556 `class _StreamingSnapshot`
  - L1557 `_StreamingSnapshot({ required this.chatId, required this.index, required this.content, required this.reasoning, this.contentBlocksJson, })`
  - L1565 `final String chatId`
  - L1566 `final int index`
  - L1567 `final String content`
  - L1568 `final String reasoning`
  - L1569 `final String? contentBlocksJson`
