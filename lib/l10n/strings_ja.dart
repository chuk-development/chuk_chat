// lib/l10n/strings_ja.dart
// Japanese UI strings.

const Map<String, String> stringsJa = {
  // ── Settings page ──────────────────────────────────────────
  'settings': '設定',
  'themeSettings': 'テーマ設定',
  'themeSettingsSubtitle': 'アプリのテーマ、カラー、外観を調整',
  'customization': 'カスタマイズ',
  'customizationSubtitle': 'アプリの動作と設定をカスタマイズ',
  'toolCalling': 'ツール呼び出し',
  'toolCallingSubtitle': 'ツールの使用、検出、表示を管理',
  'developerOptions': '開発者オプション',
  'developerOptionsSubtitle': '診断ログとデバッグツール',
  'modelSelection': 'モデル選択',
  'modelSelectionSubtitle': 'AIモデルの選択と設定',
  'aiIdentityMemory': 'AIのアイデンティティとメモリ',
  'aiIdentityMemorySubtitle':
      'ソウル、ユーザープロフィール、メモリ、システムプロンプト',
  'pricingPlans': '料金プラン',
  'pricingPlansSubtitle': 'サブスクリプションプランと料金を表示',
  'accountSettings': 'アカウント設定',
  'accountSettingsSubtitle': 'プロフィールとアカウントの管理',
  'exportChats': 'チャットのエクスポート',
  'exportChatsSubtitle': '会話をJSON形式でダウンロード',
  'about': 'このアプリについて',
  'aboutSubtitle': 'バージョン情報とオープンソースライセンス',
  'logout': 'ログアウト',
  'noChatsToExport': 'エクスポートするチャットがありません',
  'copiedToClipboard': 'クリップボードにコピーしました',
  'savedToPath': '{path} に保存しました',
  'exportCancelled': 'エクスポートがキャンセルされました',
  'shareOpened': '共有ダイアログを開きました',
  'exportFailed': 'エクスポートに失敗しました: {error}',
  'saveChatExport': 'チャットエクスポートを保存',

  // ── Customization page ─────────────────────────────────────
  'language': '言語',
  'languageSubtitle': 'お好みの言語を選択してください',
  'english': 'English',
  'german': 'Deutsch',
  'voiceTranscription': '音声文字起こし',
  'autoSendVoice': '音声メッセージを自動送信',
  'autoSendVoiceSubtitle':
      '文字起こしされた音声メッセージを確認なしで自動送信',
  'autoSendVoiceInfo':
      'オンにすると、音声の文字起こしは即座に送信されます。オフ（デフォルト）にすると、送信前にテキスト欄に表示され確認できます。',
  'messageDisplay': 'メッセージ表示',
  'showReasoningTokens': '推論トークンを表示',
  'showReasoningTokensSubtitle': 'AI応答の推論プロセスのトークンを表示',
  'showModelInfo': 'モデル情報を表示',
  'showModelInfoSubtitle': 'チャットメッセージにモデル名と情報を表示',
  'showTps': 'トークン/秒を表示',
  'showTpsSubtitle': 'AI応答の生成速度（TPS）を表示',
  'aiContext': 'AIコンテキスト',
  'recentImagesInContext': '最近の画像をコンテキストに含める',
  'recentImagesInContextSubtitle':
      '最近のメッセージの画像をAIモデルに送信',
  'allImagesInContext': 'すべての画像をコンテキストに含める',
  'allImagesInContextSubtitle':
      '会話内のすべての画像をAIに送信（トークンを多く消費）',
  'reasoningInContext': '推論をコンテキストに含める',
  'reasoningInContextSubtitle': 'AIの思考プロセスを会話履歴に含める',
  'aiContextInfo':
      '「最近の画像」は直近6メッセージの画像を送信します。「すべての画像」は会話内の全画像を送信します。「推論」はAIの思考プロセスを後続メッセージのコンテキストとして含めます。',
  'chatTitles': 'チャットタイトル',
  'autoGenerateTitles': 'チャットタイトルを自動生成',
  'autoGenerateTitlesSubtitle': 'AIを使用して新しいチャットのタイトルを生成',
  'titleGenerationPrompt': 'タイトル生成プロンプト',
  'usingCustomPrompt': 'カスタムプロンプトを使用中',
  'usingDefaultPrompt': 'デフォルトプロンプトを使用中',
  'titleGenInfo':
      'オンにすると、最初のメッセージに基づいて新しいチャットのタイトルが自動生成されます。高速で軽量なAIモデル（qwen3-8b）を使用します。',
  'systemPromptSaved': 'システムプロンプトを保存しました',
  'systemPromptResetToDefault': 'システムプロンプトをデフォルトにリセットしました',
  'reset': 'リセット',
  'save': '保存',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'ダークモード',
  'darkModeSubtitle': 'ダークテーマとライトテーマを切り替え',
  'accentColor': 'アクセントカラー',
  'accentColorSubtitle': 'メインのアクセントカラーを選択',
  'iconFgColor': 'アイコン/前景色',
  'iconFgColorSubtitle': 'アイコンと主要テキストの色を選択',
  'backgroundColor': '背景色',
  'backgroundColorSubtitle': 'アプリのメイン背景色を選択',
  'filmGrainEffect': 'フィルムグレインエフェクト',
  'filmGrainSubtitle': 'フィルム撮影風の微妙なテクスチャを追加',
  'customHexColor': 'カスタムHEXカラー (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'エンジン',
  'enableToolCalling': 'ツール呼び出しを有効にする',
  'enableToolCallingSubtitle':
      'アシスタントが組み込みツールを検出・実行することを許可',
  'behavior': '動作',
  'requireDiscoveryFirst': '最初に検出を要求',
  'requireDiscoverySubtitle':
      'ターン内で他のツールを許可する前にfind_toolsを要求',
  'markdownToolCallFallback': 'Markdownツール呼び出しフォールバック',
  'markdownFallbackSubtitle':
      'モデルがXMLタグを出力しない場合に```tool_callコードブロックを受け入れる',
  'display': '表示',
  'showToolActivity': 'チャットにツールの活動を表示',
  'showToolActivitySubtitle':
      'アシスタントメッセージに実行中/完了したツールのチップを表示',
  'toolCallingTip':
      'ヒント: 最良の互換性のためにMarkdownフォールバックを有効にしておいてください。厳密にXMLのみのツール呼び出しが必要な場合のみ無効にしてください。',
  'visualOutputNonTool': 'ビジュアル出力（非ツール）',
  'enableMapBlocks': '地図ブロックを有効にする (<map>)',
  'enableMapBlocksSubtitle':
      'モデルプロンプトに地図レンダリング指示を含めることを許可',
  'enableChartBlocks': 'チャートブロックを有効にする (<chart>)',
  'enableChartBlocksSubtitle':
      'モデルプロンプトにチャートレンダリング指示を含めることを許可',
  'connectors': 'コネクタ',
  'loadingToolSettings': 'ツール設定を読み込み中...',
  'noToolsRegistered': 'まだツールが登録されていません。',
  'catSearchWeb': '検索とウェブ',
  'catUtilities': 'ユーティリティ',
  'catMapsLocation': '地図と位置情報',
  'catDevice': 'デバイス',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / ターミナル',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google（カレンダー / Gmail）',
  'catEmailImapSmtp': 'メール (IMAP/SMTP)',
  'catWhoop': 'WHOOP',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'サンドボックス / コード',
  'catSearchWebDesc':
      'ウェブ検索、ページ取得、画像生成、データ検索',
  'catUtilitiesDesc':
      '電卓、時計、メモ、QRコード、その他のユーティリティ',
  'catMapsLocationDesc':
      '場所の検索、住所のジオコーディング、ルート計算',
  'catDeviceDesc': 'GPS、カレンダー、リマインダーなどのデバイス機能にアクセス',
  'catSpotifyDesc': '再生の制御とSpotifyライブラリの閲覧',
  'catBashTerminalDesc': 'デスクトップでサンドボックス化されたシェルコマンドを実行',
  'catGitHubDesc':
      'GitHubのリポジトリ、イシュー、PR、コミットにアクセス',
  'catSlackDesc':
      'メッセージの送信、チャンネルの検索、Slackデータの取得',
  'catGoogleCalGmailDesc':
      'Googleカレンダーと Gmail でスケジュールとメールを管理',
  'catEmailImapSmtpDesc': 'IMAPとSMTPでメールを送受信',
  'catWhoopDesc':
      'WHOOPの回復、ストレイン、睡眠、ワークアウトデータを表示',
  'catNextcloudDesc':
      'Nextcloudのファイル、カレンダー、連絡先を閲覧',
  'catSandboxDesc':
      '隔離されたサンドボックスでPythonまたはシェルコードを実行し、ファイルを読み書き',
  'connect': '接続',
  'disconnect': '切断',
  'disconnectCategory': '{label} を切断しますか？',
  'removeCredentialsWarning': '保存された認証情報が削除されます。',
  'cancel': 'キャンセル',
  'categoryConnected': '{label} に接続しました',
  'failedToConnect': '{label} への接続に失敗しました',
  'unableToConnect':
      '{label} に接続できません。もう一度お試しください。',
  'toolWebSearch': 'ウェブ検索',
  'toolWebCrawl': 'ウェブクロール',
  'toolImageGen': '画像生成',
  'toolFetchImage': '画像取得',
  'toolViewChatImages': 'チャット画像を表示',
  'toolCryptoData': '暗号資産データ',
  'toolWeather': '天気',
  'toolPlaceSearch': '場所検索',
  'toolRestaurantSearch': 'レストラン検索',
  'toolGeocoding': 'ジオコーディング',
  'toolRouting': 'ルート検索',
  'toolCalculator': '電卓',
  'toolClock': '時計',
  'toolRandomNumber': '乱数',
  'toolCoinFlip': 'コイントス',
  'toolDiceRoll': 'サイコロ',
  'toolCountdown': 'カウントダウン',
  'toolPasswordGen': 'パスワード生成',
  'toolUuidGen': 'UUID生成',
  'toolNotes': 'メモ',
  'toolQrGen': 'QR生成',
  'toolWhoopHealth': 'WHOOPヘルス',
  'resetToolSettingsTitle': 'ツール設定をリセットしますか？',
  'resetToolSettingsBody':
      'すべてのツールを再度有効にし、すべてのカスタムツールプロンプトをリセットします。',
  'resetAllToolPrefs': 'すべてのツール設定をリセット',

  // ── Account settings page ──────────────────────────────────
  'profile': 'プロフィール',
  'profileSubtitle':
      'Chuk Chatでの名前とメールアドレスの表示を更新します。',
  'displayName': '表示名',
  'displayNameHint': '他の人に表示される名前',
  'emailAddress': 'メールアドレス',
  'emailAddressHint': '通知の送信先',
  'security': 'セキュリティ',
  'securitySubtitle': 'すべてが保護されていることを確認しましょう。',
  'changePassword': 'パスワードを変更',
  'changePasswordSubtitle':
      'Supabaseのパスワードを更新し、保存されたチャットを再暗号化します。',
  'currentPassword': '現在のパスワード',
  'newPassword': '新しいパスワード',
  'minCharsPassword': '8文字以上。',
  'confirmNewPassword': '新しいパスワードを確認',
  'updatePassword': 'パスワードを更新',
  'encryptedChatRecovery': '暗号化チャットの復旧',
  'lockedChatsSingular': '{count} 件のチャットが以前のパスワードで暗号化されています。',
  'lockedChatsPlural': '{count} 件のチャットが以前のパスワードで暗号化されています。',
  'recoverChats': 'チャットを復旧',
  'dangerZone': '危険ゾーン',
  'dangerZoneSubtitle':
      'アカウント全体に影響する取り消し不能な操作。',
  'deleteAccountWarning':
      'アカウントを削除すると、すべてのサブスクリプションがキャンセルされ、データが削除され、元に戻すことはできません。',
  'deleteAccount': 'アカウントを削除',
  'unableToLoadProfile': '現在プロフィールを読み込めません。',
  'retry': '再試行',
  'saved': '保存しました',
  'emailUpdated':
      'メールが更新されました。Supabaseから{email}に送信されたリンクで変更を確認してください。',
  'failedToLoadProfile': 'プロフィールの読み込みに失敗しました: {error}',
  'failedToSaveProfile': 'プロフィールの保存に失敗しました: {error}',
  'emailCannotBeEmpty': 'メールアドレスは空にできません。',
  'passwordsDoNotMatch': '新しいパスワードが一致しません。',
  'failedToChangePassword': 'パスワードの変更に失敗しました: {error}',
  'deleteAccountQuestion': 'アカウントを削除しますか？',
  'deleteAccountConfirmBody':
      '本当にアカウントを削除しますか？\n\n以下が完全に削除されます：\n  \u2022 すべてのチャットとメッセージ\n  \u2022 すべての保存されたメモリ\n  \u2022 プロフィールと設定\n  \u2022 すべてのアクティブなサブスクリプション\n\nこの操作は取り消せません。データを復旧することはできません。',
  'yesDelete': 'はい、削除します',
  'thisIsPermanent': 'この操作は永久的です',
  'finalDeleteWarning':
      'これが最後のチャンスです。\n\n削除後、アカウント、チャット、メモリ、または関連データを復旧する方法は一切ありません。\n\nすべてが永久に失われます。\n\nそれでも続行しますか？',
  'noKeepMyAccount': 'いいえ、アカウントを残す',
  'deleteEverything': 'すべて削除',
  'confirmYourPassword': 'パスワードを確認',
  'confirmPasswordBody':
      'アカウント削除を確認するため、パスワードを入力してください。',
  'password': 'パスワード',
  'passwordRequired': 'パスワードは必須です',
  'verificationFailed': '認証に失敗しました: {error}',
  'verifyAndDelete': '認証して削除',
  'failedToDeleteAccount': 'アカウントの削除に失敗しました: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'アイデンティティシステム',
  'identityActive': 'ソウル、ユーザー、メモリが有効',
  'identityDisabled': '無効 — AIに永続的なアイデンティティなし',
  'soul': 'ソウル',
  'soulHint':
      'AIの性格、トーン、境界を定義します。すべての会話でのコミュニケーションスタイルを形成します。',
  'soulExample':
      '例：\n\u2022 直接的で簡潔に\n\u2022 ユーザーの言語とエネルギーに合わせる\n\u2022 意見を持ち、曖昧にしない\n\u2022 プライバシー優先：外部アクションの前に確認する',
  'user': 'ユーザー',
  'userHint':
      'あなたに関する事実。AIは毎回のメッセージでこれを読み、新しいことを学んだ時に更新することもあります。',
  'userExample':
      '例：\n\u2022 名前：アレックス\n\u2022 タイムゾーン：Europe/Berlin\n\u2022 言語：ドイツ語/英語\n\u2022 簡潔で技術的な回答を好む',
  'memory': 'メモリ',
  'memoryHint':
      '会話をまたいでAIが記憶する長期的な知識。重要な事実や決定を学んだ時にAIが更新することもあります。',
  'memoryExample':
      '例：\n\u2022 モバイルにはDart/Flutterを好む\n\u2022 ライセンス：全プロジェクトBSL\n\u2022 現在のプロジェクト：chuk_chat\n\u2022 ダークモード愛好者',
  'importFromAnotherAi': '他のAIからインポート',
  'systemPrompt': 'システムプロンプト',
  'systemPromptHint':
      'すべての会話で送信されるカスタム指示。チャット暗号化キーで暗号化されます。',
  'systemPromptExample':
      '例：あなたは親切なアシスタントです。簡潔で正確な回答を提供してください。',
  'characters': '文字',
  'saving': '保存中...',
  'saveChanges': '変更を保存',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'オープンソースライセンス',
  'openSourceLicensesSubtitle':
      'このビルドに含まれるすべての依存関係のライセンスを確認できます。',
  'legalDocuments': '法的文書',
  'termsOfService': '利用規約',
  'privacyPolicy': 'プライバシーポリシー',
  'versionText': 'バージョン {version}',
  'updateAvailable': 'アップデートあり: v{version} — タップしてダウンロード',
  'versionUnavailable': 'バージョン情報は利用できません。',
  'copyrightYear':
      '\u00a9 {year} Chuk Chat\nAll rights reserved.',
  'licenses': 'ライセンス',
  'unableToLoadLicenses': 'ライセンスを読み込めません。',
  'tapToViewLicense': 'タップしてライセンス全文を表示',
  'devOptionsEnabled': '開発者オプションが有効になりました',
  'devOptionsAlreadyEnabled': '開発者オプションは既に有効です',
  'devOptionsTapSingular': '開発者オプションまであと{taps}回タップ',
  'devOptionsTapsPlural': '開発者オプションまであと{taps}回タップ',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'サブスクリプション',
  'openUsageDetailsInfo':
      '使用状況の詳細を開いて、すべてのリクエスト、月間合計、モデルコストを確認できます。',
  'openUsageDetails': '使用状況の詳細を開く',
  'currentPlan': '現在のプラン',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/月',
  'monthlyCredits': '月間AIクレジット: \u20ac16.00',
  'unusedCreditsExpire': '未使用のクレジットは毎月末に失効します。',
  'manageBilling': '請求管理',
  'manageBillingSubtitle':
      '請求ポータルを使用して、サブスクリプションのキャンセルや支払い方法の更新ができます。',
  'subscribeToGetCredits': 'AIクレジットを取得するには登録',
  'subscriptionDesktopOnly':
      'サブスクリプション管理はデスクトップでのみ利用可能です。',
  'active': '有効',
  'getCreditsMonthly': '毎月\u20ac16のAIクレジットを取得',
  'accessAllModels': 'すべてのAIモデルにアクセス',
  'imageGeneration': '画像生成',
  'voiceMode': '音声モード',
  'textChatReasoning': '推論付きテキストチャット',
  'creditsExplanation':
      '\u20ac16のAIクレジットは、選択したモデルに応じてトークン単位で消費されます。未使用のクレジットは毎月末に失効します。',
  'immediateAccessAck':
      'Chuk Chatへの即時アクセスを希望し、サービス開始後は',
  'rightOfWithdrawal': '撤回権',
  'onceServiceBegins': 'を放棄することを承諾します。',
  'subscribeNow': '今すぐ登録',
  'alreadySubscribed': '既にアクティブなサブスクリプションがあります。',
  'opening': '開いています...',
  'agreeToTermsFirst':
      '利用規約に同意し、撤回権の放棄を承諾してください。',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Chuk Chatへようこそ',
  'signInWithEmail': 'メールアドレスでサインイン',
  'createAccountWithEmail': 'メールアドレスとパスワードでアカウントを作成',
  'supabaseNotConfigured':
      'Supabaseの認証情報が設定されていません。本番ビルドの前に更新してください。',
  'confirmEmailToContinue': '続行するにはメールを確認してください',
  'confirmEmailBody':
      '確認リンクをメールアドレスに送信しました。サインインする前にメールを開いてリンクをクリックしてください。',
  'howOthersSeeYou': '他の人に表示される名前',
  'email': 'メール',
  'emailPlaceholder': 'you@example.com',
  'confirmPassword': 'パスワードを確認',
  'forgotPassword': 'パスワードをお忘れですか？',
  'enterYourPassword': 'パスワードを入力してください。',
  'pleaseConfirmPassword': 'パスワードを確認してください。',
  'signIn': 'サインイン',
  'createAccount': 'アカウントを作成',
  'noAccountSignUp': 'アカウントをお持ちでないですか？登録',
  'haveAccountSignIn': '既にアカウントをお持ちですか？サインイン',
  'agreeToTerms': '以下に同意します：',
  'andText': 'および',
  'confirmAge16': '16歳以上であることを確認します',
  'mustAgreeToTerms':
      'アカウントを作成するには利用規約とプライバシーポリシーに同意する必要があります。',
  'mustBe16': 'このサービスを利用するには16歳以上である必要があります。',
  'unexpectedError': '予期しないエラー: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': '暗号化チャットの復旧',
  'noLockedChats': 'ロックされたチャットはありません',
  'allChatsAccessible': 'すべてのチャットにアクセスできます。',
  'recoverChatsInfo':
      '一部のチャットが以前のパスワードで暗号化されています。旧パスワードを入力して復旧するか、完全に削除してください。',
  'encryptedWithVersion': 'パスワードバージョン{version}で暗号化',
  'oldPassword': '旧パスワード',
  'enterOldPassword': '以前使用していたパスワードを入力',
  'lockedChatCountSingular': '{count} 件のロックされたチャット',
  'lockedChatCountPlural': '{count} 件のロックされたチャット',
  'deleteLockedChatsTitle': 'ロックされたチャットを削除しますか？',
  'deleteLockedChatsBodySingular':
      '旧パスワードで暗号化された{count}件のチャットを完全に削除します。\n\n削除後、このチャットは復旧できません。すべてのメッセージ、画像、添付ファイルが失われます。',
  'deleteLockedChatsBodyPlural':
      '旧パスワードで暗号化された{count}件のチャットを完全に削除します。\n\n削除後、これらのチャットは復旧できません。すべてのメッセージ、画像、添付ファイルが失われます。',
  'deletePermanently': '完全に削除',
  'areYouSure': '本当によろしいですか？',
  'confirmDeleteChats':
      '{count}件のチャットを削除しようとしています。確認のためDELETEと入力してください。',
  'typeDelete': 'DELETEと入力',
  'confirmDelete': '削除を確認',
  'pleaseEnterOldPassword': '旧パスワードを入力してください。',
  'derivingKey': '暗号化キーを生成中...',
  'recoveredChatsSingular': '{count}件のチャットを復旧しました。',
  'recoveredChatsPlural': '{count}件のチャットを復旧しました。',
  'recoveryFailed': '復旧に失敗しました。もう一度お試しください。',
  'deletedChatsSingular': '{count}件のチャットを削除しました。',
  'deletedChatsPlural': '{count}件のチャットを削除しました。',
  'deletionFailed': '削除に失敗しました。もう一度お試しください。',
  'recover': '復旧',
  'delete': '削除',
  'deleting': '削除中...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': '新しいパスワードを設定',
  'setNewPasswordInfo':
      'アカウントに強力なパスワードを設定してください。以前のパスワードを覚えていれば、旧チャットは引き続きアクセス可能です。',
  'setNewPasswordButton': '新しいパスワードを設定',
  'noAuthenticatedUser': 'パスワード更新後、認証済みユーザーが見つかりません。',
  'failedToPreserveEncryption':
      '旧暗号化データの保持に失敗しました。接続を確認してもう一度お試しください。',
  'failedToSetNewPassword':
      '新しいパスワードの設定に失敗しました。もう一度お試しください。',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': '開発者オプション',
  'devOptionsToggleSubtitle':
      '診断とデバッグツールを解除。無効にするとすべての開発者設定が非表示になります。',
  'enableDiagnosticsLogging': '診断ログを有効にする',
  'enableDiagnosticsSubtitle':
      'リリースビルドで動作。ラグやトレイの問題のトラブルシューティング用にアプリ/ランタイムのメタデータを記録します。',
  'diagnosticsEnabled': '診断ログが有効になりました',
  'diagnosticsDisabled': '診断ログが無効になりました',
  'logFile': 'ログファイル',
  'notInitializedYet': 'まだ初期化されていません',
  'refresh': '更新',
  'copyRecent': '最近のログをコピー',
  'copyFocusedDebug': 'デバッグレポートをコピー',
  'shareFile': 'ファイルを共有',
  'clear': 'クリア',
  'copiedRecentLogs': '最近のログをクリップボードにコピーしました',
  'noFocusedDebugData': 'デバッグデータはまだ利用できません',
  'copiedFocusedDebug': 'モデルメニューのデバッグレポートをコピーしました',
  'failedFocusedDebug':
      'デバッグレポートの作成に失敗しました: {error}',
  'noDiagnosticsLog': '診断ログは利用できません',
  'diagnosticsLogNotFound': '診断ログファイルが見つかりません',
  'failedToShareLog': '診断ログの共有に失敗しました: {error}',
  'diagnosticsLogCleared': '診断ログをクリアしました',
  'failedToClearLog': '診断ログのクリアに失敗しました: {error}',
  'recentLogLines': '最近のログ行',
  'devOptionsDisabledMsg': '開発者オプションが無効になりました。',
  'noLogsYet':
      'まだログがありません。診断ログを有効にし、アプリを使用してデータを収集してください。',

  // ── Connector detail page ──────────────────────────────────
  'back': '戻る',
  'enabled': '有効',
  'disabled': '無効',
  'modelPrompt': 'モデルプロンプト',
  'modelPromptHint':
      'この説明はツール検出後にモデルに表示されます。',
  'customPromptActive': 'カスタムプロンプトが有効',
  'savePrompt': 'プロンプトを保存',
  'parameters': 'パラメータ',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': '使用状況の詳細',
  'unableToLoadUsage': '現在、使用状況の詳細を読み込めません。',
  'usageAndBilling': '使用状況と請求',
  'usageReadOnly':
      'この画面は読み取り専用で、使用状況ログから取得されます。',
  'period': '期間',
  'totals': '合計',
  'mediaRequestsNote':
      '画像と音声のリクエストはメディアリクエストとして扱われ、テキストトークンの合計からは除外されます。',
  'noRequestsFound': 'この期間のリクエストは見つかりませんでした。',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'セッションが期限切れです。もう一度サインインしてください。',
  'offlineMessage':
      'オフラインのようです。インターネット接続を確認してください。',
  'cannotReachApi': 'APIサーバーに接続できません。',
  'maintenanceMessage':
      '現在メンテナンス中です。まもなく復旧します。',
  'free': '無料',
  'perMillion': '/M',
  'perRequest': '/リクエスト',
  'best': 'おすすめ',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'メールアプリで開く',
  'costLabel': 'コスト: {cost}',
  'generatedLabel': '生成: {label}',
  'unableToCopyImage': '画像をコピーできません',
  'unableToSaveImage': '画像を保存できません',
  'image': '画像',
  'openLink': 'リンクを開く',
  'openLinkConfirm':
      'アプリを離れて{url}を開きますか？',
  'open': '開く',

  // ── Misc / shared ─────────────────────────────────────────
  'contentCopied': 'コンテンツをクリップボードにコピーしました',
  'artifactCopied': 'アーティファクトをクリップボードにコピーしました',
  'fileSaved': 'ファイルを保存しました',
  'failedToExportArtifact': 'アーティファクトのエクスポートに失敗しました: {error}',
  'failedToSave': '保存に失敗しました: {error}',
  'markdownSaved': 'Markdownを保存しました',
  'original': 'オリジナル',
  'markdown': 'Markdown',
  'viewMarkdownSummary': 'Markdownサマリーを表示',
  'addSummary': 'サマリーを追加',
  'deletedFile': '削除されたファイル',
  'deleteFile': 'ファイルを削除',
  'deleteFileConfirm': '「{name}」を削除しますか？',
  'deleteFailed': '削除に失敗しました: {error}',
  'uploadedFile': 'アップロード: {name}',
  'freeMessagePlaceholder': '無料: --',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': '何でも聞いてください！',
  'editYourMessage': 'メッセージを編集...',
  'addMessageOrDocs': 'メッセージを追加またはドキュメントを送信',
  'micAccessFailed': 'マイクへのアクセスに失敗しました',
  'transcriptionFailed': '文字起こしに失敗しました',
  'replyTargetSelected': '返信先を選択しました',
  'clearReply': '返信をクリア',
  'nothingToResend': '再送信するものがありません',
  'freeMessagesUsed': '無料メッセージを使い切りました',
  'ok': 'OK',
  'camera': 'カメラ',
  'photos': '写真',
  'files': 'ファイル',

  // ── Model selector ─────────────────────────────────────────
  'models': 'モデル',
  'searchModels': 'モデルを検索...',
  'modelError': 'エラー: {error}',

  // ── Message bubble extras ──────────────────────────────────
  'copyImage': '画像をコピー',
  'downloadImage': '画像をダウンロード',
  'imageDetails': '画像の詳細',
  'imageCopied': '画像をコピーしました',

  // ── Free message display ───────────────────────────────────
  'freeMessages': '無料メッセージ',
  'freeUsed': '使用済み: {count}',
  'freeTotal': '合計: {count}',
  'subscribeToContinue': 'チャットを続けるには登録してください',
  'freeRemaining': '無料: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'モデルを選択',
  'noEnabledModels': '有効なモデルがありません',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': '新しいチャット',
  'workspaces': 'ワークスペース',
  'media': 'メディア',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'メディアマネージャー',
  'imageUsedInChats': 'チャットで使用されている画像',
  'imageUsedInChatsBody':
      'この画像は以下のチャットで使用されています：',
  'deleteImageShowDeleted':
      'この画像を削除すると、該当するチャットで「画像が削除されました」と表示されます。',
  'deleteImageConfirm':
      'この画像を削除してもよろしいですか？',
  'deleteAnyway': 'それでも削除',
  'deleteImageTitle': '画像を削除',
  'deleteImageBody':
      'この画像を削除してもよろしいですか？この操作は取り消せません。',
  'imageDeleted': '画像を削除しました',
  'failedToDeleteImage': '画像の削除に失敗しました: {error}',
  'someImagesUsedInChats': '一部の画像がチャットで使用されています',
  'deletedImagesWarning':
      '削除された画像はチャットで「画像が削除されました」と表示されます。',
  'deleteAllCount': '選択した{count}枚の画像をすべて削除しますか？',
  'deleteAll': 'すべて削除',
  'deleteSelectedImages': '選択した画像を削除',
  'deleteSelectedCount':
      '選択した{count}枚の画像を削除しますか？この操作は取り消せません。',
  'deletedImagesResult': '{deleted}枚の画像を削除、{failed}枚失敗',
  'deletedImagesSuccess': '{deleted}枚の画像を削除しました',
  'downloadSelected': '選択をダウンロード',
  'deleteSelected': '選択を削除',
  'errorLoadingImages': '画像の読み込みエラー',
  'noImagesStored': '保存された画像はありません',
  'imagesAppearHere': 'チャットで送信した画像がここに表示されます',
  'download': 'ダウンロード',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': '{name} を削除',
  'edit': '編集',
  'close': '閉じる',

  // ── Subscription dialogs ───────────────────────────────────
  'maybeLater': 'また今度',
};
