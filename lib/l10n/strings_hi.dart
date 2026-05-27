// lib/l10n/strings_hi.dart
// Hindi UI strings.

const Map<String, String> stringsHi = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'सेटिंग्स',
  'themeSettings': 'थीम सेटिंग्स',
  'themeSettingsSubtitle': 'ऐप थीम, रंग और दिखावट समायोजित करें',
  'customization': 'कस्टमाइज़ेशन',
  'customizationSubtitle': 'ऐप व्यवहार और प्राथमिकताएँ कॉन्फ़िगर करें',
  'toolCalling': 'टूल कॉलिंग',
  'toolCallingSubtitle': 'टूल उपयोग, खोज और टूल-कॉल डिस्प्ले नियंत्रित करें',
  'developerOptions': 'डेवलपर विकल्प',
  'developerOptionsSubtitle': 'डायग्नोस्टिक्स लॉग और डिबग टूल्स',
  'modelSelection': 'मॉडल चयन',
  'modelSelectionSubtitle': 'अपने AI मॉडल चुनें और कॉन्फ़िगर करें',
  'aiIdentityMemory': 'AI पहचान और मेमोरी',
  'aiIdentityMemorySubtitle': 'सोल, यूज़र प्रोफ़ाइल, मेमोरी और सिस्टम प्रॉम्प्ट',
  'pricingPlans': 'मूल्य योजनाएँ',
  'pricingPlansSubtitle': 'हमारी सदस्यता योजनाएँ और मूल्य देखें',
  'accountSettings': 'खाता सेटिंग्स',
  'accountSettingsSubtitle': 'अपनी प्रोफ़ाइल और खाता प्रबंधित करें',
  'exportChats': 'चैट निर्यात करें',
  'exportChatsSubtitle': 'अपनी बातचीत JSON के रूप में डाउनलोड करें',
  'about': 'जानकारी',
  'aboutSubtitle': 'संस्करण विवरण और ओपन सोर्स लाइसेंस',
  'logout': 'लॉगआउट',
  'noChatsToExport': 'निर्यात करने के लिए कोई चैट नहीं',
  'copiedToClipboard': 'क्लिपबोर्ड पर कॉपी किया गया',
  'savedToPath': '{path} पर सहेजा गया',
  'exportCancelled': 'निर्यात रद्द किया गया',
  'shareOpened': 'शेयर खोला गया',
  'exportFailed': 'निर्यात विफल: {error}',
  'saveChatExport': 'चैट निर्यात सहेजें',

  // ── Customization page ─────────────────────────────────────
  'language': 'भाषा',
  'languageSubtitle': 'अपनी पसंदीदा भाषा चुनें',
  'english': 'English',
  'german': 'Deutsch',
  'voiceTranscription': 'वॉइस ट्रांसक्रिप्शन',
  'autoSendVoice': 'वॉइस संदेश स्वतः भेजें',
  'autoSendVoiceSubtitle':
      'ट्रांसक्राइब किए गए वॉइस संदेश बिना पुष्टि के स्वतः भेजें',
  'autoSendVoiceInfo':
      'सक्षम होने पर, वॉइस ट्रांसक्रिप्शन तुरंत भेजे जाते हैं। अक्षम होने पर (डिफ़ॉल्ट), ट्रांसक्रिप्शन भेजने से पहले समीक्षा के लिए टेक्स्ट फ़ील्ड में दिखाई देते हैं।',
  'messageDisplay': 'संदेश प्रदर्शन',
  'showReasoningTokens': 'रीज़निंग टोकन दिखाएँ',
  'showReasoningTokensSubtitle':
      'AI उत्तरों में रीज़निंग प्रक्रिया टोकन प्रदर्शित करें',
  'showModelInfo': 'मॉडल जानकारी दिखाएँ',
  'showModelInfoSubtitle':
      'चैट संदेशों में मॉडल का नाम और जानकारी प्रदर्शित करें',
  'showTps': 'टोकन प्रति सेकंड दिखाएँ',
  'showTpsSubtitle': 'AI उत्तर जनरेशन गति (TPS) प्रदर्शित करें',
  'aiContext': 'AI संदर्भ',
  'recentImagesInContext': 'संदर्भ में हालिया छवियाँ',
  'recentImagesInContextSubtitle':
      'हालिया संदेशों की छवियाँ AI मॉडल को भेजें',
  'allImagesInContext': 'संदर्भ में सभी छवियाँ',
  'allImagesInContextSubtitle':
      'बातचीत की सभी छवियाँ AI को भेजें (अधिक टोकन उपयोग करता है)',
  'reasoningInContext': 'संदर्भ में रीज़निंग',
  'reasoningInContextSubtitle':
      'बातचीत इतिहास में AI सोच प्रक्रिया शामिल करें',
  'aiContextInfo':
      'हालिया छवियाँ पिछले 6 संदेशों की छवियाँ भेजती हैं। सभी छवियाँ बातचीत की हर छवि भेजती हैं। रीज़निंग AI की सोच प्रक्रिया को अनुवर्ती संदेशों के लिए संदर्भ के रूप में शामिल करती है।',
  'chatTitles': 'चैट शीर्षक',
  'autoGenerateTitles': 'चैट शीर्षक स्वतः उत्पन्न करें',
  'autoGenerateTitlesSubtitle':
      'नई चैट के लिए AI से शीर्षक उत्पन्न करें',
  'titleGenerationPrompt': 'शीर्षक जनरेशन प्रॉम्प्ट',
  'usingCustomPrompt': 'कस्टम प्रॉम्प्ट उपयोग में',
  'usingDefaultPrompt': 'डिफ़ॉल्ट प्रॉम्प्ट उपयोग में',
  'titleGenInfo':
      'सक्षम होने पर, आपके पहले संदेश के आधार पर नई चैट के लिए स्वतः एक छोटा शीर्षक उत्पन्न होगा। एक तेज़, हल्के AI मॉडल (qwen3-8b) का उपयोग करता है।',
  'systemPromptSaved': 'सिस्टम प्रॉम्प्ट सहेजा गया',
  'systemPromptResetToDefault': 'सिस्टम प्रॉम्प्ट डिफ़ॉल्ट पर रीसेट किया गया',
  'reset': 'रीसेट',
  'save': 'सहेजें',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'डार्क मोड',
  'darkModeSubtitle': 'डार्क और लाइट थीम के बीच टॉगल करें',
  'accentColor': 'एक्सेंट रंग',
  'accentColorSubtitle': 'अपना प्राथमिक एक्सेंट रंग चुनें',
  'iconFgColor': 'आइकन/अग्रभूमि रंग',
  'iconFgColorSubtitle': 'आइकन और मुख्य टेक्स्ट के लिए रंग चुनें',
  'backgroundColor': 'पृष्ठभूमि रंग',
  'backgroundColorSubtitle': 'ऐप के लिए मुख्य पृष्ठभूमि रंग चुनें',
  'filmGrainEffect': 'फ़िल्म ग्रेन इफ़ेक्ट',
  'filmGrainSubtitle': 'एक सूक्ष्म फ़िल्म-शॉट बनावट जोड़ें',
  'customHexColor': 'कस्टम हेक्स रंग (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'इंजन',
  'enableToolCalling': 'टूल कॉलिंग सक्षम करें',
  'enableToolCallingSubtitle':
      'सहायक को बिल्ट-इन टूल्स खोजने और चलाने की अनुमति दें',
  'behavior': 'व्यवहार',
  'requireDiscoveryFirst': 'पहले खोज आवश्यक',
  'requireDiscoverySubtitle':
      'एक टर्न में अन्य टूल्स की अनुमति से पहले find_tools अनिवार्य करें',
  'markdownToolCallFallback': 'Markdown टूल-कॉल फ़ॉलबैक',
  'markdownFallbackSubtitle':
      'जब मॉडल XML टैग नहीं देते तब ```tool_call कोड ब्लॉक स्वीकार करें',
  'display': 'प्रदर्शन',
  'showToolActivity': 'चैट में टूल गतिविधि दिखाएँ',
  'showToolActivitySubtitle':
      'सहायक संदेशों में चल रहे/पूर्ण टूल चिप्स प्रदर्शित करें',
  'toolCallingTip':
      'सुझाव: सर्वोत्तम संगतता के लिए Markdown फ़ॉलबैक सक्षम रखें। केवल तभी अक्षम करें जब आप सख्त XML-only टूल कॉल चाहते हैं।',
  'visualOutputNonTool': 'विज़ुअल आउटपुट (नॉन-टूल)',
  'enableMapBlocks': 'मैप ब्लॉक सक्षम करें (<map>)',
  'enableMapBlocksSubtitle':
      'मॉडल प्रॉम्प्ट में मैप रेंडरिंग निर्देश शामिल करने की अनुमति दें',
  'enableChartBlocks': 'चार्ट ब्लॉक सक्षम करें (<chart>)',
  'enableChartBlocksSubtitle':
      'मॉडल प्रॉम्प्ट में चार्ट रेंडरिंग निर्देश शामिल करने की अनुमति दें',
  'connectors': 'कनेक्टर्स',
  'loadingToolSettings': 'टूल सेटिंग्स लोड हो रही हैं...',
  'noToolsRegistered': 'अभी तक कोई टूल पंजीकृत नहीं है।',
  'catSearchWeb': 'खोज और वेब',
  'catUtilities': 'उपयोगिताएँ',
  'catMapsLocation': 'मानचित्र और स्थान',
  'catDevice': 'डिवाइस',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / टर्मिनल',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (कैलेंडर / Gmail)',
  'catEmailImapSmtp': 'ईमेल (IMAP/SMTP)',
  'catWhoop': 'WHOOP',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'सैंडबॉक्स / कोड',
  'catSearchWebDesc':
      'वेब खोजें, पेज प्राप्त करें, छवियाँ जनरेट करें और डेटा देखें',
  'catUtilitiesDesc':
      'कैलकुलेटर, घड़ी, नोट्स, QR कोड और अन्य उपयोगिताएँ',
  'catMapsLocationDesc':
      'स्थान खोजें, पते जियोकोड करें और मार्ग की गणना करें',
  'catDeviceDesc': 'GPS, कैलेंडर और रिमाइंडर जैसी डिवाइस सुविधाएँ एक्सेस करें',
  'catSpotifyDesc': 'प्लेबैक नियंत्रित करें और अपनी Spotify लाइब्रेरी ब्राउज़ करें',
  'catBashTerminalDesc': 'डेस्कटॉप पर सैंडबॉक्स्ड शेल कमांड चलाएँ',
  'catGitHubDesc':
      'GitHub से रिपॉज़, इश्यूज़, PR और कमिट्स एक्सेस करें',
  'catSlackDesc':
      'संदेश भेजें, चैनल खोजें और Slack डेटा प्राप्त करें',
  'catGoogleCalGmailDesc':
      'Google Calendar और Gmail से अपना शेड्यूल और ईमेल प्रबंधित करें',
  'catEmailImapSmtpDesc': 'IMAP और SMTP के माध्यम से ईमेल भेजें और प्राप्त करें',
  'catWhoopDesc':
      'WHOOP से रिकवरी, स्ट्रेन, नींद और वर्कआउट डेटा देखें',
  'catNextcloudDesc':
      'Nextcloud पर फ़ाइलें, कैलेंडर और संपर्क ब्राउज़ करें',
  'catSandboxDesc':
      'एक पृथक सैंडबॉक्स में Python या shell कोड चलाएँ और फ़ाइलें पढ़ें/लिखें',
  'connect': 'कनेक्ट करें',
  'disconnect': 'डिस्कनेक्ट करें',
  'disconnectCategory': '{label} डिस्कनेक्ट करें?',
  'removeCredentialsWarning': 'इससे आपके सहेजे गए क्रेडेंशियल हटा दिए जाएँगे।',
  'cancel': 'रद्द करें',
  'categoryConnected': '{label} कनेक्ट हो गया',
  'failedToConnect': '{label} कनेक्ट करने में विफल',
  'unableToConnect':
      '{label} कनेक्ट करने में असमर्थ। कृपया पुनः प्रयास करें।',
  'toolWebSearch': 'वेब खोज',
  'toolWebCrawl': 'वेब क्रॉल',
  'toolImageGen': 'छवि जनरेशन',
  'toolFetchImage': 'छवि प्राप्त करें',
  'toolViewChatImages': 'चैट छवियाँ देखें',
  'toolCryptoData': 'क्रिप्टो डेटा',
  'toolWeather': 'मौसम',
  'toolPlaceSearch': 'स्थान खोज',
  'toolRestaurantSearch': 'रेस्तराँ खोज',
  'toolGeocoding': 'जियोकोडिंग',
  'toolRouting': 'मार्ग निर्धारण',
  'toolCalculator': 'कैलकुलेटर',
  'toolClock': 'घड़ी',
  'toolRandomNumber': 'रैंडम नंबर',
  'toolCoinFlip': 'सिक्का उछालें',
  'toolDiceRoll': 'पासा फेंकें',
  'toolCountdown': 'काउंटडाउन',
  'toolPasswordGen': 'पासवर्ड जनरेटर',
  'toolUuidGen': 'UUID जनरेटर',
  'toolNotes': 'नोट्स',
  'toolQrGen': 'QR जनरेटर',
  'toolWhoopHealth': 'WHOOP स्वास्थ्य',
  'resetToolSettingsTitle': 'टूल सेटिंग्स रीसेट करें?',
  'resetToolSettingsBody':
      'इससे सभी टूल पुनः सक्षम होंगे और सभी कस्टम टूल प्रॉम्प्ट रीसेट होंगे।',
  'resetAllToolPrefs': 'सभी टूल प्राथमिकताएँ रीसेट करें',

  // ── Account settings page ──────────────────────────────────
  'profile': 'प्रोफ़ाइल',
  'profileSubtitle':
      'Chuk Chat में आपका नाम और ईमेल कैसा दिखे, यह अपडेट करें।',
  'displayName': 'प्रदर्शन नाम',
  'displayNameHint': 'दूसरे लोग आपको कैसे देखते हैं',
  'emailAddress': 'ईमेल पता',
  'emailAddressHint': 'जहाँ हम सूचनाएँ भेजते हैं',
  'security': 'सुरक्षा',
  'securitySubtitle': 'आश्वस्त हों कि सब कुछ सुरक्षित है।',
  'changePassword': 'पासवर्ड बदलें',
  'changePasswordSubtitle':
      'अपना Supabase पासवर्ड अपडेट करें और अपनी सहेजी गई चैट को पुनः एन्क्रिप्ट करें।',
  'currentPassword': 'वर्तमान पासवर्ड',
  'newPassword': 'नया पासवर्ड',
  'minCharsPassword': 'न्यूनतम 8 अक्षर।',
  'confirmNewPassword': 'नया पासवर्ड पुष्टि करें',
  'updatePassword': 'पासवर्ड अपडेट करें',
  'encryptedChatRecovery': 'एन्क्रिप्टेड चैट रिकवरी',
  'lockedChatsSingular': '{count} चैट पिछले पासवर्ड से एन्क्रिप्टेड है।',
  'lockedChatsPlural': '{count} चैट पिछले पासवर्ड से एन्क्रिप्टेड हैं।',
  'recoverChats': 'चैट पुनर्प्राप्त करें',
  'dangerZone': 'ख़तरनाक क्षेत्र',
  'dangerZoneSubtitle':
      'अपरिवर्तनीय कार्रवाइयाँ जो आपके पूरे खाते को प्रभावित करती हैं।',
  'deleteAccountWarning':
      'खाता हटाने से सभी सदस्यताएँ रद्द हो जाएँगी, आपका डेटा हट जाएगा और यह पूर्ववत नहीं किया जा सकता।',
  'deleteAccount': 'खाता हटाएँ',
  'unableToLoadProfile': 'अभी आपकी प्रोफ़ाइल लोड करने में असमर्थ।',
  'retry': 'पुनः प्रयास',
  'saved': 'सहेजा गया',
  'emailUpdated':
      'ईमेल अपडेट किया गया। Supabase द्वारा {email} पर भेजे गए लिंक से पुष्टि करें।',
  'failedToLoadProfile': 'प्रोफ़ाइल लोड करने में विफल: {error}',
  'failedToSaveProfile': 'प्रोफ़ाइल सहेजने में विफल: {error}',
  'emailCannotBeEmpty': 'ईमेल खाली नहीं हो सकता।',
  'passwordsDoNotMatch': 'नए पासवर्ड मेल नहीं खाते।',
  'failedToChangePassword': 'पासवर्ड बदलने में विफल: {error}',
  'deleteAccountQuestion': 'खाता हटाएँ?',
  'deleteAccountConfirmBody':
      'क्या आप वाकई अपना खाता हटाना चाहते हैं?\n\nइससे स्थायी रूप से मिट जाएगा:\n  \u2022 आपकी सभी चैट और संदेश\n  \u2022 सभी संग्रहीत यादें\n  \u2022 आपकी प्रोफ़ाइल और सेटिंग्स\n  \u2022 कोई भी सक्रिय सदस्यता\n\nयह कार्रवाई अपरिवर्तनीय है। आपका डेटा पुनर्प्राप्त नहीं किया जा सकता।',
  'yesDelete': 'हाँ, मैं हटाना चाहता/चाहती हूँ',
  'thisIsPermanent': 'यह स्थायी है',
  'finalDeleteWarning':
      'यह वापस जाने का आपका आख़िरी मौक़ा है।\n\nएक बार हटाने के बाद, आपके खाते, चैट, यादों या किसी भी संबंधित डेटा को पुनर्प्राप्त करने का बिल्कुल कोई तरीक़ा नहीं है।\n\nसब कुछ हमेशा के लिए चला जाएगा।\n\nक्या आप अभी भी आगे बढ़ना चाहते हैं?',
  'noKeepMyAccount': 'नहीं, मेरा खाता रखें',
  'deleteEverything': 'सब कुछ हटाएँ',
  'confirmYourPassword': 'अपना पासवर्ड पुष्टि करें',
  'confirmPasswordBody':
      'खाता हटाने की पुष्टि के लिए कृपया अपना पासवर्ड दर्ज करें।',
  'password': 'पासवर्ड',
  'passwordRequired': 'पासवर्ड आवश्यक है',
  'verificationFailed': 'सत्यापन विफल: {error}',
  'verifyAndDelete': 'सत्यापित करें और हटाएँ',
  'failedToDeleteAccount': 'खाता हटाने में विफल: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'पहचान प्रणाली',
  'identityActive': 'सोल, यूज़र और मेमोरी सक्रिय हैं',
  'identityDisabled': 'अक्षम — AI की कोई स्थायी पहचान नहीं',
  'soul': 'सोल',
  'soulHint':
      'AI के व्यक्तित्व, लहजे और सीमाएँ परिभाषित करें। यह सभी बातचीत में उसके संवाद को आकार देता है।',
  'soulExample':
      'उदाहरण:\n\u2022 सीधे और संक्षिप्त रहें\n\u2022 उपयोगकर्ता की भाषा और ऊर्जा से मेल खाएँ\n\u2022 राय रखें, हर बात में हिचकिचाएँ नहीं\n\u2022 गोपनीयता पहले: बाहरी कार्रवाई से पहले पूछें',
  'user': 'यूज़र',
  'userHint':
      'आपके बारे में तथ्य। AI इसे हर संदेश में पढ़ता है और जब यह आपके बारे में नई बातें सीखता है तो इसे अपडेट भी कर सकता है।',
  'userExample':
      'उदाहरण:\n\u2022 नाम: एलेक्स\n\u2022 समय क्षेत्र: Europe/Berlin\n\u2022 भाषा: जर्मन/अंग्रेज़ी मिश्रण\n\u2022 संक्षिप्त, तकनीकी उत्तर पसंद करते हैं',
  'memory': 'मेमोरी',
  'memoryHint':
      'दीर्घकालिक ज्ञान जो AI बातचीत के बीच याद रखता है। जब यह महत्वपूर्ण तथ्य या निर्णय सीखता है तो इसे अपडेट भी कर सकता है।',
  'memoryExample':
      'उदाहरण:\n\u2022 मोबाइल के लिए Dart/Flutter पसंद करते हैं\n\u2022 लाइसेंस: सभी प्रोजेक्ट के लिए BSL\n\u2022 वर्तमान प्रोजेक्ट: chuk_chat\n\u2022 डार्क मोड के प्रशंसक',
  'importFromAnotherAi': 'दूसरे AI से आयात करें',
  'systemPrompt': 'सिस्टम प्रॉम्प्ट',
  'systemPromptHint':
      'हर बातचीत के साथ भेजे जाने वाले कस्टम निर्देश। आपकी चैट एन्क्रिप्शन कुंजी से एन्क्रिप्ट किए गए।',
  'systemPromptExample':
      'उदाहरण: आप एक सहायक सहायक हैं। संक्षिप्त, सटीक उत्तर दें।',
  'characters': 'अक्षर',
  'saving': 'सहेजा जा रहा है...',
  'saveChanges': 'परिवर्तन सहेजें',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'ओपन सोर्स लाइसेंस',
  'openSourceLicensesSubtitle':
      'इस बिल्ड में शामिल हर डिपेंडेंसी के लाइसेंस की समीक्षा करें।',
  'legalDocuments': 'कानूनी दस्तावेज़',
  'termsOfService': 'सेवा की शर्तें',
  'privacyPolicy': 'गोपनीयता नीति',
  'versionText': 'संस्करण {version}',
  'updateAvailable': 'अपडेट उपलब्ध: v{version} — डाउनलोड करने के लिए टैप करें',
  'versionUnavailable': 'संस्करण जानकारी उपलब्ध नहीं।',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nसर्वाधिकार सुरक्षित।',
  'licenses': 'लाइसेंस',
  'unableToLoadLicenses': 'लाइसेंस लोड करने में असमर्थ।',
  'tapToViewLicense': 'पूर्ण लाइसेंस टेक्स्ट देखने के लिए टैप करें',
  'devOptionsEnabled': 'डेवलपर विकल्प सक्षम',
  'devOptionsAlreadyEnabled': 'डेवलपर विकल्प पहले से सक्षम',
  'devOptionsTapSingular': 'डेवलपर विकल्प के लिए {taps} और टैप',
  'devOptionsTapsPlural': 'डेवलपर विकल्प के लिए {taps} और टैप',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'सदस्यता',
  'openUsageDetailsInfo':
      'हर अनुरोध, मासिक कुल और मॉडल लागत देखने के लिए उपयोग विवरण खोलें।',
  'openUsageDetails': 'उपयोग विवरण खोलें',
  'currentPlan': 'वर्तमान योजना',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/माह',
  'monthlyCredits': 'मासिक AI क्रेडिट: \u20ac16.00',
  'unusedCreditsExpire':
      'अप्रयुक्त क्रेडिट हर महीने के अंत में समाप्त हो जाते हैं।',
  'manageBilling': 'बिलिंग प्रबंधित करें',
  'manageBillingSubtitle':
      'अपनी सदस्यता रद्द करने या भुगतान विधियाँ अपडेट करने के लिए बिलिंग पोर्टल का उपयोग करें।',
  'subscribeToGetCredits': 'AI क्रेडिट पाने के लिए सदस्यता लें',
  'subscriptionDesktopOnly':
      'सदस्यता प्रबंधन केवल डेस्कटॉप पर उपलब्ध है।',
  'active': 'सक्रिय',
  'getCreditsMonthly': 'मासिक \u20ac16 AI क्रेडिट प्राप्त करें',
  'accessAllModels': 'सभी AI मॉडल तक पहुँच',
  'imageGeneration': 'छवि जनरेशन',
  'voiceMode': 'वॉइस मोड',
  'textChatReasoning': 'रीज़निंग के साथ टेक्स्ट चैट',
  'creditsExplanation':
      'आपके \u20ac16 AI क्रेडिट आपके चुने हुए मॉडल के आधार पर प्रति टोकन उपयोग किए जाते हैं। अप्रयुक्त क्रेडिट हर महीने के अंत में समाप्त हो जाते हैं।',
  'immediateAccessAck':
      'मुझे Chuk Chat की तत्काल पहुँच चाहिए और मैं स्वीकार करता/करती हूँ कि सेवा शुरू होने पर मेरा ',
  'rightOfWithdrawal': 'वापसी का अधिकार',
  'onceServiceBegins': ' समाप्त हो जाएगा। मैं ',
  'subscribeNow': 'अभी सदस्यता लें',
  'alreadySubscribed': 'आपकी पहले से एक सक्रिय सदस्यता है।',
  'opening': 'खोला जा रहा है...',
  'agreeToTermsFirst':
      'कृपया शर्तों से सहमत हों और वापसी अधिकार समाप्ति को स्वीकार करें।',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Chuk Chat में आपका स्वागत है',
  'signInWithEmail': 'अपने ईमेल से साइन इन करें',
  'createAccountWithEmail': 'ईमेल और पासवर्ड से खाता बनाएँ',
  'supabaseNotConfigured':
      'Supabase क्रेडेंशियल कॉन्फ़िगर नहीं हैं। प्रोडक्शन बिल्ड चलाने से पहले उन्हें अपडेट करें।',
  'confirmEmailToContinue': 'जारी रखने के लिए अपना ईमेल पुष्टि करें',
  'confirmEmailBody':
      'हमने आपके ईमेल पते पर एक पुष्टिकरण लिंक भेजा है। कृपया साइन इन करने से पहले उसे खोलें और लिंक पर क्लिक करें।',
  'howOthersSeeYou': 'दूसरे लोग आपको कैसे देखेंगे',
  'email': 'ईमेल',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'पासवर्ड पुष्टि करें',
  'forgotPassword': 'पासवर्ड भूल गए?',
  'enterYourPassword': 'अपना पासवर्ड दर्ज करें।',
  'pleaseConfirmPassword': 'कृपया अपना पासवर्ड पुष्टि करें।',
  'signIn': 'साइन इन',
  'createAccount': 'खाता बनाएँ',
  'noAccountSignUp': 'खाता नहीं है? साइन अप करें',
  'haveAccountSignIn': 'पहले से खाता है? साइन इन करें',
  'agreeToTerms': 'मैं सहमत हूँ ',
  'andText': ' और ',
  'confirmAge16': 'मैं पुष्टि करता/करती हूँ कि मेरी आयु कम से कम 16 वर्ष है',
  'mustAgreeToTerms':
      'खाता बनाने के लिए आपको सेवा की शर्तों और गोपनीयता नीति से सहमत होना होगा।',
  'mustBe16': 'इस सेवा का उपयोग करने के लिए आपकी आयु कम से कम 16 वर्ष होनी चाहिए।',
  'unexpectedError': 'अप्रत्याशित त्रुटि: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'एन्क्रिप्टेड चैट पुनर्प्राप्त करें',
  'noLockedChats': 'कोई लॉक चैट नहीं',
  'allChatsAccessible': 'आपकी सभी चैट सुलभ हैं।',
  'recoverChatsInfo':
      'कुछ चैट पिछले पासवर्ड से एन्क्रिप्टेड हैं। उन्हें पुनर्प्राप्त करने के लिए अपना पुराना पासवर्ड दर्ज करें, या उन्हें स्थायी रूप से हटाएँ।',
  'encryptedWithVersion': 'पासवर्ड संस्करण {version} से एन्क्रिप्टेड',
  'oldPassword': 'पुराना पासवर्ड',
  'enterOldPassword': 'वह पासवर्ड दर्ज करें जो आपने पहले उपयोग किया था',
  'lockedChatCountSingular': '{count} लॉक चैट',
  'lockedChatCountPlural': '{count} लॉक चैट',
  'deleteLockedChatsTitle': 'लॉक चैट हटाएँ?',
  'deleteLockedChatsBodySingular':
      'इससे {count} चैट स्थायी रूप से हटा दी जाएगी जो आपके पुराने पासवर्ड से एन्क्रिप्टेड है।\n\nहटाने के बाद यह चैट पुनर्प्राप्त नहीं की जा सकती। आप सभी संदेश, छवियाँ और अटैचमेंट खो देंगे।',
  'deleteLockedChatsBodyPlural':
      'इससे {count} चैट स्थायी रूप से हटा दी जाएँगी जो आपके पुराने पासवर्ड से एन्क्रिप्टेड हैं।\n\nहटाने के बाद ये चैट पुनर्प्राप्त नहीं की जा सकतीं। आप सभी संदेश, छवियाँ और अटैचमेंट खो देंगे।',
  'deletePermanently': 'स्थायी रूप से हटाएँ',
  'areYouSure': 'क्या आप निश्चित हैं?',
  'confirmDeleteChats':
      'आप {count} चैट हटाने वाले हैं। पुष्टि के लिए DELETE टाइप करें।',
  'typeDelete': 'DELETE टाइप करें',
  'confirmDelete': 'हटाने की पुष्टि करें',
  'pleaseEnterOldPassword': 'कृपया अपना पुराना पासवर्ड दर्ज करें।',
  'derivingKey': 'एन्क्रिप्शन कुंजी प्राप्त हो रही है...',
  'recoveredChatsSingular': '{count} चैट सफलतापूर्वक पुनर्प्राप्त की गई।',
  'recoveredChatsPlural': '{count} चैट सफलतापूर्वक पुनर्प्राप्त की गईं।',
  'recoveryFailed': 'पुनर्प्राप्ति विफल। कृपया पुनः प्रयास करें।',
  'deletedChatsSingular': '{count} चैट हटाई गई।',
  'deletedChatsPlural': '{count} चैट हटाई गईं।',
  'deletionFailed': 'हटाना विफल। कृपया पुनः प्रयास करें।',
  'recover': 'पुनर्प्राप्त करें',
  'delete': 'हटाएँ',
  'deleting': 'हटाया जा रहा है...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'नया पासवर्ड सेट करें',
  'setNewPasswordInfo':
      'अपने खाते के लिए एक मज़बूत पासवर्ड चुनें। यदि आपको अपना पिछला पासवर्ड याद है तो आपकी पुरानी चैट सुलभ रहेंगी।',
  'setNewPasswordButton': 'नया पासवर्ड सेट करें',
  'noAuthenticatedUser': 'पासवर्ड अपडेट के बाद कोई प्रमाणित उपयोगकर्ता नहीं।',
  'failedToPreserveEncryption':
      'पुराने एन्क्रिप्शन डेटा को संरक्षित करने में विफल। कृपया अपना कनेक्शन जाँचें और पुनः प्रयास करें।',
  'failedToSetNewPassword':
      'नया पासवर्ड सेट करने में विफल। कृपया पुनः प्रयास करें।',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'डेवलपर विकल्प',
  'devOptionsToggleSubtitle':
      'डायग्नोस्टिक्स और डिबग टूल्स अनलॉक करें। सभी डेवलपर-विशेष सेटिंग्स छिपाने के लिए अक्षम करें।',
  'enableDiagnosticsLogging': 'डायग्नोस्टिक्स लॉगिंग सक्षम करें',
  'enableDiagnosticsSubtitle':
      'रिलीज़ बिल्ड में काम करता है। लैग और ट्रे समस्याओं के निवारण के लिए ऐप/रनटाइम मेटाडेटा लॉग करता है।',
  'diagnosticsEnabled': 'डायग्नोस्टिक्स लॉगिंग सक्षम',
  'diagnosticsDisabled': 'डायग्नोस्टिक्स लॉगिंग अक्षम',
  'logFile': 'लॉग फ़ाइल',
  'notInitializedYet': 'अभी तक आरंभ नहीं हुआ',
  'refresh': 'रीफ़्रेश',
  'copyRecent': 'हालिया कॉपी करें',
  'copyFocusedDebug': 'फ़ोकस्ड डिबग कॉपी करें',
  'shareFile': 'फ़ाइल शेयर करें',
  'clear': 'साफ़ करें',
  'copiedRecentLogs': 'हालिया लॉग क्लिपबोर्ड पर कॉपी किए गए',
  'noFocusedDebugData': 'अभी तक कोई फ़ोकस्ड डिबग डेटा उपलब्ध नहीं',
  'copiedFocusedDebug': 'फ़ोकस्ड मॉडल-मेनू डिबग रिपोर्ट कॉपी की गई',
  'failedFocusedDebug':
      'फ़ोकस्ड डिबग रिपोर्ट बनाने में विफल: {error}',
  'noDiagnosticsLog': 'कोई डायग्नोस्टिक्स लॉग उपलब्ध नहीं',
  'diagnosticsLogNotFound': 'डायग्नोस्टिक्स लॉग फ़ाइल नहीं मिली',
  'failedToShareLog': 'डायग्नोस्टिक्स लॉग शेयर करने में विफल: {error}',
  'diagnosticsLogCleared': 'डायग्नोस्टिक्स लॉग साफ़ किया गया',
  'failedToClearLog': 'डायग्नोस्टिक्स लॉग साफ़ करने में विफल: {error}',
  'recentLogLines': 'हालिया लॉग लाइनें',
  'devOptionsDisabledMsg': 'डेवलपर विकल्प अक्षम।',
  'noLogsYet':
      'अभी तक कोई लॉग नहीं। डायग्नोस्टिक्स लॉगिंग सक्षम करें और डेटा एकत्र करने के लिए ऐप का उपयोग करें।',

  // ── Connector detail page ──────────────────────────────────
  'back': 'वापस',
  'enabled': 'सक्षम',
  'disabled': 'अक्षम',
  'modelPrompt': 'मॉडल प्रॉम्प्ट',
  'modelPromptHint':
      'यह विवरण टूल खोज के बाद मॉडल को दिखाया जाता है।',
  'customPromptActive': 'कस्टम प्रॉम्प्ट सक्रिय',
  'savePrompt': 'प्रॉम्प्ट सहेजें',
  'parameters': 'पैरामीटर',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'उपयोग विवरण',
  'unableToLoadUsage': 'अभी उपयोग विवरण लोड करने में असमर्थ।',
  'usageAndBilling': 'उपयोग और बिलिंग',
  'usageReadOnly':
      'यह स्क्रीन केवल पढ़ने के लिए है और आपके उपयोग लॉग से ली गई है।',
  'period': 'अवधि',
  'totals': 'कुल',
  'mediaRequestsNote':
      'छवि और ऑडियो अनुरोधों को मीडिया अनुरोध माना जाता है और टेक्स्ट-टोकन कुल से बाहर रखा जाता है।',
  'noRequestsFound': 'इस अवधि के लिए कोई अनुरोध नहीं मिला।',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'सत्र समाप्त हो गया। कृपया पुनः साइन इन करें।',
  'offlineMessage':
      'ऐसा लगता है कि आप ऑफ़लाइन हैं। कृपया अपना इंटरनेट कनेक्शन जाँचें।',
  'cannotReachApi': 'API सर्वर तक नहीं पहुँचा जा सकता।',
  'maintenanceMessage':
      'हम वर्तमान में रखरखाव कर रहे हैं और जल्द ही वापस आएँगे।',
  'free': 'मुफ़्त',
  'perMillion': '/M',
  'perRequest': '/अनुरोध',
  'best': 'सर्वश्रेष्ठ',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'मेल ऐप में खोलें',
  'costLabel': 'लागत: {cost}',
  'generatedLabel': 'जनरेट किया गया: {label}',
  'unableToCopyImage': 'छवि कॉपी करने में असमर्थ',
  'unableToSaveImage': 'छवि सहेजने में असमर्थ',
  'image': 'छवि',
  'openLink': 'लिंक खोलें',
  'openLinkConfirm':
      'क्या आप वाकई ऐप छोड़कर {url} खोलना चाहते हैं?',
  'open': 'खोलें',

  // ── Misc / shared ─────────────────────────────────────────
  'contentCopied': 'सामग्री क्लिपबोर्ड पर कॉपी की गई',
  'artifactCopied': 'आर्टिफ़ैक्ट क्लिपबोर्ड पर कॉपी किया गया',
  'fileSaved': 'फ़ाइल सहेजी गई',
  'failedToExportArtifact': 'आर्टिफ़ैक्ट निर्यात करने में विफल: {error}',
  'failedToSave': 'सहेजने में विफल: {error}',
  'markdownSaved': 'Markdown सहेजा गया',
  'original': 'मूल',
  'markdown': 'Markdown',
  'viewMarkdownSummary': 'Markdown सारांश देखें',
  'addSummary': 'सारांश जोड़ें',
  'deletedFile': 'हटाई गई फ़ाइल',
  'deleteFile': 'फ़ाइल हटाएँ',
  'deleteFileConfirm': '"{name}" हटाएँ?',
  'deleteFailed': 'हटाना विफल: {error}',
  'uploadedFile': 'अपलोड किया गया: {name}',
  'freeMessagePlaceholder': 'मुफ़्त: --',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'मुझसे कुछ भी पूछें !',
  'editYourMessage': 'अपना संदेश संपादित करें...',
  'addMessageOrDocs': 'संदेश जोड़ें या दस्तावेज़ भेजें',
  'micAccessFailed': 'माइक एक्सेस विफल',
  'transcriptionFailed': 'ट्रांसक्रिप्शन विफल',
  'replyTargetSelected': 'उत्तर लक्ष्य चुना गया',
  'clearReply': 'उत्तर साफ़ करें',
  'nothingToResend': 'पुनः भेजने के लिए कुछ नहीं',
  'freeMessagesUsed': 'मुफ़्त संदेश समाप्त',
  'ok': 'ठीक है',
  'camera': 'कैमरा',
  'photos': 'फ़ोटो',
  'files': 'फ़ाइलें',

  // ── Model selector ─────────────────────────────────────────
  'models': 'मॉडल',
  'searchModels': 'मॉडल खोजें...',
  'modelError': 'त्रुटि: {error}',

  // ── Message bubble extras ──────────────────────────────────
  'copyImage': 'छवि कॉपी करें',
  'downloadImage': 'छवि डाउनलोड करें',
  'imageDetails': 'छवि विवरण',
  'imageCopied': 'छवि कॉपी की गई',

  // ── Free message display ───────────────────────────────────
  'freeMessages': 'मुफ़्त संदेश',
  'freeUsed': 'उपयोग किए: {count}',
  'freeTotal': 'कुल: {count}',
  'subscribeToContinue': 'चैट जारी रखने के लिए सदस्यता लें',
  'freeRemaining': 'मुफ़्त: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'मॉडल चुनें',
  'noEnabledModels': 'कोई सक्षम मॉडल नहीं',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'नई चैट',
  'workspaces': 'कार्यस्थान',
  'media': 'मीडिया',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'मीडिया प्रबंधक',
  'imageUsedInChats': 'चैट में उपयोग की गई छवि',
  'imageUsedInChatsBody':
      'यह छवि निम्नलिखित चैट में उपयोग की गई है:',
  'deleteImageShowDeleted':
      'यदि आप इस छवि को हटाते हैं, तो उन चैट में "छवि हटाई गई" दिखेगा।',
  'deleteImageConfirm':
      'क्या आप वाकई इस छवि को हटाना चाहते हैं?',
  'deleteAnyway': 'फिर भी हटाएँ',
  'deleteImageTitle': 'छवि हटाएँ',
  'deleteImageBody':
      'क्या आप वाकई इस छवि को हटाना चाहते हैं? यह कार्रवाई पूर्ववत नहीं की जा सकती।',
  'imageDeleted': 'छवि हटाई गई',
  'failedToDeleteImage': 'छवि हटाने में विफल: {error}',
  'someImagesUsedInChats': 'कुछ छवियाँ चैट में उपयोग की गई हैं',
  'deletedImagesWarning':
      'हटाई गई छवियाँ उन चैट में "छवि हटाई गई" के रूप में दिखेंगी।',
  'deleteAllCount': 'सभी {count} चुनी गई छवियाँ हटाएँ?',
  'deleteAll': 'सभी हटाएँ',
  'deleteSelectedImages': 'चुनी गई छवियाँ हटाएँ',
  'deleteSelectedCount':
      '{count} चुनी गई छवियाँ हटाएँ? यह कार्रवाई पूर्ववत नहीं की जा सकती।',
  'deletedImagesResult': '{deleted} छवियाँ हटाई गईं, {failed} विफल',
  'deletedImagesSuccess': '{deleted} छवियाँ हटाई गईं',
  'downloadSelected': 'चुनी गई डाउनलोड करें',
  'deleteSelected': 'चुनी गई हटाएँ',
  'errorLoadingImages': 'छवियाँ लोड करने में त्रुटि',
  'noImagesStored': 'कोई छवि संग्रहीत नहीं',
  'imagesAppearHere': 'चैट में भेजी गई छवियाँ यहाँ दिखाई देंगी',
  'download': 'डाउनलोड',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': '{name} हटाएँ',
  'edit': 'संपादित करें',
  'close': 'बंद करें',

  // ── Subscription dialogs ───────────────────────────────────
  'maybeLater': 'शायद बाद में',
};
