// lib/l10n/strings_es.dart
// Spanish UI strings.

const Map<String, String> stringsEs = {
  // ── Settings page ──────────────────────────────────────────
  'settings': 'Ajustes',
  'themeSettings': 'Ajustes de tema',
  'themeSettingsSubtitle': 'Ajusta el tema, los colores y la apariencia de la app',
  'customization': 'Personalización',
  'customizationSubtitle': 'Configura el comportamiento y las preferencias de la app',
  'toolCalling': 'Llamada de herramientas',
  'toolCallingSubtitle': 'Controla el uso, descubrimiento y visualización de herramientas',
  'developerOptions': 'Opciones de desarrollador',
  'developerOptionsSubtitle': 'Registros de diagnóstico y herramientas de depuración',
  'modelSelection': 'Selección de modelo',
  'modelSelectionSubtitle': 'Elige y configura tus modelos de IA',
  'aiIdentityMemory': 'Identidad y memoria de la IA',
  'aiIdentityMemorySubtitle': 'Alma, perfil de usuario, memoria y prompt del sistema',
  'pricingPlans': 'Planes de precios',
  'pricingPlansSubtitle': 'Consulta nuestros planes de suscripción y precios',
  'accountSettings': 'Ajustes de cuenta',
  'exportChats': 'Exportar chats',
  'exportChatsSubtitle': 'Descarga tus conversaciones como JSON',
  'about': 'Acerca de',
  'aboutSubtitle': 'Detalles de versión y licencias de código abierto',
  'logout': 'Cerrar sesión',
  'noChatsToExport': 'No hay chats para exportar',
  'copiedToClipboard': 'Copiado al portapapeles',
  'savedToPath': 'Guardado en {path}',
  'exportCancelled': 'Exportación cancelada',
  'shareOpened': 'Compartir abierto',
  'exportFailed': 'Error al exportar: {error}',
  'saveChatExport': 'Guardar exportación de chat',

  // ── Customization page ─────────────────────────────────────
  'language': 'Idioma',
  'languageSubtitle': 'Elige tu idioma preferido',
  'voiceTranscription': 'Transcripción de voz',
  'autoSendVoice': 'Enviar mensajes de voz automáticamente',
  'autoSendVoiceSubtitle':
      'Enviar automáticamente los mensajes de voz transcritos sin confirmación',
  'autoSendVoiceInfo':
      'Cuando está activado, las transcripciones de voz se envían inmediatamente. Cuando está desactivado (por defecto), las transcripciones aparecen en el campo de texto para revisarlas antes de enviar.',
  'messageDisplay': 'Visualización de mensajes',
  'showReasoningTokens': 'Mostrar tokens de razonamiento',
  'showReasoningTokensSubtitle':
      'Mostrar los tokens del proceso de razonamiento en las respuestas de la IA',
  'showModelInfo': 'Mostrar información del modelo',
  'showModelInfoSubtitle':
      'Mostrar el nombre y la información del modelo en los mensajes del chat',
  'showTps': 'Mostrar tokens por segundo',
  'showTpsSubtitle': 'Mostrar la velocidad de generación de respuestas de la IA (TPS)',
  'aiContext': 'Contexto de la IA',
  'recentImagesInContext': 'Imágenes recientes en el contexto',
  'recentImagesInContextSubtitle':
      'Enviar imágenes de mensajes recientes al modelo de IA',
  'allImagesInContext': 'Todas las imágenes en el contexto',
  'allImagesInContextSubtitle':
      'Enviar todas las imágenes de la conversación a la IA (usa más tokens)',
  'reasoningInContext': 'Razonamiento en el contexto',
  'reasoningInContextSubtitle':
      'Incluir el proceso de pensamiento de la IA en el historial de la conversación',
  'aiContextInfo':
      'Imágenes recientes envía las imágenes de los últimos 6 mensajes. Todas las imágenes envía cada imagen de la conversación. Razonamiento incluye el proceso de pensamiento de la IA como contexto para los mensajes siguientes.',
  'chatTitles': 'Títulos de chat',
  'autoGenerateTitles': 'Generar títulos de chat automáticamente',
  'autoGenerateTitlesSubtitle':
      'Usar IA para generar títulos para chats nuevos',
  'titleGenerationPrompt': 'Prompt de generación de títulos',
  'usingCustomPrompt': 'Usando prompt personalizado',
  'usingDefaultPrompt': 'Usando prompt predeterminado',
  'titleGenInfo':
      'Cuando está activado, se generará automáticamente un título corto para los chats nuevos basado en tu primer mensaje. Usa un modelo de IA rápido y ligero (qwen3-8b).',
  'systemPromptSaved': 'Prompt del sistema guardado',
  'systemPromptResetToDefault': 'Prompt del sistema restablecido a los valores predeterminados',
  'reset': 'Restablecer',
  'save': 'Guardar',

  // ── Theme page ─────────────────────────────────────────────
  'darkMode': 'Modo oscuro',
  'darkModeSubtitle': 'Alternar entre temas oscuro y claro',
  'accentColor': 'Color de acento',
  'accentColorSubtitle': 'Elige tu color de acento principal',
  'iconFgColor': 'Color de iconos/primer plano',
  'iconFgColorSubtitle': 'Elige el color de los iconos y el texto principal',
  'backgroundColor': 'Color de fondo',
  'backgroundColorSubtitle': 'Elige el color de fondo principal de la app',
  'filmGrainEffect': 'Efecto de grano de película',
  'filmGrainSubtitle': 'Añadir una textura sutil de película analógica',
  'customHexColor': 'Color hexadecimal personalizado (#RRGGBB)',

  // ── Tool calling page ──────────────────────────────────────
  'engine': 'Motor',
  'enableToolCalling': 'Activar llamada de herramientas',
  'enableToolCallingSubtitle':
      'Permitir al asistente descubrir y ejecutar herramientas integradas',
  'behavior': 'Comportamiento',
  'requireDiscoveryFirst': 'Requerir descubrimiento primero',
  'requireDiscoverySubtitle':
      'Forzar find_tools antes de que se permitan otras herramientas en un turno',
  'markdownToolCallFallback': 'Respaldo de llamada de herramientas en Markdown',
  'markdownFallbackSubtitle':
      'Aceptar bloques de código ```tool_call cuando los modelos no emiten etiquetas XML',
  'display': 'Visualización',
  'showToolActivity': 'Mostrar actividad de herramientas en el chat',
  'showToolActivitySubtitle':
      'Mostrar chips de herramientas en ejecución/completadas en los mensajes del asistente',
  'toolCallingTip':
      'Consejo: Deja activado el respaldo Markdown para mejor compatibilidad. Desactívalo solo si quieres llamadas de herramientas estrictamente en XML.',
  'enableMapBlocks': 'Activar bloques de mapa (<map>)',
  'enableMapBlocksSubtitle':
      'Permitir que el prompt del modelo incluya instrucciones de renderizado de mapas',
  'enableChartBlocks': 'Activar bloques de gráficos (<chart>)',
  'enableChartBlocksSubtitle':
      'Permitir que el prompt del modelo incluya instrucciones de renderizado de gráficos',
  'loadingToolSettings': 'Cargando ajustes de herramientas...',
  'noToolsRegistered': 'Aún no hay herramientas registradas.',
  'catSearchWeb': 'Búsqueda y web',
  'catUtilities': 'Utilidades',
  'catMapsLocation': 'Mapas y ubicación',
  'catDevice': 'Dispositivo',
  'catSpotify': 'Spotify',
  'catBashTerminal': 'Bash / Terminal',
  'catGitHub': 'GitHub',
  'catSlack': 'Slack',
  'catGoogleCalGmail': 'Google (Calendar / Gmail)',
  'catSandbox': 'Sandbox / Código',
  'catSearchWebDesc':
      'Buscar en la web, obtener páginas, generar imágenes y consultar datos',
  'catUtilitiesDesc':
      'Calculadora, reloj, notas, códigos QR y otras utilidades',
  'catMapsLocationDesc':
      'Buscar lugares, geocodificar direcciones y calcular rutas',
  'catDeviceDesc': 'Acceder a funciones del dispositivo como GPS, calendario y recordatorios',
  'catSpotifyDesc': 'Controlar la reproducción y explorar tu biblioteca de Spotify',
  'catBashTerminalDesc': 'Ejecutar comandos de shell en un entorno aislado en el escritorio',
  'catGitHubDesc':
      'Acceder a repositorios, issues, PRs y commits de GitHub',
  'catSlackDesc':
      'Enviar mensajes, buscar canales y obtener datos de Slack',
  'catGoogleCalGmailDesc':
      'Gestionar tu agenda y correo electrónico con Google Calendar y Gmail',
  'catSandboxDesc':
      'Ejecutar código Python o shell en un sandbox aislado y leer/escribir archivos',
  'connect': 'Conectar',
  'disconnect': 'Desconectar',
  'disconnectCategory': '¿Desconectar {label}?',
  'removeCredentialsWarning': 'Esto eliminará tus credenciales guardadas.',
  'cancel': 'Cancelar',
  'toolWebSearch': 'Búsqueda web',
  'toolWebCrawl': 'Rastreo web',
  'toolImageGen': 'Generación de imágenes',
  'toolFetchImage': 'Obtener imagen',
  'toolViewChatImages': 'Ver imágenes del chat',
  'toolCryptoData': 'Datos de criptomonedas',
  'toolWeather': 'Clima',
  'toolPlaceSearch': 'Búsqueda de lugares',
  'toolRestaurantSearch': 'Búsqueda de restaurantes',
  'toolGeocoding': 'Geocodificación',
  'toolRouting': 'Rutas',
  'toolCalculator': 'Calculadora',
  'toolClock': 'Reloj',
  'toolRandomNumber': 'Número aleatorio',
  'toolCoinFlip': 'Lanzar moneda',
  'toolDiceRoll': 'Tirar dado',
  'toolCountdown': 'Cuenta regresiva',
  'toolPasswordGen': 'Generador de contraseñas',
  'toolUuidGen': 'Generador de UUID',
  'toolNotes': 'Notas',
  'toolQrGen': 'Generador de QR',
  'resetToolSettingsTitle': '¿Restablecer ajustes de herramientas?',
  'resetToolSettingsBody':
      'Esto reactivará todas las herramientas y restablecerá todos los prompts personalizados de herramientas.',
  'resetAllToolPrefs': 'Restablecer todas las preferencias de herramientas',

  // ── Account settings page ──────────────────────────────────
  'profile': 'Perfil',
  'displayName': 'Nombre para mostrar',
  'displayNameHint': 'Cómo te ven los demás',
  'emailAddress': 'Correo electrónico',
  'emailAddressHint': 'Donde te enviamos las notificaciones',
  'security': 'Seguridad',
  'changePassword': 'Cambiar contraseña',
  'currentPassword': 'Contraseña actual',
  'newPassword': 'Nueva contraseña',
  'minCharsPassword': 'Mínimo 8 caracteres.',
  'confirmNewPassword': 'Confirmar nueva contraseña',
  'updatePassword': 'Actualizar contraseña',
  'encryptedChatRecovery': 'Recuperación de chats cifrados',
  'lockedChatsSingular': '{count} chat cifrado con una contraseña anterior.',
  'lockedChatsPlural': '{count} chats cifrados con una contraseña anterior.',
  'recoverChats': 'Recuperar chats',
  'deleteAccountWarning':
      'Eliminar tu cuenta cancelará todas las suscripciones, eliminará tus datos y no se puede deshacer.',
  'deleteAccount': 'Eliminar cuenta',
  'unableToLoadProfile': 'No se puede cargar tu perfil en este momento.',
  'retry': 'Reintentar',
  'saved': 'Guardado',
  'emailUpdated':
      'Correo actualizado. Confirma el cambio usando el enlace que Supabase envió a {email}.',
  'failedToLoadProfile': 'Error al cargar el perfil: {error}',
  'failedToSaveProfile': 'Error al guardar el perfil: {error}',
  'emailCannotBeEmpty': 'El correo electrónico no puede estar vacío.',
  'passwordsDoNotMatch': 'Las contraseñas nuevas no coinciden.',
  'failedToChangePassword': 'Error al cambiar la contraseña: {error}',
  'deleteAccountQuestion': '¿Eliminar cuenta?',
  'deleteAccountConfirmBody':
      '¿Estás seguro de que quieres eliminar tu cuenta?\n\nEsto eliminará permanentemente:\n  \u2022 Todos tus chats y mensajes\n  \u2022 Todos los recuerdos almacenados\n  \u2022 Tu perfil y ajustes\n  \u2022 Cualquier suscripción activa\n\nEsta acción es irreversible. Tus datos no se podrán recuperar.',
  'yesDelete': 'Sí, quiero eliminar',
  'thisIsPermanent': 'Esto es permanente',
  'finalDeleteWarning':
      'Esta es tu última oportunidad para dar marcha atrás.\n\nUna vez eliminada, no hay absolutamente ninguna forma de recuperar tu cuenta, chats, recuerdos ni ningún dato asociado.\n\nTodo desaparecerá para siempre.\n\n¿Aún deseas continuar?',
  'noKeepMyAccount': 'No, conservar mi cuenta',
  'deleteEverything': 'Eliminar todo',
  'confirmYourPassword': 'Confirma tu contraseña',
  'confirmPasswordBody':
      'Para confirmar la eliminación de la cuenta, por favor introduce tu contraseña.',
  'password': 'Contraseña',
  'passwordRequired': 'La contraseña es obligatoria',
  'verificationFailed': 'Verificación fallida: {error}',
  'verifyAndDelete': 'Verificar y eliminar',
  'failedToDeleteAccount': 'Error al eliminar la cuenta: {error}',

  // ── System prompt / Identity page ──────────────────────────
  'identitySystem': 'Sistema de identidad',
  'identityActive': 'Alma, Usuario y Memoria están activos',
  'identityDisabled': 'Desactivado \u2014 La IA no tiene identidad persistente',
  'soul': 'Alma',
  'soulHint':
      'Define la personalidad, el tono y los límites de la IA. Esto determina cómo se comunica en todas las conversaciones.',
  'soulExample':
      'Ejemplo:\n\u2022 Sé directo y conciso\n\u2022 Adapta el idioma y la energía del usuario\n\u2022 Ten opiniones, no lo relativices todo\n\u2022 Privacidad primero: pregunta antes de acciones externas',
  'user': 'Usuario',
  'userHint':
      'Datos sobre ti. La IA lee esto en cada mensaje y también puede actualizarlo cuando aprende cosas nuevas sobre ti.',
  'userExample':
      'Ejemplo:\n\u2022 Nombre: Alex\n\u2022 Zona horaria: Europe/Berlin\n\u2022 Idioma: mezcla alemán/inglés\n\u2022 Prefiere respuestas concisas y técnicas',
  'memory': 'Memoria',
  'memoryHint':
      'Conocimiento a largo plazo que la IA recuerda entre conversaciones. La IA también puede actualizarlo cuando aprende hechos o decisiones importantes.',
  'memoryExample':
      'Ejemplo:\n\u2022 Prefiere Dart/Flutter para móvil\n\u2022 Licencia: BSL para todos los proyectos\n\u2022 Proyecto actual: chuk_chat\n\u2022 Entusiasta del modo oscuro',
  'importFromAnotherAi': 'Importar desde otra IA',
  'systemPrompt': 'Prompt del sistema',
  'systemPromptHint':
      'Instrucciones personalizadas enviadas con cada conversación. Cifradas con tu clave de cifrado de chat.',
  'systemPromptExample':
      'Ejemplo: Eres un asistente útil. Proporciona respuestas concisas y precisas.',
  'characters': 'caracteres',
  'saving': 'Guardando...',
  'saveChanges': 'Guardar cambios',

  // ── About page ─────────────────────────────────────────────
  'chukChat': 'Chuk Chat',
  'openSourceLicenses': 'Licencias de código abierto',
  'openSourceLicensesSubtitle':
      'Revisa las licencias de cada dependencia incluida en esta compilación.',
  'termsOfService': 'Términos de servicio',
  'privacyPolicy': 'Política de privacidad',
  'versionText': 'Versión {version}',
  'updateAvailable': 'Actualización disponible: v{version} \u2014 toca para descargar',
  'versionUnavailable': 'Información de versión no disponible.',
  'copyrightYear':
      '\u00a9 {year} Chuk Development\nTodos los derechos reservados.',
  'licenses': 'Licencias',
  'unableToLoadLicenses': 'No se pueden cargar las licencias.',
  'tapToViewLicense': 'Toca para ver el texto completo de la licencia',
  'devOptionsEnabled': 'Opciones de desarrollador activadas',
  'devOptionsAlreadyEnabled': 'Las opciones de desarrollador ya están activadas',
  'devOptionsTapSingular': '{taps} toque más para Opciones de desarrollador',
  'devOptionsTapsPlural': '{taps} toques más para Opciones de desarrollador',

  // ── Pricing page ───────────────────────────────────────────
  'subscription': 'Suscripción',
  'openUsageDetailsInfo':
      'Abre Detalles de uso para ver cada solicitud, totales mensuales y costos por modelo.',
  'openUsageDetails': 'Abrir detalles de uso',
  'currentPlan': 'Plan actual',
  'plus': 'Plus',
  'pricePerMonth': '\u20ac20/mes',
  'monthlyCredits': 'Créditos mensuales de IA: \u20ac16,00',
  'unusedCreditsExpire':
      'Los créditos no utilizados expiran al final de cada mes.',
  'manageBilling': 'Gestionar facturación',
  'manageBillingSubtitle':
      'Usa el portal de facturación para cancelar tu suscripción o actualizar los métodos de pago.',
  'active': 'ACTIVO',
  'getCreditsMonthly': 'Obtén \u20ac16 en créditos de IA mensuales',
  'accessAllModels': 'Acceso a todos los modelos de IA',
  'imageGeneration': 'Generación de imágenes',
  'voiceMode': 'Modo de voz',
  'textChatReasoning': 'Chat de texto con razonamiento',
  'creditsExplanation':
      'Tus \u20ac16 en créditos de IA se utilizan por token según el modelo que elijas. Los créditos no utilizados expiran al final de cada mes.',
  'immediateAccessAck':
      'Quiero acceso inmediato a Chuk Chat y reconozco que pierdo mi ',
  'rightOfWithdrawal': 'derecho de desistimiento',
  'onceServiceBegins': ' una vez que el servicio comience. Acepto los ',
  'subscribeNow': 'Suscribirse ahora',
  'alreadySubscribed': 'Ya tienes una suscripción activa.',
  'opening': 'Abriendo...',
  'agreeToTermsFirst':
      'Por favor, acepta los términos y reconoce la pérdida de los derechos de desistimiento.',

  // ── Login page ─────────────────────────────────────────────
  'welcomeToChukChat': 'Bienvenido a Chuk Chat',
  'signInWithEmail': 'Inicia sesión con tu correo electrónico',
  'createAccountWithEmail': 'Crea una cuenta con correo electrónico y contraseña',
  'supabaseNotConfigured':
      'Las credenciales de Supabase no están configuradas. Actualízalas antes de ejecutar una compilación de producción.',
  'howOthersSeeYou': 'Cómo te verán los demás',
  'email': 'Correo electrónico',
  'emailPlaceholder': 'tu@ejemplo.com',
  'confirmPassword': 'Confirmar contraseña',
  'forgotPassword': '¿Olvidaste tu contraseña?',
  'enterYourPassword': 'Introduce tu contraseña.',
  'pleaseConfirmPassword': 'Por favor, confirma tu contraseña.',
  'signIn': 'Iniciar sesión',
  'createAccount': 'Crear cuenta',
  'noAccountSignUp': '¿No tienes cuenta? Regístrate',
  'haveAccountSignIn': '¿Ya tienes cuenta? Inicia sesión',
  'agreeToTerms': 'Acepto los ',
  'andText': ' y ',
  'confirmAge16': 'Confirmo que tengo al menos 16 años',
  'mustAgreeToTerms':
      'Debes aceptar los Términos de servicio y la Política de privacidad para crear una cuenta.',
  'mustBe16': 'Debes tener al menos 16 años para usar este servicio.',
  'unexpectedError': 'Error inesperado: {error}',

  // ── Recover chats page ─────────────────────────────────────
  'recoverEncryptedChats': 'Recuperar chats cifrados',
  'noLockedChats': 'No hay chats bloqueados',
  'allChatsAccessible': 'Todos tus chats son accesibles.',
  'recoverChatsInfo':
      'Algunos chats están cifrados con una contraseña anterior. Introduce tu contraseña antigua para recuperarlos o elimínalos permanentemente.',
  'encryptedWithVersion': 'Cifrado con versión de contraseña {version}',
  'oldPassword': 'Contraseña anterior',
  'enterOldPassword': 'Introduce la contraseña que usabas antes',
  'lockedChatCountSingular': '{count} chat bloqueado',
  'lockedChatCountPlural': '{count} chats bloqueados',
  'deleteLockedChatsTitle': '¿Eliminar chats bloqueados?',
  'deleteLockedChatsBodySingular':
      'Esto eliminará permanentemente {count} chat cifrado con tu contraseña anterior.\n\nEste chat no se podrá recuperar después de la eliminación. Perderás todos los mensajes, imágenes y archivos adjuntos.',
  'deleteLockedChatsBodyPlural':
      'Esto eliminará permanentemente {count} chats cifrados con tu contraseña anterior.\n\nEstos chats no se podrán recuperar después de la eliminación. Perderás todos los mensajes, imágenes y archivos adjuntos.',
  'deletePermanently': 'Eliminar permanentemente',
  'areYouSure': '¿Estás seguro?',
  'confirmDeleteChats':
      'Estás a punto de eliminar {count} chats. Escribe ELIMINAR para confirmar.',
  'typeDelete': 'Escribe ELIMINAR',
  'confirmDelete': 'Confirmar eliminación',
  'pleaseEnterOldPassword': 'Por favor, introduce tu contraseña anterior.',
  'derivingKey': 'Derivando clave de cifrado...',
  'recoveredChatsSingular': 'Se recuperó correctamente {count} chat.',
  'recoveredChatsPlural': 'Se recuperaron correctamente {count} chats.',
  'recoveryFailed': 'Error en la recuperación. Por favor, inténtalo de nuevo.',
  'deletedChatsSingular': 'Se eliminó {count} chat.',
  'deletedChatsPlural': 'Se eliminaron {count} chats.',
  'deletionFailed': 'Error en la eliminación. Por favor, inténtalo de nuevo.',
  'recover': 'Recuperar',
  'delete': 'Eliminar',
  'deleting': 'Eliminando...',

  // ── Set new password page ──────────────────────────────────
  'setNewPassword': 'Establecer una nueva contraseña',
  'setNewPasswordInfo':
      'Elige una contraseña segura para tu cuenta. Tus chats antiguos seguirán siendo accesibles si recuerdas tu contraseña anterior.',
  'setNewPasswordButton': 'Establecer nueva contraseña',
  'noAuthenticatedUser': 'No hay usuario autenticado después de actualizar la contraseña.',
  'failedToPreserveEncryption':
      'Error al preservar los datos de cifrado antiguos. Por favor, verifica tu conexión e inténtalo de nuevo.',
  'failedToSetNewPassword':
      'Error al establecer la nueva contraseña. Por favor, inténtalo de nuevo.',

  // ── Diagnostics page ───────────────────────────────────────
  'devOptionsToggle': 'Opciones de desarrollador',
  'devOptionsToggleSubtitle':
      'Desbloquear diagnósticos y herramientas de depuración. Desactiva para ocultar todos los ajustes solo para desarrolladores.',
  'enableDiagnosticsLogging': 'Activar registro de diagnósticos',
  'enableDiagnosticsSubtitle':
      'Funciona en compilaciones de producción. Registra metadatos de la app/entorno para solucionar problemas de rendimiento y bandeja del sistema.',
  'diagnosticsEnabled': 'Registro de diagnósticos activado',
  'diagnosticsDisabled': 'Registro de diagnósticos desactivado',
  'notInitializedYet': 'Aún no inicializado',
  'refresh': 'Actualizar',
  'copyRecent': 'Copiar recientes',
  'copyFocusedDebug': 'Copiar depuración enfocada',
  'shareFile': 'Compartir archivo',
  'clear': 'Limpiar',
  'copiedRecentLogs': 'Registros recientes copiados al portapapeles',
  'noFocusedDebugData': 'Aún no hay datos de depuración enfocada disponibles',
  'copiedFocusedDebug': 'Informe de depuración enfocada del menú de modelos copiado',
  'failedFocusedDebug':
      'Error al crear el informe de depuración enfocada: {error}',
  'noDiagnosticsLog': 'No hay registro de diagnósticos disponible',
  'diagnosticsLogNotFound': 'Archivo de registro de diagnósticos no encontrado',
  'failedToShareLog': 'Error al compartir el registro de diagnósticos: {error}',
  'diagnosticsLogCleared': 'Registro de diagnósticos borrado',
  'failedToClearLog': 'Error al borrar el registro de diagnósticos: {error}',
  'devOptionsDisabledMsg': 'Opciones de desarrollador desactivadas.',
  'noLogsYet':
      'Aún no hay registros. Activa el registro de diagnósticos y usa la app para recopilar datos.',

  // ── Connector detail page ──────────────────────────────────
  'back': 'Atrás',
  'enabled': 'Activado',
  'disabled': 'Desactivado',
  'modelPrompt': 'Prompt del modelo',
  'modelPromptHint':
      'Esta descripción se muestra al modelo después del descubrimiento de herramientas.',
  'customPromptActive': 'Prompt personalizado activo',
  'savePrompt': 'Guardar prompt',
  'parameters': 'Parámetros',

  // ── Usage details page ─────────────────────────────────────
  'usageDetails': 'Detalles de uso',
  'unableToLoadUsage': 'No se pueden cargar los detalles de uso en este momento.',
  'usageAndBilling': 'Uso y facturación',
  'usageReadOnly':
      'Esta pantalla es de solo lectura y se obtiene de tus registros de uso.',
  'period': 'Período',
  'totals': 'Totales',
  'mediaRequestsNote':
      'Las solicitudes de imágenes y audio se tratan como solicitudes multimedia y se excluyen de los totales de tokens de texto.',
  'noRequestsFound': 'No se encontraron solicitudes para este período.',

  // ── Model selector page ────────────────────────────────────
  'sessionExpired': 'Sesión expirada. Por favor, inicia sesión de nuevo.',
  'free': 'Gratis',
  'best': 'Mejor',

  // ── Message bubble / chat ──────────────────────────────────
  'openInMailApp': 'Abrir en la app de correo',
  'unableToSaveImage': 'No se puede guardar la imagen',
  'image': 'Imagen',
  'open': 'Abrir',

  // ── Misc / shared ─────────────────────────────────────────
  'original': 'Original',
  'markdown': 'Markdown',
  'deleteFile': 'Eliminar archivo',
  'deleteFailed': 'Error al eliminar: {error}',

  // ── Chat UI ────────────────────────────────────────────────
  'askMeAnything': '¡Pregúntame lo que quieras!',
  'aiDisclaimer': 'Estás chateando con una IA: puede equivocarse. Verifica lo importante.',
  'queuedLabel': 'En cola',
  'editYourMessage': 'Edita tu mensaje...',
  'addMessageOrDocs': 'Añade un mensaje o envía documentos',
  'micAccessFailed': 'Error de acceso al micrófono',
  'transcriptionFailed': 'Error en la transcripción',
  'nothingToResend': 'Nada que reenviar',
  'freeMessagesUsed': 'Mensajes gratuitos agotados',
  'ok': 'OK',
  'camera': 'Cámara',
  'photos': 'Fotos',
  'files': 'Archivos',

  // ── Model selector ─────────────────────────────────────────
  'models': 'Modelos',
  'searchModels': 'Buscar modelos...',
  'modelError': 'Error: {error}',

  // ── Message bubble extras ──────────────────────────────────

  // ── Free message display ───────────────────────────────────
  'freeTotal': 'Total: {count}',
  'freeRemaining': 'Gratis: {remaining}/{total}',

  // ── Model selection dropdown ───────────────────────────────
  'selectModel': 'Seleccionar modelo',
  'noEnabledModels': 'Sin modelos activados',

  // ── Navigation / sidebar ────────────────────────────────────
  'newChat': 'Nuevo chat',
  'workspaces': 'Espacios de trabajo',
  'media': 'Medios',

  // ── Media manager ──────────────────────────────────────────
  'mediaManager': 'Gestor de medios',
  'imageUsedInChats': 'Imagen usada en chats',
  'imageUsedInChatsBody':
      'Esta imagen se usa en los siguientes chats:',
  'deleteImageShowDeleted':
      'Si eliminas esta imagen, aparecerá como "Imagen eliminada" en esos chats.',
  'deleteImageConfirm':
      '¿Estás seguro de que quieres eliminar esta imagen?',
  'deleteAnyway': 'Eliminar de todos modos',
  'deleteImageTitle': 'Eliminar imagen',
  'deleteImageBody':
      '¿Estás seguro de que quieres eliminar esta imagen? Esta acción no se puede deshacer.',
  'imageDeleted': 'Imagen eliminada',
  'failedToDeleteImage': 'Error al eliminar la imagen: {error}',
  'someImagesUsedInChats': 'Algunas imágenes se usan en chats',
  'deletedImagesWarning':
      'Las imágenes eliminadas aparecerán como "Imagen eliminada" en esos chats.',
  'deleteAllCount': '¿Eliminar las {count} imágenes seleccionadas?',
  'deleteAll': 'Eliminar todo',
  'deleteSelectedImages': 'Eliminar imágenes seleccionadas',
  'deleteSelectedCount':
      '¿Eliminar {count} imágenes seleccionadas? Esta acción no se puede deshacer.',
  'deletedImagesResult': 'Se eliminaron {deleted} imágenes, {failed} fallaron',
  'deletedImagesSuccess': 'Se eliminaron {deleted} imágenes',
  'downloadSelected': 'Descargar seleccionadas',
  'deleteSelected': 'Eliminar seleccionadas',
  'errorLoadingImages': 'Error al cargar las imágenes',
  'noImagesStored': 'No hay imágenes almacenadas',
  'imagesAppearHere': 'Las imágenes que envíes en los chats aparecerán aquí',
  'download': 'Descargar',

  // ── Attachment preview bar ─────────────────────────────────
  'removeFile': 'Eliminar {name}',
  'edit': 'Editar',
  'close': 'Cerrar',

  // ── Subscription dialogs ───────────────────────────────────
  'bashSandboxFolder': 'Carpeta del sandbox',
  'bashSandboxFolderUnset': 'Sin definir: los comandos bash se rechazan',
  'bashSandboxChooseDialog': 'Elegir la carpeta del sandbox de bash',
};
