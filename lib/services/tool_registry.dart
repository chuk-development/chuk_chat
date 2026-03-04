import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_executor.dart' show ToolExecutor;

/// Maps tool names to their ToolCategory for enable/disable filtering.
const Map<String, ToolCategory> toolCategoryMap = {
  'find_tools': ToolCategory.basic,
  'calculate': ToolCategory.basic,
  'get_time': ToolCategory.basic,
  'get_device_info': ToolCategory.basic,
  'random_number': ToolCategory.basic,
  'flip_coin': ToolCategory.basic,
  'roll_dice': ToolCategory.basic,
  'countdown': ToolCategory.basic,
  'password_generator': ToolCategory.basic,
  'uuid_generator': ToolCategory.basic,
  'notes': ToolCategory.basic,
  'generate_qr': ToolCategory.basic,
  'ask_user': ToolCategory.basic,
  'web_search': ToolCategory.search,
  'web_crawl': ToolCategory.search,
  'generate_image': ToolCategory.search,
  'edit_image': ToolCategory.search,
  'fetch_image': ToolCategory.search,
  'view_chat_images': ToolCategory.search,
  'stock_data': ToolCategory.search,
  'weather': ToolCategory.search,
  'search_places': ToolCategory.map,
  'search_restaurants': ToolCategory.map,
  'geocode': ToolCategory.map,
  'get_route': ToolCategory.map,
  'spotify_control': ToolCategory.spotify,
  'bash': ToolCategory.bash,
  'github': ToolCategory.github,
  'slack': ToolCategory.slack,
  'google_calendar': ToolCategory.google,
  'gmail': ToolCategory.google,
  'email': ToolCategory.email,
  'nextcloud': ToolCategory.nextcloud,
  'device': ToolCategory.device,
  'search_chats': ToolCategory.basic,
};

/// Discovery catalog: category labels -> human-readable descriptions.
/// NO tool names exposed -- model must call find_tools to discover them.
const Map<String, String> discoveryCatalog = {
  'Maps / Karten':
      'Find places and restaurants, geocode addresses and calculate routes / '
      'Orte und Restaurants finden, Adressen geocoden, Routen berechnen',
  'Web':
      'Search the internet, crawl/read webpages, generate/edit/fetch images '
      '(costs credits, not private) / '
      'Im Internet suchen, Webseiten lesen, Bilder erzeugen/bearbeiten/holen '
      '(kostet Credits, nicht privat)',
  'Finance / Finanzen':
      'Get stock quotes and historical price data / '
      'Aktienkurse und Kursverlauf abrufen',
  'Weather / Wetter':
      'Current conditions, forecast (up to 16 days), hourly forecast / '
      'Aktuelles Wetter, Vorhersage (bis 16 Tage)',
  'Utilities / Hilfsmittel':
      'Calculate, time, random numbers, dice, coin flip, countdown, '
      'passwords, UUIDs, notes, QR codes and chat history search / '
      'Rechnen, Uhrzeit, Zufallszahlen, Passwörter, UUIDs, Notizen, QR, '
      'Chat-Verlauf durchsuchen',
  'Music / Musik':
      'Spotify: play, pause, search, playlists, volume / '
      'Spotify steuern: abspielen, pausieren, suchen, Playlists, Lautstärke',
  'Productivity / Produktivität':
      'Email (IMAP/SMTP), Gmail, Slack, GitHub, Nextcloud, Google Calendar / '
      'E-Mail, Gmail, Slack, GitHub, Nextcloud, Google Kalender',
  'Device / Gerät':
      'Create calendar events, set alarms/timers, SMS draft, GPS location / '
      'Kalendereinträge erstellen, Wecker/Timer setzen, SMS-Entwurf, GPS-Standort',
  'System':
      'Execute bash commands (sandboxed) / Bash-Befehle ausführen (sandboxed)',
};

/// All built-in tool definitions with tags for discovery.
final List<ClientTool> builtinTools = [
  // -- Meta-tool: find_tools --
  ClientTool(
    name: 'find_tools',
    description:
        'Discovery tool. Call this first in discovery mode. Provide 1-3 '
        'short category keywords and use returned TOOL entries to choose '
        'the next tool call.',
    parameters: {
      'query':
          'string (required: 1-3 SHORT category keywords -- e.g. '
          '"restaurant", "web search", "email", "rechnen". '
          'Do NOT paste the user message - use short tool-category keywords '
          'only)',
    },
    type: ToolType.builtin,
    tags: ['meta', 'tools', 'search', 'find', 'discover'],
  ),

  // -- Basic utilities --
  ClientTool(
    name: 'calculate',
    description:
        'Evaluate a math expression and return the numeric result. Supports '
        'operator precedence, parentheses, + - * / ^, and functions such as '
        'sqrt/sin/cos/tan/log/ln/abs/exp.',
    parameters: {'expression': 'string'},
    type: ToolType.builtin,
    tags: ['math', 'rechnen', 'calculate', 'berechnen', 'prozent', 'percent'],
  ),
  ClientTool(
    name: 'get_time',
    description: 'Return the current local date and time.',
    parameters: {},
    type: ToolType.builtin,
    tags: ['time', 'date', 'uhr', 'zeit', 'datum', 'clock'],
  ),
  ClientTool(
    name: 'get_device_info',
    description:
        'Return runtime environment info (platform, web/native, debug/release).',
    parameters: {},
    type: ToolType.builtin,
    tags: ['device', 'system', 'os', 'platform', 'info'],
  ),
  ClientTool(
    name: 'random_number',
    description:
        'Generate a random integer in range [min, max]. Defaults: min=1, '
        'max=100.',
    parameters: {'min': 'int', 'max': 'int'},
    type: ToolType.builtin,
    tags: ['random', 'zufall', 'zufallszahl'],
  ),
  ClientTool(
    name: 'flip_coin',
    description: 'Simulate a coin flip and return Heads or Tails.',
    parameters: {},
    type: ToolType.builtin,
    tags: ['coin', 'flip', 'zufall', 'random'],
  ),
  ClientTool(
    name: 'roll_dice',
    description:
        'Roll one or more dice and return individual rolls plus total.',
    parameters: {'sides': 'int', 'count': 'int'},
    type: ToolType.builtin,
    tags: ['dice', 'roll', 'zufall', 'random', 'game'],
  ),
  ClientTool(
    name: 'countdown',
    description:
        'Return days remaining until a target ISO date (or days since if in '
        'the past).',
    parameters: {'date': 'string YYYY-MM-DD'},
    type: ToolType.builtin,
    tags: ['countdown', 'date', 'days', 'tage', 'datum'],
  ),
  ClientTool(
    name: 'password_generator',
    description:
        'Generate a random password from letters, digits, and symbols.',
    parameters: {'length': 'int'},
    type: ToolType.builtin,
    tags: ['password', 'passwort', 'security', 'generate'],
  ),
  ClientTool(
    name: 'uuid_generator',
    description: 'Generate a UUID v4.',
    parameters: {},
    type: ToolType.builtin,
    tags: ['uuid', 'id', 'unique', 'generate'],
  ),
  ClientTool(
    name: 'notes',
    description:
        'Identity & memory system. You can read and write all three stores. '
        'update_memory: replace the full memory text (curated knowledge). '
        'update_user: replace the full user profile text. '
        'update_soul: replace the soul/personality text (MUST inform user). '
        'All three (Soul, User, Memory) are always in context — you already '
        'know what is stored. Proactively update when you learn new facts.',
    parameters: {
      'action': 'string (update_memory, update_user, update_soul)',
      'content': 'string (full replacement text for the chosen store)',
    },
    type: ToolType.builtin,
    tags: [
      'notes',
      'note',
      'memory',
      'memo',
      'notiz',
      'merken',
      'user',
      'identity',
      'soul',
    ],
  ),
  ClientTool(
    name: 'search_chats',
    description:
        'Two-step chat history search. Step 1 (find_chats): search across '
        'saved chats and return matching chat IDs. Step 2 '
        '(search_in_chat): search inside one chat_id with a more specific '
        'query. Decrypts chats on-demand if they are not already loaded.',
    parameters: {
      'action':
          'string (optional: find_chats or search_in_chat; defaults to '
          'find_chats when no chat_id is provided)',
      'query': 'string (required: search term)',
      'chat_id': 'string (required for search_in_chat)',
      'limit':
          'int (optional for find_chats: max matching chats to return, '
          'default 10)',
      'message_limit':
          'int (optional for search_in_chat: max matching messages to show, '
          'default 8)',
    },
    type: ToolType.builtin,
    tags: [
      'search',
      'chat',
      'chat id',
      'history',
      'find',
      'old',
      'previous',
      'remember',
      'recall',
      'conversation',
      'suchen',
      'verlauf',
      'finden',
      'erinnern',
      'gespräch',
      'früher',
      'gesagt',
    ],
  ),

  ClientTool(
    name: 'generate_qr',
    description:
        'Generate a QR-code PNG locally on the device (private, no network '
        'call) and return IMAGE_DATA for inline display.',
    parameters: {
      'data': 'string (required: text or URL to encode)',
      'size': 'int (optional: image size in pixels, 100-1000, default 400)',
    },
    type: ToolType.builtin,
    tags: ['qr', 'qrcode', 'barcode', 'scan', 'link', 'url', 'code'],
  ),

  // -- Interaction --
  ClientTool(
    name: 'ask_user',
    description:
        'Present the user with a question and numbered options to choose '
        'from. Use when you need clarification or the user should pick '
        'between alternatives before proceeding. The result is shown as '
        'a numbered list; the user replies with their choice.',
    parameters: {
      'question': 'string (required: the question to ask)',
      'options':
          'list of strings (required: 2-6 short option labels, e.g. '
          '["Option A", "Option B", "Option C"])',
    },
    type: ToolType.builtin,
    tags: [
      'ask',
      'question',
      'confirm',
      'choose',
      'select',
      'fragen',
      'auswahl',
      'bestätigen',
    ],
  ),

  // -- Web --
  ClientTool(
    name: 'web_search',
    description:
        'Search the web and return ranked results with links. Also auto-fetches '
        'readable content from top results to provide immediate context. Use '
        'web_crawl for deep fetch of a specific URL.',
    parameters: {
      'query': 'string (required: the search query)',
      'count': 'int (optional: number of search results, default 5, max 8)',
      'include_content':
          'bool (optional: auto-fetch page content from top hits, default true)',
      'crawl_count':
          'int (optional: number of top URLs to auto-fetch, default 2, max 3)',
      'crawl_max_chars':
          'int (optional: max chars per auto-fetched page, default 3000, max 8000)',
    },
    type: ToolType.builtin,
    tags: [
      'web',
      'search',
      'suchen',
      'internet',
      'google',
      'price',
      'preis',
      'news',
      'nachrichten',
      'info',
      'find',
      'finden',
      'aktuell',
      'current',
      'facts',
      'fakten',
    ],
  ),
  ClientTool(
    name: 'web_crawl',
    description:
        'Fetch and extract readable content from a single URL. Use this when '
        'you need full page text, often after web_search.',
    parameters: {'url': 'string (required: the URL to crawl)'},
    type: ToolType.builtin,
    tags: [
      'web',
      'crawl',
      'page',
      'seite',
      'website',
      'url',
      'content',
      'read',
      'lesen',
      'article',
      'artikel',
    ],
  ),
  ClientTool(
    name: 'generate_image',
    description:
        'Generate an image from a text prompt. The image is displayed '
        'inline in the chat automatically — do NOT repeat the URL, '
        'dimensions, seed, or other technical details to the user. '
        'Costs credits (~0.01 EUR per image). '
        'PRIVACY: generated images are processed on an external server and '
        'the operator can see them — they are NOT end-to-end encrypted like '
        'chat messages. Before calling, inform the user about the cost and '
        'that image generation is not private.',
    parameters: {
      'prompt': 'string (required: descriptive image prompt)',
      'image_size':
          'string (optional preset: square_hd, square, portrait_4_3, '
          'portrait_16_9, landscape_4_3, landscape_16_9)',
    },
    type: ToolType.builtin,
    tags: [
      'image',
      'generate',
      'picture',
      'photo',
      'art',
      'bild',
      'grafik',
      'ai image',
    ],
  ),
  ClientTool(
    name: 'edit_image',
    description:
        'Edit/modify an existing image with a text instruction. Requires '
        'the URL of the source image and a prompt describing the edit. '
        'Costs credits (~0.10 EUR per edit). '
        'PRIVACY: the source image and result are processed on an external '
        'server and the operator can see them — they are NOT end-to-end '
        'encrypted like chat messages. Before calling, inform the user about '
        'the cost and that image editing is not private.',
    parameters: {
      'prompt': 'string (required: edit instruction)',
      'image_url': 'string (required: URL of the image to edit)',
      'image_size': 'string (optional: auto, square_hd, landscape_4_3, etc.)',
    },
    type: ToolType.builtin,
    tags: [
      'image',
      'edit',
      'modify',
      'change',
      'transform',
      'bild',
      'bearbeiten',
    ],
  ),
  ClientTool(
    name: 'fetch_image',
    description:
        'Download an image from a URL and store it in the chat. Use this '
        'to display an external image inline. Returns IMAGE_DATA metadata. '
        'Max size 4 MB.',
    parameters: {'url': 'string (required: direct image URL)'},
    type: ToolType.builtin,
    tags: ['image', 'fetch', 'download', 'picture', 'url', 'bild', 'foto'],
  ),
  ClientTool(
    name: 'view_chat_images',
    description:
        'Analyze images already present in this chat using vision. ONLY call '
        'when the user explicitly asks to look at, describe, or analyze an '
        'image. Do NOT call automatically after generating or fetching images.',
    parameters: {
      'indices':
          'string (optional: comma-separated image indices to analyze, '
          'e.g. "0,2")',
    },
    type: ToolType.builtin,
    tags: ['image', 'vision', 'analyze', 'inspect', 'describe', 'bildanalyse'],
  ),
  ClientTool(
    name: 'stock_data',
    description:
        'Get stock market data from Yahoo Finance. Actions: quote (current '
        'price), history (time-series chart data), compare (multiple '
        'tickers). Returns OHLC prices, volume, and summary statistics.',
    parameters: {
      'action': 'string (optional, default quote: quote, history, compare)',
      'symbol': 'string (required for quote/history, e.g. AAPL)',
      'symbols': 'string or list (required for compare, e.g. "AAPL,MSFT,NVDA")',
      'period': 'string (optional history range: 5d, 1mo, 3mo, 6mo, 1y, 5y)',
      'interval': 'string (optional history interval: 1d, 1h, 30m, 5m)',
    },
    type: ToolType.builtin,
    tags: [
      'stock',
      'aktie',
      'finance',
      'market',
      'quote',
      'ticker',
      'preis',
      'kurs',
      'yahoo',
    ],
  ),

  // -- Maps --
  ClientTool(
    name: 'search_places',
    description:
        'Search places and points of interest via OpenStreetMap/Nominatim. '
        'Filter by query and optional location (city name or lat/lon with '
        'radius).',
    parameters: {
      'query': 'string (required, e.g. pharmacy, museum, cafe)',
      'city': 'string (optional city/region filter)',
      'lat': 'number (optional center latitude)',
      'lon': 'number (optional center longitude)',
      'radius': 'int (optional meters, with lat/lon)',
      'limit': 'int (optional number of results)',
    },
    type: ToolType.builtin,
    tags: ['map', 'place', 'poi', 'location', 'ort', 'karte', 'nearby'],
  ),
  ClientTool(
    name: 'search_restaurants',
    description:
        'Search restaurants via OpenStreetMap/Nominatim. Filter by '
        'cuisine type and optional location (city name or lat/lon with '
        'radius).',
    parameters: {
      'query': 'string (optional restaurant keyword)',
      'cuisine': 'string (optional cuisine, e.g. italian, sushi)',
      'city': 'string (optional city/region filter)',
      'lat': 'number (optional center latitude)',
      'lon': 'number (optional center longitude)',
      'radius': 'int (optional meters, with lat/lon)',
      'limit': 'int (optional number of results)',
    },
    type: ToolType.builtin,
    tags: ['restaurant', 'food', 'essen', 'cuisine', 'dinner', 'lunch', 'map'],
  ),
  ClientTool(
    name: 'geocode',
    description:
        'Forward/reverse geocoding. Convert address/query to coordinates or '
        'lat/lon to address.',
    parameters: {
      'address': 'string (forward geocoding)',
      'query': 'string (alias for address)',
      'lat': 'number (reverse geocoding latitude)',
      'lon': 'number (reverse geocoding longitude)',
    },
    type: ToolType.builtin,
    tags: ['geocode', 'address', 'coordinates', 'lat', 'lon', 'ort', 'adresse'],
  ),
  ClientTool(
    name: 'get_route',
    description:
        'Compute a route between two coordinates via OSRM. Returns distance, '
        'estimated duration, and turn-by-turn step summary.',
    parameters: {
      'from_lat': 'number (required)',
      'from_lon': 'number (required)',
      'to_lat': 'number (required)',
      'to_lon': 'number (required)',
      'profile': 'string (optional: driving, walking, cycling)',
    },
    type: ToolType.builtin,
    tags: [
      'route',
      'directions',
      'navigation',
      'distance',
      'karte',
      'weg',
      'anfahrt',
    ],
  ),

  // -- Spotify --
  ClientTool(
    name: 'spotify_control',
    description:
        'Control Spotify playback and browse music. '
        'PRIORITY ORDER: '
        '1) "what am I listening to" / "was höre ich" → use now_playing FIRST. '
        '2) "play X" / specific song/artist/playlist → use find_and_play or play with URI. '
        '3) "my playlists" / "show playlists" → use get_my_playlists. '
        '4) "recently liked" / "neue songs" → use get_recently_liked. '
        '5) "stop" / "pause" / "next" / "skip" → use pause/next/previous. '
        'For all liked songs: {"action": "play", "uri": "liked"}',
    parameters: {
      'action':
          'string (now_playing, play, pause, next, previous, volume, search, '
          'devices, shuffle, repeat, find_and_play, get_my_playlists, '
          'get_recently_liked, add_to_queue, create_playlist, get_playlists)',
      'query': 'string (for search or find_and_play)',
      'volume': 'int (0-100 for volume)',
      'uri': 'string (spotify URI)',
      'state': 'string or boolean (shuffle on/off; repeat track/context/off)',
      'limit': 'int (for get_recently_liked, default 20)',
      'name': 'string (for create_playlist)',
      'description': 'string (for create_playlist)',
    },
    type: ToolType.builtin,
    tags: [
      'spotify',
      'music',
      'musik',
      'song',
      'play',
      'abspielen',
      'playlist',
      'album',
      'artist',
      'künstler',
      'pause',
      'skip',
      'next',
      'volume',
      'lautstärke',
      'shuffle',
      'höre',
      'listening',
    ],
  ),

  // -- Bash --
  ClientTool(
    name: 'bash',
    description:
        'Execute bash commands in sandbox folder. Safe: ls, cat, mkdir, cp, '
        'mv, rm, touch, ffmpeg. Others need approval.',
    parameters: {'command': 'string'},
    type: ToolType.builtin,
    tags: [
      'bash',
      'shell',
      'command',
      'terminal',
      'file',
      'datei',
      'execute',
      'run',
      'script',
    ],
  ),

  // -- GitHub --
  ClientTool(
    name: 'github',
    description:
        'GitHub repos & issues. Actions: get_user, list_repos, get_repo, '
        'list_issues, create_issue, list_pull_requests, add_comment',
    parameters: {
      'action': 'string (required)',
      'owner': 'string (repo owner)',
      'repo': 'string (repo name)',
      'issue_number': 'int (for comments)',
      'title': 'string (for create_issue)',
      'body': 'string (for issue/comment)',
      'state': 'string (open/closed)',
    },
    type: ToolType.builtin,
    tags: [
      'github',
      'git',
      'repo',
      'repository',
      'code',
      'issue',
      'pull request',
      'pr',
      'commit',
    ],
  ),

  // -- Slack --
  ClientTool(
    name: 'slack',
    description:
        'Slack messaging. Actions: list_channels, get_channel_history, '
        'send_message, search_messages, get_users, find_channel',
    parameters: {
      'action': 'string (required)',
      'channel_id': 'string',
      'channel_name': 'string (to find)',
      'message': 'string (for send)',
      'query': 'string (for search)',
      'limit': 'int',
      'thread_ts': 'string (for threads)',
    },
    type: ToolType.builtin,
    tags: [
      'slack',
      'message',
      'nachricht',
      'chat',
      'channel',
      'team',
      'communication',
    ],
  ),

  // -- Google Calendar --
  ClientTool(
    name: 'google_calendar',
    description:
        'Google Calendar. Actions: list_calendars, list_events, '
        'create_event, update_event, delete_event',
    parameters: {
      'action': 'string (required)',
      'calendar_id': 'string (default: primary)',
      'event_id': 'string (for update/delete)',
      'summary': 'string (event title)',
      'description': 'string',
      'location': 'string',
      'start': 'string (ISO datetime)',
      'end': 'string (ISO datetime)',
      'attendees': 'list of emails',
      'max_results': 'int',
    },
    type: ToolType.builtin,
    tags: [
      'google',
      'calendar',
      'kalender',
      'event',
      'termin',
      'meeting',
      'schedule',
      'zeitplan',
    ],
  ),

  // -- Gmail --
  ClientTool(
    name: 'gmail',
    description:
        'Gmail email. Actions: list_messages, read_message, send_email, '
        'get_labels',
    parameters: {
      'action': 'string (required)',
      'message_id': 'string (for read)',
      'to': 'string (recipient)',
      'subject': 'string',
      'body': 'string',
      'cc': 'string',
      'query': 'string (Gmail search)',
      'max_results': 'int',
    },
    type: ToolType.builtin,
    tags: [
      'gmail',
      'google',
      'email',
      'mail',
      'send',
      'senden',
      'inbox',
      'posteingang',
    ],
  ),

  // -- Email (IMAP/SMTP) --
  ClientTool(
    name: 'email',
    description:
        'Universal email via IMAP/SMTP. Actions: list_mailboxes, '
        'list_emails, search_emails, read_email, send_email, unread_count. '
        'Sending requires user approval.',
    parameters: {
      'action': 'string (required)',
      'mailbox': 'string (default: INBOX)',
      'sequence_id': 'int (for read/delete/move/mark)',
      'to': 'string (recipient for send)',
      'subject': 'string (for send)',
      'body': 'string (for send)',
      'cc': 'string (for send)',
      'bcc': 'string (for send)',
      'from': 'string (search filter)',
      'text': 'string (search query)',
      'since': 'string (date YYYY-MM-DD)',
      'before': 'string (date YYYY-MM-DD)',
      'unread_only': 'boolean (search filter)',
      'limit': 'int (default: 20)',
      'offset': 'int (default: 0)',
    },
    type: ToolType.builtin,
    tags: [
      'email',
      'mail',
      'imap',
      'smtp',
      'inbox',
      'posteingang',
      'send',
      'senden',
      'read',
      'lesen',
      'message',
      'nachricht',
    ],
  ),

  // -- Nextcloud --
  ClientTool(
    name: 'nextcloud',
    description:
        'Nextcloud files & calendar. Actions: list_files, download_file, '
        'upload_file, delete_file, create_directory, get_calendars, '
        'get_events, get_contacts',
    parameters: {
      'action': 'string (required)',
      'path': 'string (file path)',
      'content': 'string (for upload)',
      'calendar_id': 'string (for events)',
      'start_date': 'string (ISO date)',
      'end_date': 'string (ISO date)',
    },
    type: ToolType.builtin,
    tags: [
      'nextcloud',
      'cloud',
      'files',
      'dateien',
      'upload',
      'download',
      'calendar',
      'kalender',
      'contacts',
      'kontakte',
    ],
  ),

  // -- Device --
  ClientTool(
    name: 'device',
    description:
        'Native device features. Creates calendar events the user just '
        'clicks to confirm, sets alarms/timers with notifications, '
        'opens SMS or email drafts for user to review, gets GPS location. '
        'Actions: create_calendar_event, set_alarm, set_timer, cancel_alarm, '
        'list_alarms, sms_draft, email_draft, get_location, get_last_location, '
        'platform_info, distance. '
        'IMPORTANT: For calendar events, SMS, and email drafts, the user gets '
        'to review and confirm before anything is sent.',
    parameters: {
      'action': 'string (required)',
      'title': 'string (for calendar event or alarm)',
      'start': 'string (ISO datetime for calendar event start)',
      'end': 'string (ISO datetime for calendar event end)',
      'description': 'string (calendar event description)',
      'location': 'string (calendar event location)',
      'all_day': 'boolean (calendar event all-day flag)',
      'time': 'string (ISO datetime for alarm)',
      'label': 'string (timer label)',
      'seconds': 'int (timer duration in seconds)',
      'minutes': 'int (timer duration in minutes)',
      'alarm_id': 'int (for cancel_alarm)',
      'phone': 'string (phone number for sms_draft)',
      'message': 'string (SMS message body)',
      'to': 'string (email address for email_draft)',
      'subject': 'string (email subject)',
      'cc': 'string (email CC)',
      'bcc': 'string (email BCC)',
      'from_lat': 'double (for distance calculation)',
      'from_lon': 'double (for distance calculation)',
      'to_lat': 'double (for distance calculation)',
      'to_lon': 'double (for distance calculation)',
    },
    type: ToolType.builtin,
    tags: [
      'device',
      'gerät',
      'calendar',
      'kalender',
      'alarm',
      'wecker',
      'timer',
      'sms',
      'gps',
      'location',
      'standort',
      'reminder',
      'erinnerung',
      'termin',
      'event',
      'nähe',
      'nearby',
      'position',
    ],
  ),

  // -- Weather --
  ClientTool(
    name: 'weather',
    description:
        'Get weather data. Actions: current, forecast, hourly. Accepts '
        'location name or latitude/longitude.',
    parameters: {
      'location': 'string (city/place name, e.g. "Berlin", "New York")',
      'latitude': 'number (optional: direct WGS84 latitude)',
      'longitude': 'number (optional: direct WGS84 longitude)',
      'action':
          'string (optional, default "current": current, forecast, '
          'hourly)',
      'days': 'int (optional, default 7: forecast days 1-16)',
      'hours': 'int (optional, default 24: hours 1-48)',
    },
    type: ToolType.builtin,
    tags: [
      'weather',
      'wetter',
      'temperature',
      'temperatur',
      'forecast',
      'vorhersage',
      'rain',
      'regen',
      'wind',
      'sun',
      'sonne',
    ],
  ),
];

/// Register all built-in tools from [builtinTools] into a [ToolExecutor].
void registerBuiltinTools(ToolExecutor executor) {
  for (final tool in builtinTools) {
    executor.registerTool(tool);
  }
}
