// lib/l10n/strings_pt.dart
// Portuguese (Brazilian) UI strings.

const Map<String, String> stringsPt = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Configurações',
  'themeSettings': 'Configurações de Tema',
  'themeSettingsSubtitle': 'Ajuste o tema, cores e aparência do app',
  'customization': 'Personalização',
  'customizationSubtitle': 'Configure o comportamento e preferências do app',
  'toolCalling': 'Chamada de Ferramentas',
  'toolCallingSubtitle':
      'Controle o uso, descoberta e exibição de chamadas de ferramentas',
  'developerOptions': 'Opções de Desenvolvedor',
  'developerOptionsSubtitle': 'Logs de diagnóstico e ferramentas de depuração',
  'modelSelection': 'Seleção de Modelo',
  'modelSelectionSubtitle': 'Escolha e configure seus modelos de IA',
  'aiIdentityMemory': 'Identidade e Memória da IA',
  'aiIdentityMemorySubtitle':
      'Alma, perfil do usuário, memória e prompt do sistema',
  'pricingPlans': 'Planos e Preços',
  'pricingPlansSubtitle': 'Veja nossos planos de assinatura e preços',
  'accountSettings': 'Configurações da Conta',
  'exportChats': 'Exportar Conversas',
  'exportChatsSubtitle': 'Baixe suas conversas como JSON',
  'about': 'Sobre',
  'aboutSubtitle': 'Detalhes da versão e licenças de código aberto',
  'logout': 'Sair',
  'noChatsToExport': 'Nenhuma conversa para exportar',
  'copiedToClipboard': 'Copiado para a área de transferência',
  'savedToPath': 'Salvo em {path}',
  'exportCancelled': 'Exportação cancelada',
  'shareOpened': 'Compartilhamento aberto',
  'exportFailed': 'Falha na exportação: {error}',
  'saveChatExport': 'Salvar exportação de conversas',

  // ── Customization page ─────────────────────────────────────
  'language': 'Idioma',
  'languageSubtitle': 'Escolha seu idioma preferido',
  'voiceTranscription': 'Transcrição de Voz',
  'autoSendVoice': 'Envio automático de mensagens de voz',
  'autoSendVoiceSubtitle':
      'Enviar automaticamente mensagens de voz transcritas sem confirmação',
  'autoSendVoiceInfo':
      'Quando ativado, as transcrições de voz são enviadas imediatamente. Quando desativado (padrão), as transcrições aparecem no campo de texto para revisão antes do envio.',
  'messageDisplay': 'Exibição de Mensagens',
  'showReasoningTokens': 'Mostrar tokens de raciocínio',
  'showReasoningTokensSubtitle':
      'Exibir tokens do processo de raciocínio nas respostas da IA',
  'showModelInfo': 'Mostrar info do modelo',
  'showModelInfoSubtitle':
      'Exibir nome e informações do modelo nas mensagens do chat',
  'showTps': 'Mostrar tokens por segundo',
  'showTpsSubtitle': 'Exibir velocidade de geração de resposta da IA (TPS)',
  'aiContext': 'Contexto da IA',
  'recentImagesInContext': 'Imagens recentes no contexto',
  'recentImagesInContextSubtitle':
      'Enviar imagens de mensagens recentes para o modelo de IA',
  'allImagesInContext': 'Todas as imagens no contexto',
  'allImagesInContextSubtitle':
      'Enviar todas as imagens da conversa para a IA (usa mais tokens)',
  'reasoningInContext': 'Raciocínio no contexto',
  'reasoningInContextSubtitle':
      'Incluir processo de pensamento da IA no histórico da conversa',
  'aiContextInfo':
      'Imagens recentes envia as imagens das últimas 6 mensagens. Todas as imagens envia todas as imagens da conversa. Raciocínio inclui o processo de pensamento da IA como contexto para mensagens seguintes.',
  'chatTitles': 'Títulos das Conversas',
  'autoGenerateTitles': 'Gerar títulos automaticamente',
  'autoGenerateTitlesSubtitle':
      'Usar IA para gerar títulos para novas conversas',
  'titleGenerationPrompt': 'Prompt de Geração de Título',
  'usingCustomPrompt': 'Usando prompt personalizado',
  'usingDefaultPrompt': 'Usando prompt padrão',
  'titleGenInfo':
      'Quando ativado, um título curto será gerado automaticamente para novas conversas com base na sua primeira mensagem. Usa um modelo de IA rápido e leve (qwen3-8b).',
  'systemPromptSaved': 'Prompt do sistema salvo',
  'systemPromptResetToDefault': 'Prompt do sistema redefinido para o padrão',
  'reset': 'Redefinir',
  'save': 'Salvar',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Modo Escuro',
  'darkModeSubtitle': 'Alternar entre temas escuro e claro',
  'accentColor': 'Cor de Destaque',
  'accentColorSubtitle': 'Escolha sua cor de destaque principal',
  'iconFgColor': 'Cor de Ícone/Primeiro Plano',
  'iconFgColorSubtitle': 'Escolha a cor dos ícones e textos principais',
  'backgroundColor': 'Cor de Fundo',
  'backgroundColorSubtitle': 'Escolha a cor de fundo principal do app',
  'customHexColor': 'Cor Hexadecimal Personalizada (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Motor',
  'enableToolCalling': 'Habilitar chamada de ferramentas',
  'enableToolCallingSubtitle':
      'Permitir que o assistente descubra e execute ferramentas integradas',
  'behavior': 'Comportamento',
  'requireDiscoveryFirst': 'Exigir descoberta primeiro',
  'requireDiscoverySubtitle':
      'Forçar find_tools antes que outras ferramentas sejam permitidas em um turno',
  'display': 'Exibição',
  'showToolActivity': 'Mostrar atividade de ferramentas no chat',
  'showToolActivitySubtitle':
      'Exibir chips de ferramentas em execução/concluídas nas mensagens do assistente',
  'toolCallingTip':
      'Dica: Desative as ferramentas apenas se quiser que o assistente responda com o próprio conhecimento, sem pesquisar ou executar ações.',
  'toolAlwaysOn': 'Sempre ativo',
  'toolArtifacts': 'Artefatos',
  'toolArtifactsSubtitle': 'Código, documentos e desenhos editáveis',
  'toolCodeSandbox': 'Sandbox de código',
  'toolCodeSandboxSubtitle': 'Executa código e gerencia arquivos em um sandbox',
  'toolGroupCodeArtifacts': 'Código e artefatos',
  'connectors': 'Conectores',
  'loadingToolSettings': 'Carregando configurações de ferramentas...',
  'noToolsRegistered': 'Nenhuma ferramenta registrada ainda.',
  'catSearchWeb': 'Busca e Web',
  'catUtilities': 'Utilitários',
  'catMapsLocation': 'Mapas e Localização',
  'catDevice': 'Dispositivo',
  'catBashTerminal': 'Bash / Terminal',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Agenda / Gmail)',
  'catSandbox': 'Sandbox / Código',
  'catSearchWebDesc':
      'Pesquisar na web, buscar páginas, gerar imagens e consultar dados',
  'catUtilitiesDesc':
      'Calculadora, relógio, notas, códigos QR e outros utilitários',
  'catMapsLocationDesc':
      'Encontrar lugares, geocodificar endereços e calcular rotas',
  'catDeviceDesc':
      'Acessar recursos do dispositivo como GPS, calendário e lembretes',
  'catBashTerminalDesc':
      'Executar comandos shell em ambiente isolado no desktop',
  'catGitHubDesc':
      'Acessar repositórios, issues, PRs e commits do GitHub',
  'catSlackDesc':
      'Enviar mensagens, pesquisar canais e buscar dados do Slack',
  'catGoogleCalGmailDesc':
      'Gerenciar sua agenda e email via Google Agenda e Gmail',
  'catSandboxDesc':
      'Executar código Python ou shell em uma sandbox isolada e ler/escrever arquivos',
  'connect': 'Conectar',
  'disconnect': 'Desconectar',
  'disconnectCategory': 'Desconectar {label}?',
  'removeCredentialsWarning': 'Isso removerá suas credenciais salvas.',
  'cancel': 'Cancelar',
  'toolWebSearch': 'Busca na Web',
  'toolWebCrawl': 'Rastreamento Web',
  'toolImageGen': 'Geração de Imagem',
  'toolFetchImage': 'Buscar Imagem',
  'toolViewChatImages': 'Ver Imagens do Chat',
  'toolCryptoData': 'Dados de Cripto',
  'toolWeather': 'Clima',
  'toolPlaceSearch': 'Busca de Lugares',
  'toolRestaurantSearch': 'Busca de Restaurantes',
  'toolGeocoding': 'Geocodificação',
  'toolRouting': 'Roteirização',
  'toolCalculator': 'Calculadora',
  'toolClock': 'Relógio',
  'toolRandomNumber': 'Número Aleatório',
  'toolCoinFlip': 'Cara ou Coroa',
  'toolDiceRoll': 'Rolar Dados',
  'toolCountdown': 'Contagem Regressiva',
  'toolPasswordGen': 'Gerador de Senhas',
  'toolUuidGen': 'Gerador de UUID',
  'toolNotes': 'Notas',
  'toolQrGen': 'Gerador de QR',
  'resetToolSettingsTitle': 'Redefinir Configurações de Ferramentas?',
  'resetToolSettingsBody':
      'Isso reativará todas as ferramentas e redefinirá todos os prompts personalizados.',
  'resetAllToolPrefs': 'Redefinir Todas as Preferências de Ferramentas',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Perfil',
  'displayName': 'Nome de exibição',
  'displayNameHint': 'Como outras pessoas veem você',
  'emailAddress': 'Endereço de email',
  'emailAddressHint': 'Para onde enviamos notificações',
  'security': 'Segurança',
  'changePassword': 'Alterar senha',
  'currentPassword': 'Senha atual',
  'newPassword': 'Nova senha',
  'minCharsPassword': 'Mínimo de 8 caracteres.',
  'confirmNewPassword': 'Confirmar nova senha',
  'updatePassword': 'Atualizar senha',
  'encryptedChatRecovery': 'Recuperação de Conversas Criptografadas',
  'lockedChatsSingular':
      '{count} conversa criptografada com uma senha anterior.',
  'lockedChatsPlural':
      '{count} conversas criptografadas com uma senha anterior.',
  'recoverChats': 'Recuperar conversas',
  'deleteAccountWarning':
      'Excluir sua conta cancelará todas as assinaturas, removerá seus dados e não pode ser desfeito.',
  'deleteAccount': 'Excluir Conta',
  'unableToLoadProfile':
      'Não foi possível carregar seu perfil no momento.',
  'retry': 'Tentar novamente',
  'saved': 'Salvo',
  'emailUpdated':
      'Email atualizado. Confirme a alteração usando o link que o Supabase enviou para {email}.',
  'failedToLoadProfile': 'Falha ao carregar perfil: {error}',
  'failedToSaveProfile': 'Falha ao salvar perfil: {error}',
  'emailCannotBeEmpty': 'O email não pode estar vazio.',
  'passwordsDoNotMatch': 'As novas senhas não coincidem.',
  'failedToChangePassword': 'Falha ao alterar senha: {error}',
  'deleteAccountQuestion': 'Excluir Conta?',
  'deleteAccountConfirmBody':
      'Tem certeza de que deseja excluir sua conta?\n\nIsso apagará permanentemente:\n  \u2022 Todas as suas conversas e mensagens\n  \u2022 Todas as memórias armazenadas\n  \u2022 Seu perfil e configurações\n  \u2022 Quaisquer assinaturas ativas\n\nEsta ação é irreversível. Seus dados não podem ser recuperados.',
  'yesDelete': 'Sim, quero excluir',
  'thisIsPermanent': 'Isso é permanente',
  'finalDeleteWarning':
      'Esta é sua última chance de voltar atrás.\n\nUma vez excluída, não há absolutamente nenhuma maneira de recuperar sua conta, conversas, memórias ou quaisquer dados associados.\n\nTudo será perdido para sempre.\n\nVocê ainda deseja prosseguir?',
  'noKeepMyAccount': 'Não, manter minha conta',
  'deleteEverything': 'Excluir tudo',
  'confirmYourPassword': 'Confirme sua senha',
  'confirmPasswordBody':
      'Para confirmar a exclusão da conta, por favor digite sua senha.',
  'password': 'Senha',
  'passwordRequired': 'A senha é obrigatória',
  'verificationFailed': 'Falha na verificação: {error}',
  'verifyAndDelete': 'Verificar e Excluir',
  'failedToDeleteAccount': 'Falha ao excluir conta: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Sistema de Identidade',
  'identityActive': 'Alma, Usuário e Memória estão ativos',
  'identityDisabled': 'Desativado \u2014 IA não tem identidade persistente',
  'soul': 'Alma',
  'soulHint':
      'Defina a personalidade, tom e limites da IA. Isso molda como ela se comunica em todas as conversas.',
  'soulExample':
      'Exemplo:\n\u2022 Seja direto e conciso\n\u2022 Acompanhe o idioma e energia do usuário\n\u2022 Tenha opiniões, não seja indeciso em tudo\n\u2022 Privacidade primeiro: pergunte antes de ações externas',
  'user': 'Usuário',
  'userHint':
      'Fatos sobre você. A IA lê isso a cada mensagem e também pode atualizá-lo quando aprende coisas novas sobre você.',
  'userExample':
      'Exemplo:\n\u2022 Nome: Alex\n\u2022 Fuso horário: America/Sao_Paulo\n\u2022 Idioma: Português/Inglês\n\u2022 Prefere respostas concisas e técnicas',
  'memory': 'Memória',
  'memoryHint':
      'Conhecimento de longo prazo que a IA lembra entre conversas. A IA também pode atualizar isso quando aprende fatos ou decisões importantes.',
  'memoryExample':
      'Exemplo:\n\u2022 Prefere Dart/Flutter para mobile\n\u2022 Licença: BSL para todos os projetos\n\u2022 Projeto atual: chuk_chat\n\u2022 Entusiasta do modo escuro',
  'importFromAnotherAi': 'Importar de outra IA',
  'systemPrompt': 'Prompt do Sistema',
  'systemPromptHint':
      'Instruções personalizadas enviadas com cada conversa. Criptografadas com sua chave de criptografia de chat.',
  'systemPromptExample':
      'Exemplo: Você é um assistente útil. Forneça respostas concisas e precisas.',
  'characters': 'caracteres',
  'saving': 'Salvando...',
  'saveChanges': 'Salvar alterações',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Licenças de Código Aberto',
  'openSourceLicensesSubtitle':
      'Revise as licenças de todas as dependências incluídas nesta compilação.',
  'termsOfService': 'Termos de Serviço',
  'privacyPolicy': 'Política de Privacidade',
  'versionText': 'Versão {version}',
  'updateAvailable':
      'Atualização disponível: v{version} \u2014 toque para baixar',
  'versionUnavailable': 'Informações da versão indisponíveis.',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nTodos os direitos reservados.',
  'licenses': 'Licenças',
  'unableToLoadLicenses': 'Não foi possível carregar as licenças.',
  'tapToViewLicense': 'Toque para ver o texto completo da licença',
  'devOptionsEnabled': 'Opções de desenvolvedor ativadas',
  'devOptionsAlreadyEnabled': 'Opções de desenvolvedor já ativadas',
  'devOptionsTapSingular': 'Mais {taps} toque para Opções de Desenvolvedor',
  'devOptionsTapsPlural': 'Mais {taps} toques para Opções de Desenvolvedor',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Assinatura',
  'openUsageDetailsInfo':
      'Abra os Detalhes de Uso para ver cada requisição, totais mensais e custos por modelo.',
  'openUsageDetails': 'Abrir Detalhes de Uso',
  'currentPlan': 'Plano Atual',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/mês',
  'monthlyCredits': 'Créditos mensais de IA: \u20ac16,00',
  'unusedCreditsExpire':
      'Créditos não utilizados expiram no final de cada mês.',
  'manageBilling': 'Gerenciar Cobrança',
  'manageBillingSubtitle':
      'Use o portal de cobrança para cancelar sua assinatura ou atualizar métodos de pagamento.',
  'active': 'ATIVO',
  'getCreditsMonthly': 'Receba \u20ac16 em créditos de IA mensalmente',
  'accessAllModels': 'Acesso a todos os modelos de IA',
  'imageGeneration': 'Geração de imagens',
  'voiceMode': 'Modo de voz',
  'textChatReasoning': 'Chat de texto com raciocínio',
  'creditsExplanation':
      'Seus \u20ac16 em créditos de IA são consumidos por token com base no modelo escolhido. Créditos não utilizados expiram no final de cada mês.',
  'immediateAccessAck':
      'Quero acesso imediato ao Chuk Chat e reconheço que perco meu ',
  'rightOfWithdrawal': 'direito de desistência',
  'onceServiceBegins':
      ' assim que o serviço começar. Concordo com os ',
  'subscribeNow': 'Assinar Agora',
  'alreadySubscribed': 'Você já possui uma assinatura ativa.',
  'opening': 'Abrindo...',
  'agreeToTermsFirst':
      'Por favor, concorde com os termos e reconheça a perda do direito de desistência.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Bem-vindo ao Chuk Chat',
  'signInWithEmail': 'Entre com seu email',
  'createAccountWithEmail': 'Crie uma conta com email e senha',
  'supabaseNotConfigured':
      'As credenciais do Supabase não estão configuradas. Atualize-as antes de executar uma compilação de produção.',
  'howOthersSeeYou': 'Como outras pessoas verão você',
  'email': 'Email',
  'emailPlaceholder': 'voce@exemplo.com',
  'confirmPassword': 'Confirmar senha',
  'forgotPassword': 'Esqueceu a senha?',
  'enterYourPassword': 'Digite sua senha.',
  'pleaseConfirmPassword': 'Por favor, confirme sua senha.',
  'signIn': 'Entrar',
  'createAccount': 'Criar conta',
  'noAccountSignUp': 'Não tem uma conta? Cadastre-se',
  'haveAccountSignIn': 'Já tem uma conta? Entre',
  'agreeToTerms': 'Concordo com os ',
  'andText': ' e ',
  'confirmAge16': 'Confirmo que tenho pelo menos 16 anos de idade',
  'mustAgreeToTerms':
      'Você deve concordar com os Termos de Serviço e a Política de Privacidade para criar uma conta.',
  'mustBe16':
      'Você deve ter pelo menos 16 anos de idade para usar este serviço.',
  'unexpectedError': 'Erro inesperado: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'Recuperar Conversas Criptografadas',
  'noLockedChats': 'Nenhuma conversa bloqueada',
  'allChatsAccessible': 'Todas as suas conversas estão acessíveis.',
  'recoverChatsInfo':
      'Algumas conversas estão criptografadas com uma senha anterior. Digite sua senha antiga para recuperá-las ou exclua-as permanentemente.',
  'encryptedWithVersion': 'Criptografada com a versão de senha {version}',
  'oldPassword': 'Senha antiga',
  'enterOldPassword': 'Digite a senha que você usava antes',
  'lockedChatCountSingular': '{count} conversa bloqueada',
  'lockedChatCountPlural': '{count} conversas bloqueadas',
  'deleteLockedChatsTitle': 'Excluir conversas bloqueadas?',
  'deleteLockedChatsBodySingular':
      'Isso excluirá permanentemente {count} conversa que está criptografada com sua senha antiga.\n\nEsta conversa não pode ser recuperada após a exclusão. Você perderá todas as mensagens, imagens e anexos.',
  'deleteLockedChatsBodyPlural':
      'Isso excluirá permanentemente {count} conversas que estão criptografadas com sua senha antiga.\n\nEssas conversas não podem ser recuperadas após a exclusão. Você perderá todas as mensagens, imagens e anexos.',
  'deletePermanently': 'Excluir permanentemente',
  'areYouSure': 'Tem certeza?',
  'confirmDeleteChats':
      'Você está prestes a excluir {count} conversas. Digite EXCLUIR para confirmar.',
  'typeDelete': 'Digite EXCLUIR',
  'confirmDelete': 'Confirmar exclusão',
  'pleaseEnterOldPassword': 'Por favor, digite sua senha antiga.',
  'derivingKey': 'Derivando chave de criptografia...',
  'recoveredChatsSingular': '{count} conversa recuperada com sucesso.',
  'recoveredChatsPlural': '{count} conversas recuperadas com sucesso.',
  'recoveryFailed': 'Falha na recuperação. Por favor, tente novamente.',
  'deletedChatsSingular': '{count} conversa excluída.',
  'deletedChatsPlural': '{count} conversas excluídas.',
  'deletionFailed': 'Falha na exclusão. Por favor, tente novamente.',
  'recover': 'Recuperar',
  'delete': 'Excluir',
  'deleting': 'Excluindo...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Definir uma nova senha',
  'setNewPasswordInfo':
      'Escolha uma senha forte para sua conta. Suas conversas antigas permanecerão acessíveis se você lembrar sua senha anterior.',
  'setNewPasswordButton': 'Definir nova senha',
  'noAuthenticatedUser':
      'Nenhum usuário autenticado após atualização de senha.',
  'failedToPreserveEncryption':
      'Falha ao preservar dados de criptografia antigos. Por favor, verifique sua conexão e tente novamente.',
  'failedToSetNewPassword':
      'Falha ao definir nova senha. Por favor, tente novamente.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Opções de desenvolvedor',
  'devOptionsToggleSubtitle':
      'Desbloquear diagnósticos e ferramentas de depuração. Desative para ocultar todas as configurações exclusivas para desenvolvedores.',
  'enableDiagnosticsLogging': 'Habilitar registro de diagnóstico',
  'enableDiagnosticsSubtitle':
      'Funciona em compilações de produção. Registra metadados do app/runtime para solução de problemas de lag e bandeja do sistema.',
  'diagnosticsEnabled': 'Registro de diagnóstico habilitado',
  'diagnosticsDisabled': 'Registro de diagnóstico desabilitado',
  'notInitializedYet': 'Ainda não inicializado',
  'refresh': 'Atualizar',
  'copyRecent': 'Copiar Recentes',
  'copyFocusedDebug': 'Copiar Debug Focado',
  'shareFile': 'Compartilhar Arquivo',
  'clear': 'Limpar',
  'copiedRecentLogs': 'Logs recentes copiados para a área de transferência',
  'noFocusedDebugData': 'Nenhum dado de debug focado disponível ainda',
  'copiedFocusedDebug': 'Relatório de debug focado do menu de modelos copiado',
  'failedFocusedDebug':
      'Falha ao criar relatório de debug focado: {error}',
  'noDiagnosticsLog': 'Nenhum log de diagnóstico disponível',
  'diagnosticsLogNotFound': 'Arquivo de log de diagnóstico não encontrado',
  'failedToShareLog':
      'Falha ao compartilhar log de diagnóstico: {error}',
  'diagnosticsLogCleared': 'Log de diagnóstico limpo',
  'failedToClearLog': 'Falha ao limpar log de diagnóstico: {error}',
  'devOptionsDisabledMsg': 'Opções de desenvolvedor desativadas.',
  'noLogsYet':
      'Nenhum log ainda. Habilite o registro de diagnóstico e use o app para coletar dados.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Voltar',
  'enabled': 'Habilitado',
  'disabled': 'Desabilitado',
  'modelPrompt': 'Prompt do Modelo',
  'modelPromptHint':
      'Esta descrição é mostrada ao modelo após a descoberta de ferramentas.',
  'customPromptActive': 'Prompt personalizado ativo',
  'savePrompt': 'Salvar Prompt',
  'parameters': 'Parâmetros',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Detalhes de Uso',
  'unableToLoadUsage':
      'Não foi possível carregar os detalhes de uso no momento.',
  'usageAndBilling': 'Uso e Cobrança',
  'usageReadOnly':
      'Esta tela é somente leitura e obtida dos seus logs de uso.',
  'period': 'Período',
  'totals': 'Totais',
  'mediaRequestsNote':
      'Requisições de imagem e áudio são tratadas como requisições de mídia e excluídas dos totais de tokens de texto.',
  'noRequestsFound': 'Nenhuma requisição encontrada para este período.',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'Sessão expirada. Por favor, entre novamente.',
  'free': 'Grátis',
  'best': 'Melhor',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'Abrir no App de Email',
  'unableToSaveImage': 'Não foi possível salvar a imagem',
  'image': 'Imagem',
  'open': 'Abrir',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'Original',
  'markdown': 'Markdown',
  'deleteFile': 'Excluir Arquivo',
  'deleteFailed': 'Falha ao excluir: {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': 'Pergunte-me qualquer coisa!',
  'aiDisclaimer': 'Você está conversando com uma IA — ela pode errar. Confira o importante.',
  'queuedLabel': 'Na fila',
  'editYourMessage': 'Edite sua mensagem...',
  'addMessageOrDocs': 'Adicione uma mensagem ou envie documentos',
  'micAccessFailed': 'Falha no acesso ao microfone',
  'transcriptionFailed': 'Falha na transcrição',
  'nothingToResend': 'Nada para reenviar',
  'freeMessagesUsed': 'Mensagens Gratuitas Esgotadas',
  'ok': 'OK',
  'camera': 'Câmera',
  'photos': 'Fotos',
  'files': 'Arquivos',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Modelos',
  'searchModels': 'Pesquisar modelos...',
  'modelError': 'Erro: {error}',

  // ── Message bubble extras ──────────────────────────────────

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'Total: {count}',
  'freeRemaining': 'Grátis: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Selecionar Modelo',
  'noEnabledModels': 'Nenhum Modelo Habilitado',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'Novo chat',
  'workspaces': 'Espaços de trabalho',
  'media': 'Mídia',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Gerenciador de Mídia',
  'imageUsedInChats': 'Imagem Usada em Conversas',
  'imageUsedInChatsBody':
      'Esta imagem é usada nas seguintes conversas:',
  'deleteImageShowDeleted':
      'Se você excluir esta imagem, ela aparecerá como "Imagem excluída" nessas conversas.',
  'deleteImageConfirm':
      'Tem certeza de que deseja excluir esta imagem?',
  'deleteAnyway': 'Excluir Mesmo Assim',
  'deleteImageTitle': 'Excluir Imagem',
  'deleteImageBody':
      'Tem certeza de que deseja excluir esta imagem? Esta ação não pode ser desfeita.',
  'imageDeleted': 'Imagem excluída',
  'failedToDeleteImage': 'Falha ao excluir imagem: {error}',
  'someImagesUsedInChats': 'Algumas Imagens Estão em Uso nas Conversas',
  'deletedImagesWarning':
      'Imagens excluídas aparecerão como "Imagem excluída" nessas conversas.',
  'deleteAllCount': 'Excluir todas as {count} imagens selecionadas?',
  'deleteAll': 'Excluir Todas',
  'deleteSelectedImages': 'Excluir Imagens Selecionadas',
  'deleteSelectedCount':
      'Excluir {count} imagens selecionadas? Esta ação não pode ser desfeita.',
  'deletedImagesResult':
      '{deleted} imagens excluídas, {failed} falharam',
  'deletedImagesSuccess': '{deleted} imagens excluídas',
  'downloadSelected': 'Baixar selecionadas',
  'deleteSelected': 'Excluir selecionadas',
  'errorLoadingImages': 'Erro ao carregar imagens',
  'noImagesStored': 'Nenhuma imagem armazenada',
  'imagesAppearHere':
      'Imagens que você enviar nas conversas aparecerão aqui',
  'download': 'Baixar',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'Remover {name}',
  'edit': 'Editar',
  'close': 'Fechar',

  // ── Subscription dialogs ───────────────────────────────────
  'bashSandboxFolder': 'Pasta do sandbox',
  'bashSandboxFolderUnset': 'Não definida — comandos bash são recusados',
  'bashSandboxChooseDialog': 'Escolher a pasta do sandbox do bash',
};
