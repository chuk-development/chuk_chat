// lib/l10n/strings_en.dart
// English UI strings — the default / fallback locale.

const Map<String, String> stringsEn = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Settings',
  'themeSettings': 'Theme Settings',
  'themeSettingsSubtitle': 'Adjust app theme, colors, and appearance',
  'customization': 'Customization',
  'customizationSubtitle': 'Configure app behavior and preferences',
  'toolCalling': 'Tool Calling',
  'toolCallingSubtitle': 'Control tool usage, discovery, and tool-call display',
  'skills': 'Skills',
  'skillsSubtitle': 'Procedures the AI loads on demand',
  'skillsExplainer':
      'A skill is a procedure the AI loads when it needs it. Only its name and '
      'description sit in every message; the instructions are added once the AI '
      'picks it up. Skills stay in the conversation after that.',
  'skillsYours': 'Your skills',
  'skillsYoursEmpty':
      'You have no skills yet. Add one to teach the AI a procedure it should '
      'follow — a format to output, a checklist to work through, house rules '
      'for a recurring task.',
  'skillsBuiltin': 'Built in',
  'skillNew': 'New skill',
  'skillEdit': 'Edit skill',
  'skillDeleteTitle': 'Delete skill?',
  'skillDeleteBody':
      'The skill "{name}" will be deleted from all your devices. This cannot '
      'be undone.',
  'skillEditorHint':
      'Write the SKILL.md source: YAML frontmatter between --- lines, then the '
      'instructions as markdown. Required: name (lowercase, hyphens) and '
      'description. Keep the description short — it is charged to every '
      'message. Optional: allowed-tools, license, compatibility, metadata.',
  'skillSaveFailed': 'Could not save the skill',
  'skillPickerTitle': 'Load a skill',
  'skillPickerEmpty': 'No skills available',
  'skillRemove': 'Remove skill',
  'developerOptions': 'Developer Options',
  'developerOptionsSubtitle': 'Diagnostics logs and debug tools',
  'modelSelection': 'Model Selection',
  'modelSelectionSubtitle': 'Choose and configure your AI models',
  'aiIdentityMemory': 'AI Identity & Memory',
  'aiIdentityMemorySubtitle': 'Soul, user profile, memory, and system prompt',
  'pricingPlans': 'Pricing Plans',
  'pricingPlansSubtitle': 'View our subscription plans and pricing',
  'accountSettings': 'Account Settings',
  'accountSettingsSubtitle': 'Manage your profile and account',
  'exportChats': 'Export Chats',
  'exportChatsSubtitle': 'Download your conversations as JSON',
  'about': 'About',
  'aboutSubtitle': 'Version details and open source licenses',
  'logout': 'Logout',
  'noChatsToExport': 'No chats to export',
  'copiedToClipboard': 'Copied to clipboard',
  'savedToPath': 'Saved to {path}',
  'exportCancelled': 'Export cancelled',
  'shareOpened': 'Share opened',
  'exportFailed': 'Export failed: {error}',
  'saveChatExport': 'Save chat export',

  // ── Customization page ─────────────────────────────────────
  'language': 'Language',
  'languageSubtitle': 'Choose your preferred language',
  'english': 'English',
  'german': 'Deutsch',
  'voiceTranscription': 'Voice Transcription',
  'autoSendVoice': 'Auto-send voice messages',
  'autoSendVoiceSubtitle':
      'Automatically send transcribed voice messages without confirmation',
  'autoSendVoiceInfo':
      'When enabled, voice transcriptions are sent immediately. When disabled (default), transcriptions appear in the text field for review before sending.',
  'messageDisplay': 'Message Display',
  'showReasoningTokens': 'Show reasoning tokens',
  'showReasoningTokensSubtitle':
      'Display reasoning process tokens in AI responses',
  'showModelInfo': 'Show model info',
  'showModelInfoSubtitle':
      'Display model name and information in chat messages',
  'showTps': 'Show tokens per second',
  'showTpsSubtitle': 'Display AI response generation speed (TPS)',
  'chatFontSize': 'Chat font size',
  'chatFontSizeSubtitle':
      'Adjust the text size of chat messages for easier reading',
  'uiScale': 'UI Scale',
  'uiScaleSubtitle':
      'Scale the entire app interface — useful on high-DPI displays',
  'uiScalePercentage': 'UI Scale: {percent}%',
  'fontSizePreview': 'The quick brown fox jumps over the lazy dog.',
  'chatFontFamily': 'Chat font',
  'chatFontFamilySubtitle': 'Choose the typeface for chat message text',
  'fontFamilySystem': 'System default',
  'fontFamilyArimo': 'Arimo (sans-serif)',
  'fontFamilyMerriweather': 'Merriweather (serif)',
  'fontFamilyJetBrainsMono': 'JetBrains Mono',
  // ── Downloads page ─────────────────────────────────────────
  'downloads': 'Downloads',
  'downloadsSubtitle': 'Where saved files go and whether to prompt each time',
  'downloadsAlwaysAsk': 'Always ask where to save',
  'downloadsAlwaysAskHintCan':
      'Turn off to save directly to your default folder',
  'downloadsAlwaysAskHintNoFolder':
      'Set a default folder below to allow turning this off',
  'downloadsDefaultFolder': 'Default download folder',
  'downloadsDefaultFolderUnset': 'Not set — every download will prompt',
  'downloadsChooseFolderDialog': 'Choose default download folder',
  'downloadsClear': 'Clear',
  'downloadsInfo':
      'These settings apply to every download in the app — chat images, media manager exports, artifact downloads and chat backups.',
  'aiContext': 'AI Context',
  'recentImagesInContext': 'Recent images in context',
  'recentImagesInContextSubtitle':
      'Send images from recent messages to the AI model',
  'allImagesInContext': 'All images in context',
  'allImagesInContextSubtitle':
      'Send all conversation images to the AI (uses more tokens)',
  'reasoningInContext': 'Reasoning in context',
  'reasoningInContextSubtitle':
      'Include AI thinking process in conversation history',
  'toolResultsInContext': 'Tool results in context',
  'toolResultsInContextSubtitle':
      'Include prior tool calls and their results so the AI can reuse already-fetched data instead of re-running the same tools',
  'aiContextInfo':
      'Recent images sends the last 6 messages\' images. All images sends every image in the conversation. Reasoning includes the AI\'s thinking process as context for follow-up messages.',
  'chatTitles': 'Chat Titles',
  'autoGenerateTitles': 'Auto-generate chat titles',
  'autoGenerateTitlesSubtitle': 'Use AI to generate titles for new chats',
  'titleGenerationPrompt': 'Title Generation Prompt',
  'usingCustomPrompt': 'Using custom prompt',
  'usingDefaultPrompt': 'Using default prompt',
  'titleGenInfo':
      'When enabled, a short title will be automatically generated for new chats based on your first message. Uses a fast, lightweight AI model (qwen3-8b).',
  'systemPromptSaved': 'System prompt saved',
  'systemPromptResetToDefault': 'System prompt reset to default',
  'reset': 'Reset',
  'save': 'Save',

  // ── Per-model system prompt ────────────────────────────────
  'perModelPromptTitle': 'Per-model system prompt',
  'perModelPromptHint':
      'Add an extra instruction that only applies when this model is selected. Encrypted at rest.',
  'perModelPromptPlaceholder':
      'Example: Always respond in formal English and cite sources.',
  'perModelPromptEdit': 'Set system prompt',
  'perModelPromptEditConfigured': 'Edit system prompt (configured)',
  'perModelPromptRemove': 'Remove',
  'perModelPromptSaveFailed': 'Failed to save the per-model prompt.',
  'perModelPromptDeleteFailed': 'Failed to remove the per-model prompt.',
  'perModelPromptModeLabel': 'Combine with global / workspace prompt',
  'perModelPromptModeOff': 'Off',
  'perModelPromptModeAppend': 'Append',
  'perModelPromptModePrepend': 'Prepend',
  'perModelPromptModeReplace': 'Replace',
  'perModelPromptModeOffHint':
      'The per-model prompt is ignored — only the global and workspace prompts are sent.',
  'perModelPromptModeAppendHint':
      'Sent after the global / workspace prompt, separated by a divider.',
  'perModelPromptModePrependHint':
      'Sent before the global / workspace prompt, separated by a divider.',
  'perModelPromptModeReplaceHint':
      'Replaces the global and workspace prompts entirely while this model is selected.',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Dark Mode',
  'darkModeSubtitle': 'Toggle between dark and light themes',
  'accentColor': 'Accent Color',
  'accentColorSubtitle': 'Choose your primary accent color',
  'iconFgColor': 'Icon/Foreground Color',
  'iconFgColorSubtitle': 'Choose the color for icons and key text',
  'backgroundColor': 'Background Color',
  'backgroundColorSubtitle': 'Choose the main background color for the app',
  'filmGrainEffect': 'Film Grain Effect',
  'filmGrainSubtitle': 'Add a subtle shot-on-film texture',
  'dynamicColor': 'Material You',
  'dynamicColorSubtitle':
      'Use your system colors and follow theme changes automatically',
  'colorDynamicNote':
      'Set automatically by your system Material You palette.',
  'customHexColor': 'Custom Hex Color (#RRGGBB)',
  'pickCustomColor': 'Pick custom color',
  'pickAColor': 'Pick a color',
  'hue': 'Hue',
  'saturation': 'Saturation',
  'brightness': 'Brightness',
  'useColor': 'Use color',
  'searchWorkspacesHint': 'Search workspaces...',
  'newWorkspace': 'New Workspace',
  'editedAt': 'Edited {date}',
  'aiDisclaimer': 'AI/LLMs can make mistakes — double-check important info.',
  'archive': 'Archive',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Engine',
  'enableToolCalling': 'Enable tool calling',
  'enableToolCallingSubtitle':
      'Allow the assistant to discover and execute built-in tools',
  'behavior': 'Behavior',
  'requireDiscoveryFirst': 'Require discovery first',
  'requireDiscoverySubtitle':
      'Force find_tools before other tools are allowed in a turn',
  'markdownToolCallFallback': 'Markdown tool-call fallback',
  'markdownFallbackSubtitle':
      'Accept ```tool_call code blocks when models do not emit XML tags',
  'display': 'Display',
  'showToolActivity': 'Show tool activity in chat',
  'showToolActivitySubtitle':
      'Display running/completed tool chips in assistant messages',
  'toolCallingTip':
      'Tip: Leave markdown fallback enabled for best compatibility. Disable it only if you want strict XML-only tool calls.',
  'visualOutputNonTool': 'Visual Output (Non-Tool)',
  'enableMapBlocks': 'Enable map blocks (<map>)',
  'enableMapBlocksSubtitle':
      'Allow the model prompt to include map rendering instructions',
  'enableChartBlocks': 'Enable chart blocks (<chart>)',
  'enableChartBlocksSubtitle':
      'Allow the model prompt to include chart rendering instructions',
  'connectors': 'Connectors',
  'loadingToolSettings': 'Loading tool settings...',
  'noToolsRegistered': 'No tools are registered yet.',
  'catSearchWeb': 'Search and Web',
  'catUtilities': 'Utilities',
  'catMapsLocation': 'Maps and Location',
  'catDevice': 'Device',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / Terminal',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Calendar / Gmail)',
  'catEmailImapSmtp': 'Email (IMAP/SMTP)',
  'catWhoop': 'WHOOP',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'Sandbox / Code',
  'catSearchWebDesc':
      'Search the web, fetch pages, generate images, and look up data',
  'catUtilitiesDesc': 'Calculator, clock, notes, QR codes, and other utilities',
  'catMapsLocationDesc': 'Find places, geocode addresses, and calculate routes',
  'catDeviceDesc': 'Access device features like GPS, calendar, and reminders',
  'catSpotifyDesc': 'Control playback and browse your Spotify library',
  'catBashTerminalDesc': 'Run sandboxed shell commands on the desktop',
  'catGitHubDesc': 'Access repos, issues, PRs, and commits from GitHub',
  'catSlackDesc': 'Send messages, search channels, and fetch Slack data',
  'catGoogleCalGmailDesc':
      'Manage your schedule and email via Google Calendar and Gmail',
  'catEmailImapSmtpDesc': 'Send and receive email via IMAP and SMTP',
  'catWhoopDesc': 'View recovery, strain, sleep, and workout data from WHOOP',
  'catNextcloudDesc': 'Browse files, calendar, and contacts on Nextcloud',
  'catSandboxDesc':
      'Run Python or shell code in an isolated sandbox and read/write files',
  'connect': 'Connect',
  'disconnect': 'Disconnect',
  'disconnectCategory': 'Disconnect {label}?',
  'removeCredentialsWarning': 'This will remove your saved credentials.',
  'cancel': 'Cancel',
  'categoryConnected': '{label} connected',
  'failedToConnect': 'Failed to connect {label}',
  'unableToConnect': 'Unable to connect {label}. Please try again.',
  'toolWebSearch': 'Web Search',
  'toolWebCrawl': 'Web Crawl',
  'toolImageGen': 'Image Generation',
  'toolFetchImage': 'Fetch Image',
  'toolViewChatImages': 'View Chat Images',
  'toolCryptoData': 'Crypto Data',
  'toolWeather': 'Weather',
  'toolPlaceSearch': 'Place Search',
  'toolRestaurantSearch': 'Restaurant Search',
  'toolGeocoding': 'Geocoding',
  'toolRouting': 'Routing',
  'toolCalculator': 'Calculator',
  'toolClock': 'Clock',
  'toolRandomNumber': 'Random Number',
  'toolCoinFlip': 'Coin Flip',
  'toolDiceRoll': 'Dice Roll',
  'toolCountdown': 'Countdown',
  'toolPasswordGen': 'Password Generator',
  'toolUuidGen': 'UUID Generator',
  'toolNotes': 'Notes',
  'toolQrGen': 'QR Generator',
  'toolWhoopHealth': 'WHOOP Health',
  'resetToolSettingsTitle': 'Reset Tool Settings?',
  'resetToolSettingsBody':
      'This will re-enable all tools and reset all custom tool prompts.',
  'resetAllToolPrefs': 'Reset All Tool Preferences',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Profile',
  'profileSubtitle': 'Update how your name and email appear inside Chuk Chat.',
  'displayName': 'Display name',
  'displayNameHint': 'How other people see you',
  'emailAddress': 'Email address',
  'emailAddressHint': 'Where we send notifications',
  'security': 'Security',
  'securitySubtitle': 'Reassure yourself everything is protected.',
  'changePassword': 'Change password',
  'changePasswordSubtitle':
      'Update your Supabase password and re-encrypt your saved chats.',
  'currentPassword': 'Current password',
  'newPassword': 'New password',
  'minCharsPassword': 'Minimum 8 characters.',
  'confirmNewPassword': 'Confirm new password',
  'updatePassword': 'Update password',
  'encryptedChatRecovery': 'Encrypted Chat Recovery',
  'lockedChatsSingular': '{count} chat encrypted with a previous password.',
  'lockedChatsPlural': '{count} chats encrypted with a previous password.',
  'recoverOldChatsAvailable':
      'You have chats encrypted with a previous password. Enter your old password to unlock them.',
  'chatsFromPreviousPassword': 'Chats from a previous password',
  'recoverChats': 'Recover chats',
  'dangerZone': 'Danger Zone',
  'dangerZoneSubtitle': 'Irreversible actions that affect your entire account.',
  'deleteAccountWarning':
      'Deleting your account will cancel all subscriptions, remove your data, and cannot be undone.',
  'deleteAccount': 'Delete Account',
  'unableToLoadProfile': 'Unable to load your profile right now.',
  'retry': 'Retry',
  'saved': 'Saved',
  'emailUpdated':
      'Email updated. Confirm the change using the link Supabase sent to {email}.',
  'failedToLoadProfile': 'Failed to load profile: {error}',
  'failedToSaveProfile': 'Failed to save profile: {error}',
  'emailCannotBeEmpty': 'Email cannot be empty.',
  'passwordsDoNotMatch': 'New passwords do not match.',
  'failedToChangePassword': 'Failed to change password: {error}',
  'deleteAccountQuestion': 'Delete Account?',
  'deleteAccountConfirmBody':
      'Are you sure you want to delete your account?\n\nThis will permanently erase:\n  \u2022 All your chats and messages\n  \u2022 All stored memories\n  \u2022 Your profile and settings\n  \u2022 Any active subscriptions\n\nThis action is irreversible. Your data cannot be recovered.',
  'yesDelete': 'Yes, I want to delete',
  'thisIsPermanent': 'This is permanent',
  'finalDeleteWarning':
      'This is your last chance to turn back.\n\nOnce deleted, there is absolutely no way to recover your account, chats, memories, or any associated data.\n\nEverything will be gone forever.\n\nDo you still want to proceed?',
  'noKeepMyAccount': 'No, keep my account',
  'deleteEverything': 'Delete everything',
  'confirmYourPassword': 'Confirm your password',
  'confirmPasswordBody':
      'To confirm account deletion, please enter your password.',
  'password': 'Password',
  'passwordRequired': 'Password is required',
  'verificationFailed': 'Verification failed: {error}',
  'verifyAndDelete': 'Verify & Delete',
  'failedToDeleteAccount': 'Failed to delete account: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Identity System',
  'identityActive': 'Soul, User, and Memory are active',
  'identityDisabled': 'Disabled \u2014 AI has no persistent identity',
  'soul': 'Soul',
  'soulHint':
      'Define the AI\'s personality, tone, and boundaries. This shapes how it communicates across all conversations.',
  'soulExample':
      'Example:\n\u2022 Be direct and concise\n\u2022 Match the user\'s language and energy\n\u2022 Have opinions, don\'t hedge everything\n\u2022 Privacy first: ask before external actions',
  'user': 'User',
  'userHint':
      'Facts about you. The AI reads this every message and can also update it when it learns new things about you.',
  'userExample':
      'Example:\n\u2022 Name: Alex\n\u2022 Timezone: Europe/Berlin\n\u2022 Language: German/English mix\n\u2022 Prefers concise, technical answers',
  'memory': 'Memory',
  'memoryHint':
      'Long-term knowledge the AI remembers across conversations. The AI can also update this when it learns important facts or decisions.',
  'memoryExample':
      'Example:\n\u2022 Prefers Dart/Flutter for mobile\n\u2022 License: BSL for all projects\n\u2022 Current workspace: chuk_chat\n\u2022 Dark mode enthusiast',
  'importFromAnotherAi': 'Import from another AI',
  'systemPrompt': 'System Prompt',
  'systemPromptHint':
      'Custom instructions sent with every conversation. Encrypted with your chat encryption key.',
  'systemPromptExample':
      'Example: You are a helpful assistant. Provide concise, accurate responses.',
  'characters': 'characters',
  'saving': 'Saving...',
  'saveChanges': 'Save changes',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Open Source Licenses',
  'openSourceLicensesSubtitle':
      'Review the licenses for every dependency included in this build.',
  'legalDocuments': 'Legal Documents',
  'termsOfService': 'Terms of Service',
  'privacyPolicy': 'Privacy Policy',
  'versionText': 'Version {version}',
  'builtOn': 'Built {date}',
  'updateAvailable': 'Update available: v{version} \u2014 tap to download',
  'versionUnavailable': 'Version information unavailable.',
  'copyrightYear': '\u00a9 {year} Chuk Development\nAll rights reserved.',
  'licenses': 'Licenses',
  'unableToLoadLicenses': 'Unable to load licenses.',
  'tapToViewLicense': 'Tap to view full license text',
  'devOptionsEnabled': 'Developer options enabled',
  'devOptionsAlreadyEnabled': 'Developer options already enabled',
  'devOptionsTapSingular': '{taps} more tap for Developer options',
  'devOptionsTapsPlural': '{taps} more taps for Developer options',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Subscription',
  'openUsageDetailsInfo':
      'Open Usage Details to see every request, monthly totals, and model costs.',
  'openUsageDetails': 'Open Usage Details',
  'currentPlan': 'Current Plan',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/month',
  'monthlyCredits': 'Monthly AI credits: \u20ac16.00',
  'unusedCreditsExpire': 'Unused credits expire at the end of each month.',
  'manageBilling': 'Manage Billing',
  'manageBillingSubtitle':
      'Use the billing portal to cancel your subscription or update payment methods.',
  'subscribeToGetCredits': 'Subscribe to Get AI Credits',
  'subscriptionDesktopOnly':
      'Subscription management is only available on desktop.',
  'paymentsDisabledInBuild': 'Direct payments are disabled in this build.',
  'active': 'ACTIVE',
  'getCreditsMonthly': 'Get \u20ac16 in AI credits monthly',
  'accessAllModels': 'Access to all AI models',
  'imageGeneration': 'Image generation',
  'voiceMode': 'Voice mode',
  'textChatReasoning': 'Text chat with reasoning',
  'creditsExplanation':
      'Your \u20ac16 in AI credits are used per token based on the model you choose. Unused credits expire at the end of each month.',
  'immediateAccessAck':
      'I want immediate access to Chuk Chat and acknowledge that I lose my ',
  'rightOfWithdrawal': 'right of withdrawal',
  'onceServiceBegins': ' once the service begins. I agree to the ',
  'subscribeNow': 'Subscribe Now',
  'alreadySubscribed': 'You already have an active subscription.',
  'opening': 'Opening...',
  'agreeToTermsFirst':
      'Please agree to the terms and acknowledge loss of withdrawal rights.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Welcome to Chuk Chat',
  'signInWithEmail': 'Sign in with your email',
  'createAccountWithEmail': 'Create an account with email & password',
  'supabaseNotConfigured':
      'Supabase credentials are not configured. Update them before running a production build.',
  'confirmEmailToContinue': 'Confirm your email to continue',
  'confirmEmailBody':
      'We sent a confirmation link to your email address. Please open it and click the link before signing in.',
  'howOthersSeeYou': 'How other people will see you',
  'email': 'Email',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'Confirm password',
  'forgotPassword': 'Forgot password?',
  'enterYourPassword': 'Enter your password.',
  'pleaseConfirmPassword': 'Please confirm your password.',
  'signIn': 'Sign in',
  'createAccount': 'Create account',
  'noAccountSignUp': "Don't have an account? Sign up",
  'haveAccountSignIn': 'Already have an account? Sign in',
  'agreeToTerms': 'I agree to the ',
  'andText': ' and ',
  'confirmAge16': 'I confirm that I am at least 16 years old',
  'mustAgreeToTerms':
      'You must agree to the Terms of Service and Privacy Policy to create an account.',
  'mustBe16': 'You must be at least 16 years old to use this service.',
  'unexpectedError': 'Unexpected error: {error}',

  // ── Email OTP verification (signup + recovery) ─────────────
  'verifyEmailTitle': 'Enter the code',
  'verifySignupBody':
      'We emailed a 6-digit code to {email}. Enter it below to confirm your account.',
  'verifyRecoveryBody':
      'We emailed a 6-digit code to {email}. Enter it below to reset your password.',
  'verificationCode': 'Verification code',
  'verificationCodeHint': '6-digit code',
  'verifyButton': 'Verify',
  'verifying': 'Verifying...',
  'resendCode': 'Resend code',
  'resendCodeIn': 'Resend code in {seconds}s',
  'codeResent': 'A new code has been sent.',
  'enterVerificationCode': 'Enter the 6-digit code.',
  'invalidCode': 'That code is invalid or has expired. Request a new one.',
  'tooManyAttempts': 'Too many attempts. Please wait a moment and try again.',
  'otpVerificationFailed': 'Verification failed. Please try again.',
  'changeEmailAddress': 'Use a different email',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'Recover Encrypted Chats',
  'noLockedChats': 'No locked chats',
  'allChatsAccessible': 'All your chats are accessible.',
  'recoverChatsInfo':
      'Some chats are encrypted with a previous password. Enter your old password to recover them, or delete them permanently.',
  'encryptedWithVersion': 'Encrypted with password version {version}',
  'oldPassword': 'Old password',
  'enterOldPassword': 'Enter the password you used before',
  'lockedChatCountSingular': '{count} locked chat',
  'lockedChatCountPlural': '{count} locked chats',
  'deleteLockedChatsTitle': 'Delete locked chats?',
  'deleteLockedChatsBodySingular':
      'This will permanently delete {count} chat that is encrypted with your old password.\n\nThis chat cannot be recovered after deletion. You will lose all messages, images, and attachments.',
  'deleteLockedChatsBodyPlural':
      'This will permanently delete {count} chats that are encrypted with your old password.\n\nThese chats cannot be recovered after deletion. You will lose all messages, images, and attachments.',
  'deletePermanently': 'Delete permanently',
  'areYouSure': 'Are you sure?',
  'confirmDeleteChats':
      'You are about to delete {count} chats. Type DELETE to confirm.',
  'typeDelete': 'Type DELETE',
  'confirmDelete': 'Confirm delete',
  'pleaseEnterOldPassword': 'Please enter your old password.',
  'derivingKey': 'Deriving encryption key...',
  'recoveredChatsSingular': 'Successfully recovered {count} chat.',
  'recoveredChatsPlural': 'Successfully recovered {count} chats.',
  'recoveryFailed': 'Recovery failed. Please try again.',
  'deletedChatsSingular': 'Deleted {count} chat.',
  'deletedChatsPlural': 'Deleted {count} chats.',
  'deletionFailed': 'Deletion failed. Please try again.',
  'recover': 'Recover',
  'delete': 'Delete',
  'deleting': 'Deleting...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Set a new password',
  'setNewPasswordInfo':
      'Choose a strong password for your account. Your old chats will remain accessible if you remember your previous password.',
  'setNewPasswordButton': 'Set new password',
  'noAuthenticatedUser': 'No authenticated user after password update.',
  'failedToPreserveEncryption':
      'Failed to preserve old encryption data. Please check your connection and try again.',
  'failedToSetNewPassword': 'Failed to set new password. Please try again.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Developer options',
  'devOptionsToggleSubtitle':
      'Unlock diagnostics and debug tools. Disable to hide all developer-only settings.',
  'enableDiagnosticsLogging': 'Enable diagnostics logging',
  'enableDiagnosticsSubtitle':
      'Works in release builds. Logs app/runtime metadata for troubleshooting lag and tray issues.',
  'diagnosticsEnabled': 'Diagnostics logging enabled',
  'diagnosticsDisabled': 'Diagnostics logging disabled',
  'logFile': 'Log file',
  'notInitializedYet': 'Not initialized yet',
  'refresh': 'Refresh',
  'copyRecent': 'Copy Recent',
  'copyFocusedDebug': 'Copy Focused Debug',
  'shareFile': 'Share File',
  'clear': 'Clear',
  'copiedRecentLogs': 'Copied recent logs to clipboard',
  'noFocusedDebugData': 'No focused debug data available yet',
  'copiedFocusedDebug': 'Copied focused model-menu debug report',
  'failedFocusedDebug': 'Failed to create focused debug report: {error}',
  'noDiagnosticsLog': 'No diagnostics log available',
  'diagnosticsLogNotFound': 'Diagnostics log file not found',
  'failedToShareLog': 'Failed to share diagnostics log: {error}',
  'diagnosticsLogCleared': 'Diagnostics log cleared',
  'failedToClearLog': 'Failed to clear diagnostics log: {error}',
  'recentLogLines': 'Recent log lines',
  'devOptionsDisabledMsg': 'Developer options disabled.',
  'noLogsYet':
      'No logs yet. Enable diagnostics logging and use the app to collect data.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Back',
  'enabled': 'Enabled',
  'disabled': 'Disabled',
  'modelPrompt': 'Model Prompt',
  'modelPromptHint':
      'This description is shown to the model after tool discovery.',
  'customPromptActive': 'Custom prompt active',
  'savePrompt': 'Save Prompt',
  'parameters': 'Parameters',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Usage Details',
  'unableToLoadUsage': 'Unable to load usage details right now.',
  'usageAndBilling': 'Usage and Billing',
  'usageReadOnly': 'This screen is read-only and pulled from your usage logs.',
  'period': 'Period',
  'totals': 'Totals',
  'mediaRequestsNote':
      'Image and audio requests are treated as media requests and excluded from text-token totals.',
  'noRequestsFound': 'No requests found for this period.',
  'cachedTokens': 'Cached tokens',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'Session expired. Please sign in again.',
  'offlineMessage':
      'You appear to be offline. Please check your internet connection.',
  'cannotReachApi': 'Cannot reach the API server.',
  'maintenanceMessage':
      'We are currently doing maintenance and will be right back.',
  'free': 'Free',
  'perMillion': '/M',
  'perRequest': '/req',
  'best': 'Best',
  'autoCheapest': 'Auto (cheapest)',
  'autoCheapestCurrently': 'Auto (cheapest) — currently: {provider} ({price})',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'Open in Mail App',
  'costLabel': 'Cost: {cost}',
  'generatedLabel': 'Generated: {label}',
  'unableToCopyImage': 'Unable to copy image',
  'unableToSaveImage': 'Unable to save image',
  'image': 'Image',
  'openLink': 'Open Link',
  'openLinkConfirm': 'Do you really want to leave the app and open {url}?',
  'open': 'Open',

  // ── Misc / shared ─────────────────────────────────────────
  'contentCopied': 'Content copied to clipboard',
  'artifactCopied': 'Artifact copied to clipboard',
  'fileSaved': 'File saved',
  'failedToExportArtifact': 'Failed to export artifact: {error}',
  'failedToSave': 'Failed to save: {error}',
  'markdownSaved': 'Markdown saved',
  'original': 'Original',
  'markdown': 'Markdown',
  'viewMarkdownSummary': 'View Markdown Summary',
  'addSummary': 'Add summary',
  'deletedFile': 'Deleted File',
  'deleteFile': 'Delete File',
  'deleteFileConfirm': 'Delete "{name}"?',
  'deleteFailed': 'Delete failed: {error}',
  'uploadedFile': 'Uploaded: {name}',
  'freeMessagePlaceholder': 'Free: --',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'Ask me anything !',
  'queuedLabel': 'Queued',
  'editYourMessage': 'Edit your message...',
  'addMessageOrDocs': 'Add a message or send documents',
  'micAccessFailed': 'Mic access failed',
  'transcriptionFailed': 'Transcription failed',
  'replyTargetSelected': 'Reply target selected',
  'clearReply': 'Clear reply',
  'nothingToResend': 'Nothing to resend',
  'freeMessagesUsed': 'Free Messages Used',
  'ok': 'OK',
  'camera': 'Camera',
  'photos': 'Photos',
  'files': 'Files',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Models',
  'searchModels': 'Search models...',
  'modelError': 'Error: {error}',

  // ── Message bubble extras ──────────────────────────────────
  'copyImage': 'Copy image',
  'downloadImage': 'Download image',
  'imageDetails': 'Image details',
  'generatingImage': 'Generating…',
  'imageCopied': 'Image copied',

  // ── Free message display ───────────────────────────────────
  'freeMessages': 'Free Messages',
  'freeUsed': 'Used: {count}',
  'freeTotal': 'Total: {count}',
  'subscribeToContinue': 'Subscribe to continue chatting',
  'freeRemaining': 'Free: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Select Model',
  'noEnabledModels': 'No Enabled Models',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'New chat',
  'workspaces': 'Workspaces',
  'media': 'Media',

  // ── CoWork mode ─────────────────────────────────────────────
  'chatMode': 'Chat',
  'coworkMode': 'CoWork',
  'coworkComingSoon': 'CoWork',
  'coworkComingSoonBody':
      'Drive an agent on your laptop from anywhere. Pairing and remote control are on the way.',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Media Manager',
  'imageUsedInChats': 'Image Used in Chats',
  'imageUsedInChatsBody': 'This image is used in the following chats:',
  'deleteImageShowDeleted':
      'If you delete this image, it will show as "Image deleted" in those chats.',
  'deleteImageConfirm': 'Are you sure you want to delete this image?',
  'deleteAnyway': 'Delete Anyway',
  'deleteImageTitle': 'Delete Image',
  'deleteImageBody':
      'Are you sure you want to delete this image? This action cannot be undone.',
  'imageDeleted': 'Image deleted',
  'failedToDeleteImage': 'Failed to delete image: {error}',
  'someImagesUsedInChats': 'Some Images Are Used in Chats',
  'deletedImagesWarning':
      'Deleted images will show as "Image deleted" in those chats.',
  'deleteAllCount': 'Delete all {count} selected images?',
  'deleteAll': 'Delete All',
  'deleteSelectedImages': 'Delete Selected Images',
  'deleteSelectedCount':
      'Delete {count} selected images? This action cannot be undone.',
  'deletedImagesResult': 'Deleted {deleted} images, {failed} failed',
  'deletedImagesSuccess': 'Deleted {deleted} images',
  'downloadSelected': 'Download selected',
  'deleteSelected': 'Delete selected',
  'errorLoadingImages': 'Error loading images',
  'noImagesStored': 'No images stored',
  'imagesAppearHere': 'Images you send in chats will appear here',
  'download': 'Download',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'Remove {name}',
  'edit': 'Edit',
  'close': 'Close',

  // ── Subscription dialogs ───────────────────────────────────
  'maybeLater': 'Maybe Later',

  // ── Workspace (project) detail ─────────────────────────────
  'projectPrivate': 'Private',
  'projectPublic': 'Public',
  'projectKnowledge': 'Project knowledge',
  'projectInstructions': 'Custom instructions',
  'projectInstructionsEmpty': 'No instructions yet',
  'projectInstructionsSubtitle':
      'Sent to the AI at the start of every chat in this project.',
  'projectLatestChats': 'Recent chats',
  'projectNoChats': 'No chats yet',
  'projectNoChatsHint': 'Start a new chat with this project selected.',
  'projectNewChat': 'New chat',
  'projectFileCountSingular': '{count} file',
  'projectFileCountPlural': '{count} files',
  'projectNoFiles': 'No files yet',
  'projectAddContent': 'Add content',
  'projectUploadFromDevice': 'Upload from device',
  'projectTakePhoto': 'Take photo',
  'projectPickImage': 'Pick image',
  'projectCreateDocument': 'Create new document',
  'projectNewDocument': 'New document',
  'projectDocumentTitle': 'Title',
  'projectDocumentContent': 'Content',
  'projectDocumentTitleHint': 'e.g. Meeting notes',
  'projectDocumentContentHint': 'Start writing…',
  'projectEditProject': 'Edit project',
  'projectDeleteProject': 'Delete project',
  'projectDeleteProjectBody':
      'Delete this project? Chats and files will not be deleted.',
  'projectWorkspaceNotFound': 'Project not found',
  'projectName': 'Name',
  'projectDescriptionLabel': 'Description',
  'projectDiscardChangesTitle': 'Discard changes?',
  'projectDiscardChangesBody': 'Your changes have not been saved.',
  'projectKeepEditing': 'Keep editing',
  'projectDiscardAction': 'Discard',
  'projectSaveFailed': 'Save failed: {error}',
  'projectLoadFailed': 'Failed to load: {error}',
  'projectUploadFailed': 'Upload failed: {error}',
  'projectDeleteFailed': 'Delete failed: {error}',
  'projectUploaded': 'Uploaded: {name}',
  'projectCameraFailed': 'Camera failed: {error}',
  'projectImagePickFailed': 'Image pick failed: {error}',
  'projectContextBudgetTitle': 'Context budget warning',
  'projectContextBudgetBody':
      'This file (~{tokens} tokens) may exceed the context budget. Upload anyway?',
  'projectUploadAnyway': 'Upload anyway',
  'projectEncryptingUploading': 'Encrypting and uploading…',
  'projectConvertingMarkdown': 'Converting to markdown…',
  'projectDeleteFileTitle': 'Delete file',
  'projectDeleteFileBody': 'Delete "{name}"?',
  'projectView': 'View',
  'projectNotSupportedPlatform': 'Not supported on this platform.',
  'projectEditProjectTitle': 'Edit project',
  // ── Offline queue ──────────────────────────────────────────
  'messagePending': 'Will send when online',
  'messageFailed': 'Failed to send',
  'messageRetry': 'Retry',

  // ── Onboarding ─────────────────────────────────────────────
  'onboardingSkip': 'Skip',
  'onboardingNext': 'Next',
  'onboardingBack': 'Back',
  'onboardingDone': 'Done',
  'onboardingNoModelHint': 'No model selected yet',
  'onboardingReplayTile': 'Show onboarding again',
  'onboardingReplayTileSubtitle': 'Replay the welcome tour',

  // Interactive guided tour (banner overlay shown over real UI)
  'tourSkip': 'Skip',
  'tourEndTour': 'End tour',
  'tourContinue': 'Continue',
  'tourGetStarted': 'Get started',
  'tourFinish': 'Finish',
  'tourWelcomeTitle': 'Welcome to Chuk Chat',
  'tourWelcomeBody':
      "End-to-end encrypted AI chat. First, you'll need to pick a model — let me show you where.",
  'tourModelTitle': 'Pick a model — required',
  'tourModelBody':
      'You need to pick a model before you can chat. Tap here to open the picker.',
  'tourSettingsModelBody':
      'Tap Model Selection to open the picker. You generally need a model and a provider selected to chat.',
  'tourModelPageBody':
      "Choose a model and a provider — this is required to send messages. Try 'Auto (cheapest)' for the best price.",
  'tourSettingsTitle': 'Make it yours',
  'tourSettingsBody':
      'Settings is where you change theme, font size, UI scale, and your account.',
  'tourSettingsPageBody': 'Customize the app: theme, font, UI scale, account.',
  'tourSettingsTapHere': 'Tap Settings here.',
  'tourMenuTitle': 'Open the menu',
  'tourMenuBody': 'Tap the menu icon to find Settings.',
  'tourChatTitle': 'Start chatting',
  'tourChatBody':
      'Type your message at the bottom and press Enter. Use the paperclip to attach files.',
  'tourProviderPillBody':
      'Pick a provider on any model — the provider is what activates it. Auto (cheapest) is the default.',
  'tourSettingsPricingTitle': 'Subscription',
  'tourSettingsPricingBody':
      'Subscribe here to unlock more usage. Pay directly — no app-store middleman.',
  'tourSettingsAiIdentityTitle': 'AI behavior',
  'tourSettingsAiIdentityBody':
      'Configure system prompt, memory on/off, and reasoning here.',
  'tourDoneTitle': "You're all set",
  'tourDoneBody': 'You can replay this tour any time from Settings.',
  // ── Battery optimization prompt ──────────────────────────────
  'batteryOptimizationTitle': 'Keep responses running',
  'batteryOptimizationBody':
      'Android may pause Chuk Chat when the screen is locked, cutting off long '
      'AI responses and tool steps mid-way. Allow unrestricted background '
      'activity so replies finish even when your phone is locked.',
  'batteryOptimizationAllow': 'Allow',
  'batteryOptimizationLater': 'Later',
};
