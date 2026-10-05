// lib/l10n/app_localizations.dart
// Simple manual localization — no code generation needed.

import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_es.dart';
import 'package:chuk_chat/l10n/strings_fr.dart';
import 'package:chuk_chat/l10n/strings_pt.dart';

/// Holds all translated UI strings for the current locale.
///
/// Access via `AppLocalizations.of(context)!.someKey`.
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('de'),
    Locale('es'),
    Locale('fr'),
    Locale('pt'),
  ];

  static const Map<String, Map<String, String> Function()> _localeMap = {
    'de': _getDe,
    'es': _getEs,
    'fr': _getFr,
    'pt': _getPt,
  };

  static Map<String, String> _getDe() => stringsDe;
  static Map<String, String> _getEs() => stringsEs;
  static Map<String, String> _getFr() => stringsFr;
  static Map<String, String> _getPt() => stringsPt;

  late final Map<String, String> _strings =
      _localeMap[locale.languageCode]?.call() ?? stringsEn;

  String _get(String key) => _strings[key] ?? stringsEn[key] ?? key;

  // ── Settings page ──────────────────────────────────────────
  String get settings => _get('settings');
  String get themeSettings => _get('themeSettings');
  String get themeSettingsSubtitle => _get('themeSettingsSubtitle');
  String get customization => _get('customization');
  String get customizationSubtitle => _get('customizationSubtitle');
  String get toolCalling => _get('toolCalling');
  String get toolCallingSubtitle => _get('toolCallingSubtitle');
  String get connectorsSubtitle => _get('connectorsSubtitle');
  String get skills => _get('skills');
  String get skillsSubtitle => _get('skillsSubtitle');
  String get skillsExplainer => _get('skillsExplainer');
  String get skillsYours => _get('skillsYours');
  String get skillsYoursEmpty => _get('skillsYoursEmpty');
  String get skillsBuiltin => _get('skillsBuiltin');
  String get skillsSearchHint => _get('skillsSearchHint');
  String skillsNoMatches(String query) =>
      _get('skillsNoMatches').replaceAll('{query}', query);
  String get skillNew => _get('skillNew');
  String get skillEdit => _get('skillEdit');
  String get skillDeleteTitle => _get('skillDeleteTitle');
  String skillDeleteBody(String name) =>
      _get('skillDeleteBody').replaceAll('{name}', name);
  String get skillEditorHint => _get('skillEditorHint');
  String get skillSaveFailed => _get('skillSaveFailed');
  String get assistantSurface => _get('assistantSurface');
  String get assistantSurfaceSubtitle => _get('assistantSurfaceSubtitle');
  String get developerOptions => _get('developerOptions');
  String get developerOptionsSubtitle => _get('developerOptionsSubtitle');
  String get modelSelection => _get('modelSelection');
  String get modelDefaultAgentsInfo => _get('modelDefaultAgentsInfo');
  String get modelSelectionSubtitle => _get('modelSelectionSubtitle');
  String get aiIdentityMemory => _get('aiIdentityMemory');
  String get aiIdentityMemorySubtitle => _get('aiIdentityMemorySubtitle');
  String get pricingPlans => _get('pricingPlans');
  String get pricingPlansSubtitle => _get('pricingPlansSubtitle');
  String get accountSettings => _get('accountSettings');
  String get exportChats => _get('exportChats');
  String get exportChatsSubtitle => _get('exportChatsSubtitle');
  String get about => _get('about');
  String get aboutSubtitle => _get('aboutSubtitle');
  String get logout => _get('logout');
  String get logoutFailed => _get('logoutFailed');
  String get noChatsToExport => _get('noChatsToExport');
  String get copiedToClipboard => _get('copiedToClipboard');
  String savedToPath(String path) =>
      _get('savedToPath').replaceAll('{path}', path);
  String get exportCancelled => _get('exportCancelled');
  String get shareOpened => _get('shareOpened');
  String exportFailed(String error) =>
      _get('exportFailed').replaceAll('{error}', error);
  String get saveChatExport => _get('saveChatExport');

  // ── Customization page ─────────────────────────────────────
  String get language => _get('language');
  String get languageSubtitle => _get('languageSubtitle');
  String get voiceTranscription => _get('voiceTranscription');
  String get autoSendVoice => _get('autoSendVoice');
  String get autoSendVoiceSubtitle => _get('autoSendVoiceSubtitle');
  String get autoSendVoiceInfo => _get('autoSendVoiceInfo');
  String get messageDisplay => _get('messageDisplay');
  String get showReasoningTokens => _get('showReasoningTokens');
  String get showReasoningTokensSubtitle => _get('showReasoningTokensSubtitle');
  String get showModelInfo => _get('showModelInfo');
  String get showModelInfoSubtitle => _get('showModelInfoSubtitle');
  String get showTps => _get('showTps');
  String get showTpsSubtitle => _get('showTpsSubtitle');
  String get chatFontSize => _get('chatFontSize');
  String get chatFontSizeSubtitle => _get('chatFontSizeSubtitle');
  String get uiScale => _get('uiScale');
  String get uiScaleSubtitle => _get('uiScaleSubtitle');
  String uiScalePercentage(String percent) =>
      _get('uiScalePercentage').replaceAll('{percent}', percent);
  String get fontSizePreview => _get('fontSizePreview');
  String get chatFontFamily => _get('chatFontFamily');
  String get chatFontFamilySubtitle => _get('chatFontFamilySubtitle');
  String get fontFamilySystem => _get('fontFamilySystem');
  String get fontFamilyArimo => _get('fontFamilyArimo');
  String get fontFamilyMerriweather => _get('fontFamilyMerriweather');
  String get fontFamilyJetBrainsMono => _get('fontFamilyJetBrainsMono');
  // Theme editor: presets, contrast and fonts.
  String get themePresets => _get('themePresets');
  String get themePresetPack => _get('themePresetPack');
  String get themePresetPackSubtitle => _get('themePresetPackSubtitle');
  String get themePresetCustom => _get('themePresetCustom');
  String get themeContrast => _get('themeContrast');
  String get themeContrastStrength => _get('themeContrastStrength');
  String get themeContrastSubtitle => _get('themeContrastSubtitle');
  String get themeFonts => _get('themeFonts');
  String get interfaceFont => _get('interfaceFont');
  String get interfaceFontSubtitle => _get('interfaceFontSubtitle');
  String get downloads => _get('downloads');
  String get downloadsSubtitle => _get('downloadsSubtitle');
  String get downloadsAlwaysAsk => _get('downloadsAlwaysAsk');
  String get downloadsAlwaysAskHintCan => _get('downloadsAlwaysAskHintCan');
  String get downloadsAlwaysAskHintNoFolder =>
      _get('downloadsAlwaysAskHintNoFolder');
  String get downloadsDefaultFolder => _get('downloadsDefaultFolder');
  String get downloadsDefaultFolderUnset => _get('downloadsDefaultFolderUnset');
  String get downloadsChooseFolderDialog => _get('downloadsChooseFolderDialog');
  String get downloadsClear => _get('downloadsClear');
  String get downloadsInfo => _get('downloadsInfo');
  String get aiContext => _get('aiContext');
  String get recentImagesInContext => _get('recentImagesInContext');
  String get recentImagesInContextSubtitle =>
      _get('recentImagesInContextSubtitle');
  String get allImagesInContext => _get('allImagesInContext');
  String get allImagesInContextSubtitle => _get('allImagesInContextSubtitle');
  String get reasoningInContext => _get('reasoningInContext');
  String get reasoningInContextSubtitle => _get('reasoningInContextSubtitle');
  String get toolResultsInContext => _get('toolResultsInContext');
  String get toolResultsInContextSubtitle =>
      _get('toolResultsInContextSubtitle');
  String get aiContextInfo => _get('aiContextInfo');
  String get chatTitles => _get('chatTitles');
  String get autoGenerateTitles => _get('autoGenerateTitles');
  String get autoGenerateTitlesSubtitle => _get('autoGenerateTitlesSubtitle');
  String get titleGenerationPrompt => _get('titleGenerationPrompt');
  String get usingCustomPrompt => _get('usingCustomPrompt');
  String get usingDefaultPrompt => _get('usingDefaultPrompt');
  String get titleGenInfo => _get('titleGenInfo');
  String get systemPromptSaved => _get('systemPromptSaved');
  String get systemPromptResetToDefault => _get('systemPromptResetToDefault');
  String get reset => _get('reset');
  String get save => _get('save');

  // ── Per-model system prompt ──────────────────────────────────
  String get perModelPromptTitle => _get('perModelPromptTitle');
  String get perModelPromptHint => _get('perModelPromptHint');
  String get perModelPromptPlaceholder => _get('perModelPromptPlaceholder');
  String get perModelPromptEdit => _get('perModelPromptEdit');
  String get perModelPromptEditConfigured =>
      _get('perModelPromptEditConfigured');
  String get perModelPromptRemove => _get('perModelPromptRemove');
  String get perModelPromptSaveFailed => _get('perModelPromptSaveFailed');
  String get perModelPromptDeleteFailed => _get('perModelPromptDeleteFailed');
  String get perModelPromptModeLabel => _get('perModelPromptModeLabel');
  String get perModelPromptModeOff => _get('perModelPromptModeOff');
  String get perModelPromptModeAppend => _get('perModelPromptModeAppend');
  String get perModelPromptModePrepend => _get('perModelPromptModePrepend');
  String get perModelPromptModeReplace => _get('perModelPromptModeReplace');
  String get perModelPromptModeOffHint => _get('perModelPromptModeOffHint');
  String get perModelPromptModeAppendHint =>
      _get('perModelPromptModeAppendHint');
  String get perModelPromptModePrependHint =>
      _get('perModelPromptModePrependHint');
  String get perModelPromptModeReplaceHint =>
      _get('perModelPromptModeReplaceHint');

  // ── Theme page ─────────────────────────────────────────────
  String get darkMode => _get('darkMode');
  String get darkModeSubtitle => _get('darkModeSubtitle');
  String get accentColor => _get('accentColor');
  String get accentColorSubtitle => _get('accentColorSubtitle');
  String get iconFgColor => _get('iconFgColor');
  String get iconFgColorSubtitle => _get('iconFgColorSubtitle');
  String get backgroundColor => _get('backgroundColor');
  String get backgroundColorSubtitle => _get('backgroundColorSubtitle');
  String get dynamicColor => _get('dynamicColor');
  String get dynamicColorSubtitle => _get('dynamicColorSubtitle');
  String get colorDynamicNote => _get('colorDynamicNote');
  String get customHexColor => _get('customHexColor');
  String get pickCustomColor => _get('pickCustomColor');
  String get pickAColor => _get('pickAColor');
  String get hue => _get('hue');
  String get saturation => _get('saturation');
  String get brightness => _get('brightness');
  String get useColor => _get('useColor');
  String get searchWorkspacesHint => _get('searchWorkspacesHint');
  String get newWorkspace => _get('newWorkspace');
  String editedAt(String date) => _get('editedAt').replaceAll('{date}', date);
  String get aiDisclaimer => _get('aiDisclaimer');
  String get agentsAiDisclaimer => _get('agentsAiDisclaimer');
  String get archive => _get('archive');
  // Agents: the live status line and the browser takeover card.
  String get agentsPhaseSending => _get('agentsPhaseSending');
  String get agentsPhaseNoAnswer => _get('agentsPhaseNoAnswer');
  String get agentsPhaseOffline => _get('agentsPhaseOffline');
  String get agentsPhaseReceived => _get('agentsPhaseReceived');
  String get agentsPhaseQueued => _get('agentsPhaseQueued');
  String get agentsPhasePreparing => _get('agentsPhasePreparing');
  String get agentsPhaseThinking => _get('agentsPhaseThinking');
  String get agentsPhaseWorking => _get('agentsPhaseWorking');
  String get agentsPhaseWriting => _get('agentsPhaseWriting');
  String get agentsPhaseWaitingForYou => _get('agentsPhaseWaitingForYou');
  String get agentsPhaseNotDelivered => _get('agentsPhaseNotDelivered');
  String get agentsPhaseRetry => _get('agentsPhaseRetry');
  // UI audit fixes A: tool phase, automation states, phone coworker page.
  String get agentsToolSearchingWeb => _get('agentsToolSearchingWeb');
  String get agentsToolSearching => _get('agentsToolSearching');
  String get agentsToolReadingPage => _get('agentsToolReadingPage');
  String get agentsToolCompiling => _get('agentsToolCompiling');
  String get agentsToolGeneratingImage => _get('agentsToolGeneratingImage');
  String get agentsToolRunningCommand => _get('agentsToolRunningCommand');
  String get agentsToolSendingFile => _get('agentsToolSendingFile');
  String agentsToolRunning(String tool) =>
      _get('agentsToolRunning').replaceAll('{tool}', tool);
  String get agentsAutomationStateActive => _get('agentsAutomationStateActive');
  String get agentsAutomationStatePaused => _get('agentsAutomationStatePaused');
  String get agentsAutomationStateDone => _get('agentsAutomationStateDone');
  String get agentsAutomationStateFailed => _get('agentsAutomationStateFailed');
  String get agentsCwTitle => _get('agentsCwTitle');
  String get agentsCwGone => _get('agentsCwGone');
  String get agentsCwEdit => _get('agentsCwEdit');
  String agentsCwRemoveTitle(String name) =>
      _get('agentsCwRemoveTitle').replaceAll('{name}', name);
  String get agentsCwRemoveBody => _get('agentsCwRemoveBody');
  String get agentsCwRemove => _get('agentsCwRemove');
  String get agentsCwRemoveCoworker => _get('agentsCwRemoveCoworker');
  String get agentsCwRoleFallback => _get('agentsCwRoleFallback');
  String get agentsCwModel => _get('agentsCwModel');
  String get agentsCwModelSubtitle => _get('agentsCwModelSubtitle');
  String get agentsCwProfile => _get('agentsCwProfile');
  String get agentsCwProfileSubtitle => _get('agentsCwProfileSubtitle');
  String get agentsCwHost => _get('agentsCwHost');
  String get agentsCwHostSubtitle => _get('agentsCwHostSubtitle');
  String get agentsCwSharedFiles => _get('agentsCwSharedFiles');
  String get agentsCwDocuments => _get('agentsCwDocuments');
  String get agentsCwDocumentsSubtitle => _get('agentsCwDocumentsSubtitle');
  String get agentsCwConversation => _get('agentsCwConversation');
  String get agentsCwShowThinking => _get('agentsCwShowThinking');
  String get agentsCwShowThinkingSubtitle =>
      _get('agentsCwShowThinkingSubtitle');
  String get agentsCwShowWork => _get('agentsCwShowWork');
  String get agentsCwShowWorkSubtitle => _get('agentsCwShowWorkSubtitle');
  String get agentsCwExport => _get('agentsCwExport');
  String get agentsCwAgentTools => _get('agentsCwAgentTools');
  String get agentsCwSchedules => _get('agentsCwSchedules');
  String get agentsCwSchedulesSubtitle => _get('agentsCwSchedulesSubtitle');
  String get agentsCwConnections => _get('agentsCwConnections');
  String get agentsCwConnectedApps => _get('agentsCwConnectedApps');
  String get agentsCwApiKeys => _get('agentsCwApiKeys');
  String get agentsCwControlRooms => _get('agentsCwControlRooms');
  String get agentsCwOpenScreen => _get('agentsCwOpenScreen');
  String get agentsCwApp => _get('agentsCwApp');
  String get agentsCwAccountSettings => _get('agentsCwAccountSettings');
  String get agentsCwAccountSettingsSubtitle =>
      _get('agentsCwAccountSettingsSubtitle');
  String get agentsCwActionChat => _get('agentsCwActionChat');
  String get agentsCwActionFiles => _get('agentsCwActionFiles');
  String get agentsCwActionSchedules => _get('agentsCwActionSchedules');
  String get agentsCwActionSkills => _get('agentsCwActionSkills');
  String takeoverTitle(String name) =>
      _get('takeoverTitle').replaceAll('{name}', name);
  String get takeoverSomeone => _get('takeoverSomeone');
  String get takeoverThisSite => _get('takeoverThisSite');
  String takeoverLogin(String site) =>
      _get('takeoverLogin').replaceAll('{site}', site);
  String takeoverTwoFactor(String site) =>
      _get('takeoverTwoFactor').replaceAll('{site}', site);
  String takeoverCaptcha(String site) =>
      _get('takeoverCaptcha').replaceAll('{site}', site);
  String takeoverOther(String site) =>
      _get('takeoverOther').replaceAll('{site}', site);
  String get takeoverOpen => _get('takeoverOpen');
  String get takeoverDone => _get('takeoverDone');
  String get takeoverSkip => _get('takeoverSkip');
  String takeoverContinues(String name) =>
      _get('takeoverContinues').replaceAll('{name}', name);
  // Agents: a coworker's Telegram channel.
  String get agentsChannels => _get('agentsChannels');
  String get agentsTelegramTitle => _get('agentsTelegramTitle');
  String get agentsTelegramNotE2e => _get('agentsTelegramNotE2e');
  String get agentsTelegramPaste => _get('agentsTelegramPaste');
  String get agentsTelegramTokenLabel => _get('agentsTelegramTokenLabel');
  String get agentsTelegramTokenHint => _get('agentsTelegramTokenHint');
  String get agentsTelegramTurnOn => _get('agentsTelegramTurnOn');
  String get agentsTelegramCancel => _get('agentsTelegramCancel');
  String agentsTelegramLinkSteps(String bot) =>
      _get('agentsTelegramLinkSteps').replaceAll('{bot}', bot);
  String get agentsTelegramLinkStepsNoBot =>
      _get('agentsTelegramLinkStepsNoBot');
  String get agentsTelegramCodeLabel => _get('agentsTelegramCodeLabel');
  String get agentsTelegramLink => _get('agentsTelegramLink');
  String agentsTelegramLinkedTo(String name) =>
      _get('agentsTelegramLinkedTo').replaceAll('{name}', name);
  String get agentsTelegramLinkedChat => _get('agentsTelegramLinkedChat');
  String get agentsTelegramUnlink => _get('agentsTelegramUnlink');
  String get agentsTelegramForget => _get('agentsTelegramForget');
  String get agentsTelegramStateOff => _get('agentsTelegramStateOff');
  String get agentsTelegramStateDisallowed =>
      _get('agentsTelegramStateDisallowed');
  String get agentsTelegramStateStarting => _get('agentsTelegramStateStarting');
  String agentsTelegramStatePolling(String bot) =>
      _get('agentsTelegramStatePolling').replaceAll('{bot}', bot);
  String get agentsTelegramStateOn => _get('agentsTelegramStateOn');
  String get agentsTelegramStateBackoff => _get('agentsTelegramStateBackoff');
  String get agentsTelegramStateConflict => _get('agentsTelegramStateConflict');
  String get agentsTelegramStateUnauthorized =>
      _get('agentsTelegramStateUnauthorized');
  String get agentsTelegramStateStopped => _get('agentsTelegramStateStopped');
  String get agentsTelegramOffline => _get('agentsTelegramOffline');
  String get agentsTelegramAsking => _get('agentsTelegramAsking');
  String get agentsTelegramNoAnswer => _get('agentsTelegramNoAnswer');
  String get agentsTelegramErrTokenRequired =>
      _get('agentsTelegramErrTokenRequired');
  String get agentsTelegramErrTokenInvalid =>
      _get('agentsTelegramErrTokenInvalid');
  String get agentsTelegramErrTokenInUse => _get('agentsTelegramErrTokenInUse');
  String get agentsTelegramErrNotRunning => _get('agentsTelegramErrNotRunning');
  String get agentsTelegramErrWrongCode => _get('agentsTelegramErrWrongCode');
  String get agentsTelegramErrTooManyAttempts =>
      _get('agentsTelegramErrTooManyAttempts');
  String get agentsTelegramErrNoPendingLink =>
      _get('agentsTelegramErrNoPendingLink');
  String get agentsTelegramErrUnknownAgent =>
      _get('agentsTelegramErrUnknownAgent');
  String agentsTelegramErrOther(String code) =>
      _get('agentsTelegramErrOther').replaceAll('{code}', code);

  // ── Tool calling page ──────────────────────────────────────
  String get engine => _get('engine');
  String get enableToolCalling => _get('enableToolCalling');
  String get enableToolCallingSubtitle => _get('enableToolCallingSubtitle');
  String get behavior => _get('behavior');
  String get requireDiscoveryFirst => _get('requireDiscoveryFirst');
  String get requireDiscoverySubtitle => _get('requireDiscoverySubtitle');
  String get display => _get('display');
  String get showToolActivity => _get('showToolActivity');
  String get showToolActivitySubtitle => _get('showToolActivitySubtitle');
  String get toolCallingTip => _get('toolCallingTip');
  String get toolAlwaysOn => _get('toolAlwaysOn');
  String get toolArtifacts => _get('toolArtifacts');
  String get toolArtifactsSubtitle => _get('toolArtifactsSubtitle');
  String get toolGroupCodeArtifacts => _get('toolGroupCodeArtifacts');
  String get connectors => _get('connectors');
  String get loadingToolSettings => _get('loadingToolSettings');
  String get noToolsRegistered => _get('noToolsRegistered');
  String get catSearchWeb => _get('catSearchWeb');
  String get catUtilities => _get('catUtilities');
  String get catMapsLocation => _get('catMapsLocation');
  String get catDevice => _get('catDevice');
  String get catBashTerminal => _get('catBashTerminal');
  String get catGitHub => _get('catGitHub');
  String get catSlack => _get('catSlack');
  String get catGoogleCalGmail => _get('catGoogleCalGmail');
  String get catSearchWebDesc => _get('catSearchWebDesc');
  String get catUtilitiesDesc => _get('catUtilitiesDesc');
  String get catMapsLocationDesc => _get('catMapsLocationDesc');
  String get catDeviceDesc => _get('catDeviceDesc');
  String get catBashTerminalDesc => _get('catBashTerminalDesc');
  String get catGitHubDesc => _get('catGitHubDesc');
  String get catSlackDesc => _get('catSlackDesc');
  String get catGoogleCalGmailDesc => _get('catGoogleCalGmailDesc');
  String get connect => _get('connect');
  String get disconnect => _get('disconnect');
  String disconnectCategory(String label) =>
      _get('disconnectCategory').replaceAll('{label}', label);
  String get removeCredentialsWarning => _get('removeCredentialsWarning');
  String get cancel => _get('cancel');
  String get toolWebSearch => _get('toolWebSearch');
  String get toolWebCrawl => _get('toolWebCrawl');
  String get toolImageGen => _get('toolImageGen');
  String get toolFetchImage => _get('toolFetchImage');
  String get toolViewChatImages => _get('toolViewChatImages');
  String get toolCryptoData => _get('toolCryptoData');
  String get toolWeather => _get('toolWeather');
  String get toolPlaceSearch => _get('toolPlaceSearch');
  String get toolRestaurantSearch => _get('toolRestaurantSearch');
  String get toolGeocoding => _get('toolGeocoding');
  String get toolRouting => _get('toolRouting');
  String get toolCalculator => _get('toolCalculator');
  String get toolClock => _get('toolClock');
  String get toolRandomNumber => _get('toolRandomNumber');
  String get toolCoinFlip => _get('toolCoinFlip');
  String get toolDiceRoll => _get('toolDiceRoll');
  String get toolCountdown => _get('toolCountdown');
  String get toolPasswordGen => _get('toolPasswordGen');
  String get toolUuidGen => _get('toolUuidGen');
  String get toolNotes => _get('toolNotes');
  String get toolQrGen => _get('toolQrGen');
  String get resetToolSettingsTitle => _get('resetToolSettingsTitle');
  String get resetToolSettingsBody => _get('resetToolSettingsBody');
  String get resetAllToolPrefs => _get('resetAllToolPrefs');

  // ── Account settings page ──────────────────────────────────
  String get profile => _get('profile');
  String get displayName => _get('displayName');
  String get displayNameHint => _get('displayNameHint');
  String get emailAddress => _get('emailAddress');
  String get emailAddressHint => _get('emailAddressHint');
  String get security => _get('security');
  String get changePassword => _get('changePassword');
  String get currentPassword => _get('currentPassword');
  String get newPassword => _get('newPassword');
  String get minCharsPassword => _get('minCharsPassword');
  String get confirmNewPassword => _get('confirmNewPassword');
  String get updatePassword => _get('updatePassword');
  String get encryptedChatRecovery => _get('encryptedChatRecovery');
  String lockedChatsCount(int count) => _get(
    count == 1 ? 'lockedChatsSingular' : 'lockedChatsPlural',
  ).replaceAll('{count}', count.toString());
  String get recoverOldChatsAvailable => _get('recoverOldChatsAvailable');
  String get chatsFromPreviousPassword => _get('chatsFromPreviousPassword');
  String get recoverChats => _get('recoverChats');
  String get deleteAccountWarning => _get('deleteAccountWarning');
  String get deleteAccount => _get('deleteAccount');
  String get unableToLoadProfile => _get('unableToLoadProfile');
  String get retry => _get('retry');

  // ── Chat maintenance (payload v3 rewrite) ──────────────────
  String get maintenanceTitle => _get('maintenanceTitle');
  String get maintenanceBody => _get('maintenanceBody');
  String get maintenanceMigrating => _get('maintenanceMigrating');
  String get maintenanceVerifying => _get('maintenanceVerifying');
  String maintenanceCount(int n, int total) => _get(
    'maintenanceCount',
  ).replaceAll('{n}', '$n').replaceAll('{total}', '$total');
  String get maintenanceFailedTitle => _get('maintenanceFailedTitle');
  String get maintenanceFailedBody => _get('maintenanceFailedBody');
  String get maintenanceContinue => _get('maintenanceContinue');
  String get saved => _get('saved');
  String emailUpdated(String email) =>
      _get('emailUpdated').replaceAll('{email}', email);
  String failedToLoadProfile(String error) =>
      _get('failedToLoadProfile').replaceAll('{error}', error);
  String failedToSaveProfile(String error) =>
      _get('failedToSaveProfile').replaceAll('{error}', error);
  String get emailCannotBeEmpty => _get('emailCannotBeEmpty');
  String get passwordsDoNotMatch => _get('passwordsDoNotMatch');
  String failedToChangePassword(String error) =>
      _get('failedToChangePassword').replaceAll('{error}', error);
  String get deleteAccountQuestion => _get('deleteAccountQuestion');
  String get deleteAccountConfirmBody => _get('deleteAccountConfirmBody');
  String get yesDelete => _get('yesDelete');
  String get thisIsPermanent => _get('thisIsPermanent');
  String get finalDeleteWarning => _get('finalDeleteWarning');
  String get noKeepMyAccount => _get('noKeepMyAccount');
  String get deleteEverything => _get('deleteEverything');
  String get confirmYourPassword => _get('confirmYourPassword');
  String get confirmPasswordBody => _get('confirmPasswordBody');
  String get password => _get('password');
  String get passwordRequired => _get('passwordRequired');
  String verificationFailed(String error) =>
      _get('verificationFailed').replaceAll('{error}', error);
  String get verifyAndDelete => _get('verifyAndDelete');
  String failedToDeleteAccount(String error) =>
      _get('failedToDeleteAccount').replaceAll('{error}', error);

  // ── System prompt / Identity page ──────────────────────────
  String get identitySystem => _get('identitySystem');
  String get identityActive => _get('identityActive');
  String get identityDisabled => _get('identityDisabled');
  String get soul => _get('soul');
  String get soulHint => _get('soulHint');
  String get soulExample => _get('soulExample');
  String get user => _get('user');
  String get userHint => _get('userHint');
  String get userExample => _get('userExample');
  String get memory => _get('memory');
  String get memoryHint => _get('memoryHint');
  String get memoryExample => _get('memoryExample');
  String get importFromAnotherAi => _get('importFromAnotherAi');
  String get systemPrompt => _get('systemPrompt');
  String get systemPromptHint => _get('systemPromptHint');
  String get systemPromptExample => _get('systemPromptExample');
  String get characters => _get('characters');
  String get saving => _get('saving');
  String get saveChanges => _get('saveChanges');

  // ── About page ─────────────────────────────────────────────
  String get chukChat => _get('chukChat');
  String get openSourceLicenses => _get('openSourceLicenses');
  String get openSourceLicensesSubtitle => _get('openSourceLicensesSubtitle');
  String get termsOfService => _get('termsOfService');
  String get privacyPolicy => _get('privacyPolicy');
  String versionText(String version) =>
      _get('versionText').replaceAll('{version}', version);
  String builtOn(String date) => _get('builtOn').replaceAll('{date}', date);
  String updateAvailable(String version) =>
      _get('updateAvailable').replaceAll('{version}', version);
  String get versionUnavailable => _get('versionUnavailable');
  String copyrightYear(String year) =>
      _get('copyrightYear').replaceAll('{year}', year);
  String get licenses => _get('licenses');
  String get unableToLoadLicenses => _get('unableToLoadLicenses');
  String get tapToViewLicense => _get('tapToViewLicense');
  String get devOptionsEnabled => _get('devOptionsEnabled');
  String get devOptionsAlreadyEnabled => _get('devOptionsAlreadyEnabled');
  String devOptionsTaps(int taps) => _get(
    taps == 1 ? 'devOptionsTapSingular' : 'devOptionsTapsPlural',
  ).replaceAll('{taps}', taps.toString());

  // ── Pricing page ───────────────────────────────────────────
  String get subscription => _get('subscription');
  String get openUsageDetailsInfo => _get('openUsageDetailsInfo');
  String get openUsageDetails => _get('openUsageDetails');
  String get currentPlan => _get('currentPlan');
  String get plus => _get('plus');
  String get pricePerMonth => _get('pricePerMonth');
  String get monthlyCredits => _get('monthlyCredits');
  String get unusedCreditsExpire => _get('unusedCreditsExpire');
  String get manageBilling => _get('manageBilling');
  String get manageBillingSubtitle => _get('manageBillingSubtitle');
  String get paymentsDisabledInBuild => _get('paymentsDisabledInBuild');
  String get active => _get('active');
  String get getCreditsMonthly => _get('getCreditsMonthly');
  String get accessAllModels => _get('accessAllModels');
  String get imageGeneration => _get('imageGeneration');
  String get voiceMode => _get('voiceMode');
  String get textChatReasoning => _get('textChatReasoning');
  String get creditsExplanation => _get('creditsExplanation');
  String get immediateAccessAck => _get('immediateAccessAck');
  String get rightOfWithdrawal => _get('rightOfWithdrawal');
  String get onceServiceBegins => _get('onceServiceBegins');
  String get subscribeNow => _get('subscribeNow');
  String get alreadySubscribed => _get('alreadySubscribed');
  String get opening => _get('opening');
  String get agreeToTermsFirst => _get('agreeToTermsFirst');

  // ── Login page ─────────────────────────────────────────────
  String get welcomeToChukChat => _get('welcomeToChukChat');
  String get signInWithEmail => _get('signInWithEmail');
  String get createAccountWithEmail => _get('createAccountWithEmail');
  String get supabaseNotConfigured => _get('supabaseNotConfigured');
  String get howOthersSeeYou => _get('howOthersSeeYou');
  String get email => _get('email');
  String get emailPlaceholder => _get('emailPlaceholder');
  String get confirmPassword => _get('confirmPassword');
  String get forgotPassword => _get('forgotPassword');
  String get enterYourPassword => _get('enterYourPassword');
  String get pleaseConfirmPassword => _get('pleaseConfirmPassword');
  String get signIn => _get('signIn');
  String get createAccount => _get('createAccount');
  String get noAccountSignUp => _get('noAccountSignUp');
  String get haveAccountSignIn => _get('haveAccountSignIn');
  String get agreeToTerms => _get('agreeToTerms');
  String get andText => _get('andText');
  String get confirmAge16 => _get('confirmAge16');
  String get mustAgreeToTerms => _get('mustAgreeToTerms');
  String get mustBe16 => _get('mustBe16');
  String unexpectedError(String error) =>
      _get('unexpectedError').replaceAll('{error}', error);

  // ── Email OTP verification (signup + recovery) ─────────────
  String get verifyEmailTitle => _get('verifyEmailTitle');
  String verifySignupBody(String email) =>
      _get('verifySignupBody').replaceAll('{email}', email);
  String verifyRecoveryBody(String email) =>
      _get('verifyRecoveryBody').replaceAll('{email}', email);
  String get verificationCode => _get('verificationCode');
  String get verificationCodeHint => _get('verificationCodeHint');
  String get verifyButton => _get('verifyButton');
  String get verifying => _get('verifying');
  String get resendCode => _get('resendCode');
  String resendCodeIn(String seconds) =>
      _get('resendCodeIn').replaceAll('{seconds}', seconds);
  String get codeResent => _get('codeResent');
  String get enterVerificationCode => _get('enterVerificationCode');
  String get invalidCode => _get('invalidCode');
  String get tooManyAttempts => _get('tooManyAttempts');
  String get otpVerificationFailed => _get('otpVerificationFailed');
  String get changeEmailAddress => _get('changeEmailAddress');

  // ── Recover chats page ─────────────────────────────────────
  String get recoverEncryptedChats => _get('recoverEncryptedChats');
  String get noLockedChats => _get('noLockedChats');
  String get allChatsAccessible => _get('allChatsAccessible');
  String get recoverChatsInfo => _get('recoverChatsInfo');
  String encryptedWithVersion(int version) =>
      _get('encryptedWithVersion').replaceAll('{version}', version.toString());
  String get oldPassword => _get('oldPassword');
  String get enterOldPassword => _get('enterOldPassword');
  String lockedChatCount(int count) => _get(
    count == 1 ? 'lockedChatCountSingular' : 'lockedChatCountPlural',
  ).replaceAll('{count}', count.toString());
  String get deleteLockedChatsTitle => _get('deleteLockedChatsTitle');
  String deleteLockedChatsBody(int count) => _get(
    count == 1
        ? 'deleteLockedChatsBodySingular'
        : 'deleteLockedChatsBodyPlural',
  ).replaceAll('{count}', count.toString());
  String get deletePermanently => _get('deletePermanently');
  String get areYouSure => _get('areYouSure');
  String confirmDeleteChats(int count) =>
      _get('confirmDeleteChats').replaceAll('{count}', count.toString());
  String get typeDelete => _get('typeDelete');
  String get confirmDelete => _get('confirmDelete');
  String get pleaseEnterOldPassword => _get('pleaseEnterOldPassword');
  String get derivingKey => _get('derivingKey');
  String recoveredChats(int count) => _get(
    count == 1 ? 'recoveredChatsSingular' : 'recoveredChatsPlural',
  ).replaceAll('{count}', count.toString());
  String get recoveryFailed => _get('recoveryFailed');
  String deletedChats(int count) => _get(
    count == 1 ? 'deletedChatsSingular' : 'deletedChatsPlural',
  ).replaceAll('{count}', count.toString());
  String get deletionFailed => _get('deletionFailed');
  String get recover => _get('recover');
  String get delete => _get('delete');
  String get deleting => _get('deleting');

  // ── Set new password page ──────────────────────────────────
  String get setNewPassword => _get('setNewPassword');
  String get setNewPasswordInfo => _get('setNewPasswordInfo');
  String get setNewPasswordButton => _get('setNewPasswordButton');
  String get noAuthenticatedUser => _get('noAuthenticatedUser');
  String get failedToPreserveEncryption => _get('failedToPreserveEncryption');
  String get failedToSetNewPassword => _get('failedToSetNewPassword');

  // ── Diagnostics page ───────────────────────────────────────
  String get devOptionsToggle => _get('devOptionsToggle');
  String get devOptionsToggleSubtitle => _get('devOptionsToggleSubtitle');
  String get enableDiagnosticsLogging => _get('enableDiagnosticsLogging');
  String get enableDiagnosticsSubtitle => _get('enableDiagnosticsSubtitle');
  String get diagnosticsEnabled => _get('diagnosticsEnabled');
  String get diagnosticsDisabled => _get('diagnosticsDisabled');
  String get notInitializedYet => _get('notInitializedYet');
  String get refresh => _get('refresh');
  String get copyRecent => _get('copyRecent');
  String get copyFocusedDebug => _get('copyFocusedDebug');
  String get shareFile => _get('shareFile');
  String get clear => _get('clear');
  String get copiedRecentLogs => _get('copiedRecentLogs');
  String get noFocusedDebugData => _get('noFocusedDebugData');
  String get copiedFocusedDebug => _get('copiedFocusedDebug');
  String failedFocusedDebug(String error) =>
      _get('failedFocusedDebug').replaceAll('{error}', error);
  String get noDiagnosticsLog => _get('noDiagnosticsLog');
  String get diagnosticsLogNotFound => _get('diagnosticsLogNotFound');
  String failedToShareLog(String error) =>
      _get('failedToShareLog').replaceAll('{error}', error);
  String get diagnosticsLogCleared => _get('diagnosticsLogCleared');
  String failedToClearLog(String error) =>
      _get('failedToClearLog').replaceAll('{error}', error);
  String get devOptionsDisabledMsg => _get('devOptionsDisabledMsg');
  String get noLogsYet => _get('noLogsYet');

  // ── Connector detail page ──────────────────────────────────
  String get back => _get('back');
  String get enabled => _get('enabled');
  String get disabled => _get('disabled');
  String get modelPrompt => _get('modelPrompt');
  String get modelPromptHint => _get('modelPromptHint');
  String get customPromptActive => _get('customPromptActive');
  String get savePrompt => _get('savePrompt');
  String get parameters => _get('parameters');

  // ── Usage details page ─────────────────────────────────────
  String get usageDetails => _get('usageDetails');
  String get unableToLoadUsage => _get('unableToLoadUsage');
  String get usageAndBilling => _get('usageAndBilling');
  String get usageReadOnly => _get('usageReadOnly');
  String get period => _get('period');
  String get totals => _get('totals');
  String get mediaRequestsNote => _get('mediaRequestsNote');
  String get noRequestsFound => _get('noRequestsFound');
  String get cachedTokens => _get('cachedTokens');

  // ── Model selector page ────────────────────────────────────
  String get sessionExpired => _get('sessionExpired');
  String get free => _get('free');
  String get best => _get('best');
  String get autoCheapest => _get('autoCheapest');
  String autoCheapestCurrently(String provider, String price) => _get(
    'autoCheapestCurrently',
  ).replaceAll('{provider}', provider).replaceAll('{price}', price);

  // ── Message bubble / chat ──────────────────────────────────
  String get openInMailApp => _get('openInMailApp');
  String get unableToSaveImage => _get('unableToSaveImage');
  String get image => _get('image');
  String get open => _get('open');

  // ── Misc / shared ─────────────────────────────────────────
  String get original => _get('original');
  String get markdown => _get('markdown');
  String get deleteFile => _get('deleteFile');
  String deleteFailed(String error) =>
      _get('deleteFailed').replaceAll('{error}', error);

  // ── Chat UI ────────────────────────────────────────────────
  String get askMeAnything => _get('askMeAnything');
  String get queuedLabel => _get('queuedLabel');
  String queuedMessagesCount(String count) =>
      _get('queuedMessagesCount').replaceAll('{count}', count);
  String get editYourMessage => _get('editYourMessage');
  String get addMessageOrDocs => _get('addMessageOrDocs');
  String get micAccessFailed => _get('micAccessFailed');
  String get transcriptionFailed => _get('transcriptionFailed');
  String get nothingToResend => _get('nothingToResend');
  String get freeMessagesUsed => _get('freeMessagesUsed');
  String get ok => _get('ok');
  String get camera => _get('camera');
  String get photos => _get('photos');
  String get files => _get('files');

  // ── Model selector ─────────────────────────────────────────
  String get models => _get('models');
  String get searchModels => _get('searchModels');
  String get modelProvider => _get('modelProvider');
  String get chooseProvider => _get('chooseProvider');
  String get modelPromptCustom => _get('modelPromptCustom');
  String get fastMode => _get('fastMode');
  String get thinkingMode => _get('thinkingMode');
  String availableModels(int count) =>
      (count == 1 ? _get('availableModelsOne') : _get('availableModelsMany'))
          .replaceAll('{count}', count.toString());
  String modelsFound(int count) =>
      (count == 1 ? _get('modelsFoundOne') : _get('modelsFoundMany'))
          .replaceAll('{count}', count.toString());
  String modelError(String error) =>
      _get('modelError').replaceAll('{error}', error);

  // ── Message bubble extras ──────────────────────────────────
  String get generatingImage => _get('generatingImage');

  // ── Free message display ───────────────────────────────────
  String freeTotal(String count) =>
      _get('freeTotal').replaceAll('{count}', count);
  String freeRemaining(String remaining, String total) => _get(
    'freeRemaining',
  ).replaceAll('{remaining}', remaining).replaceAll('{total}', total);

  // ── Model selection dropdown ───────────────────────────────
  String get selectModel => _get('selectModel');
  String get noEnabledModels => _get('noEnabledModels');

  // ── Navigation / sidebar ────────────────────────────────────
  String get newChat => _get('newChat');
  String get workspaces => _get('workspaces');
  String get media => _get('media');
  String get search => _get('search');
  String get retryConnection => _get('retryConnection');
  String get today => _get('today');
  String get thisWeek => _get('thisWeek');
  String get thisMonth => _get('thisMonth');
  String get pinned => _get('pinned');
  String get searchChatsHint => _get('searchChatsHint');
  String get hideSidebar => _get('hideSidebar');
  String get checkForUpdates => _get('checkForUpdates');

  // ── Media manager ──────────────────────────────────────────
  String get mediaManager => _get('mediaManager');
  String get imageUsedInChats => _get('imageUsedInChats');
  String get imageUsedInChatsBody => _get('imageUsedInChatsBody');
  String get deleteImageShowDeleted => _get('deleteImageShowDeleted');
  String get deleteImageConfirm => _get('deleteImageConfirm');
  String get deleteAnyway => _get('deleteAnyway');
  String get deleteImageTitle => _get('deleteImageTitle');
  String get deleteImageBody => _get('deleteImageBody');
  String get imageDeleted => _get('imageDeleted');
  String failedToDeleteImage(String error) =>
      _get('failedToDeleteImage').replaceAll('{error}', error);
  String get someImagesUsedInChats => _get('someImagesUsedInChats');
  String get deletedImagesWarning => _get('deletedImagesWarning');
  String deleteAllCount(int count) =>
      _get('deleteAllCount').replaceAll('{count}', count.toString());
  String get deleteAll => _get('deleteAll');
  String get deleteSelectedImages => _get('deleteSelectedImages');
  String deleteSelectedCount(int count) =>
      _get('deleteSelectedCount').replaceAll('{count}', count.toString());
  String deletedImagesResult(int deleted, int failed) =>
      _get('deletedImagesResult')
          .replaceAll('{deleted}', deleted.toString())
          .replaceAll('{failed}', failed.toString());
  String deletedImagesSuccess(int count) =>
      _get('deletedImagesSuccess').replaceAll('{count}', count.toString());
  String get downloadSelected => _get('downloadSelected');
  String get deleteSelected => _get('deleteSelected');
  String get errorLoadingImages => _get('errorLoadingImages');
  String get noImagesStored => _get('noImagesStored');
  String get imagesAppearHere => _get('imagesAppearHere');
  String get download => _get('download');

  // ── Attachment preview bar ─────────────────────────────────
  String removeFile(String name) =>
      _get('removeFile').replaceAll('{name}', name);
  String get edit => _get('edit');
  String get close => _get('close');

  // ── Subscription dialogs ───────────────────────────────────

  // ── Workspace (project) detail ─────────────────────────────
  String get projectPrivate => _get('projectPrivate');
  String get projectPublic => _get('projectPublic');
  String get projectKnowledge => _get('projectKnowledge');
  String get projectInstructions => _get('projectInstructions');
  String get projectInstructionsEmpty => _get('projectInstructionsEmpty');
  String get projectInstructionsSubtitle => _get('projectInstructionsSubtitle');
  String get projectLatestChats => _get('projectLatestChats');
  String get projectNoChatsHint => _get('projectNoChatsHint');
  String get projectNewChat => _get('projectNewChat');
  String projectFileCount(int count) => _get(
    count == 1 ? 'projectFileCountSingular' : 'projectFileCountPlural',
  ).replaceAll('{count}', count.toString());
  String get projectNoFiles => _get('projectNoFiles');
  String get projectAddContent => _get('projectAddContent');
  String get projectUploadFromDevice => _get('projectUploadFromDevice');
  String get projectTakePhoto => _get('projectTakePhoto');
  String get projectPickImage => _get('projectPickImage');
  String get projectCreateDocument => _get('projectCreateDocument');
  String get projectNewDocument => _get('projectNewDocument');
  String get projectDocumentTitleHint => _get('projectDocumentTitleHint');
  String get projectDocumentContentHint => _get('projectDocumentContentHint');
  String get projectEditProject => _get('projectEditProject');
  String get projectDeleteProject => _get('projectDeleteProject');
  String get projectDeleteProjectBody => _get('projectDeleteProjectBody');
  String get projectWorkspaceNotFound => _get('projectWorkspaceNotFound');
  String get projectName => _get('projectName');
  String get projectDescriptionLabel => _get('projectDescriptionLabel');
  String get projectDiscardChangesTitle => _get('projectDiscardChangesTitle');
  String get projectDiscardChangesBody => _get('projectDiscardChangesBody');
  String get projectKeepEditing => _get('projectKeepEditing');
  String get projectDiscardAction => _get('projectDiscardAction');
  String projectSaveFailed(String error) =>
      _get('projectSaveFailed').replaceAll('{error}', error);
  String projectLoadFailed(String error) =>
      _get('projectLoadFailed').replaceAll('{error}', error);
  String projectDeleteFailed(String error) =>
      _get('projectDeleteFailed').replaceAll('{error}', error);
  String projectUploaded(String name) =>
      _get('projectUploaded').replaceAll('{name}', name);
  String projectCameraFailed(String error) =>
      _get('projectCameraFailed').replaceAll('{error}', error);
  String projectImagePickFailed(String error) =>
      _get('projectImagePickFailed').replaceAll('{error}', error);
  String get projectContextBudgetTitle => _get('projectContextBudgetTitle');
  String projectContextBudgetBody(int tokens) => _get(
    'projectContextBudgetBody',
  ).replaceAll('{tokens}', tokens.toString());
  String get projectUploadAnyway => _get('projectUploadAnyway');
  String get projectEncryptingUploading => _get('projectEncryptingUploading');
  String get projectConvertingMarkdown => _get('projectConvertingMarkdown');
  String get projectDeleteFileTitle => _get('projectDeleteFileTitle');
  String projectDeleteFileBody(String name) =>
      _get('projectDeleteFileBody').replaceAll('{name}', name);
  String get projectView => _get('projectView');
  String get projectNotSupportedPlatform => _get('projectNotSupportedPlatform');
  String get projectEditProjectTitle => _get('projectEditProjectTitle');

  // ── Offline queue ──────────────────────────────────────────
  String get messagePending => _get('messagePending');
  String get messageFailed => _get('messageFailed');
  String get messageRetry => _get('messageRetry');

  // ── Onboarding ─────────────────────────────────────────────
  String get onboardingReplayTile => _get('onboardingReplayTile');
  String get onboardingReplayTileSubtitle =>
      _get('onboardingReplayTileSubtitle');

  // Interactive guided tour
  String get tourSkip => _get('tourSkip');
  String get tourEndTour => _get('tourEndTour');
  String get tourContinue => _get('tourContinue');
  String get tourGetStarted => _get('tourGetStarted');
  String get tourFinish => _get('tourFinish');
  String get tourWelcomeTitle => _get('tourWelcomeTitle');
  String get tourWelcomeBody => _get('tourWelcomeBody');
  String get tourModelTitle => _get('tourModelTitle');
  String get tourSettingsModelBody => _get('tourSettingsModelBody');
  String get tourSettingsTitle => _get('tourSettingsTitle');
  String get tourSettingsPageBody => _get('tourSettingsPageBody');
  String get tourSettingsTapHere => _get('tourSettingsTapHere');
  String get tourMenuTitle => _get('tourMenuTitle');
  String get tourMenuBody => _get('tourMenuBody');
  String get tourProviderPillBody => _get('tourProviderPillBody');
  String get tourSettingsPricingTitle => _get('tourSettingsPricingTitle');
  String get tourSettingsPricingBody => _get('tourSettingsPricingBody');
  String get tourSettingsAiIdentityTitle => _get('tourSettingsAiIdentityTitle');
  String get tourSettingsAiIdentityBody => _get('tourSettingsAiIdentityBody');
  String get tourAssistantTitle => _get('tourAssistantTitle');
  String get tourAssistantBody => _get('tourAssistantBody');
  String get tourDoneTitle => _get('tourDoneTitle');
  String get tourDoneBody => _get('tourDoneBody');

  // ── Battery optimization prompt ────────────────────────────
  String get batteryOptimizationTitle => _get('batteryOptimizationTitle');
  String get batteryOptimizationBody => _get('batteryOptimizationBody');
  String get batteryOptimizationAllow => _get('batteryOptimizationAllow');
  String get batteryOptimizationLater => _get('batteryOptimizationLater');
  String get bashSandboxFolder => _get('bashSandboxFolder');
  String get bashSandboxFolderUnset => _get('bashSandboxFolderUnset');
  String get bashSandboxChooseDialog => _get('bashSandboxChooseDialog');

  // ── Agent mail (docs/AGENT_MAIL.md §6) ────────────────────
  String get agentMail => _get('agentMail');
  String get agentMailSubtitle => _get('agentMailSubtitle');
  String get agentMailAddressHint => _get('agentMailAddressHint');
  String get agentMailCopyAddress => _get('agentMailCopyAddress');
  String get agentMailAddressCopied => _get('agentMailAddressCopied');
  String get agentMailContacts => _get('agentMailContacts');
  String get agentMailContactsSubtitle => _get('agentMailContactsSubtitle');
  String get agentMailFrozen => _get('agentMailFrozen');
  String get agentMailSendSuspended => _get('agentMailSendSuspended');
  String get agentMailPrivacy => _get('agentMailPrivacy');
  String get agentMailFolderInbox => _get('agentMailFolderInbox');
  String get agentMailFolderUnknown => _get('agentMailFolderUnknown');
  String get agentMailFolderDrafts => _get('agentMailFolderDrafts');
  String get agentMailFolderSent => _get('agentMailFolderSent');
  String get agentMailFolderArchive => _get('agentMailFolderArchive');
  String get agentMailArchiveSubtitle => _get('agentMailArchiveSubtitle');
  String get agentMailEmptyInbox => _get('agentMailEmptyInbox');
  String get agentMailEmptyUnknown => _get('agentMailEmptyUnknown');
  String get agentMailEmptyDrafts => _get('agentMailEmptyDrafts');
  String get agentMailEmptySent => _get('agentMailEmptySent');
  String get agentMailEmptyArchive => _get('agentMailEmptyArchive');
  String get agentMailEmptyHint => _get('agentMailEmptyHint');
  String get agentMailUnknownInfo => _get('agentMailUnknownInfo');
  String get agentMailDraftsInfo => _get('agentMailDraftsInfo');
  String get agentMailLoadMore => _get('agentMailLoadMore');
  String get agentMailNoSubscription => _get('agentMailNoSubscription');
  String get agentMailSeePlans => _get('agentMailSeePlans');
  String get agentMailUnavailable => _get('agentMailUnavailable');
  String get agentMailLoadFailed => _get('agentMailLoadFailed');
  String agentMailTo(String names) => _get('agentMailTo').replaceAll('{names}', names);
  String get agentMailNoSubject => _get('agentMailNoSubject');
  String get agentMailTrustOwner => _get('agentMailTrustOwner');
  String get agentMailTrustTrusted => _get('agentMailTrustTrusted');
  String get agentMailTrustUnknown => _get('agentMailTrustUnknown');
  String get agentMailBulk => _get('agentMailBulk');
  String get agentMailDraftBadge => _get('agentMailDraftBadge');
  String get agentMailNotDelivered => _get('agentMailNotDelivered');
  String get agentMailMessage => _get('agentMailMessage');
  String get agentMailFrom => _get('agentMailFrom');
  String get agentMailToLabel => _get('agentMailToLabel');
  String get agentMailCc => _get('agentMailCc');
  String get agentMailDate => _get('agentMailDate');
  String get agentMailSenderCheck => _get('agentMailSenderCheck');
  String agentMailDkimAligned(String domain) => _get('agentMailDkimAligned').replaceAll('{domain}', domain);
  String get agentMailDkimNotAligned => _get('agentMailDkimNotAligned');
  String get agentMailAgentNote => _get('agentMailAgentNote');
  String get agentMailImportanceHigh => _get('agentMailImportanceHigh');
  String get agentMailImportanceNormal => _get('agentMailImportanceNormal');
  String get agentMailImportanceLow => _get('agentMailImportanceLow');
  String get agentMailUnknownSenderInfo => _get('agentMailUnknownSenderInfo');
  String get agentMailText => _get('agentMailText');
  String get agentMailNoText => _get('agentMailNoText');
  String get agentMailAttachments => _get('agentMailAttachments');
  String get agentMailAttachmentTooLarge => _get('agentMailAttachmentTooLarge');
  String get agentMailDownload => _get('agentMailDownload');
  String agentMailSaved(String path) => _get('agentMailSaved').replaceAll('{path}', path);
  String get agentMailDownloadFailed => _get('agentMailDownloadFailed');
  String get agentMailActions => _get('agentMailActions');
  String get agentMailArchive => _get('agentMailArchive');
  String get agentMailMoveToInbox => _get('agentMailMoveToInbox');
  String get agentMailMoveToSent => _get('agentMailMoveToSent');
  String get agentMailTrustSender => _get('agentMailTrustSender');
  String get agentMailTrustSenderSubtitle => _get('agentMailTrustSenderSubtitle');
  String get agentMailBlockSender => _get('agentMailBlockSender');
  String get agentMailBlockSenderSubtitle => _get('agentMailBlockSenderSubtitle');
  String get agentMailDelete => _get('agentMailDelete');
  String get agentMailDeleteTitle => _get('agentMailDeleteTitle');
  String get agentMailDeleteBody => _get('agentMailDeleteBody');
  String agentMailBlockTitle(String address) => _get('agentMailBlockTitle').replaceAll('{address}', address);
  String get agentMailBlockBody => _get('agentMailBlockBody');
  String get agentMailBlock => _get('agentMailBlock');
  String get agentMailTrust => _get('agentMailTrust');
  String get agentMailArchived => _get('agentMailArchived');
  String get agentMailMovedToInbox => _get('agentMailMovedToInbox');
  String get agentMailMovedToSent => _get('agentMailMovedToSent');
  String get agentMailDeleted => _get('agentMailDeleted');
  String get agentMailSenderTrusted => _get('agentMailSenderTrusted');
  String get agentMailSenderBlocked => _get('agentMailSenderBlocked');
  String get agentMailDraft => _get('agentMailDraft');
  String get agentMailDraftInfo => _get('agentMailDraftInfo');
  String get agentMailSubject => _get('agentMailSubject');
  String get agentMailBody => _get('agentMailBody');
  String get agentMailSend => _get('agentMailSend');
  String get agentMailDiscard => _get('agentMailDiscard');
  String get agentMailDiscardTitle => _get('agentMailDiscardTitle');
  String get agentMailDiscardBody => _get('agentMailDiscardBody');
  String get agentMailSent => _get('agentMailSent');
  String get agentMailKeptAsDraft => _get('agentMailKeptAsDraft');
  String get agentMailDiscarded => _get('agentMailDiscarded');
  String get agentMailLoadMessageFailed => _get('agentMailLoadMessageFailed');
  String get agentMailErrNoSubscription => _get('agentMailErrNoSubscription');
  String get agentMailErrFrozen => _get('agentMailErrFrozen');
  String get agentMailErrSuspended => _get('agentMailErrSuspended');
  String get agentMailErrTooManyRecipients => _get('agentMailErrTooManyRecipients');
  String get agentMailErrRateLimited => _get('agentMailErrRateLimited');
  String get agentMailErrQuota => _get('agentMailErrQuota');
  String get agentMailErrSignedOut => _get('agentMailErrSignedOut');
  String get agentMailErrNetwork => _get('agentMailErrNetwork');
  String get agentMailErrNotFound => _get('agentMailErrNotFound');
  String agentMailErrGeneric(String code) => _get('agentMailErrGeneric').replaceAll('{code}', code);
  String get agentMailUnreadable => _get('agentMailUnreadable');
  String get agentMailContactUnreadable => _get('agentMailContactUnreadable');
  String get agentMailErrUnseal => _get('agentMailErrUnseal');
  String get agentMailErrKeyLocked => _get('agentMailErrKeyLocked');
  String get agentMailErrKeyUnreadable => _get('agentMailErrKeyUnreadable');
  String get agentMailErrNoKey => _get('agentMailErrNoKey');
  String get agentMailErrKeyRefused => _get('agentMailErrKeyRefused');
  String get agentMailErrAttachmentsTooLarge => _get('agentMailErrAttachmentsTooLarge');
  String get agentMailErrRecipientSuppressed => _get('agentMailErrRecipientSuppressed');
  String get agentMailContactsIntro => _get('agentMailContactsIntro');
  String get agentMailTrusted => _get('agentMailTrusted');
  String get agentMailBlocked => _get('agentMailBlocked');
  String get agentMailNoTrusted => _get('agentMailNoTrusted');
  String get agentMailNoBlocked => _get('agentMailNoBlocked');
  String get agentMailContactInbound => _get('agentMailContactInbound');
  String get agentMailContactOutbound => _get('agentMailContactOutbound');
  String get agentMailContactDomain => _get('agentMailContactDomain');
  String get agentMailRemoveContact => _get('agentMailRemoveContact');
  String get agentMailContactRemoved => _get('agentMailContactRemoved');
  String get agentMailAddContact => _get('agentMailAddContact');
  String get agentMailAddContactSubtitle => _get('agentMailAddContactSubtitle');
  String get agentMailAddressLabel => _get('agentMailAddressLabel');
  String get agentMailAddressInvalid => _get('agentMailAddressInvalid');
  String get agentMailContactSaved => _get('agentMailContactSaved');
  // ── UI audit fixes B (agent B) ──
  String get agentsRoomEmptyHint => _get('agentsRoomEmptyHint');
  String get agentsRoomConnectHostHint => _get('agentsRoomConnectHostHint');
  String get agentsHostYourComputer => _get('agentsHostYourComputer');
  String get coworkerModelListFailed => _get('coworkerModelListFailed');
  String get profileSaveFailedPlain => _get('profileSaveFailedPlain');
  String get agentsTelegramLinkedHeading => _get('agentsTelegramLinkedHeading');
  String get agentsTelegramLinkedChatShort =>
      _get('agentsTelegramLinkedChatShort');
  // ── F2: automations + cost totals ──
  String get automationsTitle => _get('automationsTitle');
  String get automationNew => _get('automationNew');
  String get automationEdit => _get('automationEdit');
  String get automationEditTooltip => _get('automationEditTooltip');
  String get automationKindSchedule => _get('automationKindSchedule');
  String get automationKindPage => _get('automationKindPage');
  String get automationKindMail => _get('automationKindMail');
  String get automationTriggerClock => _get('automationTriggerClock');
  String get automationTriggerPage => _get('automationTriggerPage');
  String get automationTriggerMail => _get('automationTriggerMail');
  String get automationTriggerScript => _get('automationTriggerScript');
  String get automationScheduleLabel => _get('automationScheduleLabel');
  String get automationScheduleHelp => _get('automationScheduleHelp');
  String get automationUrlLabel => _get('automationUrlLabel');
  String get automationIntervalLabel => _get('automationIntervalLabel');
  String get automationIntervalHelp => _get('automationIntervalHelp');
  String get automationMailFromLabel => _get('automationMailFromLabel');
  String get automationMailSubjectLabel => _get('automationMailSubjectLabel');
  String get automationMailHelp => _get('automationMailHelp');
  String get automationPromptLabel => _get('automationPromptLabel');
  String get automationNameLabel => _get('automationNameLabel');
  String get automationCoworkerLabel => _get('automationCoworkerLabel');
  String get automationNotifyOnChange => _get('automationNotifyOnChange');
  String get automationNotifyOnChangeHelp => _get('automationNotifyOnChangeHelp');
  String get automationCreate => _get('automationCreate');
  String get automationErrPrompt => _get('automationErrPrompt');
  String get automationErrSchedule => _get('automationErrSchedule');
  String get automationErrUrl => _get('automationErrUrl');
  String get automationErrInterval => _get('automationErrInterval');
  String get automationErrMail => _get('automationErrMail');
  String get automationErrTooLong => _get('automationErrTooLong');
  String get automationErrCoworker => _get('automationErrCoworker');
  String get automationNothingChanged => _get('automationNothingChanged');
  String get automationSaved => _get('automationSaved');
  String get automationNotConnected => _get('automationNotConnected');
  String get automationNotifyAlwaysShort => _get('automationNotifyAlwaysShort');
  String get automationNotifyChangeShort => _get('automationNotifyChangeShort');
  String get automationQuietOne => _get('automationQuietOne');
  String automationQuietMany(String count) =>
      _get('automationQuietMany').replaceAll('{count}', count);
  String automationNextCheck(String when) =>
      _get('automationNextCheck').replaceAll('{when}', when);
  String get automationNoChange => _get('automationNoChange');
  String get automationLastResult => _get('automationLastResult');
  String get costHeading => _get('costHeading');
  String get costThisThread => _get('costThisThread');
  String get costToday => _get('costToday');
  String get costThisWeek => _get('costThisWeek');
  String get costLastRun => _get('costLastRun');
  String costWeekOfBudget(String spent, String budget) =>
      _get('costWeekOfBudget').replaceAll('{spent}', spent).replaceAll('{budget}', budget);
  String get costBudgetWarning => _get('costBudgetWarning');
  String get costBudgetExceeded => _get('costBudgetExceeded');
  String get budgetWeeklyLabel => _get('budgetWeeklyLabel');
  String get budgetNoLimit => _get('budgetNoLimit');
  String get budgetHelp => _get('budgetHelp');
  String get budgetInvalid => _get('budgetInvalid');
  String get budgetSendFailed => _get('budgetSendFailed');
  // ── end F2 ──
  // ── F1: approvals + cost ──
  String get approvalTitleFallback => _get('approvalTitleFallback');
  String get approvalAllowOnce => _get('approvalAllowOnce');
  String approvalAlwaysAgent(String name) =>
      _get('approvalAlwaysAgent').replaceAll('{name}', name);
  String approvalAlwaysConnector(String name) =>
      _get('approvalAlwaysConnector').replaceAll('{name}', name);
  String approvalAlwaysSite(String site) =>
      _get('approvalAlwaysSite').replaceAll('{site}', site);
  String get approvalDeny => _get('approvalDeny');
  String get approvalThisCoworker => _get('approvalThisCoworker');
  String get approvalThisSite => _get('approvalThisSite');
  String get approvalMailTo => _get('approvalMailTo');
  String get approvalMailCc => _get('approvalMailCc');
  String get approvalMailSubject => _get('approvalMailSubject');
  String get approvalMailReply => _get('approvalMailReply');
  String get approvalMailAttachments => _get('approvalMailAttachments');
  String get approvalConnector => _get('approvalConnector');
  String get approvalConnectorTool => _get('approvalConnectorTool');
  String get approvalBrowserSite => _get('approvalBrowserSite');
  String get approvalBrowserTarget => _get('approvalBrowserTarget');
  String approvalBrowserTargetSubmit(String target) =>
      _get('approvalBrowserTargetSubmit').replaceAll('{target}', target);
  String get approvalBrowserKey => _get('approvalBrowserKey');
  String get approvalBrowserFields => _get('approvalBrowserFields');
  String get approvalBrowserFiles => _get('approvalBrowserFiles');
  String get approvalPublicSite => _get('approvalPublicSite');
  String get approvalDecidedOnce => _get('approvalDecidedOnce');
  String approvalDecidedAlwaysAgent(String name) =>
      _get('approvalDecidedAlwaysAgent').replaceAll('{name}', name);
  String approvalDecidedAlwaysSite(String site) =>
      _get('approvalDecidedAlwaysSite').replaceAll('{site}', site);
  String get approvalDecidedDenied => _get('approvalDecidedDenied');
  String get approvalNotConnected => _get('approvalNotConnected');
  String get approvalsHeading => _get('approvalsHeading');
  String get approvalsSendExternal => _get('approvalsSendExternal');
  String get approvalsSendExternalHelp => _get('approvalsSendExternalHelp');
  String get approvalsMcpDestructive => _get('approvalsMcpDestructive');
  String get approvalsMcpDestructiveHelp => _get('approvalsMcpDestructiveHelp');
  String get approvalsBrowserAct => _get('approvalsBrowserAct');
  String get approvalsBrowserActHelp => _get('approvalsBrowserActHelp');
  String get approvalsPublish => _get('approvalsPublish');
  String get approvalsPublishHelp => _get('approvalsPublishHelp');
  String get approvalsModeAsk => _get('approvalsModeAsk');
  String get approvalsModeAllow => _get('approvalsModeAllow');
  String get approvalsModeDeny => _get('approvalsModeDeny');
  String approvalsDefault(String mode) =>
      _get('approvalsDefault').replaceAll('{mode}', mode);
  String get approvalsSites => _get('approvalsSites');
  String get approvalsNoSites => _get('approvalsNoSites');
  String approvalsRemoveSite(String site) =>
      _get('approvalsRemoveSite').replaceAll('{site}', site);
  String get approvalsApplies => _get('approvalsApplies');
  String get approvalsNotConnected => _get('approvalsNotConnected');
  String runCostTokens(String count) =>
      _get('runCostTokens').replaceAll('{count}', count);
  String get runCostSheetTitle => _get('runCostSheetTitle');
  String get runCostTotal => _get('runCostTotal');
  String get runCostLineRun => _get('runCostLineRun');
  String get runCostLineAux => _get('runCostLineAux');
  String get runCostLineBrowser => _get('runCostLineBrowser');
  String get runCostNoPrice => _get('runCostNoPrice');
  String runCostCached(String count) =>
      _get('runCostCached').replaceAll('{count}', count);
  String get runCostDetails => _get('runCostDetails');
  String budgetNoticeWarning(String spent, String budget) =>
      _get('budgetNoticeWarning').replaceAll('{spent}', spent).replaceAll('{budget}', budget);
  String budgetNoticeExceeded(String spent, String budget) =>
      _get('budgetNoticeExceeded').replaceAll('{spent}', spent).replaceAll('{budget}', budget);
  String get budgetNoticeWarningPlain => _get('budgetNoticeWarningPlain');
  String get budgetNoticeExceededPlain => _get('budgetNoticeExceededPlain');
  String get budgetRefusedTitle => _get('budgetRefusedTitle');
  String get budgetRunAnyway => _get('budgetRunAnyway');
  String get budgetChange => _get('budgetChange');
  String get budgetDismiss => _get('budgetDismiss');
  String get budgetRunAnywayFailed => _get('budgetRunAnywayFailed');
  // ── end F1 ──
  // ── templates ──
  String get tplPickerTitle => _get('tplPickerTitle');
  String get tplPickerSubtitle => _get('tplPickerSubtitle');
  String get tplSearchHint => _get('tplSearchHint');
  String get tplCategoryAll => _get('tplCategoryAll');
  String get tplCategoryWork => _get('tplCategoryWork');
  String get tplCategoryWatch => _get('tplCategoryWatch');
  String get tplCategoryPersonal => _get('tplCategoryPersonal');
  String get tplBlankName => _get('tplBlankName');
  String get tplBlankDesc => _get('tplBlankDesc');
  String get tplNoMatch => _get('tplNoMatch');
  String get tplNameLabel => _get('tplNameLabel');
  String get tplNameHint => _get('tplNameHint');
  String get tplNameLater => _get('tplNameLater');
  String get tplNameEmpty => _get('tplNameEmpty');
  String get tplUses => _get('tplUses');
  String get tplPersonaTitle => _get('tplPersonaTitle');
  String get tplPersonaNote => _get('tplPersonaNote');
  String get tplStarterTitle => _get('tplStarterTitle');
  String get tplBack => _get('tplBack');
  String get tplCancel => _get('tplCancel');
  String get tplCreate => _get('tplCreate');
  String tplStarterFailed(String name, String error) => _get(
    'tplStarterFailed',
  ).replaceAll('{name}', name).replaceAll('{error}', error);

  /// A coworker template's string by its catalogue key: `tpl.<id>.name`,
  /// `tpl.<id>.desc`, `tpl.<id>.starter`, `tpl.<id>.starterWhen`,
  /// `tpl.tool.<tool>` (lib/services/agents/coworker_templates.dart).
  String tpl(String key) => _get(key);
  // ── end templates ──
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      ['en', 'de', 'es', 'fr', 'pt'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) =>
      false;
}
