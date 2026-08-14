// lib/l10n/strings_fr.dart
// French UI strings.

const Map<String, String> stringsFr = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Paramètres',
  'themeSettings': 'Paramètres du thème',
  'themeSettingsSubtitle':
      'Ajuster le thème, les couleurs et l\'apparence de l\'application',
  'customization': 'Personnalisation',
  'customizationSubtitle':
      'Configurer le comportement et les préférences de l\'application',
  'toolCalling': 'Appel d\'outils',
  'toolCallingSubtitle':
      'Contrôler l\'utilisation, la découverte et l\'affichage des appels d\'outils',
  'developerOptions': 'Options développeur',
  'developerOptionsSubtitle':
      'Journaux de diagnostic et outils de débogage',
  'modelSelection': 'Sélection du modèle',
  'modelSelectionSubtitle':
      'Choisir et configurer vos modèles d\'IA',
  'aiIdentityMemory': 'Identité et mémoire de l\'IA',
  'aiIdentityMemorySubtitle':
      'Âme, profil utilisateur, mémoire et prompt système',
  'pricingPlans': 'Tarifs',
  'pricingPlansSubtitle':
      'Consulter nos abonnements et nos tarifs',
  'accountSettings': 'Paramètres du compte',
  'exportChats': 'Exporter les conversations',
  'exportChatsSubtitle':
      'Télécharger vos conversations au format JSON',
  'about': 'À propos',
  'aboutSubtitle': 'Détails de version et licences open source',
  'logout': 'Déconnexion',
  'noChatsToExport': 'Aucune conversation à exporter',
  'copiedToClipboard': 'Copié dans le presse-papiers',
  'savedToPath': 'Enregistré dans {path}',
  'exportCancelled': 'Export annulé',
  'shareOpened': 'Partage ouvert',
  'exportFailed': 'Échec de l\'export : {error}',
  'saveChatExport': 'Enregistrer l\'export des conversations',

  // ── Customization page ─────────────────────────────────────
  'language': 'Langue',
  'languageSubtitle': 'Choisir votre langue préférée',
  'voiceTranscription': 'Transcription vocale',
  'autoSendVoice': 'Envoi automatique des messages vocaux',
  'autoSendVoiceSubtitle':
      'Envoyer automatiquement les messages vocaux transcrits sans confirmation',
  'autoSendVoiceInfo':
      'Lorsque cette option est activée, les transcriptions vocales sont envoyées immédiatement. Lorsqu\'elle est désactivée (par défaut), les transcriptions apparaissent dans le champ de texte pour relecture avant envoi.',
  'messageDisplay': 'Affichage des messages',
  'showReasoningTokens': 'Afficher les tokens de raisonnement',
  'showReasoningTokensSubtitle':
      'Afficher les tokens du processus de raisonnement dans les réponses de l\'IA',
  'showModelInfo': 'Afficher les infos du modèle',
  'showModelInfoSubtitle':
      'Afficher le nom et les informations du modèle dans les messages',
  'showTps': 'Afficher les tokens par seconde',
  'showTpsSubtitle':
      'Afficher la vitesse de génération des réponses de l\'IA (TPS)',
  'aiContext': 'Contexte de l\'IA',
  'recentImagesInContext': 'Images récentes dans le contexte',
  'recentImagesInContextSubtitle':
      'Envoyer les images des messages récents au modèle d\'IA',
  'allImagesInContext': 'Toutes les images dans le contexte',
  'allImagesInContextSubtitle':
      'Envoyer toutes les images de la conversation à l\'IA (consomme plus de tokens)',
  'reasoningInContext': 'Raisonnement dans le contexte',
  'reasoningInContextSubtitle':
      'Inclure le processus de réflexion de l\'IA dans l\'historique de conversation',
  'aiContextInfo':
      'Images récentes envoie les images des 6 derniers messages. Toutes les images envoie chaque image de la conversation. Raisonnement inclut le processus de réflexion de l\'IA comme contexte pour les messages suivants.',
  'chatTitles': 'Titres des conversations',
  'autoGenerateTitles':
      'Générer automatiquement les titres des conversations',
  'autoGenerateTitlesSubtitle':
      'Utiliser l\'IA pour générer des titres pour les nouvelles conversations',
  'titleGenerationPrompt': 'Prompt de génération de titre',
  'usingCustomPrompt': 'Utilise un prompt personnalisé',
  'usingDefaultPrompt': 'Utilise le prompt par défaut',
  'titleGenInfo':
      'Lorsque cette option est activée, un titre court sera automatiquement généré pour les nouvelles conversations en fonction de votre premier message. Utilise un modèle d\'IA rapide et léger (qwen3-8b).',
  'systemPromptSaved': 'Prompt système enregistré',
  'systemPromptResetToDefault':
      'Prompt système réinitialisé aux valeurs par défaut',
  'reset': 'Réinitialiser',
  'save': 'Enregistrer',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Mode sombre',
  'darkModeSubtitle': 'Basculer entre le thème sombre et clair',
  'accentColor': 'Couleur d\'accentuation',
  'accentColorSubtitle':
      'Choisir votre couleur d\'accentuation principale',
  'iconFgColor': 'Couleur des icônes/premier plan',
  'iconFgColorSubtitle':
      'Choisir la couleur des icônes et du texte principal',
  'backgroundColor': 'Couleur de fond',
  'backgroundColorSubtitle':
      'Choisir la couleur de fond principale de l\'application',
  'filmGrainEffect': 'Effet grain de film',
  'filmGrainSubtitle': 'Ajouter une texture subtile de film argentique',
  'customHexColor': 'Couleur hexadécimale personnalisée (#RRVVBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Moteur',
  'enableToolCalling': 'Activer l\'appel d\'outils',
  'enableToolCallingSubtitle':
      'Permettre à l\'assistant de découvrir et d\'exécuter les outils intégrés',
  'behavior': 'Comportement',
  'requireDiscoveryFirst': 'Exiger la découverte d\'abord',
  'requireDiscoverySubtitle':
      'Forcer find_tools avant que d\'autres outils ne soient autorisés dans un tour',
  'markdownToolCallFallback':
      'Solution de repli Markdown pour les appels d\'outils',
  'markdownFallbackSubtitle':
      'Accepter les blocs de code ```tool_call lorsque les modèles n\'émettent pas de balises XML',
  'display': 'Affichage',
  'showToolActivity': 'Afficher l\'activité des outils dans le chat',
  'showToolActivitySubtitle':
      'Afficher les pastilles d\'outils en cours/terminés dans les messages de l\'assistant',
  'toolCallingTip':
      'Astuce : Laissez la solution de repli Markdown activée pour une meilleure compatibilité. Désactivez-la uniquement si vous souhaitez des appels d\'outils strictement XML.',
  'enableMapBlocks': 'Activer les blocs carte (<map>)',
  'enableMapBlocksSubtitle':
      'Autoriser le prompt du modèle à inclure des instructions de rendu de carte',
  'enableChartBlocks': 'Activer les blocs graphique (<chart>)',
  'enableChartBlocksSubtitle':
      'Autoriser le prompt du modèle à inclure des instructions de rendu de graphique',
  'loadingToolSettings':
      'Chargement des paramètres des outils...',
  'noToolsRegistered': 'Aucun outil n\'est encore enregistré.',
  'catSearchWeb': 'Recherche et Web',
  'catUtilities': 'Utilitaires',
  'catMapsLocation': 'Cartes et localisation',
  'catDevice': 'Appareil',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / Terminal',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Agenda / Gmail)',
  'catEmailImapSmtp': 'E-mail (IMAP/SMTP)',
  'catNextcloud': 'Nextcloud',
  'catSandbox': 'Sandbox / Code',
  'catSearchWebDesc':
      'Rechercher sur le web, récupérer des pages, générer des images et consulter des données',
  'catUtilitiesDesc':
      'Calculatrice, horloge, notes, codes QR et autres utilitaires',
  'catMapsLocationDesc':
      'Trouver des lieux, géocoder des adresses et calculer des itinéraires',
  'catDeviceDesc':
      'Accéder aux fonctionnalités de l\'appareil comme le GPS, le calendrier et les rappels',
  'catSpotifyDesc':
      'Contrôler la lecture et parcourir votre bibliothèque Spotify',
  'catBashTerminalDesc':
      'Exécuter des commandes shell en bac à sable sur le bureau',
  'catGitHubDesc':
      'Accéder aux dépôts, issues, PRs et commits depuis GitHub',
  'catSlackDesc':
      'Envoyer des messages, rechercher des canaux et récupérer des données Slack',
  'catGoogleCalGmailDesc':
      'Gérer votre emploi du temps et vos e-mails via Google Agenda et Gmail',
  'catEmailImapSmtpDesc':
      'Envoyer et recevoir des e-mails via IMAP et SMTP',
  'catNextcloudDesc':
      'Parcourir les fichiers, le calendrier et les contacts sur Nextcloud',
  'catSandboxDesc':
      'Exécuter du code Python ou shell dans un bac à sable isolé et lire/écrire des fichiers',
  'connect': 'Connecter',
  'disconnect': 'Déconnecter',
  'disconnectCategory': 'Déconnecter {label} ?',
  'removeCredentialsWarning':
      'Cela supprimera vos identifiants enregistrés.',
  'cancel': 'Annuler',
  'toolWebSearch': 'Recherche Web',
  'toolWebCrawl': 'Exploration Web',
  'toolImageGen': 'Génération d\'images',
  'toolFetchImage': 'Récupérer une image',
  'toolViewChatImages': 'Voir les images du chat',
  'toolCryptoData': 'Données crypto',
  'toolWeather': 'Météo',
  'toolPlaceSearch': 'Recherche de lieux',
  'toolRestaurantSearch': 'Recherche de restaurants',
  'toolGeocoding': 'Géocodage',
  'toolRouting': 'Itinéraire',
  'toolCalculator': 'Calculatrice',
  'toolClock': 'Horloge',
  'toolRandomNumber': 'Nombre aléatoire',
  'toolCoinFlip': 'Pile ou face',
  'toolDiceRoll': 'Lancer de dés',
  'toolCountdown': 'Compte à rebours',
  'toolPasswordGen': 'Générateur de mots de passe',
  'toolUuidGen': 'Générateur d\'UUID',
  'toolNotes': 'Notes',
  'toolQrGen': 'Générateur de QR',
  'resetToolSettingsTitle':
      'Réinitialiser les paramètres des outils ?',
  'resetToolSettingsBody':
      'Cela réactivera tous les outils et réinitialisera tous les prompts d\'outils personnalisés.',
  'resetAllToolPrefs':
      'Réinitialiser toutes les préférences d\'outils',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Profil',
  'displayName': 'Nom d\'affichage',
  'displayNameHint': 'Comment les autres vous voient',
  'emailAddress': 'Adresse e-mail',
  'emailAddressHint': 'Où nous envoyons les notifications',
  'security': 'Sécurité',
  'changePassword': 'Changer le mot de passe',
  'currentPassword': 'Mot de passe actuel',
  'newPassword': 'Nouveau mot de passe',
  'minCharsPassword': 'Minimum 8 caractères.',
  'confirmNewPassword': 'Confirmer le nouveau mot de passe',
  'updatePassword': 'Mettre à jour le mot de passe',
  'encryptedChatRecovery':
      'Récupération des conversations chiffrées',
  'lockedChatsSingular':
      '{count} conversation chiffrée avec un ancien mot de passe.',
  'lockedChatsPlural':
      '{count} conversations chiffrées avec un ancien mot de passe.',
  'recoverChats': 'Récupérer les conversations',
  'deleteAccountWarning':
      'La suppression de votre compte annulera tous les abonnements, supprimera vos données et ne pourra pas être annulée.',
  'deleteAccount': 'Supprimer le compte',
  'unableToLoadProfile':
      'Impossible de charger votre profil pour le moment.',
  'retry': 'Réessayer',
  'saved': 'Enregistré',
  'emailUpdated':
      'E-mail mis à jour. Confirmez le changement en utilisant le lien envoyé par Supabase à {email}.',
  'failedToLoadProfile':
      'Échec du chargement du profil : {error}',
  'failedToSaveProfile':
      'Échec de l\'enregistrement du profil : {error}',
  'emailCannotBeEmpty': 'L\'adresse e-mail ne peut pas être vide.',
  'passwordsDoNotMatch':
      'Les nouveaux mots de passe ne correspondent pas.',
  'failedToChangePassword':
      'Échec du changement de mot de passe : {error}',
  'deleteAccountQuestion': 'Supprimer le compte ?',
  'deleteAccountConfirmBody':
      'Êtes-vous sûr de vouloir supprimer votre compte ?\n\nCela supprimera définitivement :\n  \u2022 Toutes vos conversations et messages\n  \u2022 Toutes les mémoires enregistrées\n  \u2022 Votre profil et vos paramètres\n  \u2022 Tous les abonnements actifs\n\nCette action est irréversible. Vos données ne pourront pas être récupérées.',
  'yesDelete': 'Oui, je veux supprimer',
  'thisIsPermanent': 'C\'est définitif',
  'finalDeleteWarning':
      'C\'est votre dernière chance de revenir en arrière.\n\nUne fois supprimé, il n\'y a absolument aucun moyen de récupérer votre compte, vos conversations, vos mémoires ou toute donnée associée.\n\nTout sera perdu pour toujours.\n\nVoulez-vous quand même continuer ?',
  'noKeepMyAccount': 'Non, garder mon compte',
  'deleteEverything': 'Tout supprimer',
  'confirmYourPassword': 'Confirmez votre mot de passe',
  'confirmPasswordBody':
      'Pour confirmer la suppression du compte, veuillez entrer votre mot de passe.',
  'password': 'Mot de passe',
  'passwordRequired': 'Le mot de passe est requis',
  'verificationFailed':
      'Échec de la vérification : {error}',
  'verifyAndDelete': 'Vérifier et supprimer',
  'failedToDeleteAccount':
      'Échec de la suppression du compte : {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Système d\'identité',
  'identityActive': 'Âme, utilisateur et mémoire sont actifs',
  'identityDisabled':
      'Désactivé \u2014 l\'IA n\'a pas d\'identité persistante',
  'soul': 'Âme',
  'soulHint':
      'Définir la personnalité, le ton et les limites de l\'IA. Cela façonne sa façon de communiquer dans toutes les conversations.',
  'soulExample':
      'Exemple :\n\u2022 Être direct et concis\n\u2022 S\'adapter à la langue et à l\'énergie de l\'utilisateur\n\u2022 Avoir des opinions, ne pas tout relativiser\n\u2022 Confidentialité d\'abord : demander avant toute action externe',
  'user': 'Utilisateur',
  'userHint':
      'Des informations sur vous. L\'IA les lit à chaque message et peut les mettre à jour lorsqu\'elle apprend de nouvelles choses sur vous.',
  'userExample':
      'Exemple :\n\u2022 Nom : Alex\n\u2022 Fuseau horaire : Europe/Berlin\n\u2022 Langue : mélange allemand/anglais\n\u2022 Préfère les réponses concises et techniques',
  'memory': 'Mémoire',
  'memoryHint':
      'Connaissances à long terme que l\'IA retient d\'une conversation à l\'autre. L\'IA peut aussi les mettre à jour lorsqu\'elle apprend des faits ou des décisions importants.',
  'memoryExample':
      'Exemple :\n\u2022 Préfère Dart/Flutter pour le mobile\n\u2022 Licence : BSL pour tous les projets\n\u2022 Projet en cours : chuk_chat\n\u2022 Passionné du mode sombre',
  'importFromAnotherAi': 'Importer depuis une autre IA',
  'systemPrompt': 'Prompt système',
  'systemPromptHint':
      'Instructions personnalisées envoyées avec chaque conversation. Chiffrées avec votre clé de chiffrement des conversations.',
  'systemPromptExample':
      'Exemple : Vous êtes un assistant utile. Fournissez des réponses concises et précises.',
  'characters': 'caractères',
  'saving': 'Enregistrement...',
  'saveChanges': 'Enregistrer les modifications',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Licences open source',
  'openSourceLicensesSubtitle':
      'Consulter les licences de chaque dépendance incluse dans cette version.',
  'termsOfService': 'Conditions d\'utilisation',
  'privacyPolicy': 'Politique de confidentialité',
  'versionText': 'Version {version}',
  'updateAvailable':
      'Mise à jour disponible : v{version} \u2014 appuyez pour télécharger',
  'versionUnavailable':
      'Informations de version indisponibles.',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nTous droits réservés.',
  'licenses': 'Licences',
  'unableToLoadLicenses':
      'Impossible de charger les licences.',
  'tapToViewLicense':
      'Appuyez pour voir le texte complet de la licence',
  'devOptionsEnabled': 'Options développeur activées',
  'devOptionsAlreadyEnabled':
      'Options développeur déjà activées',
  'devOptionsTapSingular':
      'Encore {taps} appui pour les options développeur',
  'devOptionsTapsPlural':
      'Encore {taps} appuis pour les options développeur',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Abonnement',
  'openUsageDetailsInfo':
      'Ouvrir les détails d\'utilisation pour voir chaque requête, les totaux mensuels et les coûts par modèle.',
  'openUsageDetails': 'Ouvrir les détails d\'utilisation',
  'currentPlan': 'Forfait actuel',
  'plus': 'Plus',
  'pricePerMonth': '20\u00a0\u20ac/mois',
  'monthlyCredits': 'Crédits IA mensuels : 16,00\u00a0\u20ac',
  'unusedCreditsExpire':
      'Les crédits non utilisés expirent à la fin de chaque mois.',
  'manageBilling': 'Gérer la facturation',
  'manageBillingSubtitle':
      'Utilisez le portail de facturation pour annuler votre abonnement ou mettre à jour vos moyens de paiement.',
  'active': 'ACTIF',
  'getCreditsMonthly':
      'Obtenez 16\u00a0\u20ac de crédits IA par mois',
  'accessAllModels': 'Accès à tous les modèles d\'IA',
  'imageGeneration': 'Génération d\'images',
  'voiceMode': 'Mode vocal',
  'textChatReasoning': 'Chat textuel avec raisonnement',
  'creditsExplanation':
      'Vos 16\u00a0\u20ac de crédits IA sont utilisés par token selon le modèle choisi. Les crédits non utilisés expirent à la fin de chaque mois.',
  'immediateAccessAck':
      'Je souhaite un accès immédiat à Chuk Chat et reconnais perdre mon ',
  'rightOfWithdrawal': 'droit de rétractation',
  'onceServiceBegins':
      ' dès le début du service. J\'accepte les ',
  'subscribeNow': 'S\'abonner maintenant',
  'alreadySubscribed':
      'Vous avez déjà un abonnement actif.',
  'opening': 'Ouverture...',
  'agreeToTermsFirst':
      'Veuillez accepter les conditions et reconnaître la perte du droit de rétractation.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Bienvenue sur Chuk Chat',
  'signInWithEmail': 'Connectez-vous avec votre e-mail',
  'createAccountWithEmail':
      'Créez un compte avec un e-mail et un mot de passe',
  'supabaseNotConfigured':
      'Les identifiants Supabase ne sont pas configurés. Mettez-les à jour avant de lancer une version de production.',
  'howOthersSeeYou': 'Comment les autres vous verront',
  'email': 'E-mail',
  'emailPlaceholder': 'vous@exemple.com',
  'confirmPassword': 'Confirmer le mot de passe',
  'forgotPassword': 'Mot de passe oublié ?',
  'enterYourPassword': 'Entrez votre mot de passe.',
  'pleaseConfirmPassword':
      'Veuillez confirmer votre mot de passe.',
  'signIn': 'Se connecter',
  'createAccount': 'Créer un compte',
  'noAccountSignUp':
      'Vous n\'avez pas de compte ? Inscrivez-vous',
  'haveAccountSignIn':
      'Vous avez déjà un compte ? Connectez-vous',
  'agreeToTerms': 'J\'accepte les ',
  'andText': ' et ',
  'confirmAge16':
      'Je confirme avoir au moins 16 ans',
  'mustAgreeToTerms':
      'Vous devez accepter les conditions d\'utilisation et la politique de confidentialité pour créer un compte.',
  'mustBe16':
      'Vous devez avoir au moins 16 ans pour utiliser ce service.',
  'unexpectedError': 'Erreur inattendue : {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats':
      'Récupérer les conversations chiffrées',
  'noLockedChats': 'Aucune conversation verrouillée',
  'allChatsAccessible':
      'Toutes vos conversations sont accessibles.',
  'recoverChatsInfo':
      'Certaines conversations sont chiffrées avec un ancien mot de passe. Entrez votre ancien mot de passe pour les récupérer, ou supprimez-les définitivement.',
  'encryptedWithVersion':
      'Chiffré avec la version de mot de passe {version}',
  'oldPassword': 'Ancien mot de passe',
  'enterOldPassword':
      'Entrez le mot de passe que vous utilisiez auparavant',
  'lockedChatCountSingular':
      '{count} conversation verrouillée',
  'lockedChatCountPlural':
      '{count} conversations verrouillées',
  'deleteLockedChatsTitle':
      'Supprimer les conversations verrouillées ?',
  'deleteLockedChatsBodySingular':
      'Cela supprimera définitivement {count} conversation chiffrée avec votre ancien mot de passe.\n\nCette conversation ne pourra pas être récupérée après suppression. Vous perdrez tous les messages, images et pièces jointes.',
  'deleteLockedChatsBodyPlural':
      'Cela supprimera définitivement {count} conversations chiffrées avec votre ancien mot de passe.\n\nCes conversations ne pourront pas être récupérées après suppression. Vous perdrez tous les messages, images et pièces jointes.',
  'deletePermanently': 'Supprimer définitivement',
  'areYouSure': 'Êtes-vous sûr ?',
  'confirmDeleteChats':
      'Vous êtes sur le point de supprimer {count} conversations. Tapez SUPPRIMER pour confirmer.',
  'typeDelete': 'Tapez SUPPRIMER',
  'confirmDelete': 'Confirmer la suppression',
  'pleaseEnterOldPassword':
      'Veuillez entrer votre ancien mot de passe.',
  'derivingKey': 'Dérivation de la clé de chiffrement...',
  'recoveredChatsSingular':
      '{count} conversation récupérée avec succès.',
  'recoveredChatsPlural':
      '{count} conversations récupérées avec succès.',
  'recoveryFailed':
      'Échec de la récupération. Veuillez réessayer.',
  'deletedChatsSingular': '{count} conversation supprimée.',
  'deletedChatsPlural': '{count} conversations supprimées.',
  'deletionFailed':
      'Échec de la suppression. Veuillez réessayer.',
  'recover': 'Récupérer',
  'delete': 'Supprimer',
  'deleting': 'Suppression...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Définir un nouveau mot de passe',
  'setNewPasswordInfo':
      'Choisissez un mot de passe fort pour votre compte. Vos anciennes conversations resteront accessibles si vous vous souvenez de votre ancien mot de passe.',
  'setNewPasswordButton':
      'Définir le nouveau mot de passe',
  'noAuthenticatedUser':
      'Aucun utilisateur authentifié après la mise à jour du mot de passe.',
  'failedToPreserveEncryption':
      'Échec de la préservation des anciennes données de chiffrement. Veuillez vérifier votre connexion et réessayer.',
  'failedToSetNewPassword':
      'Échec de la définition du nouveau mot de passe. Veuillez réessayer.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Options développeur',
  'devOptionsToggleSubtitle':
      'Déverrouiller les diagnostics et les outils de débogage. Désactivez pour masquer tous les paramètres réservés aux développeurs.',
  'enableDiagnosticsLogging':
      'Activer la journalisation des diagnostics',
  'enableDiagnosticsSubtitle':
      'Fonctionne en version release. Journalise les métadonnées de l\'application et du runtime pour diagnostiquer les ralentissements et les problèmes de barre système.',
  'diagnosticsEnabled':
      'Journalisation des diagnostics activée',
  'diagnosticsDisabled':
      'Journalisation des diagnostics désactivée',
  'notInitializedYet': 'Pas encore initialisé',
  'refresh': 'Actualiser',
  'copyRecent': 'Copier les récents',
  'copyFocusedDebug': 'Copier le débogage ciblé',
  'shareFile': 'Partager le fichier',
  'clear': 'Effacer',
  'copiedRecentLogs':
      'Journaux récents copiés dans le presse-papiers',
  'noFocusedDebugData':
      'Aucune donnée de débogage ciblé disponible pour le moment',
  'copiedFocusedDebug':
      'Rapport de débogage ciblé du menu des modèles copié',
  'failedFocusedDebug':
      'Échec de la création du rapport de débogage ciblé : {error}',
  'noDiagnosticsLog':
      'Aucun journal de diagnostics disponible',
  'diagnosticsLogNotFound':
      'Fichier journal de diagnostics introuvable',
  'failedToShareLog':
      'Échec du partage du journal de diagnostics : {error}',
  'diagnosticsLogCleared':
      'Journal de diagnostics effacé',
  'failedToClearLog':
      'Échec de l\'effacement du journal de diagnostics : {error}',
  'devOptionsDisabledMsg':
      'Options développeur désactivées.',
  'noLogsYet':
      'Aucun journal pour le moment. Activez la journalisation des diagnostics et utilisez l\'application pour collecter des données.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Retour',
  'enabled': 'Activé',
  'disabled': 'Désactivé',
  'modelPrompt': 'Prompt du modèle',
  'modelPromptHint':
      'Cette description est montrée au modèle après la découverte des outils.',
  'customPromptActive': 'Prompt personnalisé actif',
  'savePrompt': 'Enregistrer le prompt',
  'parameters': 'Paramètres',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Détails d\'utilisation',
  'unableToLoadUsage':
      'Impossible de charger les détails d\'utilisation pour le moment.',
  'usageAndBilling': 'Utilisation et facturation',
  'usageReadOnly':
      'Cet écran est en lecture seule et provient de vos journaux d\'utilisation.',
  'period': 'Période',
  'totals': 'Totaux',
  'mediaRequestsNote':
      'Les requêtes d\'images et audio sont traitées comme des requêtes média et exclues des totaux de tokens texte.',
  'noRequestsFound':
      'Aucune requête trouvée pour cette période.',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired':
      'Session expirée. Veuillez vous reconnecter.',
  'free': 'Gratuit',
  'best': 'Meilleur',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'Ouvrir dans l\'application mail',
  'unableToSaveImage':
      'Impossible d\'enregistrer l\'image',
  'image': 'Image',
  'open': 'Ouvrir',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'Original',
  'markdown': 'Markdown',
  'deleteFile': 'Supprimer le fichier',
  'deleteFailed': 'Échec de la suppression : {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'Posez-moi n\'importe quelle question !',
  'aiDisclaimer': 'Vous discutez avec une IA — elle peut se tromper. Vérifiez l\'essentiel.',
  'queuedLabel': 'En file d\'attente',
  'editYourMessage': 'Modifier votre message...',
  'addMessageOrDocs':
      'Ajouter un message ou envoyer des documents',
  'micAccessFailed': 'Échec de l\'accès au microphone',
  'transcriptionFailed': 'Échec de la transcription',
  'nothingToResend': 'Rien à renvoyer',
  'freeMessagesUsed': 'Messages gratuits utilisés',
  'ok': 'OK',
  'camera': 'Appareil photo',
  'photos': 'Photos',
  'files': 'Fichiers',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Modèles',
  'searchModels': 'Rechercher des modèles...',
  'modelError': 'Erreur : {error}',

  // ── Message bubble extras ──────────────────────────────────

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'Total : {count}',
  'freeRemaining': 'Gratuit : {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Sélectionner un modèle',
  'noEnabledModels': 'Aucun modèle activé',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'Nouveau chat',
  'workspaces': 'Espaces de travail',
  'media': 'Médias',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Gestionnaire de médias',
  'imageUsedInChats':
      'Image utilisée dans des conversations',
  'imageUsedInChatsBody':
      'Cette image est utilisée dans les conversations suivantes :',
  'deleteImageShowDeleted':
      'Si vous supprimez cette image, elle apparaîtra comme « Image supprimée » dans ces conversations.',
  'deleteImageConfirm':
      'Êtes-vous sûr de vouloir supprimer cette image ?',
  'deleteAnyway': 'Supprimer quand même',
  'deleteImageTitle': 'Supprimer l\'image',
  'deleteImageBody':
      'Êtes-vous sûr de vouloir supprimer cette image ? Cette action est irréversible.',
  'imageDeleted': 'Image supprimée',
  'failedToDeleteImage':
      'Échec de la suppression de l\'image : {error}',
  'someImagesUsedInChats':
      'Certaines images sont utilisées dans des conversations',
  'deletedImagesWarning':
      'Les images supprimées apparaîtront comme « Image supprimée » dans ces conversations.',
  'deleteAllCount':
      'Supprimer les {count} images sélectionnées ?',
  'deleteAll': 'Tout supprimer',
  'deleteSelectedImages':
      'Supprimer les images sélectionnées',
  'deleteSelectedCount':
      'Supprimer {count} images sélectionnées ? Cette action est irréversible.',
  'deletedImagesResult':
      '{deleted} images supprimées, {failed} échecs',
  'deletedImagesSuccess': '{deleted} images supprimées',
  'downloadSelected': 'Télécharger la sélection',
  'deleteSelected': 'Supprimer la sélection',
  'errorLoadingImages':
      'Erreur lors du chargement des images',
  'noImagesStored': 'Aucune image stockée',
  'imagesAppearHere':
      'Les images que vous envoyez dans les conversations apparaîtront ici',
  'download': 'Télécharger',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'Retirer {name}',
  'edit': 'Modifier',
  'close': 'Fermer',

  // ── Subscription dialogs ───────────────────────────────────
};
