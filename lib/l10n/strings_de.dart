// lib/l10n/strings_de.dart
// German UI strings.

const Map<String, String> stringsDe = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Einstellungen',
  'themeSettings': 'Design',
  'themeSettingsSubtitle': 'App-Design, Farben und Darstellung anpassen',
  'customization': 'Anpassung',
  'customizationSubtitle': 'App-Verhalten und Einstellungen konfigurieren',
  'toolCalling': 'Tool-Aufrufe',
  'toolCallingSubtitle': 'Tool-Nutzung, Erkennung und Anzeige steuern',
  'skills': 'Skills',
  'skillsSubtitle': 'Anleitungen, die die KI bei Bedarf lädt',
  'skillsExplainer':
      'Ein Skill ist eine Anleitung, die die KI lädt, wenn sie sie braucht. In '
      'jeder Nachricht stehen nur Name und Beschreibung; die Anleitung kommt '
      'erst dazu, wenn die KI den Skill aufgreift. Danach bleibt sie im '
      'Gespräch.',
  'skillsYours': 'Deine Skills',
  'skillsYoursEmpty':
      'Du hast noch keine Skills. Leg einen an, um der KI eine Anleitung '
      'beizubringen — ein Ausgabeformat, eine Checkliste, feste Regeln für '
      'eine wiederkehrende Aufgabe.',
  'skillsBuiltin': 'Eingebaut',
  'skillNew': 'Neuer Skill',
  'skillEdit': 'Skill bearbeiten',
  'skillDeleteTitle': 'Skill löschen?',
  'skillDeleteBody':
      'Der Skill "{name}" wird auf allen deinen Geräten gelöscht. Das lässt '
      'sich nicht rückgängig machen.',
  'skillEditorHint':
      'Schreib die SKILL.md: YAML-Frontmatter zwischen ---Zeilen, danach die '
      'Anleitung als Markdown. Pflicht: name (klein, mit Bindestrichen) und '
      'description. Halt die Beschreibung kurz — sie kostet in jeder '
      'Nachricht. Optional: allowed-tools, license, compatibility, metadata.',
  'skillSaveFailed': 'Skill konnte nicht gespeichert werden',
  'developerOptions': 'Entwickleroptionen',
  'developerOptionsSubtitle': 'Diagnose-Logs und Debug-Werkzeuge',
  'modelSelection': 'Modellauswahl',
  'modelSelectionSubtitle': 'KI-Modelle auswählen und konfigurieren',
  'aiIdentityMemory': 'KI-Identität & Gedächtnis',
  'aiIdentityMemorySubtitle':
      'Seele, Benutzerprofil, Gedächtnis und Systemprompt',
  'pricingPlans': 'Preise & Abonnements',
  'pricingPlansSubtitle': 'Unsere Abonnements und Preise ansehen',
  'accountSettings': 'Kontoeinstellungen',
  'exportChats': 'Chats exportieren',
  'exportChatsSubtitle': 'Unterhaltungen als JSON herunterladen',
  'about': 'Über',
  'aboutSubtitle': 'Versionsinformationen und Open-Source-Lizenzen',
  'logout': 'Abmelden',
  'noChatsToExport': 'Keine Chats zum Exportieren',
  'copiedToClipboard': 'In die Zwischenablage kopiert',
  'savedToPath': 'Gespeichert unter {path}',
  'exportCancelled': 'Export abgebrochen',
  'shareOpened': 'Teilen geöffnet',
  'exportFailed': 'Export fehlgeschlagen: {error}',
  'saveChatExport': 'Chat-Export speichern',

  // ── Customization page ─────────────────────────────────────
  'language': 'Sprache',
  'languageSubtitle': 'Bevorzugte Sprache wählen',
  'voiceTranscription': 'Sprachtranskription',
  'autoSendVoice': 'Sprachnachrichten automatisch senden',
  'autoSendVoiceSubtitle':
      'Transkribierte Sprachnachrichten ohne Bestätigung senden',
  'autoSendVoiceInfo':
      'Wenn aktiviert, werden Sprachtranskriptionen sofort gesendet. Wenn deaktiviert (Standard), erscheinen Transkriptionen im Textfeld zur Überprüfung.',
  'messageDisplay': 'Nachrichtenanzeige',
  'showReasoningTokens': 'Reasoning-Tokens anzeigen',
  'showReasoningTokensSubtitle': 'Denkprozess-Tokens in KI-Antworten anzeigen',
  'showModelInfo': 'Modellinfo anzeigen',
  'showModelInfoSubtitle':
      'Modellname und Informationen in Chat-Nachrichten anzeigen',
  'showTps': 'Tokens pro Sekunde anzeigen',
  'showTpsSubtitle': 'KI-Antwort-Generierungsgeschwindigkeit (TPS) anzeigen',
  'chatFontSize': 'Chat-Schriftgröße',
  'chatFontSizeSubtitle':
      'Textgröße der Chatnachrichten anpassen für bessere Lesbarkeit',
  'uiScale': 'UI-Skalierung',
  'uiScaleSubtitle':
      'Skaliert die gesamte App-Oberfläche — nützlich auf hochauflösenden Bildschirmen',
  'uiScalePercentage': 'UI-Skalierung: {percent}%',
  'fontSizePreview':
      'Franz jagt im komplett verwahrlosten Taxi quer durch Bayern.',
  'chatFontFamily': 'Chat-Schriftart',
  'chatFontFamilySubtitle': 'Schriftart für Chatnachrichten auswählen',
  'fontFamilySystem': 'System-Standard',
  'fontFamilyArimo': 'Arimo (Serifenlos)',
  'fontFamilyMerriweather': 'Merriweather (Serifen)',
  'fontFamilyJetBrainsMono': 'JetBrains Mono',
  // ── Downloads-Seite ────────────────────────────────────────
  'downloads': 'Downloads',
  'downloadsSubtitle':
      'Wohin gespeicherte Dateien gehen und ob jedes Mal gefragt wird',
  'downloadsAlwaysAsk': 'Immer fragen, wo gespeichert wird',
  'downloadsAlwaysAskHintCan':
      'Ausschalten, um direkt in den Standardordner zu speichern',
  'downloadsAlwaysAskHintNoFolder':
      'Standardordner unten festlegen, um dies ausschalten zu können',
  'downloadsDefaultFolder': 'Standard-Download-Ordner',
  'downloadsDefaultFolderUnset': 'Nicht festgelegt — jeder Download fragt nach',
  'downloadsChooseFolderDialog': 'Standard-Download-Ordner wählen',
  'downloadsClear': 'Löschen',
  'downloadsInfo':
      'Diese Einstellungen gelten für jeden Download in der App — Chat-Bilder, Medien-Manager-Exporte, Artifact-Downloads und Chat-Backups.',
  'aiContext': 'KI-Kontext',
  'recentImagesInContext': 'Aktuelle Bilder im Kontext',
  'recentImagesInContextSubtitle':
      'Bilder aus letzten Nachrichten an das KI-Modell senden',
  'allImagesInContext': 'Alle Bilder im Kontext',
  'allImagesInContextSubtitle':
      'Alle Unterhaltungsbilder an die KI senden (verbraucht mehr Tokens)',
  'reasoningInContext': 'Reasoning im Kontext',
  'reasoningInContextSubtitle':
      'KI-Denkprozess in den Gesprächsverlauf einbeziehen',
  'toolResultsInContext': 'Tool-Ergebnisse im Kontext',
  'toolResultsInContextSubtitle':
      'Frühere Tool-Aufrufe und ihre Ergebnisse mitsenden, damit die KI bereits geholte Daten wiederverwendet, statt dieselben Tools erneut auszuführen',
  'aiContextInfo':
      'Aktuelle Bilder sendet die Bilder der letzten 6 Nachrichten. Alle Bilder sendet jedes Bild der Unterhaltung. Reasoning bezieht den Denkprozess der KI als Kontext für Folgenachrichten ein.',
  'chatTitles': 'Chat-Titel',
  'autoGenerateTitles': 'Chat-Titel automatisch generieren',
  'autoGenerateTitlesSubtitle':
      'KI zum Generieren von Titeln für neue Chats verwenden',
  'titleGenerationPrompt': 'Titelgenerierungs-Prompt',
  'usingCustomPrompt': 'Benutzerdefinierter Prompt aktiv',
  'usingDefaultPrompt': 'Standard-Prompt aktiv',
  'titleGenInfo':
      'Wenn aktiviert, wird automatisch ein kurzer Titel für neue Chats basierend auf Ihrer ersten Nachricht generiert. Verwendet ein schnelles, leichtgewichtiges KI-Modell (qwen3-8b).',
  'systemPromptSaved': 'Systemprompt gespeichert',
  'systemPromptResetToDefault': 'Systemprompt auf Standard zurückgesetzt',
  'reset': 'Zurücksetzen',
  'save': 'Speichern',

  // ── Pro-Modell Systemprompt ────────────────────────────────
  'perModelPromptTitle': 'Modellspezifischer Systemprompt',
  'perModelPromptHint':
      'Eine zusätzliche Anweisung, die nur greift, wenn dieses Modell ausgewählt ist. Wird verschlüsselt gespeichert.',
  'perModelPromptPlaceholder':
      'Beispiel: Antworte stets förmlich auf Deutsch und nenne Quellen.',
  'perModelPromptEdit': 'Systemprompt festlegen',
  'perModelPromptEditConfigured': 'Systemprompt bearbeiten (eingerichtet)',
  'perModelPromptRemove': 'Entfernen',
  'perModelPromptSaveFailed':
      'Modellspezifischer Prompt konnte nicht gespeichert werden.',
  'perModelPromptDeleteFailed':
      'Modellspezifischer Prompt konnte nicht entfernt werden.',
  'perModelPromptModeLabel': 'Mit globalem / Workspace-Prompt kombinieren',
  'perModelPromptModeOff': 'Aus',
  'perModelPromptModeAppend': 'Anhängen',
  'perModelPromptModePrepend': 'Voranstellen',
  'perModelPromptModeReplace': 'Ersetzen',
  'perModelPromptModeOffHint':
      'Der modellspezifische Prompt wird ignoriert — nur die globalen und Workspace-Prompts werden gesendet.',
  'perModelPromptModeAppendHint':
      'Wird nach dem globalen / Workspace-Prompt gesendet, durch einen Trenner abgesetzt.',
  'perModelPromptModePrependHint':
      'Wird vor dem globalen / Workspace-Prompt gesendet, durch einen Trenner abgesetzt.',
  'perModelPromptModeReplaceHint':
      'Ersetzt die globalen und Workspace-Prompts vollständig, solange dieses Modell ausgewählt ist.',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Dunkelmodus',
  'darkModeSubtitle': 'Zwischen dunklem und hellem Design wechseln',
  'accentColor': 'Akzentfarbe',
  'accentColorSubtitle': 'Primäre Akzentfarbe wählen',
  'iconFgColor': 'Symbol-/Vordergrundfarbe',
  'iconFgColorSubtitle': 'Farbe für Symbole und wichtigen Text wählen',
  'backgroundColor': 'Hintergrundfarbe',
  'backgroundColorSubtitle': 'Haupt-Hintergrundfarbe der App wählen',
  'filmGrainEffect': 'Filmkorn-Effekt',
  'filmGrainSubtitle': 'Subtile Filmkorn-Textur hinzufügen',
  'dynamicColor': 'Material You',
  'dynamicColorSubtitle':
      'Systemfarben verwenden und Theme-Änderungen automatisch übernehmen',
  'colorDynamicNote':
      'Wird automatisch von deiner Material-You-Systempalette festgelegt.',
  'customHexColor': 'Benutzerdefinierte Hex-Farbe (#RRGGBB)',
  'pickCustomColor': 'Eigene Farbe wählen',
  'pickAColor': 'Farbe auswählen',
  'hue': 'Farbton',
  'saturation': 'Sättigung',
  'brightness': 'Helligkeit',
  'useColor': 'Farbe verwenden',
  'searchWorkspacesHint': 'Arbeitsbereiche suchen...',
  'newWorkspace': 'Neuer Arbeitsbereich',
  'editedAt': 'Bearbeitet {date}',
  'aiDisclaimer': 'Du chattest mit einer KI — Fehler möglich, Wichtiges prüfen.',
  'archive': 'Archivieren',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Engine',
  'enableToolCalling': 'Tool-Aufrufe aktivieren',
  'enableToolCallingSubtitle':
      'Dem Assistenten erlauben, eingebaute Tools zu entdecken und auszuführen',
  'behavior': 'Verhalten',
  'requireDiscoveryFirst': 'Erkennung zuerst erforderlich',
  'requireDiscoverySubtitle':
      'find_tools vor anderen Tools in einem Zug erzwingen',
  'markdownToolCallFallback': 'Markdown-Tool-Call-Fallback',
  'markdownFallbackSubtitle':
      '```tool_call-Codeblöcke akzeptieren, wenn Modelle keine XML-Tags ausgeben',
  'display': 'Anzeige',
  'showToolActivity': 'Tool-Aktivität im Chat anzeigen',
  'showToolActivitySubtitle':
      'Laufende/abgeschlossene Tool-Chips in Assistenten-Nachrichten anzeigen',
  'toolCallingTip':
      'Tipp: Markdown-Fallback für beste Kompatibilität aktiviert lassen. Nur deaktivieren, wenn Sie ausschließlich XML-Tool-Calls möchten.',
  'enableMapBlocks': 'Kartenblöcke aktivieren (<map>)',
  'enableMapBlocksSubtitle':
      'Dem Modell-Prompt Karten-Rendering-Anweisungen erlauben',
  'enableChartBlocks': 'Diagrammblöcke aktivieren (<chart>)',
  'enableChartBlocksSubtitle':
      'Dem Modell-Prompt Diagramm-Rendering-Anweisungen erlauben',
  'loadingToolSettings': 'Tool-Einstellungen werden geladen...',
  'noToolsRegistered': 'Noch keine Tools registriert.',
  'catSearchWeb': 'Suche und Web',
  'catUtilities': 'Hilfsprogramme',
  'catMapsLocation': 'Karten und Standort',
  'catDevice': 'Gerät',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / Terminal',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Kalender / Gmail)',
  'catSandbox': 'Sandbox / Code',
  'catSearchWebDesc':
      'Web durchsuchen, Seiten abrufen, Bilder generieren und Daten nachschlagen',
  'catUtilitiesDesc':
      'Rechner, Uhr, Notizen, QR-Codes und andere Hilfsprogramme',
  'catMapsLocationDesc':
      'Orte finden, Adressen geokodieren und Routen berechnen',
  'catDeviceDesc':
      'Auf Gerätefunktionen wie GPS, Kalender und Erinnerungen zugreifen',
  'catSpotifyDesc':
      'Wiedergabe steuern und Ihre Spotify-Bibliothek durchsuchen',
  'catBashTerminalDesc': 'Sandboxed Shell-Befehle auf dem Desktop ausführen',
  'catGitHubDesc': 'Auf Repos, Issues, PRs und Commits von GitHub zugreifen',
  'catSlackDesc':
      'Nachrichten senden, Kanäle durchsuchen und Slack-Daten abrufen',
  'catGoogleCalGmailDesc':
      'Termine und E-Mails über Google Kalender und Gmail verwalten',
  'catSandboxDesc':
      'Python- oder Shell-Code in einer isolierten Sandbox ausführen und Dateien lesen/schreiben',
  'connect': 'Verbinden',
  'disconnect': 'Trennen',
  'disconnectCategory': '{label} trennen?',
  'removeCredentialsWarning':
      'Ihre gespeicherten Zugangsdaten werden entfernt.',
  'cancel': 'Abbrechen',
  'toolWebSearch': 'Websuche',
  'toolWebCrawl': 'Web-Crawl',
  'toolImageGen': 'Bildgenerierung',
  'toolFetchImage': 'Bild abrufen',
  'toolViewChatImages': 'Chat-Bilder anzeigen',
  'toolCryptoData': 'Krypto-Daten',
  'toolWeather': 'Wetter',
  'toolPlaceSearch': 'Ortssuche',
  'toolRestaurantSearch': 'Restaurantsuche',
  'toolGeocoding': 'Geokodierung',
  'toolRouting': 'Routenplanung',
  'toolCalculator': 'Rechner',
  'toolClock': 'Uhr',
  'toolRandomNumber': 'Zufallszahl',
  'toolCoinFlip': 'Münzwurf',
  'toolDiceRoll': 'Würfelwurf',
  'toolCountdown': 'Countdown',
  'toolPasswordGen': 'Passwort-Generator',
  'toolUuidGen': 'UUID-Generator',
  'toolNotes': 'Notizen',
  'toolQrGen': 'QR-Generator',
  'resetToolSettingsTitle': 'Tool-Einstellungen zurücksetzen?',
  'resetToolSettingsBody':
      'Alle Tools werden wieder aktiviert und alle benutzerdefinierten Tool-Prompts zurückgesetzt.',
  'resetAllToolPrefs': 'Alle Tool-Einstellungen zurücksetzen',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Profil',
  'displayName': 'Anzeigename',
  'displayNameHint': 'So sehen andere Sie',
  'emailAddress': 'E-Mail-Adresse',
  'emailAddressHint': 'Wohin wir Benachrichtigungen senden',
  'security': 'Sicherheit',
  'changePassword': 'Passwort ändern',
  'currentPassword': 'Aktuelles Passwort',
  'newPassword': 'Neues Passwort',
  'minCharsPassword': 'Mindestens 8 Zeichen.',
  'confirmNewPassword': 'Neues Passwort bestätigen',
  'updatePassword': 'Passwort aktualisieren',
  'encryptedChatRecovery': 'Verschlüsselte Chat-Wiederherstellung',
  'lockedChatsSingular':
      '{count} Chat mit einem früheren Passwort verschlüsselt.',
  'lockedChatsPlural':
      '{count} Chats mit einem früheren Passwort verschlüsselt.',
  'recoverOldChatsAvailable':
      'Du hast Chats, die mit einem früheren Passwort verschlüsselt sind. Gib dein altes Passwort ein, um sie zu entsperren.',
  'chatsFromPreviousPassword': 'Chats von einem früheren Passwort',
  'recoverChats': 'Chats wiederherstellen',
  'deleteAccountWarning':
      'Das Löschen Ihres Kontos beendet alle Abonnements, entfernt Ihre Daten und kann nicht rückgängig gemacht werden.',
  'deleteAccount': 'Konto löschen',
  'unableToLoadProfile': 'Ihr Profil kann derzeit nicht geladen werden.',
  'retry': 'Erneut versuchen',
  'saved': 'Gespeichert',
  'emailUpdated':
      'E-Mail aktualisiert. Bestätigen Sie die Änderung über den Link, den Supabase an {email} gesendet hat.',
  'failedToLoadProfile': 'Profil konnte nicht geladen werden: {error}',
  'failedToSaveProfile': 'Profil konnte nicht gespeichert werden: {error}',
  'emailCannotBeEmpty': 'E-Mail darf nicht leer sein.',
  'passwordsDoNotMatch': 'Neue Passwörter stimmen nicht überein.',
  'failedToChangePassword': 'Passwort konnte nicht geändert werden: {error}',
  'deleteAccountQuestion': 'Konto löschen?',
  'deleteAccountConfirmBody':
      'Sind Sie sicher, dass Sie Ihr Konto löschen möchten?\n\nDies wird unwiderruflich löschen:\n  \u2022 Alle Ihre Chats und Nachrichten\n  \u2022 Alle gespeicherten Erinnerungen\n  \u2022 Ihr Profil und Ihre Einstellungen\n  \u2022 Alle aktiven Abonnements\n\nDiese Aktion ist unwiderruflich. Ihre Daten können nicht wiederhergestellt werden.',
  'yesDelete': 'Ja, ich möchte löschen',
  'thisIsPermanent': 'Dies ist endgültig',
  'finalDeleteWarning':
      'Dies ist Ihre letzte Chance umzukehren.\n\nNach dem Löschen gibt es absolut keine Möglichkeit, Ihr Konto, Ihre Chats, Erinnerungen oder andere zugehörige Daten wiederherzustellen.\n\nAlles wird für immer verschwunden sein.\n\nMöchten Sie trotzdem fortfahren?',
  'noKeepMyAccount': 'Nein, Konto behalten',
  'deleteEverything': 'Alles löschen',
  'confirmYourPassword': 'Passwort bestätigen',
  'confirmPasswordBody':
      'Zur Bestätigung der Kontolöschung geben Sie bitte Ihr Passwort ein.',
  'password': 'Passwort',
  'passwordRequired': 'Passwort ist erforderlich',
  'verificationFailed': 'Überprüfung fehlgeschlagen: {error}',
  'verifyAndDelete': 'Überprüfen & Löschen',
  'failedToDeleteAccount': 'Konto konnte nicht gelöscht werden: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Identitätssystem',
  'identityActive': 'Seele, Benutzer und Gedächtnis sind aktiv',
  'identityDisabled': 'Deaktiviert \u2014 KI hat keine persistente Identität',
  'soul': 'Seele',
  'soulHint':
      'Definieren Sie die Persönlichkeit, den Ton und die Grenzen der KI. Dies prägt die Kommunikation über alle Unterhaltungen hinweg.',
  'soulExample':
      'Beispiel:\n\u2022 Direkt und prägnant sein\n\u2022 Sprache und Energie des Benutzers anpassen\n\u2022 Meinungen haben, nicht alles abschwächen\n\u2022 Datenschutz zuerst: vor externen Aktionen fragen',
  'user': 'Benutzer',
  'userHint':
      'Fakten über Sie. Die KI liest dies bei jeder Nachricht und kann es aktualisieren, wenn sie Neues über Sie erfährt.',
  'userExample':
      'Beispiel:\n\u2022 Name: Alex\n\u2022 Zeitzone: Europe/Berlin\n\u2022 Sprache: Deutsch/Englisch gemischt\n\u2022 Bevorzugt knappe, technische Antworten',
  'memory': 'Gedächtnis',
  'memoryHint':
      'Langzeitwissen, das die KI über Unterhaltungen hinweg behält. Die KI kann dies auch aktualisieren, wenn sie wichtige Fakten oder Entscheidungen erfährt.',
  'memoryExample':
      'Beispiel:\n\u2022 Bevorzugt Dart/Flutter für Mobilgeräte\n\u2022 Lizenz: BSL für alle Projekte\n\u2022 Aktuelles Projekt: chuk_chat\n\u2022 Dark-Mode-Enthusiast',
  'importFromAnotherAi': 'Von einer anderen KI importieren',
  'systemPrompt': 'Systemprompt',
  'systemPromptHint':
      'Benutzerdefinierte Anweisungen, die mit jeder Unterhaltung gesendet werden. Verschlüsselt mit Ihrem Chat-Verschlüsselungsschlüssel.',
  'systemPromptExample':
      'Beispiel: Du bist ein hilfreicher Assistent. Gib präzise und genaue Antworten.',
  'characters': 'Zeichen',
  'saving': 'Wird gespeichert...',
  'saveChanges': 'Änderungen speichern',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Open-Source-Lizenzen',
  'openSourceLicensesSubtitle':
      'Lizenzen aller in diesem Build enthaltenen Abhängigkeiten einsehen.',
  'termsOfService': 'Nutzungsbedingungen',
  'privacyPolicy': 'Datenschutzrichtlinie',
  'versionText': 'Version {version}',
  'builtOn': 'Erstellt am {date}',
  'updateAvailable':
      'Update verfügbar: v{version} \u2014 zum Herunterladen tippen',
  'versionUnavailable': 'Versionsinformationen nicht verfügbar.',
  'copyrightYear': '\u00a9 {year} Chuk Development\nAlle Rechte vorbehalten.',
  'licenses': 'Lizenzen',
  'unableToLoadLicenses': 'Lizenzen konnten nicht geladen werden.',
  'tapToViewLicense': 'Tippen, um den vollständigen Lizenztext anzuzeigen',
  'devOptionsEnabled': 'Entwickleroptionen aktiviert',
  'devOptionsAlreadyEnabled': 'Entwickleroptionen bereits aktiviert',
  'devOptionsTapSingular': 'Noch {taps} Mal tippen für Entwickleroptionen',
  'devOptionsTapsPlural': 'Noch {taps} Mal tippen für Entwickleroptionen',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Abonnement',
  'openUsageDetailsInfo':
      'Nutzungsdetails öffnen, um jede Anfrage, monatliche Gesamtwerte und Modellkosten zu sehen.',
  'openUsageDetails': 'Nutzungsdetails öffnen',
  'currentPlan': 'Aktueller Plan',
  'plus': 'Plus',
  'pricePerMonth': '20\u00a0\u20ac/Monat',
  'monthlyCredits': 'Monatliches KI-Guthaben: 16,00\u00a0\u20ac',
  'unusedCreditsExpire': 'Ungenutztes Guthaben verfällt am Ende jedes Monats.',
  'manageBilling': 'Abrechnung verwalten',
  'manageBillingSubtitle':
      'Verwenden Sie das Abrechnungsportal, um Ihr Abonnement zu kündigen oder Zahlungsmethoden zu aktualisieren.',
  'paymentsDisabledInBuild':
      'Direkte Zahlungen sind in diesem Build deaktiviert.',
  'active': 'AKTIV',
  'getCreditsMonthly': '16\u00a0\u20ac KI-Guthaben monatlich erhalten',
  'accessAllModels': 'Zugang zu allen KI-Modellen',
  'imageGeneration': 'Bildgenerierung',
  'voiceMode': 'Sprachmodus',
  'textChatReasoning': 'Text-Chat mit Reasoning',
  'creditsExplanation':
      'Ihre 16\u00a0\u20ac KI-Guthaben werden pro Token basierend auf dem gewählten Modell verbraucht. Ungenutztes Guthaben verfällt am Ende jedes Monats.',
  'immediateAccessAck':
      'Ich möchte sofortigen Zugang zu Chuk Chat und erkenne an, dass ich mein ',
  'rightOfWithdrawal': 'Widerrufsrecht',
  'onceServiceBegins': ' verliere, sobald der Dienst beginnt. Ich stimme den ',
  'subscribeNow': 'Jetzt abonnieren',
  'alreadySubscribed': 'Sie haben bereits ein aktives Abonnement.',
  'opening': 'Wird geöffnet...',
  'agreeToTermsFirst':
      'Bitte stimmen Sie den Bedingungen zu und bestätigen Sie den Verlust des Widerrufsrechts.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Willkommen bei Chuk Chat',
  'signInWithEmail': 'Mit E-Mail anmelden',
  'createAccountWithEmail': 'Konto mit E-Mail & Passwort erstellen',
  'supabaseNotConfigured':
      'Supabase-Zugangsdaten sind nicht konfiguriert. Aktualisieren Sie sie vor einem Produktions-Build.',
  'howOthersSeeYou': 'So sehen andere Sie',
  'email': 'E-Mail',
  'emailPlaceholder': 'sie@beispiel.de',
  'confirmPassword': 'Passwort bestätigen',
  'forgotPassword': 'Passwort vergessen?',
  'enterYourPassword': 'Geben Sie Ihr Passwort ein.',
  'pleaseConfirmPassword': 'Bitte bestätigen Sie Ihr Passwort.',
  'signIn': 'Anmelden',
  'createAccount': 'Konto erstellen',
  'noAccountSignUp': 'Noch kein Konto? Registrieren',
  'haveAccountSignIn': 'Bereits ein Konto? Anmelden',
  'agreeToTerms': 'Ich stimme den ',
  'andText': ' und der ',
  'confirmAge16': 'Ich bestätige, dass ich mindestens 16 Jahre alt bin',
  'mustAgreeToTerms':
      'Sie müssen den Nutzungsbedingungen und der Datenschutzrichtlinie zustimmen, um ein Konto zu erstellen.',
  'mustBe16':
      'Sie müssen mindestens 16 Jahre alt sein, um diesen Dienst zu nutzen.',
  'unexpectedError': 'Unerwarteter Fehler: {error}',

  // ── Email OTP verification (signup + recovery) ─────────────
  'verifyEmailTitle': 'Code eingeben',
  'verifySignupBody':
      'Wir haben einen 6-stelligen Code an {email} gesendet. Gib ihn unten ein, um dein Konto zu bestätigen.',
  'verifyRecoveryBody':
      'Wir haben einen 6-stelligen Code an {email} gesendet. Gib ihn unten ein, um dein Passwort zurückzusetzen.',
  'verificationCode': 'Bestätigungscode',
  'verificationCodeHint': '6-stelliger Code',
  'verifyButton': 'Bestätigen',
  'verifying': 'Wird bestätigt...',
  'resendCode': 'Code erneut senden',
  'resendCodeIn': 'Erneut senden in {seconds}s',
  'codeResent': 'Ein neuer Code wurde gesendet.',
  'enterVerificationCode': 'Gib den 6-stelligen Code ein.',
  'invalidCode': 'Dieser Code ist ungültig oder abgelaufen. Fordere einen neuen an.',
  'tooManyAttempts': 'Zu viele Versuche. Bitte warte einen Moment und versuche es erneut.',
  'otpVerificationFailed': 'Bestätigung fehlgeschlagen. Bitte versuche es erneut.',
  'changeEmailAddress': 'Andere E-Mail verwenden',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'Verschlüsselte Chats wiederherstellen',
  'noLockedChats': 'Keine gesperrten Chats',
  'allChatsAccessible': 'Alle Ihre Chats sind zugänglich.',
  'recoverChatsInfo':
      'Einige Chats sind mit einem früheren Passwort verschlüsselt. Geben Sie Ihr altes Passwort ein, um sie wiederherzustellen, oder löschen Sie sie dauerhaft.',
  'encryptedWithVersion': 'Verschlüsselt mit Passwort-Version {version}',
  'oldPassword': 'Altes Passwort',
  'enterOldPassword': 'Geben Sie das zuvor verwendete Passwort ein',
  'lockedChatCountSingular': '{count} gesperrter Chat',
  'lockedChatCountPlural': '{count} gesperrte Chats',
  'deleteLockedChatsTitle': 'Gesperrte Chats löschen?',
  'deleteLockedChatsBodySingular':
      'Dies wird {count} Chat, der mit Ihrem alten Passwort verschlüsselt ist, dauerhaft löschen.\n\nDieser Chat kann nach dem Löschen nicht wiederhergestellt werden. Sie verlieren alle Nachrichten, Bilder und Anhänge.',
  'deleteLockedChatsBodyPlural':
      'Dies wird {count} Chats, die mit Ihrem alten Passwort verschlüsselt sind, dauerhaft löschen.\n\nDiese Chats können nach dem Löschen nicht wiederhergestellt werden. Sie verlieren alle Nachrichten, Bilder und Anhänge.',
  'deletePermanently': 'Dauerhaft löschen',
  'areYouSure': 'Sind Sie sicher?',
  'confirmDeleteChats':
      'Sie sind dabei, {count} Chats zu löschen. Geben Sie LÖSCHEN ein, um zu bestätigen.',
  'typeDelete': 'LÖSCHEN eingeben',
  'confirmDelete': 'Löschen bestätigen',
  'pleaseEnterOldPassword': 'Bitte geben Sie Ihr altes Passwort ein.',
  'derivingKey': 'Verschlüsselungsschlüssel wird abgeleitet...',
  'recoveredChatsSingular': '{count} Chat erfolgreich wiederhergestellt.',
  'recoveredChatsPlural': '{count} Chats erfolgreich wiederhergestellt.',
  'recoveryFailed':
      'Wiederherstellung fehlgeschlagen. Bitte versuchen Sie es erneut.',
  'deletedChatsSingular': '{count} Chat gelöscht.',
  'deletedChatsPlural': '{count} Chats gelöscht.',
  'deletionFailed': 'Löschen fehlgeschlagen. Bitte versuchen Sie es erneut.',
  'recover': 'Wiederherstellen',
  'delete': 'Löschen',
  'deleting': 'Wird gelöscht...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Neues Passwort festlegen',
  'setNewPasswordInfo':
      'Wählen Sie ein starkes Passwort für Ihr Konto. Ihre alten Chats bleiben zugänglich, wenn Sie sich an Ihr vorheriges Passwort erinnern.',
  'setNewPasswordButton': 'Neues Passwort festlegen',
  'noAuthenticatedUser':
      'Kein authentifizierter Benutzer nach Passwort-Aktualisierung.',
  'failedToPreserveEncryption':
      'Alte Verschlüsselungsdaten konnten nicht erhalten werden. Bitte überprüfen Sie Ihre Verbindung und versuchen Sie es erneut.',
  'failedToSetNewPassword':
      'Neues Passwort konnte nicht festgelegt werden. Bitte versuchen Sie es erneut.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Entwickleroptionen',
  'devOptionsToggleSubtitle':
      'Diagnose- und Debug-Werkzeuge freischalten. Deaktivieren, um alle Entwickler-Einstellungen auszublenden.',
  'enableDiagnosticsLogging': 'Diagnose-Protokollierung aktivieren',
  'enableDiagnosticsSubtitle':
      'Funktioniert in Release-Builds. Protokolliert App-/Laufzeit-Metadaten zur Fehlerbehebung.',
  'diagnosticsEnabled': 'Diagnose-Protokollierung aktiviert',
  'diagnosticsDisabled': 'Diagnose-Protokollierung deaktiviert',
  'notInitializedYet': 'Noch nicht initialisiert',
  'refresh': 'Aktualisieren',
  'copyRecent': 'Letzte kopieren',
  'copyFocusedDebug': 'Fokussierten Debug kopieren',
  'shareFile': 'Datei teilen',
  'clear': 'Löschen',
  'copiedRecentLogs': 'Letzte Logs in Zwischenablage kopiert',
  'noFocusedDebugData': 'Noch keine fokussierten Debug-Daten verfügbar',
  'copiedFocusedDebug': 'Fokussierten Modell-Menü-Debug-Report kopiert',
  'failedFocusedDebug':
      'Fokussierter Debug-Report konnte nicht erstellt werden: {error}',
  'noDiagnosticsLog': 'Kein Diagnose-Log verfügbar',
  'diagnosticsLogNotFound': 'Diagnose-Logdatei nicht gefunden',
  'failedToShareLog': 'Diagnose-Log konnte nicht geteilt werden: {error}',
  'diagnosticsLogCleared': 'Diagnose-Log gelöscht',
  'failedToClearLog': 'Diagnose-Log konnte nicht gelöscht werden: {error}',
  'devOptionsDisabledMsg': 'Entwickleroptionen deaktiviert.',
  'noLogsYet':
      'Noch keine Logs. Aktivieren Sie die Diagnose-Protokollierung und verwenden Sie die App, um Daten zu sammeln.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Zurück',
  'enabled': 'Aktiviert',
  'disabled': 'Deaktiviert',
  'modelPrompt': 'Modell-Prompt',
  'modelPromptHint':
      'Diese Beschreibung wird dem Modell nach der Tool-Erkennung angezeigt.',
  'customPromptActive': 'Benutzerdefinierter Prompt aktiv',
  'savePrompt': 'Prompt speichern',
  'parameters': 'Parameter',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Nutzungsdetails',
  'unableToLoadUsage': 'Nutzungsdetails können derzeit nicht geladen werden.',
  'usageAndBilling': 'Nutzung und Abrechnung',
  'usageReadOnly':
      'Dieser Bildschirm ist schreibgeschützt und wird aus Ihren Nutzungsprotokollen abgerufen.',
  'period': 'Zeitraum',
  'totals': 'Gesamtwerte',
  'mediaRequestsNote':
      'Bild- und Audio-Anfragen werden als Medien-Anfragen behandelt und von den Text-Token-Gesamtwerten ausgeschlossen.',
  'noRequestsFound': 'Keine Anfragen für diesen Zeitraum gefunden.',
  'cachedTokens': 'Gecachte Tokens',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'Sitzung abgelaufen. Bitte melden Sie sich erneut an.',
  'free': 'Kostenlos',
  'best': 'Beste',
  'autoCheapest': 'Auto (günstigster)',
  'autoCheapestCurrently': 'Auto (günstigster) — aktuell: {provider} ({price})',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'In Mail-App öffnen',
  'unableToSaveImage': 'Bild konnte nicht gespeichert werden',
  'image': 'Bild',
  'open': 'Öffnen',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'Original',
  'markdown': 'Markdown',
  'deleteFile': 'Datei löschen',
  'deleteFailed': 'Löschen fehlgeschlagen: {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'Frag mich alles!',
  'queuedLabel': 'In Warteschlange',
  'editYourMessage': 'Nachricht bearbeiten...',
  'addMessageOrDocs': 'Nachricht oder Dokumente senden',
  'micAccessFailed': 'Mikrofonzugriff fehlgeschlagen',
  'transcriptionFailed': 'Transkription fehlgeschlagen',
  'nothingToResend': 'Nichts zum erneuten Senden',
  'freeMessagesUsed': 'Kostenlose Nachrichten aufgebraucht',
  'ok': 'OK',
  'camera': 'Kamera',
  'photos': 'Fotos',
  'files': 'Dateien',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Modelle',
  'searchModels': 'Modelle suchen...',
  'modelError': 'Fehler: {error}',

  // ── Message bubble extras ──────────────────────────────────
  'generatingImage': 'Wird generiert…',

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'Gesamt: {count}',
  'freeRemaining': 'Kostenlos: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Modell wählen',
  'noEnabledModels': 'Keine aktivierten Modelle',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'Neuer Chat',
  'workspaces': 'Arbeitsbereiche',
  'media': 'Medien',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Medienverwaltung',
  'imageUsedInChats': 'Bild in Chats verwendet',
  'imageUsedInChatsBody': 'Dieses Bild wird in folgenden Chats verwendet:',
  'deleteImageShowDeleted':
      'Wenn Sie dieses Bild löschen, wird es in diesen Chats als „Bild gelöscht" angezeigt.',
  'deleteImageConfirm': 'Möchten Sie dieses Bild wirklich löschen?',
  'deleteAnyway': 'Trotzdem löschen',
  'deleteImageTitle': 'Bild löschen',
  'deleteImageBody':
      'Möchten Sie dieses Bild wirklich löschen? Diese Aktion kann nicht rückgängig gemacht werden.',
  'imageDeleted': 'Bild gelöscht',
  'failedToDeleteImage': 'Bild konnte nicht gelöscht werden: {error}',
  'someImagesUsedInChats': 'Einige Bilder werden in Chats verwendet',
  'deletedImagesWarning':
      'Gelöschte Bilder werden in diesen Chats als „Bild gelöscht" angezeigt.',
  'deleteAllCount': 'Alle {count} ausgewählten Bilder löschen?',
  'deleteAll': 'Alle löschen',
  'deleteSelectedImages': 'Ausgewählte Bilder löschen',
  'deleteSelectedCount':
      '{count} ausgewählte Bilder löschen? Diese Aktion kann nicht rückgängig gemacht werden.',
  'deletedImagesResult': '{deleted} Bilder gelöscht, {failed} fehlgeschlagen',
  'deletedImagesSuccess': '{deleted} Bilder gelöscht',
  'downloadSelected': 'Ausgewählte herunterladen',
  'deleteSelected': 'Ausgewählte löschen',
  'errorLoadingImages': 'Fehler beim Laden der Bilder',
  'noImagesStored': 'Keine Bilder gespeichert',
  'imagesAppearHere': 'Bilder, die Sie in Chats senden, erscheinen hier',
  'download': 'Herunterladen',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': '{name} entfernen',
  'edit': 'Bearbeiten',
  'close': 'Schließen',

  // ── Subscription dialogs ───────────────────────────────────

  // ── Workspace (project) detail ─────────────────────────────
  'projectPrivate': 'Privat',
  'projectPublic': 'Öffentlich',
  'projectKnowledge': 'Projektwissen',
  'projectInstructions': 'Benutzerdefinierte Anweisungen',
  'projectInstructionsEmpty': 'Noch keine Anweisungen',
  'projectInstructionsSubtitle':
      'Wird der KI zu Beginn jedes Chats in diesem Projekt gesendet.',
  'projectLatestChats': 'Neueste Chats',
  'projectNoChatsHint': 'Starte einen neuen Chat mit diesem Projekt.',
  'projectNewChat': 'Neuer Chat',
  'projectFileCountSingular': '{count} Datei',
  'projectFileCountPlural': '{count} Dateien',
  'projectNoFiles': 'Noch keine Dateien',
  'projectAddContent': 'Inhalt hinzufügen',
  'projectUploadFromDevice': 'Vom Gerät hochladen',
  'projectTakePhoto': 'Foto aufnehmen',
  'projectPickImage': 'Bild auswählen',
  'projectCreateDocument': 'Neues Dokument erstellen',
  'projectNewDocument': 'Neues Dokument',
  'projectDocumentTitleHint': 'z. B. Besprechungsnotizen',
  'projectDocumentContentHint': 'Tippe los…',
  'projectEditProject': 'Projekt bearbeiten',
  'projectDeleteProject': 'Projekt löschen',
  'projectDeleteProjectBody':
      'Dieses Projekt löschen? Chats und Dateien bleiben erhalten.',
  'projectWorkspaceNotFound': 'Projekt nicht gefunden',
  'projectName': 'Name',
  'projectDescriptionLabel': 'Beschreibung',
  'projectDiscardChangesTitle': 'Änderungen verwerfen?',
  'projectDiscardChangesBody': 'Deine Änderungen wurden nicht gespeichert.',
  'projectKeepEditing': 'Weiter bearbeiten',
  'projectDiscardAction': 'Verwerfen',
  'projectSaveFailed': 'Speichern fehlgeschlagen: {error}',
  'projectLoadFailed': 'Laden fehlgeschlagen: {error}',
  'projectDeleteFailed': 'Löschen fehlgeschlagen: {error}',
  'projectUploaded': 'Hochgeladen: {name}',
  'projectCameraFailed': 'Kamera fehlgeschlagen: {error}',
  'projectImagePickFailed': 'Bildauswahl fehlgeschlagen: {error}',
  'projectContextBudgetTitle': 'Kontextbudget-Warnung',
  'projectContextBudgetBody':
      'Diese Datei (~{tokens} Tokens) überschreitet möglicherweise das Kontextbudget. Trotzdem hochladen?',
  'projectUploadAnyway': 'Trotzdem hochladen',
  'projectEncryptingUploading': 'Verschlüsseln und hochladen…',
  'projectConvertingMarkdown': 'Nach Markdown konvertieren…',
  'projectDeleteFileTitle': 'Datei löschen',
  'projectDeleteFileBody': '„{name}" löschen?',
  'projectView': 'Anzeigen',
  'projectNotSupportedPlatform': 'Auf dieser Plattform nicht unterstützt.',
  'projectEditProjectTitle': 'Projekt bearbeiten',
  // ── Offline-Warteschlange ──────────────────────────────────
  'messagePending': 'Wird gesendet sobald online',
  'messageFailed': 'Senden fehlgeschlagen',
  'messageRetry': 'Erneut versuchen',

  // ── Onboarding ─────────────────────────────────────────────
  'onboardingReplayTile': 'Onboarding erneut anzeigen',
  'onboardingReplayTileSubtitle': 'Begrüßungstour erneut abspielen',

  // Interaktive Tour (Banner über der echten UI)
  'tourSkip': 'Überspringen',
  'tourEndTour': 'Tour beenden',
  'tourContinue': 'Weiter',
  'tourGetStarted': "Los geht's",
  'tourFinish': 'Fertig',
  'tourWelcomeTitle': 'Willkommen bei Chuk Chat',
  'tourWelcomeBody':
      'Ende-zu-Ende verschlüsselter AI-Chat. Zuerst musst du ein Modell auswählen — ich zeige dir wo.',
  'tourModelTitle': 'Modell wählen — Pflicht',
  'tourSettingsModelBody':
      'Tippe auf Modellauswahl, um den Picker zu öffnen. Du brauchst in der Regel ein Modell und einen Anbieter, um chatten zu können.',
  'tourSettingsTitle': 'Personalisiere die App',
  'tourSettingsPageBody':
      'Personalisiere die App: Theme, Schrift, UI-Skalierung, Konto.',
  'tourSettingsTapHere': 'Tippe hier auf Einstellungen.',
  'tourMenuTitle': 'Menü öffnen',
  'tourMenuBody': 'Tippe auf das Menü-Icon, um Einstellungen zu finden.',
  'tourProviderPillBody':
      'Wähle einen Anbieter für ein Modell — der Anbieter aktiviert es. Auto (günstigster) ist die Voreinstellung.',
  'tourSettingsPricingTitle': 'Abo',
  'tourSettingsPricingBody':
      'Hier kannst du ein Abo abschließen — direkt bezahlen, kein App-Store-Zwischenhändler.',
  'tourSettingsAiIdentityTitle': 'AI-Verhalten',
  'tourSettingsAiIdentityBody':
      'Hier konfigurierst du System-Prompt, Memory an/aus und Reasoning.',
  'tourDoneTitle': 'Alles bereit',
  'tourDoneBody':
      'Du kannst diese Tour jederzeit in den Einstellungen erneut starten.',
  // ── Akku-Optimierung ─────────────────────────────────────────
  'batteryOptimizationTitle': 'Antworten am Laufen halten',
  'batteryOptimizationBody':
      'Android kann Chuk Chat pausieren, sobald der Bildschirm gesperrt ist, '
      'und bricht so lange AI-Antworten und Tool-Schritte mittendrin ab. '
      'Erlaube uneingeschränkte Hintergrundaktivität, damit Antworten auch '
      'bei gesperrtem Handy fertig werden.',
  'batteryOptimizationAllow': 'Erlauben',
  'batteryOptimizationLater': 'Später',
  'bashSandboxFolder': 'Sandbox-Ordner',
  'bashSandboxFolderUnset': 'Nicht gesetzt — bash-Befehle werden abgelehnt',
  'bashSandboxChooseDialog': 'Bash-Sandbox-Ordner wählen',
};
