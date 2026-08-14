// lib/l10n/strings_ru.dart
// Russian UI strings.

const Map<String, String> stringsRu = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Настройки',
  'themeSettings': 'Настройки темы',
  'themeSettingsSubtitle': 'Настройка темы, цветов и внешнего вида',
  'customization': 'Персонализация',
  'customizationSubtitle': 'Настройка поведения и предпочтений приложения',
  'toolCalling': 'Вызов инструментов',
  'toolCallingSubtitle':
      'Управление использованием, обнаружением и отображением инструментов',
  'developerOptions': 'Параметры разработчика',
  'developerOptionsSubtitle': 'Журналы диагностики и инструменты отладки',
  'modelSelection': 'Выбор модели',
  'modelSelectionSubtitle': 'Выбор и настройка моделей ИИ',
  'aiIdentityMemory': 'Личность и память ИИ',
  'aiIdentityMemorySubtitle':
      'Душа, профиль пользователя, память и системный промпт',
  'pricingPlans': 'Тарифные планы',
  'pricingPlansSubtitle': 'Просмотр планов подписки и цен',
  'accountSettings': 'Настройки аккаунта',
  'exportChats': 'Экспорт чатов',
  'exportChatsSubtitle': 'Скачать ваши разговоры в формате JSON',
  'about': 'О приложении',
  'aboutSubtitle': 'Информация о версии и лицензии открытого ПО',
  'logout': 'Выйти',
  'noChatsToExport': 'Нет чатов для экспорта',
  'copiedToClipboard': 'Скопировано в буфер обмена',
  'savedToPath': 'Сохранено в {path}',
  'exportCancelled': 'Экспорт отменён',
  'shareOpened': 'Открыт диалог отправки',
  'exportFailed': 'Ошибка экспорта: {error}',
  'saveChatExport': 'Сохранить экспорт чата',

  // ── Customization page ─────────────────────────────────────
  'language': 'Язык',
  'languageSubtitle': 'Выберите предпочитаемый язык',
  'voiceTranscription': 'Голосовая транскрипция',
  'autoSendVoice': 'Автоотправка голосовых сообщений',
  'autoSendVoiceSubtitle':
      'Автоматически отправлять распознанные голосовые сообщения без подтверждения',
  'autoSendVoiceInfo':
      'Когда включено, голосовые транскрипции отправляются сразу. Когда выключено (по умолчанию), транскрипции появляются в текстовом поле для проверки перед отправкой.',
  'messageDisplay': 'Отображение сообщений',
  'showReasoningTokens': 'Показывать токены рассуждений',
  'showReasoningTokensSubtitle':
      'Отображать процесс рассуждений в ответах ИИ',
  'showModelInfo': 'Показывать информацию о модели',
  'showModelInfoSubtitle':
      'Отображать название и информацию о модели в сообщениях чата',
  'showTps': 'Показывать токены в секунду',
  'showTpsSubtitle': 'Отображать скорость генерации ответов ИИ (TPS)',
  'aiContext': 'Контекст ИИ',
  'recentImagesInContext': 'Недавние изображения в контексте',
  'recentImagesInContextSubtitle':
      'Отправлять изображения из недавних сообщений модели ИИ',
  'allImagesInContext': 'Все изображения в контексте',
  'allImagesInContextSubtitle':
      'Отправлять все изображения из разговора в ИИ (использует больше токенов)',
  'reasoningInContext': 'Рассуждения в контексте',
  'reasoningInContextSubtitle':
      'Включать процесс мышления ИИ в историю разговора',
  'aiContextInfo':
      'Недавние изображения отправляют картинки из последних 6 сообщений. Все изображения отправляют каждое изображение в разговоре. Рассуждения включают процесс мышления ИИ как контекст для последующих сообщений.',
  'chatTitles': 'Заголовки чатов',
  'autoGenerateTitles': 'Автоматически генерировать заголовки чатов',
  'autoGenerateTitlesSubtitle':
      'Использовать ИИ для генерации заголовков новых чатов',
  'titleGenerationPrompt': 'Промпт для генерации заголовков',
  'usingCustomPrompt': 'Используется пользовательский промпт',
  'usingDefaultPrompt': 'Используется промпт по умолчанию',
  'titleGenInfo':
      'Когда включено, короткий заголовок будет автоматически сгенерирован для новых чатов на основе вашего первого сообщения. Используется быстрая и лёгкая модель ИИ (qwen3-8b).',
  'systemPromptSaved': 'Системный промпт сохранён',
  'systemPromptResetToDefault': 'Системный промпт сброшен на значение по умолчанию',
  'reset': 'Сбросить',
  'save': 'Сохранить',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Тёмная тема',
  'darkModeSubtitle': 'Переключение между тёмной и светлой темой',
  'accentColor': 'Акцентный цвет',
  'accentColorSubtitle': 'Выберите основной акцентный цвет',
  'iconFgColor': 'Цвет иконок/переднего плана',
  'iconFgColorSubtitle': 'Выберите цвет для иконок и ключевого текста',
  'backgroundColor': 'Цвет фона',
  'backgroundColorSubtitle': 'Выберите основной цвет фона приложения',
  'filmGrainEffect': 'Эффект плёночного зерна',
  'filmGrainSubtitle': 'Добавить лёгкую текстуру плёночной съёмки',
  'customHexColor': 'Пользовательский HEX-цвет (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Движок',
  'enableToolCalling': 'Включить вызов инструментов',
  'enableToolCallingSubtitle':
      'Разрешить ассистенту обнаруживать и выполнять встроенные инструменты',
  'behavior': 'Поведение',
  'requireDiscoveryFirst': 'Сначала требовать обнаружение',
  'requireDiscoverySubtitle':
      'Требовать find_tools перед использованием других инструментов в ходе обмена',
  'markdownToolCallFallback': 'Резервный вызов инструментов через Markdown',
  'markdownFallbackSubtitle':
      'Принимать блоки кода ```tool_call, когда модели не генерируют XML-теги',
  'display': 'Отображение',
  'showToolActivity': 'Показывать активность инструментов в чате',
  'showToolActivitySubtitle':
      'Отображать чипы работающих/завершённых инструментов в сообщениях ассистента',
  'toolCallingTip':
      'Совет: оставьте Markdown-резерв включённым для лучшей совместимости. Отключайте только если хотите строго XML-вызовы инструментов.',
  'enableMapBlocks': 'Включить блоки карт (<map>)',
  'enableMapBlocksSubtitle':
      'Разрешить промпту модели включать инструкции рендеринга карт',
  'enableChartBlocks': 'Включить блоки графиков (<chart>)',
  'enableChartBlocksSubtitle':
      'Разрешить промпту модели включать инструкции рендеринга графиков',
  'loadingToolSettings': 'Загрузка настроек инструментов...',
  'noToolsRegistered': 'Инструменты ещё не зарегистрированы.',
  'catSearchWeb': 'Поиск и Интернет',
  'catUtilities': 'Утилиты',
  'catMapsLocation': 'Карты и местоположение',
  'catDevice': 'Устройство',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / Терминал',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Календарь / Gmail)',
  'catEmailImapSmtp': 'Электронная почта (IMAP/SMTP)',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'Песочница / Код',
  'catSearchWebDesc':
      'Поиск в интернете, загрузка страниц, генерация изображений и получение данных',
  'catUtilitiesDesc':
      'Калькулятор, часы, заметки, QR-коды и другие утилиты',
  'catMapsLocationDesc':
      'Поиск мест, геокодирование адресов и расчёт маршрутов',
  'catDeviceDesc':
      'Доступ к функциям устройства: GPS, календарь и напоминания',
  'catSpotifyDesc': 'Управление воспроизведением и просмотр библиотеки Spotify',
  'catBashTerminalDesc':
      'Запуск изолированных команд оболочки на рабочем столе',
  'catGitHubDesc':
      'Доступ к репозиториям, задачам, PR и коммитам на GitHub',
  'catSlackDesc':
      'Отправка сообщений, поиск каналов и получение данных из Slack',
  'catGoogleCalGmailDesc':
      'Управление расписанием и почтой через Google Календарь и Gmail',
  'catEmailImapSmtpDesc':
      'Отправка и получение электронной почты через IMAP и SMTP',
  'catNextcloudDesc':
      'Просмотр файлов, календаря и контактов в Nextcloud',
  'catSandboxDesc':
      'Запуск Python- или shell-кода в изолированной песочнице и чтение/запись файлов',
  'connect': 'Подключить',
  'disconnect': 'Отключить',
  'disconnectCategory': 'Отключить {label}?',
  'removeCredentialsWarning': 'Это удалит ваши сохранённые учётные данные.',
  'cancel': 'Отмена',
  'toolWebSearch': 'Веб-поиск',
  'toolWebCrawl': 'Веб-сканирование',
  'toolImageGen': 'Генерация изображений',
  'toolFetchImage': 'Загрузка изображения',
  'toolViewChatImages': 'Просмотр изображений чата',
  'toolCryptoData': 'Данные криптовалют',
  'toolWeather': 'Погода',
  'toolPlaceSearch': 'Поиск мест',
  'toolRestaurantSearch': 'Поиск ресторанов',
  'toolGeocoding': 'Геокодирование',
  'toolRouting': 'Маршрутизация',
  'toolCalculator': 'Калькулятор',
  'toolClock': 'Часы',
  'toolRandomNumber': 'Случайное число',
  'toolCoinFlip': 'Подбрасывание монеты',
  'toolDiceRoll': 'Бросок кубика',
  'toolCountdown': 'Обратный отсчёт',
  'toolPasswordGen': 'Генератор паролей',
  'toolUuidGen': 'Генератор UUID',
  'toolNotes': 'Заметки',
  'toolQrGen': 'Генератор QR',
  'resetToolSettingsTitle': 'Сбросить настройки инструментов?',
  'resetToolSettingsBody':
      'Это включит все инструменты обратно и сбросит все пользовательские промпты инструментов.',
  'resetAllToolPrefs': 'Сбросить все настройки инструментов',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Профиль',
  'displayName': 'Отображаемое имя',
  'displayNameHint': 'Как другие люди видят вас',
  'emailAddress': 'Адрес электронной почты',
  'emailAddressHint': 'Куда мы отправляем уведомления',
  'security': 'Безопасность',
  'changePassword': 'Сменить пароль',
  'currentPassword': 'Текущий пароль',
  'newPassword': 'Новый пароль',
  'minCharsPassword': 'Минимум 8 символов.',
  'confirmNewPassword': 'Подтвердите новый пароль',
  'updatePassword': 'Обновить пароль',
  'encryptedChatRecovery': 'Восстановление зашифрованных чатов',
  'lockedChatsSingular':
      '{count} чат зашифрован предыдущим паролем.',
  'lockedChatsPlural':
      '{count} чатов зашифрованы предыдущим паролем.',
  'recoverChats': 'Восстановить чаты',
  'deleteAccountWarning':
      'Удаление аккаунта отменит все подписки, удалит ваши данные и не может быть отменено.',
  'deleteAccount': 'Удалить аккаунт',
  'unableToLoadProfile': 'Не удалось загрузить ваш профиль.',
  'retry': 'Повторить',
  'saved': 'Сохранено',
  'emailUpdated':
      'Email обновлён. Подтвердите изменение по ссылке, отправленной Supabase на {email}.',
  'failedToLoadProfile': 'Не удалось загрузить профиль: {error}',
  'failedToSaveProfile': 'Не удалось сохранить профиль: {error}',
  'emailCannotBeEmpty': 'Email не может быть пустым.',
  'passwordsDoNotMatch': 'Новые пароли не совпадают.',
  'failedToChangePassword': 'Не удалось сменить пароль: {error}',
  'deleteAccountQuestion': 'Удалить аккаунт?',
  'deleteAccountConfirmBody':
      'Вы уверены, что хотите удалить свой аккаунт?\n\nЭто безвозвратно удалит:\n  \u2022 Все ваши чаты и сообщения\n  \u2022 Все сохранённые воспоминания\n  \u2022 Ваш профиль и настройки\n  \u2022 Все активные подписки\n\nЭто действие необратимо. Ваши данные невозможно будет восстановить.',
  'yesDelete': 'Да, хочу удалить',
  'thisIsPermanent': 'Это навсегда',
  'finalDeleteWarning':
      'Это ваш последний шанс передумать.\n\nПосле удаления абсолютно невозможно восстановить ваш аккаунт, чаты, воспоминания или любые связанные данные.\n\nВсё будет потеряно навсегда.\n\nВы всё ещё хотите продолжить?',
  'noKeepMyAccount': 'Нет, сохранить аккаунт',
  'deleteEverything': 'Удалить всё',
  'confirmYourPassword': 'Подтвердите ваш пароль',
  'confirmPasswordBody':
      'Для подтверждения удаления аккаунта введите ваш пароль.',
  'password': 'Пароль',
  'passwordRequired': 'Необходимо ввести пароль',
  'verificationFailed': 'Проверка не удалась: {error}',
  'verifyAndDelete': 'Подтвердить и удалить',
  'failedToDeleteAccount': 'Не удалось удалить аккаунт: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Система личности',
  'identityActive': 'Душа, Пользователь и Память активны',
  'identityDisabled': 'Отключено — у ИИ нет постоянной личности',
  'soul': 'Душа',
  'soulHint':
      'Определите личность, тон и границы ИИ. Это формирует стиль общения во всех разговорах.',
  'soulExample':
      'Пример:\n\u2022 Быть прямым и кратким\n\u2022 Подстраиваться под язык и энергию пользователя\n\u2022 Иметь мнение, не уклоняться от ответов\n\u2022 Приватность прежде всего: спрашивать перед внешними действиями',
  'user': 'Пользователь',
  'userHint':
      'Факты о вас. ИИ читает это при каждом сообщении и может обновлять, когда узнаёт о вас что-то новое.',
  'userExample':
      'Пример:\n\u2022 Имя: Алекс\n\u2022 Часовой пояс: Europe/Berlin\n\u2022 Язык: немецкий/английский\n\u2022 Предпочитает краткие технические ответы',
  'memory': 'Память',
  'memoryHint':
      'Долговременные знания, которые ИИ помнит между разговорами. ИИ может обновлять это, когда узнаёт важные факты или решения.',
  'memoryExample':
      'Пример:\n\u2022 Предпочитает Dart/Flutter для мобильных\n\u2022 Лицензия: BSL для всех проектов\n\u2022 Текущий проект: chuk_chat\n\u2022 Любитель тёмной темы',
  'importFromAnotherAi': 'Импортировать из другого ИИ',
  'systemPrompt': 'Системный промпт',
  'systemPromptHint':
      'Пользовательские инструкции, отправляемые с каждым разговором. Зашифрованы вашим ключом шифрования чатов.',
  'systemPromptExample':
      'Пример: Вы — полезный ассистент. Давайте краткие и точные ответы.',
  'characters': 'символов',
  'saving': 'Сохранение...',
  'saveChanges': 'Сохранить изменения',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Лицензии открытого ПО',
  'openSourceLicensesSubtitle':
      'Просмотр лицензий всех зависимостей, включённых в эту сборку.',
  'termsOfService': 'Условия использования',
  'privacyPolicy': 'Политика конфиденциальности',
  'versionText': 'Версия {version}',
  'updateAvailable': 'Доступно обновление: v{version} — нажмите для загрузки',
  'versionUnavailable': 'Информация о версии недоступна.',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nВсе права защищены.',
  'licenses': 'Лицензии',
  'unableToLoadLicenses': 'Не удалось загрузить лицензии.',
  'tapToViewLicense': 'Нажмите для просмотра полного текста лицензии',
  'devOptionsEnabled': 'Параметры разработчика включены',
  'devOptionsAlreadyEnabled': 'Параметры разработчика уже включены',
  'devOptionsTapSingular': 'Ещё {taps} нажатие для параметров разработчика',
  'devOptionsTapsPlural': 'Ещё {taps} нажатий для параметров разработчика',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Подписка',
  'openUsageDetailsInfo':
      'Откройте «Сведения об использовании», чтобы увидеть каждый запрос, ежемесячные итоги и стоимость моделей.',
  'openUsageDetails': 'Открыть сведения об использовании',
  'currentPlan': 'Текущий план',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/месяц',
  'monthlyCredits': 'Ежемесячные кредиты ИИ: \u20ac16,00',
  'unusedCreditsExpire':
      'Неиспользованные кредиты сгорают в конце каждого месяца.',
  'manageBilling': 'Управление оплатой',
  'manageBillingSubtitle':
      'Используйте портал оплаты для отмены подписки или обновления способов оплаты.',
  'active': 'АКТИВНА',
  'getCreditsMonthly': 'Получайте \u20ac16 кредитов ИИ ежемесячно',
  'accessAllModels': 'Доступ ко всем моделям ИИ',
  'imageGeneration': 'Генерация изображений',
  'voiceMode': 'Голосовой режим',
  'textChatReasoning': 'Текстовый чат с рассуждениями',
  'creditsExplanation':
      'Ваши \u20ac16 кредитов ИИ расходуются по токенам в зависимости от выбранной модели. Неиспользованные кредиты сгорают в конце каждого месяца.',
  'immediateAccessAck':
      'Я хочу немедленный доступ к Chuk Chat и подтверждаю, что теряю своё ',
  'rightOfWithdrawal': 'право на отказ',
  'onceServiceBegins': ' после начала предоставления услуги. Я принимаю ',
  'subscribeNow': 'Подписаться сейчас',
  'alreadySubscribed': 'У вас уже есть активная подписка.',
  'opening': 'Открытие...',
  'agreeToTermsFirst':
      'Пожалуйста, примите условия и подтвердите потерю права на отказ.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Добро пожаловать в Chuk Chat',
  'signInWithEmail': 'Войдите с помощью email',
  'createAccountWithEmail': 'Создайте аккаунт с email и паролем',
  'supabaseNotConfigured':
      'Учётные данные Supabase не настроены. Обновите их перед сборкой для продакшена.',
  'howOthersSeeYou': 'Как другие люди будут вас видеть',
  'email': 'Email',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'Подтвердите пароль',
  'forgotPassword': 'Забыли пароль?',
  'enterYourPassword': 'Введите ваш пароль.',
  'pleaseConfirmPassword': 'Пожалуйста, подтвердите ваш пароль.',
  'signIn': 'Войти',
  'createAccount': 'Создать аккаунт',
  'noAccountSignUp': 'Нет аккаунта? Зарегистрируйтесь',
  'haveAccountSignIn': 'Уже есть аккаунт? Войдите',
  'agreeToTerms': 'Я принимаю ',
  'andText': ' и ',
  'confirmAge16': 'Я подтверждаю, что мне не менее 16 лет',
  'mustAgreeToTerms':
      'Для создания аккаунта необходимо принять Условия использования и Политику конфиденциальности.',
  'mustBe16': 'Для использования этого сервиса вам должно быть не менее 16 лет.',
  'unexpectedError': 'Непредвиденная ошибка: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'Восстановление зашифрованных чатов',
  'noLockedChats': 'Нет заблокированных чатов',
  'allChatsAccessible': 'Все ваши чаты доступны.',
  'recoverChatsInfo':
      'Некоторые чаты зашифрованы предыдущим паролем. Введите старый пароль для их восстановления или удалите их навсегда.',
  'encryptedWithVersion': 'Зашифровано версией пароля {version}',
  'oldPassword': 'Старый пароль',
  'enterOldPassword': 'Введите пароль, который вы использовали ранее',
  'lockedChatCountSingular': '{count} заблокированный чат',
  'lockedChatCountPlural': '{count} заблокированных чатов',
  'deleteLockedChatsTitle': 'Удалить заблокированные чаты?',
  'deleteLockedChatsBodySingular':
      'Это безвозвратно удалит {count} чат, зашифрованный вашим старым паролем.\n\nЭтот чат невозможно восстановить после удаления. Вы потеряете все сообщения, изображения и вложения.',
  'deleteLockedChatsBodyPlural':
      'Это безвозвратно удалит {count} чатов, зашифрованных вашим старым паролем.\n\nЭти чаты невозможно восстановить после удаления. Вы потеряете все сообщения, изображения и вложения.',
  'deletePermanently': 'Удалить навсегда',
  'areYouSure': 'Вы уверены?',
  'confirmDeleteChats':
      'Вы собираетесь удалить {count} чатов. Введите DELETE для подтверждения.',
  'typeDelete': 'Введите DELETE',
  'confirmDelete': 'Подтвердить удаление',
  'pleaseEnterOldPassword': 'Пожалуйста, введите ваш старый пароль.',
  'derivingKey': 'Генерация ключа шифрования...',
  'recoveredChatsSingular': 'Успешно восстановлен {count} чат.',
  'recoveredChatsPlural': 'Успешно восстановлено {count} чатов.',
  'recoveryFailed': 'Восстановление не удалось. Попробуйте снова.',
  'deletedChatsSingular': 'Удалён {count} чат.',
  'deletedChatsPlural': 'Удалено {count} чатов.',
  'deletionFailed': 'Удаление не удалось. Попробуйте снова.',
  'recover': 'Восстановить',
  'delete': 'Удалить',
  'deleting': 'Удаление...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Установить новый пароль',
  'setNewPasswordInfo':
      'Выберите надёжный пароль для вашего аккаунта. Ваши старые чаты останутся доступны, если вы помните предыдущий пароль.',
  'setNewPasswordButton': 'Установить новый пароль',
  'noAuthenticatedUser':
      'Нет аутентифицированного пользователя после обновления пароля.',
  'failedToPreserveEncryption':
      'Не удалось сохранить старые данные шифрования. Проверьте подключение и попробуйте снова.',
  'failedToSetNewPassword':
      'Не удалось установить новый пароль. Попробуйте снова.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Параметры разработчика',
  'devOptionsToggleSubtitle':
      'Разблокировать диагностику и инструменты отладки. Отключите, чтобы скрыть все настройки для разработчиков.',
  'enableDiagnosticsLogging': 'Включить журнал диагностики',
  'enableDiagnosticsSubtitle':
      'Работает в релизных сборках. Записывает метаданные приложения и среды выполнения для устранения зависаний и проблем с треем.',
  'diagnosticsEnabled': 'Журнал диагностики включён',
  'diagnosticsDisabled': 'Журнал диагностики отключён',
  'notInitializedYet': 'Ещё не инициализирован',
  'refresh': 'Обновить',
  'copyRecent': 'Копировать недавние',
  'copyFocusedDebug': 'Копировать отчёт отладки',
  'shareFile': 'Поделиться файлом',
  'clear': 'Очистить',
  'copiedRecentLogs': 'Недавние журналы скопированы в буфер обмена',
  'noFocusedDebugData': 'Данные отладки ещё недоступны',
  'copiedFocusedDebug': 'Отчёт отладки меню модели скопирован',
  'failedFocusedDebug':
      'Не удалось создать отчёт отладки: {error}',
  'noDiagnosticsLog': 'Журнал диагностики недоступен',
  'diagnosticsLogNotFound': 'Файл журнала диагностики не найден',
  'failedToShareLog': 'Не удалось поделиться журналом диагностики: {error}',
  'diagnosticsLogCleared': 'Журнал диагностики очищен',
  'failedToClearLog': 'Не удалось очистить журнал диагностики: {error}',
  'devOptionsDisabledMsg': 'Параметры разработчика отключены.',
  'noLogsYet':
      'Журналов пока нет. Включите диагностику и используйте приложение для сбора данных.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Назад',
  'enabled': 'Включено',
  'disabled': 'Отключено',
  'modelPrompt': 'Промпт модели',
  'modelPromptHint':
      'Это описание показывается модели после обнаружения инструмента.',
  'customPromptActive': 'Пользовательский промпт активен',
  'savePrompt': 'Сохранить промпт',
  'parameters': 'Параметры',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Сведения об использовании',
  'unableToLoadUsage':
      'Не удалось загрузить сведения об использовании.',
  'usageAndBilling': 'Использование и оплата',
  'usageReadOnly':
      'Этот экран доступен только для чтения и формируется из журналов использования.',
  'period': 'Период',
  'totals': 'Итого',
  'mediaRequestsNote':
      'Запросы изображений и аудио считаются медиа-запросами и исключены из итогов текстовых токенов.',
  'noRequestsFound': 'Запросов за этот период не найдено.',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'Сессия истекла. Пожалуйста, войдите снова.',
  'free': 'Бесплатно',
  'best': 'Лучшая',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'Открыть в почтовом приложении',
  'unableToSaveImage': 'Не удалось сохранить изображение',
  'image': 'Изображение',
  'open': 'Открыть',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'Оригинал',
  'markdown': 'Markdown',
  'deleteFile': 'Удалить файл',
  'deleteFailed': 'Ошибка удаления: {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'Спросите меня о чём угодно!',
  'aiDisclaimer': 'Вы общаетесь с ИИ — он может ошибаться. Проверяйте важное.',
  'queuedLabel': 'В очереди',
  'editYourMessage': 'Редактируйте ваше сообщение...',
  'addMessageOrDocs': 'Добавьте сообщение или отправьте документы',
  'micAccessFailed': 'Не удалось получить доступ к микрофону',
  'transcriptionFailed': 'Ошибка транскрипции',
  'nothingToResend': 'Нечего переотправить',
  'freeMessagesUsed': 'Бесплатные сообщения использованы',
  'ok': 'ОК',
  'camera': 'Камера',
  'photos': 'Фото',
  'files': 'Файлы',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Модели',
  'searchModels': 'Поиск моделей...',
  'modelError': 'Ошибка: {error}',

  // ── Message bubble extras ──────────────────────────────────

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'Всего: {count}',
  'freeRemaining': 'Бесплатно: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Выбрать модель',
  'noEnabledModels': 'Нет включённых моделей',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'Новый чат',
  'workspaces': 'Рабочие области',
  'media': 'Медиа',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Менеджер медиа',
  'imageUsedInChats': 'Изображение используется в чатах',
  'imageUsedInChatsBody':
      'Это изображение используется в следующих чатах:',
  'deleteImageShowDeleted':
      'Если вы удалите это изображение, в этих чатах оно будет отображаться как «Изображение удалено».',
  'deleteImageConfirm':
      'Вы уверены, что хотите удалить это изображение?',
  'deleteAnyway': 'Всё равно удалить',
  'deleteImageTitle': 'Удалить изображение',
  'deleteImageBody':
      'Вы уверены, что хотите удалить это изображение? Это действие нельзя отменить.',
  'imageDeleted': 'Изображение удалено',
  'failedToDeleteImage': 'Не удалось удалить изображение: {error}',
  'someImagesUsedInChats': 'Некоторые изображения используются в чатах',
  'deletedImagesWarning':
      'Удалённые изображения будут отображаться как «Изображение удалено» в этих чатах.',
  'deleteAllCount': 'Удалить все {count} выбранных изображений?',
  'deleteAll': 'Удалить все',
  'deleteSelectedImages': 'Удалить выбранные изображения',
  'deleteSelectedCount':
      'Удалить {count} выбранных изображений? Это действие нельзя отменить.',
  'deletedImagesResult': 'Удалено {deleted} изображений, {failed} не удалось',
  'deletedImagesSuccess': 'Удалено {deleted} изображений',
  'downloadSelected': 'Скачать выбранные',
  'deleteSelected': 'Удалить выбранные',
  'errorLoadingImages': 'Ошибка загрузки изображений',
  'noImagesStored': 'Нет сохранённых изображений',
  'imagesAppearHere': 'Изображения из ваших чатов появятся здесь',
  'download': 'Скачать',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'Удалить {name}',
  'edit': 'Редактировать',
  'close': 'Закрыть',

  // ── Subscription dialogs ───────────────────────────────────
};
