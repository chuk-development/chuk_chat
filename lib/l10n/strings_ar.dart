// lib/l10n/strings_ar.dart
// Arabic UI strings.

const Map<String, String> stringsAr = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'الإعدادات',
  'themeSettings': 'إعدادات المظهر',
  'themeSettingsSubtitle': 'تعديل مظهر التطبيق والألوان والشكل العام',
  'customization': 'التخصيص',
  'customizationSubtitle': 'ضبط سلوك التطبيق والتفضيلات',
  'toolCalling': 'استدعاء الأدوات',
  'toolCallingSubtitle': 'التحكم في استخدام الأدوات واكتشافها وعرض استدعاءاتها',
  'developerOptions': 'خيارات المطور',
  'developerOptionsSubtitle': 'سجلات التشخيص وأدوات التصحيح',
  'modelSelection': 'اختيار النموذج',
  'modelSelectionSubtitle': 'اختيار وضبط نماذج الذكاء الاصطناعي',
  'aiIdentityMemory': 'هوية الذكاء الاصطناعي والذاكرة',
  'aiIdentityMemorySubtitle': 'الشخصية، ملف المستخدم، الذاكرة، وتعليمات النظام',
  'pricingPlans': 'خطط الأسعار',
  'pricingPlansSubtitle': 'عرض خطط الاشتراك والأسعار',
  'accountSettings': 'إعدادات الحساب',
  'exportChats': 'تصدير المحادثات',
  'exportChatsSubtitle': 'تحميل محادثاتك بصيغة JSON',
  'about': 'حول التطبيق',
  'aboutSubtitle': 'تفاصيل الإصدار وتراخيص المصادر المفتوحة',
  'logout': 'تسجيل الخروج',
  'noChatsToExport': 'لا توجد محادثات للتصدير',
  'copiedToClipboard': 'تم النسخ إلى الحافظة',
  'savedToPath': 'تم الحفظ في {path}',
  'exportCancelled': 'تم إلغاء التصدير',
  'shareOpened': 'تم فتح المشاركة',
  'exportFailed': 'فشل التصدير: {error}',
  'saveChatExport': 'حفظ تصدير المحادثات',

  // ── Customization page ─────────────────────────────────────
  'language': 'اللغة',
  'languageSubtitle': 'اختر لغتك المفضلة',
  'voiceTranscription': 'تحويل الصوت إلى نص',
  'autoSendVoice': 'إرسال الرسائل الصوتية تلقائياً',
  'autoSendVoiceSubtitle':
      'إرسال الرسائل الصوتية المحوّلة تلقائياً دون تأكيد',
  'autoSendVoiceInfo':
      'عند التفعيل، تُرسل النصوص المحوّلة من الصوت فوراً. عند التعطيل (الافتراضي)، تظهر النصوص المحوّلة في حقل النص للمراجعة قبل الإرسال.',
  'messageDisplay': 'عرض الرسائل',
  'showReasoningTokens': 'عرض رموز التفكير',
  'showReasoningTokensSubtitle':
      'عرض عملية التفكير في ردود الذكاء الاصطناعي',
  'showModelInfo': 'عرض معلومات النموذج',
  'showModelInfoSubtitle':
      'عرض اسم النموذج ومعلوماته في رسائل المحادثة',
  'showTps': 'عرض الرموز في الثانية',
  'showTpsSubtitle': 'عرض سرعة توليد ردود الذكاء الاصطناعي (TPS)',
  'aiContext': 'سياق الذكاء الاصطناعي',
  'recentImagesInContext': 'الصور الأخيرة في السياق',
  'recentImagesInContextSubtitle':
      'إرسال الصور من الرسائل الأخيرة إلى نموذج الذكاء الاصطناعي',
  'allImagesInContext': 'جميع الصور في السياق',
  'allImagesInContextSubtitle':
      'إرسال جميع صور المحادثة إلى الذكاء الاصطناعي (يستهلك رموزاً أكثر)',
  'reasoningInContext': 'التفكير في السياق',
  'reasoningInContextSubtitle':
      'تضمين عملية تفكير الذكاء الاصطناعي في سجل المحادثة',
  'aiContextInfo':
      'الصور الأخيرة ترسل صور آخر 6 رسائل. جميع الصور ترسل كل صورة في المحادثة. التفكير يتضمن عملية تفكير الذكاء الاصطناعي كسياق للرسائل اللاحقة.',
  'chatTitles': 'عناوين المحادثات',
  'autoGenerateTitles': 'توليد عناوين المحادثات تلقائياً',
  'autoGenerateTitlesSubtitle':
      'استخدام الذكاء الاصطناعي لتوليد عناوين للمحادثات الجديدة',
  'titleGenerationPrompt': 'تعليمات توليد العنوان',
  'usingCustomPrompt': 'يُستخدم تعليمات مخصصة',
  'usingDefaultPrompt': 'يُستخدم التعليمات الافتراضية',
  'titleGenInfo':
      'عند التفعيل، يُولَّد عنوان قصير تلقائياً للمحادثات الجديدة بناءً على رسالتك الأولى. يستخدم نموذج ذكاء اصطناعي سريع وخفيف (qwen3-8b).',
  'systemPromptSaved': 'تم حفظ تعليمات النظام',
  'systemPromptResetToDefault': 'تمت إعادة تعليمات النظام إلى الافتراضية',
  'reset': 'إعادة تعيين',
  'save': 'حفظ',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'الوضع الداكن',
  'darkModeSubtitle': 'التبديل بين المظهر الداكن والفاتح',
  'accentColor': 'لون التمييز',
  'accentColorSubtitle': 'اختر لون التمييز الرئيسي',
  'iconFgColor': 'لون الأيقونات/النص الأمامي',
  'iconFgColorSubtitle': 'اختر لون الأيقونات والنصوص الرئيسية',
  'backgroundColor': 'لون الخلفية',
  'backgroundColorSubtitle': 'اختر لون الخلفية الرئيسي للتطبيق',
  'filmGrainEffect': 'تأثير حبيبات الفيلم',
  'filmGrainSubtitle': 'إضافة ملمس فيلم خفيف',
  'customHexColor': 'لون سداسي مخصص (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'المحرك',
  'enableToolCalling': 'تفعيل استدعاء الأدوات',
  'enableToolCallingSubtitle':
      'السماح للمساعد باكتشاف وتنفيذ الأدوات المدمجة',
  'behavior': 'السلوك',
  'requireDiscoveryFirst': 'طلب الاكتشاف أولاً',
  'requireDiscoverySubtitle':
      'فرض استخدام find_tools قبل السماح بأدوات أخرى في الدور',
  'markdownToolCallFallback': 'بديل استدعاء الأدوات بـ Markdown',
  'markdownFallbackSubtitle':
      'قبول كتل tool_call البرمجية عندما لا تصدر النماذج وسوم XML',
  'display': 'العرض',
  'showToolActivity': 'عرض نشاط الأدوات في المحادثة',
  'showToolActivitySubtitle':
      'عرض شرائح الأدوات قيد التشغيل/المكتملة في رسائل المساعد',
  'toolCallingTip':
      'نصيحة: اترك بديل Markdown مفعّلاً لأفضل توافق. عطّله فقط إذا كنت تريد استدعاءات أدوات XML حصرية.',
  'enableMapBlocks': 'تفعيل كتل الخرائط (<map>)',
  'enableMapBlocksSubtitle':
      'السماح لتعليمات النموذج بتضمين إرشادات عرض الخرائط',
  'enableChartBlocks': 'تفعيل كتل الرسوم البيانية (<chart>)',
  'enableChartBlocksSubtitle':
      'السماح لتعليمات النموذج بتضمين إرشادات عرض الرسوم البيانية',
  'loadingToolSettings': 'جارٍ تحميل إعدادات الأدوات...',
  'noToolsRegistered': 'لم تُسجَّل أي أدوات بعد.',
  'catSearchWeb': 'البحث والويب',
  'catUtilities': 'الأدوات المساعدة',
  'catMapsLocation': 'الخرائط والموقع',
  'catDevice': 'الجهاز',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / الطرفية',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (التقويم / Gmail)',
  'catSandbox': 'الصندوق الرملي / الكود',
  'catSearchWebDesc':
      'البحث في الويب، جلب الصفحات، توليد الصور، والبحث عن البيانات',
  'catUtilitiesDesc':
      'الآلة الحاسبة، الساعة، الملاحظات، رموز QR، وأدوات أخرى',
  'catMapsLocationDesc':
      'البحث عن الأماكن، ترميز العناوين جغرافياً، وحساب المسارات',
  'catDeviceDesc': 'الوصول إلى ميزات الجهاز مثل GPS والتقويم والتذكيرات',
  'catSpotifyDesc': 'التحكم في التشغيل وتصفح مكتبة Spotify',
  'catBashTerminalDesc': 'تشغيل أوامر الطرفية المعزولة على سطح المكتب',
  'catGitHubDesc':
      'الوصول إلى المستودعات والمشكلات وطلبات الدمج والإيداعات من GitHub',
  'catSlackDesc':
      'إرسال الرسائل والبحث في القنوات وجلب بيانات Slack',
  'catGoogleCalGmailDesc':
      'إدارة جدولك وبريدك الإلكتروني عبر تقويم Google و Gmail',
  'catSandboxDesc':
      'تشغيل كود Python أو الصدفة في صندوق رملي معزول وقراءة/كتابة الملفات',
  'connect': 'اتصال',
  'disconnect': 'قطع الاتصال',
  'disconnectCategory': 'قطع اتصال {label}؟',
  'removeCredentialsWarning': 'سيؤدي هذا إلى إزالة بيانات الاعتماد المحفوظة.',
  'cancel': 'إلغاء',
  'toolWebSearch': 'بحث الويب',
  'toolWebCrawl': 'زحف الويب',
  'toolImageGen': 'توليد الصور',
  'toolFetchImage': 'جلب صورة',
  'toolViewChatImages': 'عرض صور المحادثة',
  'toolCryptoData': 'بيانات العملات الرقمية',
  'toolWeather': 'الطقس',
  'toolPlaceSearch': 'البحث عن الأماكن',
  'toolRestaurantSearch': 'البحث عن المطاعم',
  'toolGeocoding': 'الترميز الجغرافي',
  'toolRouting': 'التوجيه',
  'toolCalculator': 'الآلة الحاسبة',
  'toolClock': 'الساعة',
  'toolRandomNumber': 'رقم عشوائي',
  'toolCoinFlip': 'رمي العملة',
  'toolDiceRoll': 'رمي النرد',
  'toolCountdown': 'العد التنازلي',
  'toolPasswordGen': 'مولّد كلمات المرور',
  'toolUuidGen': 'مولّد UUID',
  'toolNotes': 'الملاحظات',
  'toolQrGen': 'مولّد QR',
  'resetToolSettingsTitle': 'إعادة تعيين إعدادات الأدوات؟',
  'resetToolSettingsBody':
      'سيؤدي هذا إلى إعادة تفعيل جميع الأدوات وإعادة تعيين جميع تعليمات الأدوات المخصصة.',
  'resetAllToolPrefs': 'إعادة تعيين جميع تفضيلات الأدوات',

  // ── Account settings page ──────────────────────────────────
  'profile': 'الملف الشخصي',
  'displayName': 'الاسم المعروض',
  'displayNameHint': 'كيف يراك الآخرون',
  'emailAddress': 'عنوان البريد الإلكتروني',
  'emailAddressHint': 'أين نرسل الإشعارات',
  'security': 'الأمان',
  'changePassword': 'تغيير كلمة المرور',
  'currentPassword': 'كلمة المرور الحالية',
  'newPassword': 'كلمة المرور الجديدة',
  'minCharsPassword': '8 أحرف كحد أدنى.',
  'confirmNewPassword': 'تأكيد كلمة المرور الجديدة',
  'updatePassword': 'تحديث كلمة المرور',
  'encryptedChatRecovery': 'استعادة المحادثات المشفرة',
  'lockedChatsSingular': '{count} محادثة مشفرة بكلمة مرور سابقة.',
  'lockedChatsPlural': '{count} محادثات مشفرة بكلمة مرور سابقة.',
  'recoverChats': 'استعادة المحادثات',
  'deleteAccountWarning':
      'حذف حسابك سيلغي جميع الاشتراكات ويزيل بياناتك ولا يمكن التراجع عنه.',
  'deleteAccount': 'حذف الحساب',
  'unableToLoadProfile': 'تعذر تحميل ملفك الشخصي الآن.',
  'retry': 'إعادة المحاولة',
  'saved': 'تم الحفظ',
  'emailUpdated':
      'تم تحديث البريد الإلكتروني. أكّد التغيير عبر الرابط الذي أرسله Supabase إلى {email}.',
  'failedToLoadProfile': 'فشل تحميل الملف الشخصي: {error}',
  'failedToSaveProfile': 'فشل حفظ الملف الشخصي: {error}',
  'emailCannotBeEmpty': 'لا يمكن ترك البريد الإلكتروني فارغاً.',
  'passwordsDoNotMatch': 'كلمتا المرور الجديدتان غير متطابقتين.',
  'failedToChangePassword': 'فشل تغيير كلمة المرور: {error}',
  'deleteAccountQuestion': 'حذف الحساب؟',
  'deleteAccountConfirmBody':
      'هل أنت متأكد أنك تريد حذف حسابك؟\n\nسيؤدي هذا إلى محو:\n  \u2022 جميع محادثاتك ورسائلك\n  \u2022 جميع الذكريات المخزنة\n  \u2022 ملفك الشخصي وإعداداتك\n  \u2022 أي اشتراكات نشطة\n\nهذا الإجراء لا رجعة فيه. لا يمكن استعادة بياناتك.',
  'yesDelete': 'نعم، أريد الحذف',
  'thisIsPermanent': 'هذا نهائي',
  'finalDeleteWarning':
      'هذه فرصتك الأخيرة للتراجع.\n\nبمجرد الحذف، لا توجد أي طريقة لاستعادة حسابك أو محادثاتك أو ذكرياتك أو أي بيانات مرتبطة.\n\nسيضيع كل شيء إلى الأبد.\n\nهل تريد المتابعة؟',
  'noKeepMyAccount': 'لا، أبقِ حسابي',
  'deleteEverything': 'حذف كل شيء',
  'confirmYourPassword': 'أكّد كلمة مرورك',
  'confirmPasswordBody':
      'لتأكيد حذف الحساب، يرجى إدخال كلمة مرورك.',
  'password': 'كلمة المرور',
  'passwordRequired': 'كلمة المرور مطلوبة',
  'verificationFailed': 'فشل التحقق: {error}',
  'verifyAndDelete': 'تحقق واحذف',
  'failedToDeleteAccount': 'فشل حذف الحساب: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'نظام الهوية',
  'identityActive': 'الشخصية والمستخدم والذاكرة نشطة',
  'identityDisabled': 'معطّل — لا يملك الذكاء الاصطناعي هوية دائمة',
  'soul': 'الشخصية',
  'soulHint':
      'حدد شخصية الذكاء الاصطناعي ونبرته وحدوده. هذا يشكّل طريقة تواصله في جميع المحادثات.',
  'soulExample':
      'مثال:\n\u2022 كن مباشراً وموجزاً\n\u2022 تناغم مع لغة المستخدم وطاقته\n\u2022 كن صاحب رأي، لا تتردد في كل شيء\n\u2022 الخصوصية أولاً: اسأل قبل الإجراءات الخارجية',
  'user': 'المستخدم',
  'userHint':
      'حقائق عنك. يقرأها الذكاء الاصطناعي مع كل رسالة ويمكنه تحديثها عندما يتعلم أشياء جديدة عنك.',
  'userExample':
      'مثال:\n\u2022 الاسم: أحمد\n\u2022 المنطقة الزمنية: Asia/Riyadh\n\u2022 اللغة: عربي/إنجليزي\n\u2022 يفضل الإجابات المختصرة والتقنية',
  'memory': 'الذاكرة',
  'memoryHint':
      'معرفة طويلة المدى يتذكرها الذكاء الاصطناعي عبر المحادثات. يمكنه أيضاً تحديثها عند تعلم حقائق أو قرارات مهمة.',
  'memoryExample':
      'مثال:\n\u2022 يفضل Dart/Flutter للهاتف\n\u2022 الترخيص: BSL لجميع المشاريع\n\u2022 المشروع الحالي: chuk_chat\n\u2022 من محبي الوضع الداكن',
  'importFromAnotherAi': 'استيراد من ذكاء اصطناعي آخر',
  'systemPrompt': 'تعليمات النظام',
  'systemPromptHint':
      'تعليمات مخصصة تُرسل مع كل محادثة. مشفرة بمفتاح تشفير محادثاتك.',
  'systemPromptExample':
      'مثال: أنت مساعد مفيد. قدم ردوداً موجزة ودقيقة.',
  'characters': 'حرف',
  'saving': 'جارٍ الحفظ...',
  'saveChanges': 'حفظ التغييرات',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'تراخيص المصادر المفتوحة',
  'openSourceLicensesSubtitle':
      'مراجعة التراخيص لكل مكتبة مضمّنة في هذا الإصدار.',
  'termsOfService': 'شروط الخدمة',
  'privacyPolicy': 'سياسة الخصوصية',
  'versionText': 'الإصدار {version}',
  'updateAvailable': 'تحديث متاح: v{version} — انقر للتحميل',
  'versionUnavailable': 'معلومات الإصدار غير متاحة.',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nجميع الحقوق محفوظة.',
  'licenses': 'التراخيص',
  'unableToLoadLicenses': 'تعذر تحميل التراخيص.',
  'tapToViewLicense': 'انقر لعرض نص الترخيص الكامل',
  'devOptionsEnabled': 'تم تفعيل خيارات المطور',
  'devOptionsAlreadyEnabled': 'خيارات المطور مفعّلة بالفعل',
  'devOptionsTapSingular': 'نقرة {taps} أخرى لخيارات المطور',
  'devOptionsTapsPlural': '{taps} نقرات أخرى لخيارات المطور',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'الاشتراك',
  'openUsageDetailsInfo':
      'افتح تفاصيل الاستخدام لرؤية كل طلب والإجماليات الشهرية وتكاليف النماذج.',
  'openUsageDetails': 'فتح تفاصيل الاستخدام',
  'currentPlan': 'الخطة الحالية',
  'plus': 'بلس',
  'pricePerMonth': '\u20ac20/شهرياً',
  'monthlyCredits': 'رصيد الذكاء الاصطناعي الشهري: \u20ac16.00',
  'unusedCreditsExpire':
      'الرصيد غير المستخدم ينتهي في نهاية كل شهر.',
  'manageBilling': 'إدارة الفواتير',
  'manageBillingSubtitle':
      'استخدم بوابة الفواتير لإلغاء اشتراكك أو تحديث طرق الدفع.',
  'active': 'نشط',
  'getCreditsMonthly': 'احصل على \u20ac16 رصيد ذكاء اصطناعي شهرياً',
  'accessAllModels': 'الوصول إلى جميع نماذج الذكاء الاصطناعي',
  'imageGeneration': 'توليد الصور',
  'voiceMode': 'الوضع الصوتي',
  'textChatReasoning': 'محادثة نصية مع التفكير',
  'creditsExplanation':
      'يُستخدم رصيدك البالغ \u20ac16 لكل رمز بناءً على النموذج الذي تختاره. ينتهي الرصيد غير المستخدم في نهاية كل شهر.',
  'immediateAccessAck':
      'أريد الوصول الفوري إلى Chuk Chat وأقر بأنني أفقد ',
  'rightOfWithdrawal': 'حق الانسحاب',
  'onceServiceBegins': ' بمجرد بدء الخدمة. أوافق على ',
  'subscribeNow': 'اشترك الآن',
  'alreadySubscribed': 'لديك اشتراك نشط بالفعل.',
  'opening': 'جارٍ الفتح...',
  'agreeToTermsFirst':
      'يرجى الموافقة على الشروط والإقرار بفقدان حق الانسحاب.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'مرحباً بك في Chuk Chat',
  'signInWithEmail': 'سجّل الدخول ببريدك الإلكتروني',
  'createAccountWithEmail': 'أنشئ حساباً بالبريد الإلكتروني وكلمة المرور',
  'supabaseNotConfigured':
      'بيانات اعتماد Supabase غير مضبوطة. حدّثها قبل تشغيل إصدار الإنتاج.',
  'howOthersSeeYou': 'كيف سيراك الآخرون',
  'email': 'البريد الإلكتروني',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'تأكيد كلمة المرور',
  'forgotPassword': 'نسيت كلمة المرور؟',
  'enterYourPassword': 'أدخل كلمة مرورك.',
  'pleaseConfirmPassword': 'يرجى تأكيد كلمة مرورك.',
  'signIn': 'تسجيل الدخول',
  'createAccount': 'إنشاء حساب',
  'noAccountSignUp': 'ليس لديك حساب؟ سجّل الآن',
  'haveAccountSignIn': 'لديك حساب بالفعل؟ سجّل الدخول',
  'agreeToTerms': 'أوافق على ',
  'andText': ' و ',
  'confirmAge16': 'أؤكد أن عمري 16 عاماً على الأقل',
  'mustAgreeToTerms':
      'يجب الموافقة على شروط الخدمة وسياسة الخصوصية لإنشاء حساب.',
  'mustBe16': 'يجب أن يكون عمرك 16 عاماً على الأقل لاستخدام هذه الخدمة.',
  'unexpectedError': 'خطأ غير متوقع: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'استعادة المحادثات المشفرة',
  'noLockedChats': 'لا توجد محادثات مقفلة',
  'allChatsAccessible': 'جميع محادثاتك متاحة.',
  'recoverChatsInfo':
      'بعض المحادثات مشفرة بكلمة مرور سابقة. أدخل كلمة مرورك القديمة لاستعادتها، أو احذفها نهائياً.',
  'encryptedWithVersion': 'مشفرة بإصدار كلمة المرور {version}',
  'oldPassword': 'كلمة المرور القديمة',
  'enterOldPassword': 'أدخل كلمة المرور التي استخدمتها سابقاً',
  'lockedChatCountSingular': '{count} محادثة مقفلة',
  'lockedChatCountPlural': '{count} محادثات مقفلة',
  'deleteLockedChatsTitle': 'حذف المحادثات المقفلة؟',
  'deleteLockedChatsBodySingular':
      'سيؤدي هذا إلى حذف {count} محادثة مشفرة بكلمة مرورك القديمة نهائياً.\n\nلا يمكن استعادة هذه المحادثة بعد الحذف. ستفقد جميع الرسائل والصور والمرفقات.',
  'deleteLockedChatsBodyPlural':
      'سيؤدي هذا إلى حذف {count} محادثات مشفرة بكلمة مرورك القديمة نهائياً.\n\nلا يمكن استعادة هذه المحادثات بعد الحذف. ستفقد جميع الرسائل والصور والمرفقات.',
  'deletePermanently': 'حذف نهائي',
  'areYouSure': 'هل أنت متأكد؟',
  'confirmDeleteChats':
      'أنت على وشك حذف {count} محادثات. اكتب DELETE للتأكيد.',
  'typeDelete': 'اكتب DELETE',
  'confirmDelete': 'تأكيد الحذف',
  'pleaseEnterOldPassword': 'يرجى إدخال كلمة مرورك القديمة.',
  'derivingKey': 'جارٍ اشتقاق مفتاح التشفير...',
  'recoveredChatsSingular': 'تم استعادة {count} محادثة بنجاح.',
  'recoveredChatsPlural': 'تم استعادة {count} محادثات بنجاح.',
  'recoveryFailed': 'فشلت الاستعادة. يرجى المحاولة مرة أخرى.',
  'deletedChatsSingular': 'تم حذف {count} محادثة.',
  'deletedChatsPlural': 'تم حذف {count} محادثات.',
  'deletionFailed': 'فشل الحذف. يرجى المحاولة مرة أخرى.',
  'recover': 'استعادة',
  'delete': 'حذف',
  'deleting': 'جارٍ الحذف...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'تعيين كلمة مرور جديدة',
  'setNewPasswordInfo':
      'اختر كلمة مرور قوية لحسابك. ستبقى محادثاتك القديمة متاحة إذا تذكرت كلمة مرورك السابقة.',
  'setNewPasswordButton': 'تعيين كلمة المرور الجديدة',
  'noAuthenticatedUser': 'لا يوجد مستخدم مصادق عليه بعد تحديث كلمة المرور.',
  'failedToPreserveEncryption':
      'فشل الحفاظ على بيانات التشفير القديمة. يرجى التحقق من اتصالك والمحاولة مرة أخرى.',
  'failedToSetNewPassword':
      'فشل تعيين كلمة المرور الجديدة. يرجى المحاولة مرة أخرى.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'خيارات المطور',
  'devOptionsToggleSubtitle':
      'فتح أدوات التشخيص والتصحيح. عطّل لإخفاء جميع إعدادات المطور.',
  'enableDiagnosticsLogging': 'تفعيل سجل التشخيص',
  'enableDiagnosticsSubtitle':
      'يعمل في إصدارات الإنتاج. يسجل بيانات التطبيق/وقت التشغيل لاستكشاف مشاكل التأخير وشريط النظام.',
  'diagnosticsEnabled': 'تم تفعيل سجل التشخيص',
  'diagnosticsDisabled': 'تم تعطيل سجل التشخيص',
  'notInitializedYet': 'لم يتم التهيئة بعد',
  'refresh': 'تحديث',
  'copyRecent': 'نسخ الأخيرة',
  'copyFocusedDebug': 'نسخ تقرير التصحيح المركّز',
  'shareFile': 'مشاركة الملف',
  'clear': 'مسح',
  'copiedRecentLogs': 'تم نسخ السجلات الأخيرة إلى الحافظة',
  'noFocusedDebugData': 'لا تتوفر بيانات تصحيح مركّزة بعد',
  'copiedFocusedDebug': 'تم نسخ تقرير تصحيح قائمة النماذج المركّز',
  'failedFocusedDebug':
      'فشل إنشاء تقرير التصحيح المركّز: {error}',
  'noDiagnosticsLog': 'لا يتوفر سجل تشخيص',
  'diagnosticsLogNotFound': 'ملف سجل التشخيص غير موجود',
  'failedToShareLog': 'فشل مشاركة سجل التشخيص: {error}',
  'diagnosticsLogCleared': 'تم مسح سجل التشخيص',
  'failedToClearLog': 'فشل مسح سجل التشخيص: {error}',
  'devOptionsDisabledMsg': 'تم تعطيل خيارات المطور.',
  'noLogsYet':
      'لا توجد سجلات بعد. فعّل سجل التشخيص واستخدم التطبيق لجمع البيانات.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'رجوع',
  'enabled': 'مفعّل',
  'disabled': 'معطّل',
  'modelPrompt': 'تعليمات النموذج',
  'modelPromptHint':
      'يُعرض هذا الوصف للنموذج بعد اكتشاف الأدوات.',
  'customPromptActive': 'التعليمات المخصصة نشطة',
  'savePrompt': 'حفظ التعليمات',
  'parameters': 'المعاملات',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'تفاصيل الاستخدام',
  'unableToLoadUsage': 'تعذر تحميل تفاصيل الاستخدام الآن.',
  'usageAndBilling': 'الاستخدام والفواتير',
  'usageReadOnly':
      'هذه الشاشة للقراءة فقط ومأخوذة من سجلات استخدامك.',
  'period': 'الفترة',
  'totals': 'الإجماليات',
  'mediaRequestsNote':
      'طلبات الصور والصوت تُعامل كطلبات وسائط ومستبعدة من إجماليات الرموز النصية.',
  'noRequestsFound': 'لم يتم العثور على طلبات لهذه الفترة.',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'انتهت الجلسة. يرجى تسجيل الدخول مرة أخرى.',
  'free': 'مجاني',
  'best': 'الأفضل',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'فتح في تطبيق البريد',
  'unableToSaveImage': 'تعذر حفظ الصورة',
  'image': 'صورة',
  'open': 'فتح',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'الأصلي',
  'markdown': 'Markdown',
  'deleteFile': 'حذف الملف',
  'deleteFailed': 'فشل الحذف: {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'اسألني أي شيء!',
  'aiDisclaimer': 'أنت تتحدث مع ذكاء اصطناعي — قد يخطئ. تحقق من المعلومات المهمة.',
  'queuedLabel': 'في قائمة الانتظار',
  'editYourMessage': 'عدّل رسالتك...',
  'addMessageOrDocs': 'أضف رسالة أو أرسل مستندات',
  'micAccessFailed': 'فشل الوصول إلى الميكروفون',
  'transcriptionFailed': 'فشل تحويل الصوت إلى نص',
  'nothingToResend': 'لا يوجد شيء لإعادة الإرسال',
  'freeMessagesUsed': 'تم استخدام الرسائل المجانية',
  'ok': 'حسناً',
  'camera': 'الكاميرا',
  'photos': 'الصور',
  'files': 'الملفات',

  // ── Model selector ─────────────────────────────────────────
  'models': 'النماذج',
  'searchModels': 'بحث في النماذج...',
  'modelError': 'خطأ: {error}',

  // ── Message bubble extras ──────────────────────────────────

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'الإجمالي: {count}',
  'freeRemaining': 'مجاني: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'اختر النموذج',
  'noEnabledModels': 'لا توجد نماذج مفعّلة',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'محادثة جديدة',
  'workspaces': 'مساحات العمل',
  'media': 'الوسائط',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'مدير الوسائط',
  'imageUsedInChats': 'الصورة مستخدمة في محادثات',
  'imageUsedInChatsBody':
      'هذه الصورة مستخدمة في المحادثات التالية:',
  'deleteImageShowDeleted':
      'إذا حذفت هذه الصورة، ستظهر كـ "صورة محذوفة" في تلك المحادثات.',
  'deleteImageConfirm':
      'هل أنت متأكد أنك تريد حذف هذه الصورة؟',
  'deleteAnyway': 'حذف على أي حال',
  'deleteImageTitle': 'حذف الصورة',
  'deleteImageBody':
      'هل أنت متأكد أنك تريد حذف هذه الصورة؟ لا يمكن التراجع عن هذا الإجراء.',
  'imageDeleted': 'تم حذف الصورة',
  'failedToDeleteImage': 'فشل حذف الصورة: {error}',
  'someImagesUsedInChats': 'بعض الصور مستخدمة في محادثات',
  'deletedImagesWarning':
      'الصور المحذوفة ستظهر كـ "صورة محذوفة" في تلك المحادثات.',
  'deleteAllCount': 'حذف جميع الصور المحددة ({count})؟',
  'deleteAll': 'حذف الكل',
  'deleteSelectedImages': 'حذف الصور المحددة',
  'deleteSelectedCount':
      'حذف {count} صور محددة؟ لا يمكن التراجع عن هذا الإجراء.',
  'deletedImagesResult': 'تم حذف {deleted} صور، فشل {failed}',
  'deletedImagesSuccess': 'تم حذف {deleted} صور',
  'downloadSelected': 'تحميل المحدد',
  'deleteSelected': 'حذف المحدد',
  'errorLoadingImages': 'خطأ في تحميل الصور',
  'noImagesStored': 'لا توجد صور مخزنة',
  'imagesAppearHere': 'الصور التي ترسلها في المحادثات ستظهر هنا',
  'download': 'تحميل',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'إزالة {name}',
  'edit': 'تعديل',
  'close': 'إغلاق',

  // ── Subscription dialogs ───────────────────────────────────
};
