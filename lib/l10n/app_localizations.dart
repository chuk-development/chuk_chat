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
  String get skillNew => _get('skillNew');
  String get skillEdit => _get('skillEdit');
  String get skillDeleteTitle => _get('skillDeleteTitle');
  String skillDeleteBody(String name) =>
      _get('skillDeleteBody').replaceAll('{name}', name);
  String get skillEditorHint => _get('skillEditorHint');
  String get skillSaveFailed => _get('skillSaveFailed');
  String get developerOptions => _get('developerOptions');
  String get developerOptionsSubtitle => _get('developerOptionsSubtitle');
  String get modelSelection => _get('modelSelection');
  String get modelSelectionSubtitle => _get('modelSelectionSubtitle');
  String get aiIdentityMemory => _get('aiIdentityMemory');
  String get aiIdentityMemorySubtitle => _get('aiIdentityMemorySubtitle');
  String get pricingPlans => _get('pricingPlans');
  String get pricingPlansSubtitle => _get('pricingPlansSubtitle');
  String get accountSettings => _get('accountSettings');
  String get accountSettingsSubtitle => _get('accountSettingsSubtitle');
  String get exportChats => _get('exportChats');
  String get exportChatsSubtitle => _get('exportChatsSubtitle');
  String get about => _get('about');
  String get aboutSubtitle => _get('aboutSubtitle');
  String get logout => _get('logout');
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
  String get english => _get('english');
  String get german => _get('german');
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
  String get archive => _get('archive');

  // ── Tool calling page ──────────────────────────────────────
  String get engine => _get('engine');
  String get enableToolCalling => _get('enableToolCalling');
  String get enableToolCallingSubtitle => _get('enableToolCallingSubtitle');
  String get behavior => _get('behavior');
  String get requireDiscoveryFirst => _get('requireDiscoveryFirst');
  String get requireDiscoverySubtitle => _get('requireDiscoverySubtitle');
  String get markdownToolCallFallback => _get('markdownToolCallFallback');
  String get markdownFallbackSubtitle => _get('markdownFallbackSubtitle');
  String get display => _get('display');
  String get showToolActivity => _get('showToolActivity');
  String get showToolActivitySubtitle => _get('showToolActivitySubtitle');
  String get toolCallingTip => _get('toolCallingTip');
  String get visualOutputNonTool => _get('visualOutputNonTool');
  String get enableMapBlocks => _get('enableMapBlocks');
  String get enableMapBlocksSubtitle => _get('enableMapBlocksSubtitle');
  String get enableChartBlocks => _get('enableChartBlocks');
  String get enableChartBlocksSubtitle => _get('enableChartBlocksSubtitle');
  String get connectors => _get('connectors');
  String get loadingToolSettings => _get('loadingToolSettings');
  String get noToolsRegistered => _get('noToolsRegistered');
  String get catSearchWeb => _get('catSearchWeb');
  String get catUtilities => _get('catUtilities');
  String get catMapsLocation => _get('catMapsLocation');
  String get catDevice => _get('catDevice');
  String get catSpotify => _get('catSpotify');
  String get catBashTerminal => _get('catBashTerminal');
  String get catGitHub => _get('catGitHub');
  String get catSlack => _get('catSlack');
  String get catGoogleCalGmail => _get('catGoogleCalGmail');
  String get catEmailImapSmtp => _get('catEmailImapSmtp');
  String get catWhoop => _get('catWhoop');
  String get catNextcloud => _get('catNextcloud');
  String get catSandbox => _get('catSandbox');
  String get catSearchWebDesc => _get('catSearchWebDesc');
  String get catUtilitiesDesc => _get('catUtilitiesDesc');
  String get catMapsLocationDesc => _get('catMapsLocationDesc');
  String get catDeviceDesc => _get('catDeviceDesc');
  String get catSpotifyDesc => _get('catSpotifyDesc');
  String get catBashTerminalDesc => _get('catBashTerminalDesc');
  String get catGitHubDesc => _get('catGitHubDesc');
  String get catSlackDesc => _get('catSlackDesc');
  String get catGoogleCalGmailDesc => _get('catGoogleCalGmailDesc');
  String get catEmailImapSmtpDesc => _get('catEmailImapSmtpDesc');
  String get catWhoopDesc => _get('catWhoopDesc');
  String get catNextcloudDesc => _get('catNextcloudDesc');
  String get catSandboxDesc => _get('catSandboxDesc');
  String get connect => _get('connect');
  String get disconnect => _get('disconnect');
  String disconnectCategory(String label) =>
      _get('disconnectCategory').replaceAll('{label}', label);
  String get removeCredentialsWarning => _get('removeCredentialsWarning');
  String get cancel => _get('cancel');
  String categoryConnected(String label) =>
      _get('categoryConnected').replaceAll('{label}', label);
  String failedToConnect(String label) =>
      _get('failedToConnect').replaceAll('{label}', label);
  String unableToConnect(String label) =>
      _get('unableToConnect').replaceAll('{label}', label);
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
  String get toolWhoopHealth => _get('toolWhoopHealth');
  String get resetToolSettingsTitle => _get('resetToolSettingsTitle');
  String get resetToolSettingsBody => _get('resetToolSettingsBody');
  String get resetAllToolPrefs => _get('resetAllToolPrefs');

  // ── Account settings page ──────────────────────────────────
  String get profile => _get('profile');
  String get profileSubtitle => _get('profileSubtitle');
  String get displayName => _get('displayName');
  String get displayNameHint => _get('displayNameHint');
  String get emailAddress => _get('emailAddress');
  String get emailAddressHint => _get('emailAddressHint');
  String get security => _get('security');
  String get securitySubtitle => _get('securitySubtitle');
  String get changePassword => _get('changePassword');
  String get changePasswordSubtitle => _get('changePasswordSubtitle');
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
  String get dangerZone => _get('dangerZone');
  String get dangerZoneSubtitle => _get('dangerZoneSubtitle');
  String get deleteAccountWarning => _get('deleteAccountWarning');
  String get deleteAccount => _get('deleteAccount');
  String get unableToLoadProfile => _get('unableToLoadProfile');
  String get retry => _get('retry');
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
  String get legalDocuments => _get('legalDocuments');
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
  String get subscribeToGetCredits => _get('subscribeToGetCredits');
  String get subscriptionDesktopOnly => _get('subscriptionDesktopOnly');
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
  String get confirmEmailToContinue => _get('confirmEmailToContinue');
  String get confirmEmailBody => _get('confirmEmailBody');
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
  String get logFile => _get('logFile');
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
  String get recentLogLines => _get('recentLogLines');
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
  String get offlineMessage => _get('offlineMessage');
  String get cannotReachApi => _get('cannotReachApi');
  String get maintenanceMessage => _get('maintenanceMessage');
  String get free => _get('free');
  String get perMillion => _get('perMillion');
  String get perRequest => _get('perRequest');
  String get best => _get('best');
  String get autoCheapest => _get('autoCheapest');
  String autoCheapestCurrently(String provider, String price) => _get(
    'autoCheapestCurrently',
  ).replaceAll('{provider}', provider).replaceAll('{price}', price);

  // ── Message bubble / chat ──────────────────────────────────
  String get openInMailApp => _get('openInMailApp');
  String costLabel(String cost) => _get('costLabel').replaceAll('{cost}', cost);
  String generatedLabel(String label) =>
      _get('generatedLabel').replaceAll('{label}', label);
  String get unableToCopyImage => _get('unableToCopyImage');
  String get unableToSaveImage => _get('unableToSaveImage');
  String get image => _get('image');
  String get openLink => _get('openLink');
  String openLinkConfirm(String url) =>
      _get('openLinkConfirm').replaceAll('{url}', url);
  String get open => _get('open');

  // ── Misc / shared ─────────────────────────────────────────
  String get contentCopied => _get('contentCopied');
  String get artifactCopied => _get('artifactCopied');
  String get fileSaved => _get('fileSaved');
  String failedToExportArtifact(String error) =>
      _get('failedToExportArtifact').replaceAll('{error}', error);
  String failedToSave(String error) =>
      _get('failedToSave').replaceAll('{error}', error);
  String get markdownSaved => _get('markdownSaved');
  String get original => _get('original');
  String get markdown => _get('markdown');
  String get viewMarkdownSummary => _get('viewMarkdownSummary');
  String get addSummary => _get('addSummary');
  String get deletedFile => _get('deletedFile');
  String get deleteFile => _get('deleteFile');
  String deleteFileConfirm(String name) =>
      _get('deleteFileConfirm').replaceAll('{name}', name);
  String deleteFailed(String error) =>
      _get('deleteFailed').replaceAll('{error}', error);
  String uploadedFile(String name) =>
      _get('uploadedFile').replaceAll('{name}', name);
  String get freeMessagePlaceholder => _get('freeMessagePlaceholder');

  // ── Chat UI ────────────────────────────────────────────────
  String get askMeAnything => _get('askMeAnything');
  String get queuedLabel => _get('queuedLabel');
  String get editYourMessage => _get('editYourMessage');
  String get addMessageOrDocs => _get('addMessageOrDocs');
  String get micAccessFailed => _get('micAccessFailed');
  String get transcriptionFailed => _get('transcriptionFailed');
  String get replyTargetSelected => _get('replyTargetSelected');
  String get clearReply => _get('clearReply');
  String get nothingToResend => _get('nothingToResend');
  String get freeMessagesUsed => _get('freeMessagesUsed');
  String get ok => _get('ok');
  String get camera => _get('camera');
  String get photos => _get('photos');
  String get files => _get('files');

  // ── Model selector ─────────────────────────────────────────
  String get models => _get('models');
  String get searchModels => _get('searchModels');
  String modelError(String error) =>
      _get('modelError').replaceAll('{error}', error);

  // ── Message bubble extras ──────────────────────────────────
  String get copyImage => _get('copyImage');
  String get downloadImage => _get('downloadImage');
  String get imageDetails => _get('imageDetails');
  String get generatingImage => _get('generatingImage');
  String get imageCopied => _get('imageCopied');

  // ── Free message display ───────────────────────────────────
  String get freeMessages => _get('freeMessages');
  String freeUsed(String count) =>
      _get('freeUsed').replaceAll('{count}', count);
  String freeTotal(String count) =>
      _get('freeTotal').replaceAll('{count}', count);
  String get subscribeToContinue => _get('subscribeToContinue');
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

  // ── CoWork mode ─────────────────────────────────────────────
  String get chatMode => _get('chatMode');
  String get coworkMode => _get('coworkMode');
  String get coworkComingSoon => _get('coworkComingSoon');
  String get coworkComingSoonBody => _get('coworkComingSoonBody');

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
  String get maybeLater => _get('maybeLater');

  // ── Workspace (project) detail ─────────────────────────────
  String get projectPrivate => _get('projectPrivate');
  String get projectPublic => _get('projectPublic');
  String get projectKnowledge => _get('projectKnowledge');
  String get projectInstructions => _get('projectInstructions');
  String get projectInstructionsEmpty => _get('projectInstructionsEmpty');
  String get projectInstructionsSubtitle => _get('projectInstructionsSubtitle');
  String get projectLatestChats => _get('projectLatestChats');
  String get projectNoChats => _get('projectNoChats');
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
  String get projectDocumentTitle => _get('projectDocumentTitle');
  String get projectDocumentContent => _get('projectDocumentContent');
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
  String projectUploadFailed(String error) =>
      _get('projectUploadFailed').replaceAll('{error}', error);
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
  String get onboardingSkip => _get('onboardingSkip');
  String get onboardingNext => _get('onboardingNext');
  String get onboardingBack => _get('onboardingBack');
  String get onboardingDone => _get('onboardingDone');
  String get onboardingNoModelHint => _get('onboardingNoModelHint');
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
  String get tourModelBody => _get('tourModelBody');
  String get tourSettingsModelBody => _get('tourSettingsModelBody');
  String get tourModelPageBody => _get('tourModelPageBody');
  String get tourSettingsTitle => _get('tourSettingsTitle');
  String get tourSettingsBody => _get('tourSettingsBody');
  String get tourSettingsPageBody => _get('tourSettingsPageBody');
  String get tourSettingsTapHere => _get('tourSettingsTapHere');
  String get tourMenuTitle => _get('tourMenuTitle');
  String get tourMenuBody => _get('tourMenuBody');
  String get tourChatTitle => _get('tourChatTitle');
  String get tourChatBody => _get('tourChatBody');
  String get tourProviderPillBody => _get('tourProviderPillBody');
  String get tourSettingsPricingTitle => _get('tourSettingsPricingTitle');
  String get tourSettingsPricingBody => _get('tourSettingsPricingBody');
  String get tourSettingsAiIdentityTitle => _get('tourSettingsAiIdentityTitle');
  String get tourSettingsAiIdentityBody => _get('tourSettingsAiIdentityBody');
  String get tourDoneTitle => _get('tourDoneTitle');
  String get tourDoneBody => _get('tourDoneBody');

  // ── Battery optimization prompt ────────────────────────────
  String get batteryOptimizationTitle => _get('batteryOptimizationTitle');
  String get batteryOptimizationBody => _get('batteryOptimizationBody');
  String get batteryOptimizationAllow => _get('batteryOptimizationAllow');
  String get batteryOptimizationLater => _get('batteryOptimizationLater');
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => [
    'en',
    'de',
    'es',
    'fr',
    'pt',
  ].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) =>
      false;
}
