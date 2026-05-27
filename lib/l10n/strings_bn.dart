// lib/l10n/strings_bn.dart
// Bengali UI strings.

const Map<String, String> stringsBn = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'সেটিংস',
  'themeSettings': 'থিম সেটিংস',
  'themeSettingsSubtitle': 'অ্যাপ থিম, রঙ এবং চেহারা পরিবর্তন করুন',
  'customization': 'কাস্টমাইজেশন',
  'customizationSubtitle': 'অ্যাপের আচরণ এবং পছন্দ কনফিগার করুন',
  'toolCalling': 'টুল কলিং',
  'toolCallingSubtitle': 'টুল ব্যবহার, আবিষ্কার এবং টুল-কল প্রদর্শন নিয়ন্ত্রণ করুন',
  'developerOptions': 'ডেভেলপার অপশন',
  'developerOptionsSubtitle': 'ডায়াগনস্টিকস লগ এবং ডিবাগ টুলস',
  'modelSelection': 'মডেল নির্বাচন',
  'modelSelectionSubtitle': 'আপনার AI মডেল বেছে নিন এবং কনফিগার করুন',
  'aiIdentityMemory': 'AI পরিচয় ও স্মৃতি',
  'aiIdentityMemorySubtitle': 'সোল, ব্যবহারকারী প্রোফাইল, স্মৃতি এবং সিস্টেম প্রম্পট',
  'pricingPlans': 'মূল্য পরিকল্পনা',
  'pricingPlansSubtitle': 'আমাদের সাবস্ক্রিপশন প্ল্যান এবং মূল্য দেখুন',
  'accountSettings': 'অ্যাকাউন্ট সেটিংস',
  'accountSettingsSubtitle': 'আপনার প্রোফাইল এবং অ্যাকাউন্ট পরিচালনা করুন',
  'exportChats': 'চ্যাট এক্সপোর্ট',
  'exportChatsSubtitle': 'আপনার কথোপকথন JSON হিসেবে ডাউনলোড করুন',
  'about': 'সম্পর্কে',
  'aboutSubtitle': 'সংস্করণ বিবরণ এবং ওপেন সোর্স লাইসেন্স',
  'logout': 'লগআউট',
  'noChatsToExport': 'এক্সপোর্ট করার মতো কোনো চ্যাট নেই',
  'copiedToClipboard': 'ক্লিপবোর্ডে কপি করা হয়েছে',
  'savedToPath': '{path}-এ সংরক্ষিত',
  'exportCancelled': 'এক্সপোর্ট বাতিল করা হয়েছে',
  'shareOpened': 'শেয়ার খোলা হয়েছে',
  'exportFailed': 'এক্সপোর্ট ব্যর্থ: {error}',
  'saveChatExport': 'চ্যাট এক্সপোর্ট সংরক্ষণ করুন',

  // ── Customization page ─────────────────────────────────────
  'language': 'ভাষা',
  'languageSubtitle': 'আপনার পছন্দের ভাষা বেছে নিন',
  'english': 'English',
  'german': 'Deutsch',
  'voiceTranscription': 'ভয়েস ট্রান্সক্রিপশন',
  'autoSendVoice': 'ভয়েস মেসেজ স্বয়ংক্রিয়ভাবে পাঠান',
  'autoSendVoiceSubtitle':
      'নিশ্চিতকরণ ছাড়াই স্বয়ংক্রিয়ভাবে ট্রান্সক্রাইব করা ভয়েস মেসেজ পাঠান',
  'autoSendVoiceInfo':
      'সক্রিয় থাকলে, ভয়েস ট্রান্সক্রিপশন সাথে সাথে পাঠানো হয়। নিষ্ক্রিয় থাকলে (ডিফল্ট), ট্রান্সক্রিপশন পাঠানোর আগে পর্যালোচনার জন্য টেক্সট ফিল্ডে দেখায়।',
  'messageDisplay': 'মেসেজ প্রদর্শন',
  'showReasoningTokens': 'রিজনিং টোকেন দেখান',
  'showReasoningTokensSubtitle':
      'AI উত্তরে রিজনিং প্রক্রিয়ার টোকেন প্রদর্শন করুন',
  'showModelInfo': 'মডেল তথ্য দেখান',
  'showModelInfoSubtitle':
      'চ্যাট মেসেজে মডেলের নাম এবং তথ্য প্রদর্শন করুন',
  'showTps': 'প্রতি সেকেন্ডে টোকেন দেখান',
  'showTpsSubtitle': 'AI উত্তর তৈরির গতি (TPS) প্রদর্শন করুন',
  'aiContext': 'AI কনটেক্সট',
  'recentImagesInContext': 'কনটেক্সটে সাম্প্রতিক ছবি',
  'recentImagesInContextSubtitle':
      'সাম্প্রতিক মেসেজের ছবি AI মডেলে পাঠান',
  'allImagesInContext': 'কনটেক্সটে সব ছবি',
  'allImagesInContextSubtitle':
      'কথোপকথনের সব ছবি AI-তে পাঠান (বেশি টোকেন ব্যবহার করে)',
  'reasoningInContext': 'কনটেক্সটে রিজনিং',
  'reasoningInContextSubtitle':
      'কথোপকথনের ইতিহাসে AI-এর চিন্তা প্রক্রিয়া অন্তর্ভুক্ত করুন',
  'aiContextInfo':
      'সাম্প্রতিক ছবি শেষ ৬টি মেসেজের ছবি পাঠায়। সব ছবি কথোপকথনের প্রতিটি ছবি পাঠায়। রিজনিং ফলো-আপ মেসেজের কনটেক্সট হিসেবে AI-এর চিন্তা প্রক্রিয়া অন্তর্ভুক্ত করে।',
  'chatTitles': 'চ্যাট শিরোনাম',
  'autoGenerateTitles': 'স্বয়ংক্রিয়ভাবে চ্যাট শিরোনাম তৈরি করুন',
  'autoGenerateTitlesSubtitle':
      'নতুন চ্যাটের জন্য AI ব্যবহার করে শিরোনাম তৈরি করুন',
  'titleGenerationPrompt': 'শিরোনাম তৈরির প্রম্পট',
  'usingCustomPrompt': 'কাস্টম প্রম্পট ব্যবহার হচ্ছে',
  'usingDefaultPrompt': 'ডিফল্ট প্রম্পট ব্যবহার হচ্ছে',
  'titleGenInfo':
      'সক্রিয় থাকলে, আপনার প্রথম মেসেজের উপর ভিত্তি করে নতুন চ্যাটের জন্য স্বয়ংক্রিয়ভাবে একটি সংক্ষিপ্ত শিরোনাম তৈরি হবে। একটি দ্রুত, হালকা AI মডেল (qwen3-8b) ব্যবহার করে।',
  'systemPromptSaved': 'সিস্টেম প্রম্পট সংরক্ষিত',
  'systemPromptResetToDefault': 'সিস্টেম প্রম্পট ডিফল্টে রিসেট করা হয়েছে',
  'reset': 'রিসেট',
  'save': 'সংরক্ষণ',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'ডার্ক মোড',
  'darkModeSubtitle': 'ডার্ক এবং লাইট থিমের মধ্যে পরিবর্তন করুন',
  'accentColor': 'অ্যাকসেন্ট রঙ',
  'accentColorSubtitle': 'আপনার প্রাথমিক অ্যাকসেন্ট রঙ বেছে নিন',
  'iconFgColor': 'আইকন/ফোরগ্রাউন্ড রঙ',
  'iconFgColorSubtitle': 'আইকন এবং প্রধান টেক্সটের রঙ বেছে নিন',
  'backgroundColor': 'পটভূমির রঙ',
  'backgroundColorSubtitle': 'অ্যাপের প্রধান পটভূমির রঙ বেছে নিন',
  'filmGrainEffect': 'ফিল্ম গ্রেইন ইফেক্ট',
  'filmGrainSubtitle': 'একটি সূক্ষ্ম ফিল্ম-শট টেক্সচার যোগ করুন',
  'customHexColor': 'কাস্টম হেক্স রঙ (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'ইঞ্জিন',
  'enableToolCalling': 'টুল কলিং সক্রিয় করুন',
  'enableToolCallingSubtitle':
      'সহকারীকে বিল্ট-ইন টুল আবিষ্কার এবং চালানোর অনুমতি দিন',
  'behavior': 'আচরণ',
  'requireDiscoveryFirst': 'প্রথমে আবিষ্কার প্রয়োজন',
  'requireDiscoverySubtitle':
      'একটি টার্নে অন্যান্য টুলের আগে find_tools বাধ্যতামূলক করুন',
  'markdownToolCallFallback': 'মার্কডাউন টুল-কল ফলব্যাক',
  'markdownFallbackSubtitle':
      'মডেল XML ট্যাগ না দিলে ```tool_call কোড ব্লক গ্রহণ করুন',
  'display': 'প্রদর্শন',
  'showToolActivity': 'চ্যাটে টুল কার্যকলাপ দেখান',
  'showToolActivitySubtitle':
      'সহকারী মেসেজে চলমান/সম্পন্ন টুল চিপ প্রদর্শন করুন',
  'toolCallingTip':
      'পরামর্শ: সেরা সামঞ্জস্যের জন্য মার্কডাউন ফলব্যাক সক্রিয় রাখুন। শুধুমাত্র কঠোর XML-শুধু টুল কলের জন্য নিষ্ক্রিয় করুন।',
  'visualOutputNonTool': 'ভিজ্যুয়াল আউটপুট (নন-টুল)',
  'enableMapBlocks': 'ম্যাপ ব্লক সক্রিয় করুন (<map>)',
  'enableMapBlocksSubtitle':
      'মডেল প্রম্পটে ম্যাপ রেন্ডারিং নির্দেশনা অন্তর্ভুক্ত করার অনুমতি দিন',
  'enableChartBlocks': 'চার্ট ব্লক সক্রিয় করুন (<chart>)',
  'enableChartBlocksSubtitle':
      'মডেল প্রম্পটে চার্ট রেন্ডারিং নির্দেশনা অন্তর্ভুক্ত করার অনুমতি দিন',
  'connectors': 'সংযোগকারী',
  'loadingToolSettings': 'টুল সেটিংস লোড হচ্ছে...',
  'noToolsRegistered': 'এখনও কোনো টুল নিবন্ধিত হয়নি।',
  'catSearchWeb': 'সার্চ এবং ওয়েব',
  'catUtilities': 'ইউটিলিটি',
  'catMapsLocation': 'ম্যাপ এবং লোকেশন',
  'catDevice': 'ডিভাইস',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / টার্মিনাল',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (ক্যালেন্ডার / Gmail)',
  'catEmailImapSmtp': 'ইমেইল (IMAP/SMTP)',
  'catWhoop': 'WHOOP',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'স্যান্ডবক্স / কোড',
  'catSearchWebDesc':
      'ওয়েবে সার্চ করুন, পেজ ফেচ করুন, ছবি তৈরি করুন এবং ডেটা খুঁজুন',
  'catUtilitiesDesc':
      'ক্যালকুলেটর, ঘড়ি, নোট, QR কোড এবং অন্যান্য ইউটিলিটি',
  'catMapsLocationDesc':
      'স্থান খুঁজুন, ঠিকানা জিওকোড করুন এবং রুট গণনা করুন',
  'catDeviceDesc': 'GPS, ক্যালেন্ডার এবং রিমাইন্ডারের মতো ডিভাইস ফিচার অ্যাক্সেস করুন',
  'catSpotifyDesc': 'প্লেব্যাক নিয়ন্ত্রণ করুন এবং আপনার Spotify লাইব্রেরি ব্রাউজ করুন',
  'catBashTerminalDesc': 'ডেস্কটপে স্যান্ডবক্সড শেল কমান্ড চালান',
  'catGitHubDesc':
      'GitHub থেকে রিপো, ইস্যু, PR এবং কমিট অ্যাক্সেস করুন',
  'catSlackDesc':
      'মেসেজ পাঠান, চ্যানেল সার্চ করুন এবং Slack ডেটা ফেচ করুন',
  'catGoogleCalGmailDesc':
      'Google Calendar এবং Gmail-এর মাধ্যমে আপনার সময়সূচি এবং ইমেইল পরিচালনা করুন',
  'catEmailImapSmtpDesc': 'IMAP এবং SMTP-এর মাধ্যমে ইমেইল পাঠান এবং গ্রহণ করুন',
  'catWhoopDesc':
      'WHOOP থেকে রিকভারি, স্ট্রেইন, ঘুম এবং ওয়ার্কআউট ডেটা দেখুন',
  'catNextcloudDesc':
      'Nextcloud-এ ফাইল, ক্যালেন্ডার এবং পরিচিতি ব্রাউজ করুন',
  'catSandboxDesc':
      'একটি বিচ্ছিন্ন স্যান্ডবক্সে Python বা shell কোড চালান এবং ফাইল পড়ুন/লিখুন',
  'connect': 'সংযুক্ত করুন',
  'disconnect': 'সংযোগ বিচ্ছিন্ন করুন',
  'disconnectCategory': '{label} সংযোগ বিচ্ছিন্ন করবেন?',
  'removeCredentialsWarning': 'এটি আপনার সংরক্ষিত শংসাপত্র মুছে ফেলবে।',
  'cancel': 'বাতিল',
  'categoryConnected': '{label} সংযুক্ত',
  'failedToConnect': '{label} সংযুক্ত করতে ব্যর্থ',
  'unableToConnect':
      '{label} সংযুক্ত করা যায়নি। অনুগ্রহ করে আবার চেষ্টা করুন।',
  'toolWebSearch': 'ওয়েব সার্চ',
  'toolWebCrawl': 'ওয়েব ক্রল',
  'toolImageGen': 'ছবি তৈরি',
  'toolFetchImage': 'ছবি ফেচ',
  'toolViewChatImages': 'চ্যাট ছবি দেখুন',
  'toolCryptoData': 'ক্রিপ্টো ডেটা',
  'toolWeather': 'আবহাওয়া',
  'toolPlaceSearch': 'স্থান সার্চ',
  'toolRestaurantSearch': 'রেস্তোরাঁ সার্চ',
  'toolGeocoding': 'জিওকোডিং',
  'toolRouting': 'রাউটিং',
  'toolCalculator': 'ক্যালকুলেটর',
  'toolClock': 'ঘড়ি',
  'toolRandomNumber': 'র‍্যান্ডম নম্বর',
  'toolCoinFlip': 'কয়েন ফ্লিপ',
  'toolDiceRoll': 'ডাইস রোল',
  'toolCountdown': 'কাউন্টডাউন',
  'toolPasswordGen': 'পাসওয়ার্ড জেনারেটর',
  'toolUuidGen': 'UUID জেনারেটর',
  'toolNotes': 'নোট',
  'toolQrGen': 'QR জেনারেটর',
  'toolWhoopHealth': 'WHOOP স্বাস্থ্য',
  'resetToolSettingsTitle': 'টুল সেটিংস রিসেট করবেন?',
  'resetToolSettingsBody':
      'এটি সব টুল পুনরায় সক্রিয় করবে এবং সব কাস্টম টুল প্রম্পট রিসেট করবে।',
  'resetAllToolPrefs': 'সব টুল পছন্দ রিসেট করুন',

  // ── Account settings page ──────────────────────────────────
  'profile': 'প্রোফাইল',
  'profileSubtitle':
      'Chuk Chat-এ আপনার নাম এবং ইমেইল কিভাবে দেখায় তা আপডেট করুন।',
  'displayName': 'প্রদর্শনের নাম',
  'displayNameHint': 'অন্যরা আপনাকে যেভাবে দেখে',
  'emailAddress': 'ইমেইল ঠিকানা',
  'emailAddressHint': 'যেখানে আমরা বিজ্ঞপ্তি পাঠাই',
  'security': 'নিরাপত্তা',
  'securitySubtitle': 'নিশ্চিত করুন সবকিছু সুরক্ষিত আছে।',
  'changePassword': 'পাসওয়ার্ড পরিবর্তন করুন',
  'changePasswordSubtitle':
      'আপনার Supabase পাসওয়ার্ড আপডেট করুন এবং আপনার সংরক্ষিত চ্যাট পুনরায় এনক্রিপ্ট করুন।',
  'currentPassword': 'বর্তমান পাসওয়ার্ড',
  'newPassword': 'নতুন পাসওয়ার্ড',
  'minCharsPassword': 'সর্বনিম্ন ৮ অক্ষর।',
  'confirmNewPassword': 'নতুন পাসওয়ার্ড নিশ্চিত করুন',
  'updatePassword': 'পাসওয়ার্ড আপডেট করুন',
  'encryptedChatRecovery': 'এনক্রিপ্টেড চ্যাট পুনরুদ্ধার',
  'lockedChatsSingular': '{count}টি চ্যাট পূর্ববর্তী পাসওয়ার্ড দিয়ে এনক্রিপ্ট করা।',
  'lockedChatsPlural': '{count}টি চ্যাট পূর্ববর্তী পাসওয়ার্ড দিয়ে এনক্রিপ্ট করা।',
  'recoverChats': 'চ্যাট পুনরুদ্ধার করুন',
  'dangerZone': 'বিপদ অঞ্চল',
  'dangerZoneSubtitle':
      'অপরিবর্তনীয় পদক্ষেপ যা আপনার পুরো অ্যাকাউন্টকে প্রভাবিত করে।',
  'deleteAccountWarning':
      'আপনার অ্যাকাউন্ট মুছে ফেললে সব সাবস্ক্রিপশন বাতিল হবে, আপনার ডেটা মুছে যাবে এবং এটি পূর্বাবস্থায় ফেরানো যাবে না।',
  'deleteAccount': 'অ্যাকাউন্ট মুছুন',
  'unableToLoadProfile': 'এই মুহূর্তে আপনার প্রোফাইল লোড করা যাচ্ছে না।',
  'retry': 'পুনরায় চেষ্টা',
  'saved': 'সংরক্ষিত',
  'emailUpdated':
      'ইমেইল আপডেট হয়েছে। {email}-এ Supabase যে লিঙ্ক পাঠিয়েছে তা ব্যবহার করে পরিবর্তন নিশ্চিত করুন।',
  'failedToLoadProfile': 'প্রোফাইল লোড করতে ব্যর্থ: {error}',
  'failedToSaveProfile': 'প্রোফাইল সংরক্ষণ করতে ব্যর্থ: {error}',
  'emailCannotBeEmpty': 'ইমেইল খালি রাখা যাবে না।',
  'passwordsDoNotMatch': 'নতুন পাসওয়ার্ডগুলো মিলছে না।',
  'failedToChangePassword': 'পাসওয়ার্ড পরিবর্তন করতে ব্যর্থ: {error}',
  'deleteAccountQuestion': 'অ্যাকাউন্ট মুছবেন?',
  'deleteAccountConfirmBody':
      'আপনি কি নিশ্চিত যে আপনার অ্যাকাউন্ট মুছতে চান?\n\nএটি স্থায়ীভাবে মুছে ফেলবে:\n  \u2022 আপনার সব চ্যাট এবং মেসেজ\n  \u2022 সব সংরক্ষিত স্মৃতি\n  \u2022 আপনার প্রোফাইল এবং সেটিংস\n  \u2022 যেকোনো সক্রিয় সাবস্ক্রিপশন\n\nএই পদক্ষেপ অপরিবর্তনীয়। আপনার ডেটা পুনরুদ্ধার করা যাবে না।',
  'yesDelete': 'হ্যাঁ, আমি মুছতে চাই',
  'thisIsPermanent': 'এটি স্থায়ী',
  'finalDeleteWarning':
      'এটি আপনার ফিরে আসার শেষ সুযোগ।\n\nমুছে ফেলার পর, আপনার অ্যাকাউন্ট, চ্যাট, স্মৃতি বা কোনো সংশ্লিষ্ট ডেটা পুনরুদ্ধার করার কোনো উপায় নেই।\n\nসবকিছু চিরতরে মুছে যাবে।\n\nআপনি কি এখনও এগিয়ে যেতে চান?',
  'noKeepMyAccount': 'না, আমার অ্যাকাউন্ট রাখুন',
  'deleteEverything': 'সবকিছু মুছুন',
  'confirmYourPassword': 'আপনার পাসওয়ার্ড নিশ্চিত করুন',
  'confirmPasswordBody':
      'অ্যাকাউন্ট মুছে ফেলা নিশ্চিত করতে, অনুগ্রহ করে আপনার পাসওয়ার্ড দিন।',
  'password': 'পাসওয়ার্ড',
  'passwordRequired': 'পাসওয়ার্ড আবশ্যক',
  'verificationFailed': 'যাচাইকরণ ব্যর্থ: {error}',
  'verifyAndDelete': 'যাচাই করুন ও মুছুন',
  'failedToDeleteAccount': 'অ্যাকাউন্ট মুছতে ব্যর্থ: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'পরিচয় সিস্টেম',
  'identityActive': 'সোল, ব্যবহারকারী এবং স্মৃতি সক্রিয়',
  'identityDisabled': 'নিষ্ক্রিয় — AI-এর কোনো স্থায়ী পরিচয় নেই',
  'soul': 'সোল',
  'soulHint':
      'AI-এর ব্যক্তিত্ব, ভঙ্গি এবং সীমানা নির্ধারণ করুন। এটি সব কথোপকথনে তার যোগাযোগের ধরন গঠন করে।',
  'soulExample':
      'উদাহরণ:\n\u2022 সরাসরি এবং সংক্ষিপ্ত হোন\n\u2022 ব্যবহারকারীর ভাষা এবং শক্তির সাথে মিল রাখুন\n\u2022 মতামত রাখুন, সবকিছু অস্পষ্ট রাখবেন না\n\u2022 গোপনীয়তা প্রথমে: বাহ্যিক পদক্ষেপের আগে জিজ্ঞাসা করুন',
  'user': 'ব্যবহারকারী',
  'userHint':
      'আপনার সম্পর্কে তথ্য। AI প্রতিটি মেসেজে এটি পড়ে এবং আপনার সম্পর্কে নতুন কিছু জানলে এটি আপডেটও করতে পারে।',
  'userExample':
      'উদাহরণ:\n\u2022 নাম: আলেক্স\n\u2022 টাইমজোন: Europe/Berlin\n\u2022 ভাষা: জার্মান/ইংরেজি মিশ্র\n\u2022 সংক্ষিপ্ত, প্রযুক্তিগত উত্তর পছন্দ করে',
  'memory': 'স্মৃতি',
  'memoryHint':
      'কথোপকথন জুড়ে AI যে দীর্ঘমেয়াদী জ্ঞান মনে রাখে। গুরুত্বপূর্ণ তথ্য বা সিদ্ধান্ত জানলে AI এটি আপডেটও করতে পারে।',
  'memoryExample':
      'উদাহরণ:\n\u2022 মোবাইলের জন্য Dart/Flutter পছন্দ করে\n\u2022 লাইসেন্স: সব প্রজেক্টের জন্য BSL\n\u2022 বর্তমান প্রজেক্ট: chuk_chat\n\u2022 ডার্ক মোড উৎসাহী',
  'importFromAnotherAi': 'অন্য AI থেকে আমদানি করুন',
  'systemPrompt': 'সিস্টেম প্রম্পট',
  'systemPromptHint':
      'প্রতিটি কথোপকথনে পাঠানো কাস্টম নির্দেশনা। আপনার চ্যাট এনক্রিপশন কী দিয়ে এনক্রিপ্ট করা।',
  'systemPromptExample':
      'উদাহরণ: আপনি একজন সহায়ক সহকারী। সংক্ষিপ্ত, সঠিক উত্তর দিন।',
  'characters': 'অক্ষর',
  'saving': 'সংরক্ষণ হচ্ছে...',
  'saveChanges': 'পরিবর্তন সংরক্ষণ করুন',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'ওপেন সোর্স লাইসেন্স',
  'openSourceLicensesSubtitle':
      'এই বিল্ডে অন্তর্ভুক্ত প্রতিটি নির্ভরতার লাইসেন্স পর্যালোচনা করুন।',
  'legalDocuments': 'আইনি নথি',
  'termsOfService': 'সেবার শর্তাবলী',
  'privacyPolicy': 'গোপনীয়তা নীতি',
  'versionText': 'সংস্করণ {version}',
  'updateAvailable': 'আপডেট উপলব্ধ: v{version} — ডাউনলোড করতে ট্যাপ করুন',
  'versionUnavailable': 'সংস্করণ তথ্য অনুপলব্ধ।',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nসর্বস্বত্ব সংরক্ষিত।',
  'licenses': 'লাইসেন্স',
  'unableToLoadLicenses': 'লাইসেন্স লোড করা যাচ্ছে না।',
  'tapToViewLicense': 'সম্পূর্ণ লাইসেন্স টেক্সট দেখতে ট্যাপ করুন',
  'devOptionsEnabled': 'ডেভেলপার অপশন সক্রিয়',
  'devOptionsAlreadyEnabled': 'ডেভেলপার অপশন আগেই সক্রিয়',
  'devOptionsTapSingular': 'ডেভেলপার অপশনের জন্য আরো {taps}টি ট্যাপ',
  'devOptionsTapsPlural': 'ডেভেলপার অপশনের জন্য আরো {taps}টি ট্যাপ',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'সাবস্ক্রিপশন',
  'openUsageDetailsInfo':
      'প্রতিটি অনুরোধ, মাসিক মোট এবং মডেল খরচ দেখতে ব্যবহারের বিবরণ খুলুন।',
  'openUsageDetails': 'ব্যবহারের বিবরণ খুলুন',
  'currentPlan': 'বর্তমান প্ল্যান',
  'plus': 'প্লাস',
  'pricePerMonth': '\u20ac২০/মাস',
  'monthlyCredits': 'মাসিক AI ক্রেডিট: \u20ac১৬.০০',
  'unusedCreditsExpire':
      'অব্যবহৃত ক্রেডিট প্রতি মাসের শেষে মেয়াদোত্তীর্ণ হয়।',
  'manageBilling': 'বিলিং পরিচালনা',
  'manageBillingSubtitle':
      'আপনার সাবস্ক্রিপশন বাতিল করতে বা পেমেন্ট পদ্ধতি আপডেট করতে বিলিং পোর্টাল ব্যবহার করুন।',
  'subscribeToGetCredits': 'AI ক্রেডিট পেতে সাবস্ক্রাইব করুন',
  'subscriptionDesktopOnly':
      'সাবস্ক্রিপশন পরিচালনা শুধুমাত্র ডেস্কটপে উপলব্ধ।',
  'active': 'সক্রিয়',
  'getCreditsMonthly': 'মাসিক \u20ac১৬ AI ক্রেডিট পান',
  'accessAllModels': 'সব AI মডেলে অ্যাক্সেস',
  'imageGeneration': 'ছবি তৈরি',
  'voiceMode': 'ভয়েস মোড',
  'textChatReasoning': 'রিজনিং সহ টেক্সট চ্যাট',
  'creditsExplanation':
      'আপনার \u20ac১৬ AI ক্রেডিট আপনার বেছে নেওয়া মডেল অনুযায়ী প্রতি টোকেনে ব্যবহৃত হয়। অব্যবহৃত ক্রেডিট প্রতি মাসের শেষে মেয়াদোত্তীর্ণ হয়।',
  'immediateAccessAck':
      'আমি Chuk Chat-এ তাৎক্ষণিক অ্যাক্সেস চাই এবং স্বীকার করছি যে সেবা শুরু হলে আমি আমার ',
  'rightOfWithdrawal': 'প্রত্যাহারের অধিকার',
  'onceServiceBegins': ' হারাবো। আমি ',
  'subscribeNow': 'এখনই সাবস্ক্রাইব করুন',
  'alreadySubscribed': 'আপনার ইতিমধ্যে একটি সক্রিয় সাবস্ক্রিপশন আছে।',
  'opening': 'খোলা হচ্ছে...',
  'agreeToTermsFirst':
      'অনুগ্রহ করে শর্তাবলীতে সম্মত হন এবং প্রত্যাহারের অধিকার হারানো স্বীকার করুন।',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Chuk Chat-এ স্বাগতম',
  'signInWithEmail': 'আপনার ইমেইল দিয়ে সাইন ইন করুন',
  'createAccountWithEmail': 'ইমেইল ও পাসওয়ার্ড দিয়ে একটি অ্যাকাউন্ট তৈরি করুন',
  'supabaseNotConfigured':
      'Supabase শংসাপত্র কনফিগার করা হয়নি। প্রোডাকশন বিল্ডের আগে আপডেট করুন।',
  'confirmEmailToContinue': 'চালিয়ে যেতে আপনার ইমেইল নিশ্চিত করুন',
  'confirmEmailBody':
      'আমরা আপনার ইমেইল ঠিকানায় একটি নিশ্চিতকরণ লিঙ্ক পাঠিয়েছি। সাইন ইন করার আগে অনুগ্রহ করে এটি খুলুন এবং লিঙ্কে ক্লিক করুন।',
  'howOthersSeeYou': 'অন্যরা আপনাকে যেভাবে দেখবে',
  'email': 'ইমেইল',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'পাসওয়ার্ড নিশ্চিত করুন',
  'forgotPassword': 'পাসওয়ার্ড ভুলে গেছেন?',
  'enterYourPassword': 'আপনার পাসওয়ার্ড দিন।',
  'pleaseConfirmPassword': 'অনুগ্রহ করে আপনার পাসওয়ার্ড নিশ্চিত করুন।',
  'signIn': 'সাইন ইন',
  'createAccount': 'অ্যাকাউন্ট তৈরি করুন',
  'noAccountSignUp': 'অ্যাকাউন্ট নেই? সাইন আপ করুন',
  'haveAccountSignIn': 'ইতিমধ্যে অ্যাকাউন্ট আছে? সাইন ইন করুন',
  'agreeToTerms': 'আমি সম্মত ',
  'andText': ' এবং ',
  'confirmAge16': 'আমি নিশ্চিত করছি যে আমার বয়স কমপক্ষে ১৬ বছর',
  'mustAgreeToTerms':
      'অ্যাকাউন্ট তৈরি করতে আপনাকে সেবার শর্তাবলী এবং গোপনীয়তা নীতিতে সম্মত হতে হবে।',
  'mustBe16': 'এই সেবা ব্যবহার করতে আপনার বয়স কমপক্ষে ১৬ বছর হতে হবে।',
  'unexpectedError': 'অপ্রত্যাশিত ত্রুটি: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'এনক্রিপ্টেড চ্যাট পুনরুদ্ধার করুন',
  'noLockedChats': 'কোনো লক করা চ্যাট নেই',
  'allChatsAccessible': 'আপনার সব চ্যাট অ্যাক্সেসযোগ্য।',
  'recoverChatsInfo':
      'কিছু চ্যাট পূর্ববর্তী পাসওয়ার্ড দিয়ে এনক্রিপ্ট করা। পুনরুদ্ধার করতে আপনার পুরানো পাসওয়ার্ড দিন, অথবা স্থায়ীভাবে মুছে ফেলুন।',
  'encryptedWithVersion': 'পাসওয়ার্ড সংস্করণ {version} দিয়ে এনক্রিপ্ট করা',
  'oldPassword': 'পুরানো পাসওয়ার্ড',
  'enterOldPassword': 'আগে যে পাসওয়ার্ড ব্যবহার করতেন তা দিন',
  'lockedChatCountSingular': '{count}টি লক করা চ্যাট',
  'lockedChatCountPlural': '{count}টি লক করা চ্যাট',
  'deleteLockedChatsTitle': 'লক করা চ্যাট মুছবেন?',
  'deleteLockedChatsBodySingular':
      'এটি আপনার পুরানো পাসওয়ার্ড দিয়ে এনক্রিপ্ট করা {count}টি চ্যাট স্থায়ীভাবে মুছে ফেলবে।\n\nমুছে ফেলার পর এই চ্যাট পুনরুদ্ধার করা যাবে না। আপনি সব মেসেজ, ছবি এবং সংযুক্তি হারাবেন।',
  'deleteLockedChatsBodyPlural':
      'এটি আপনার পুরানো পাসওয়ার্ড দিয়ে এনক্রিপ্ট করা {count}টি চ্যাট স্থায়ীভাবে মুছে ফেলবে।\n\nমুছে ফেলার পর এই চ্যাটগুলো পুনরুদ্ধার করা যাবে না। আপনি সব মেসেজ, ছবি এবং সংযুক্তি হারাবেন।',
  'deletePermanently': 'স্থায়ীভাবে মুছুন',
  'areYouSure': 'আপনি কি নিশ্চিত?',
  'confirmDeleteChats':
      'আপনি {count}টি চ্যাট মুছতে যাচ্ছেন। নিশ্চিত করতে DELETE টাইপ করুন।',
  'typeDelete': 'DELETE টাইপ করুন',
  'confirmDelete': 'মুছে ফেলা নিশ্চিত করুন',
  'pleaseEnterOldPassword': 'অনুগ্রহ করে আপনার পুরানো পাসওয়ার্ড দিন।',
  'derivingKey': 'এনক্রিপশন কী তৈরি হচ্ছে...',
  'recoveredChatsSingular': 'সফলভাবে {count}টি চ্যাট পুনরুদ্ধার করা হয়েছে।',
  'recoveredChatsPlural': 'সফলভাবে {count}টি চ্যাট পুনরুদ্ধার করা হয়েছে।',
  'recoveryFailed': 'পুনরুদ্ধার ব্যর্থ। অনুগ্রহ করে আবার চেষ্টা করুন।',
  'deletedChatsSingular': '{count}টি চ্যাট মুছে ফেলা হয়েছে।',
  'deletedChatsPlural': '{count}টি চ্যাট মুছে ফেলা হয়েছে।',
  'deletionFailed': 'মুছে ফেলা ব্যর্থ। অনুগ্রহ করে আবার চেষ্টা করুন।',
  'recover': 'পুনরুদ্ধার',
  'delete': 'মুছুন',
  'deleting': 'মুছে ফেলা হচ্ছে...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'নতুন পাসওয়ার্ড সেট করুন',
  'setNewPasswordInfo':
      'আপনার অ্যাকাউন্টের জন্য একটি শক্তিশালী পাসওয়ার্ড বেছে নিন। আপনার পূর্ববর্তী পাসওয়ার্ড মনে থাকলে পুরানো চ্যাট অ্যাক্সেসযোগ্য থাকবে।',
  'setNewPasswordButton': 'নতুন পাসওয়ার্ড সেট করুন',
  'noAuthenticatedUser': 'পাসওয়ার্ড আপডেটের পর কোনো প্রমাণীকৃত ব্যবহারকারী নেই।',
  'failedToPreserveEncryption':
      'পুরানো এনক্রিপশন ডেটা সংরক্ষণ করতে ব্যর্থ। অনুগ্রহ করে আপনার সংযোগ পরীক্ষা করে আবার চেষ্টা করুন।',
  'failedToSetNewPassword':
      'নতুন পাসওয়ার্ড সেট করতে ব্যর্থ। অনুগ্রহ করে আবার চেষ্টা করুন।',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'ডেভেলপার অপশন',
  'devOptionsToggleSubtitle':
      'ডায়াগনস্টিকস এবং ডিবাগ টুল আনলক করুন। সব ডেভেলপার-শুধু সেটিংস লুকাতে নিষ্ক্রিয় করুন।',
  'enableDiagnosticsLogging': 'ডায়াগনস্টিকস লগিং সক্রিয় করুন',
  'enableDiagnosticsSubtitle':
      'রিলিজ বিল্ডে কাজ করে। ল্যাগ এবং ট্রে সমস্যার জন্য অ্যাপ/রানটাইম মেটাডেটা লগ করে।',
  'diagnosticsEnabled': 'ডায়াগনস্টিকস লগিং সক্রিয়',
  'diagnosticsDisabled': 'ডায়াগনস্টিকস লগিং নিষ্ক্রিয়',
  'logFile': 'লগ ফাইল',
  'notInitializedYet': 'এখনও ইনিশিয়ালাইজ হয়নি',
  'refresh': 'রিফ্রেশ',
  'copyRecent': 'সাম্প্রতিক কপি করুন',
  'copyFocusedDebug': 'ফোকাসড ডিবাগ কপি করুন',
  'shareFile': 'ফাইল শেয়ার করুন',
  'clear': 'মুছে ফেলুন',
  'copiedRecentLogs': 'সাম্প্রতিক লগ ক্লিপবোর্ডে কপি করা হয়েছে',
  'noFocusedDebugData': 'এখনও কোনো ফোকাসড ডিবাগ ডেটা নেই',
  'copiedFocusedDebug': 'ফোকাসড মডেল-মেনু ডিবাগ রিপোর্ট কপি করা হয়েছে',
  'failedFocusedDebug':
      'ফোকাসড ডিবাগ রিপোর্ট তৈরি করতে ব্যর্থ: {error}',
  'noDiagnosticsLog': 'কোনো ডায়াগনস্টিকস লগ উপলব্ধ নেই',
  'diagnosticsLogNotFound': 'ডায়াগনস্টিকস লগ ফাইল পাওয়া যায়নি',
  'failedToShareLog': 'ডায়াগনস্টিকস লগ শেয়ার করতে ব্যর্থ: {error}',
  'diagnosticsLogCleared': 'ডায়াগনস্টিকস লগ মুছে ফেলা হয়েছে',
  'failedToClearLog': 'ডায়াগনস্টিকস লগ মুছতে ব্যর্থ: {error}',
  'recentLogLines': 'সাম্প্রতিক লগ লাইন',
  'devOptionsDisabledMsg': 'ডেভেলপার অপশন নিষ্ক্রিয়।',
  'noLogsYet':
      'এখনও কোনো লগ নেই। ডায়াগনস্টিকস লগিং সক্রিয় করুন এবং ডেটা সংগ্রহ করতে অ্যাপ ব্যবহার করুন।',

  // ── Connector detail page ──────────────────────────────────
  'back': 'পেছনে',
  'enabled': 'সক্রিয়',
  'disabled': 'নিষ্ক্রিয়',
  'modelPrompt': 'মডেল প্রম্পট',
  'modelPromptHint':
      'টুল আবিষ্কারের পর মডেলকে এই বিবরণ দেখানো হয়।',
  'customPromptActive': 'কাস্টম প্রম্পট সক্রিয়',
  'savePrompt': 'প্রম্পট সংরক্ষণ করুন',
  'parameters': 'প্যারামিটার',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'ব্যবহারের বিবরণ',
  'unableToLoadUsage': 'এই মুহূর্তে ব্যবহারের বিবরণ লোড করা যাচ্ছে না।',
  'usageAndBilling': 'ব্যবহার এবং বিলিং',
  'usageReadOnly':
      'এই স্ক্রিন শুধু-পঠনযোগ্য এবং আপনার ব্যবহারের লগ থেকে আনা হয়েছে।',
  'period': 'সময়কাল',
  'totals': 'মোট',
  'mediaRequestsNote':
      'ছবি এবং অডিও অনুরোধ মিডিয়া অনুরোধ হিসেবে গণ্য এবং টেক্সট-টোকেন মোট থেকে বাদ দেওয়া হয়।',
  'noRequestsFound': 'এই সময়কালে কোনো অনুরোধ পাওয়া যায়নি।',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'সেশন মেয়াদোত্তীর্ণ। অনুগ্রহ করে আবার সাইন ইন করুন।',
  'offlineMessage':
      'আপনি অফলাইনে আছেন বলে মনে হচ্ছে। অনুগ্রহ করে আপনার ইন্টারনেট সংযোগ পরীক্ষা করুন।',
  'cannotReachApi': 'API সার্ভারে পৌঁছানো যাচ্ছে না।',
  'maintenanceMessage':
      'আমরা বর্তমানে রক্ষণাবেক্ষণ করছি এবং শীঘ্রই ফিরে আসব।',
  'free': 'বিনামূল্যে',
  'perMillion': '/M',
  'perRequest': '/অনুরোধ',
  'best': 'সেরা',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'মেইল অ্যাপে খুলুন',
  'costLabel': 'খরচ: {cost}',
  'generatedLabel': 'তৈরি: {label}',
  'unableToCopyImage': 'ছবি কপি করা যায়নি',
  'unableToSaveImage': 'ছবি সংরক্ষণ করা যায়নি',
  'image': 'ছবি',
  'openLink': 'লিঙ্ক খুলুন',
  'openLinkConfirm':
      'আপনি কি সত্যিই অ্যাপ ছেড়ে {url} খুলতে চান?',
  'open': 'খুলুন',

  // ── Misc / shared ─────────────────────────────────────────
  'contentCopied': 'বিষয়বস্তু ক্লিপবোর্ডে কপি করা হয়েছে',
  'artifactCopied': 'আর্টিফ্যাক্ট ক্লিপবোর্ডে কপি করা হয়েছে',
  'fileSaved': 'ফাইল সংরক্ষিত',
  'failedToExportArtifact': 'আর্টিফ্যাক্ট এক্সপোর্ট করতে ব্যর্থ: {error}',
  'failedToSave': 'সংরক্ষণ করতে ব্যর্থ: {error}',
  'markdownSaved': 'মার্কডাউন সংরক্ষিত',
  'original': 'মূল',
  'markdown': 'মার্কডাউন',
  'viewMarkdownSummary': 'মার্কডাউন সারাংশ দেখুন',
  'addSummary': 'সারাংশ যোগ করুন',
  'deletedFile': 'মুছে ফেলা ফাইল',
  'deleteFile': 'ফাইল মুছুন',
  'deleteFileConfirm': '"{name}" মুছবেন?',
  'deleteFailed': 'মুছতে ব্যর্থ: {error}',
  'uploadedFile': 'আপলোড করা হয়েছে: {name}',
  'freeMessagePlaceholder': 'বিনামূল্যে: --',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'আমাকে যেকোনো কিছু জিজ্ঞাসা করুন!',
  'editYourMessage': 'আপনার মেসেজ সম্পাদনা করুন...',
  'addMessageOrDocs': 'একটি মেসেজ যোগ করুন বা ডকুমেন্ট পাঠান',
  'micAccessFailed': 'মাইক্রোফোন অ্যাক্সেস ব্যর্থ',
  'transcriptionFailed': 'ট্রান্সক্রিপশন ব্যর্থ',
  'replyTargetSelected': 'রিপ্লাই টার্গেট নির্বাচিত',
  'clearReply': 'রিপ্লাই মুছুন',
  'nothingToResend': 'পুনরায় পাঠানোর কিছু নেই',
  'freeMessagesUsed': 'বিনামূল্যে মেসেজ ব্যবহৃত',
  'ok': 'ঠিক আছে',
  'camera': 'ক্যামেরা',
  'photos': 'ছবি',
  'files': 'ফাইল',

  // ── Model selector ─────────────────────────────────────────
  'models': 'মডেল',
  'searchModels': 'মডেল খুঁজুন...',
  'modelError': 'ত্রুটি: {error}',

  // ── Message bubble extras ──────────────────────────────────
  'copyImage': 'ছবি কপি করুন',
  'downloadImage': 'ছবি ডাউনলোড করুন',
  'imageDetails': 'ছবির বিবরণ',
  'imageCopied': 'ছবি কপি করা হয়েছে',

  // ── Free message display ───────────────────────────────────
  'freeMessages': 'বিনামূল্যে মেসেজ',
  'freeUsed': 'ব্যবহৃত: {count}',
  'freeTotal': 'মোট: {count}',
  'subscribeToContinue': 'চ্যাট চালিয়ে যেতে সাবস্ক্রাইব করুন',
  'freeRemaining': 'বিনামূল্যে: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'মডেল নির্বাচন করুন',
  'noEnabledModels': 'কোনো সক্রিয় মডেল নেই',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'নতুন চ্যাট',
  'workspaces': 'ওয়ার্কস্পেস',
  'media': 'মিডিয়া',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'মিডিয়া ম্যানেজার',
  'imageUsedInChats': 'চ্যাটে ব্যবহৃত ছবি',
  'imageUsedInChatsBody':
      'এই ছবিটি নিম্নলিখিত চ্যাটে ব্যবহৃত হয়েছে:',
  'deleteImageShowDeleted':
      'আপনি যদি এই ছবি মুছে ফেলেন, সেই চ্যাটগুলোতে "ছবি মুছে ফেলা হয়েছে" দেখাবে।',
  'deleteImageConfirm':
      'আপনি কি নিশ্চিত যে এই ছবি মুছতে চান?',
  'deleteAnyway': 'তবুও মুছুন',
  'deleteImageTitle': 'ছবি মুছুন',
  'deleteImageBody':
      'আপনি কি নিশ্চিত যে এই ছবি মুছতে চান? এই পদক্ষেপ পূর্বাবস্থায় ফেরানো যাবে না।',
  'imageDeleted': 'ছবি মুছে ফেলা হয়েছে',
  'failedToDeleteImage': 'ছবি মুছতে ব্যর্থ: {error}',
  'someImagesUsedInChats': 'কিছু ছবি চ্যাটে ব্যবহৃত',
  'deletedImagesWarning':
      'মুছে ফেলা ছবি সেই চ্যাটগুলোতে "ছবি মুছে ফেলা হয়েছে" হিসেবে দেখাবে।',
  'deleteAllCount': 'নির্বাচিত {count}টি ছবি সব মুছবেন?',
  'deleteAll': 'সব মুছুন',
  'deleteSelectedImages': 'নির্বাচিত ছবি মুছুন',
  'deleteSelectedCount':
      'নির্বাচিত {count}টি ছবি মুছবেন? এই পদক্ষেপ পূর্বাবস্থায় ফেরানো যাবে না।',
  'deletedImagesResult': '{deleted}টি ছবি মুছে ফেলা হয়েছে, {failed}টি ব্যর্থ',
  'deletedImagesSuccess': '{deleted}টি ছবি মুছে ফেলা হয়েছে',
  'downloadSelected': 'নির্বাচিত ডাউনলোড করুন',
  'deleteSelected': 'নির্বাচিত মুছুন',
  'errorLoadingImages': 'ছবি লোড করতে ত্রুটি',
  'noImagesStored': 'কোনো ছবি সংরক্ষিত নেই',
  'imagesAppearHere': 'চ্যাটে পাঠানো ছবি এখানে দেখা যাবে',
  'download': 'ডাউনলোড',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': '{name} সরান',
  'edit': 'সম্পাদনা',
  'close': 'বন্ধ',

  // ── Subscription dialogs ───────────────────────────────────
  'maybeLater': 'পরে হয়তো',
};
