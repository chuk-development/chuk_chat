import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/platform_config.dart'
    show
        kFeatureArtifacts,
        kFeatureServerTools,
        kFeatureSkills,
        kFeatureSpotify,
        kPlatformDesktop,
        kPlatformMobile;
import 'package:chuk_chat/services/tool_executor.dart' show ToolExecutor;
import 'package:chuk_chat/utils/io_helper.dart' show Platform;

const Set<String> _serverBackedToolNames = {
  'github',
  'slack',
  'google_calendar',
  'gmail',
  // Sandbox tools — proxy through the api_server to the chuk-chat-sandbox
  // upstream. Gating them with kFeatureServerTools keeps offline /
  // server-free builds from advertising tools they cannot fulfil.
  'code_run',
  'sandbox_list',
  'sandbox_read',
  'sandbox_write',
  'sandbox_reset',
  'send_file_to_user',
};

/// Maps tool names to their ToolCategory for enable/disable filtering.
const Map<String, ToolCategory> toolCategoryMap = {
  'find_tools': ToolCategory.basic,
  'calculate': ToolCategory.basic,
  'get_time': ToolCategory.basic,
  'random_number': ToolCategory.basic,
  'flip_coin': ToolCategory.basic,
  'roll_dice': ToolCategory.basic,
  'countdown': ToolCategory.basic,
  'password_generator': ToolCategory.basic,
  'uuid_generator': ToolCategory.basic,
  'notes': ToolCategory.basic,
  'generate_qr': ToolCategory.basic,
  'ask_user': ToolCategory.basic,
  'skill': ToolCategory.basic,
  'web_search': ToolCategory.search,
  'web_crawl': ToolCategory.search,
  'generate_image': ToolCategory.search,
  'fetch_image': ToolCategory.search,
  'view_chat_images': ToolCategory.search,
  'crypto_data': ToolCategory.search,
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
  'device': ToolCategory.device,
  'calendar': ToolCategory.device,
  'reminder': ToolCategory.device,
  'search_chats': ToolCategory.basic,
  'artifact_manager': ToolCategory.basic,
  'artifact_schema': ToolCategory.basic,
  'update_project': ToolCategory.basic,
  'typst_compile': ToolCategory.basic,
  'code_run': ToolCategory.sandbox,
  'sandbox_list': ToolCategory.sandbox,
  'sandbox_read': ToolCategory.sandbox,
  'sandbox_write': ToolCategory.sandbox,
  'sandbox_reset': ToolCategory.sandbox,
  'send_file_to_user': ToolCategory.sandbox,
};

/// Discovery catalog: category labels -> human-readable descriptions.
/// Tool names are shown in discovery mode; detailed descriptions stay gated.
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
      'Cryptocurrency prices, market data, trending coins (CoinGecko) / '
      'Kryptowährungspreise, Marktdaten, Trending Coins (CoinGecko)',
  'Domains':
      'Check domain name availability across 1400+ TLDs with WHOIS data / '
      'Domain-Verfügbarkeit über 1400+ TLDs prüfen, WHOIS-Daten',
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
  if (kFeatureServerTools)
    'Productivity / Produktivität':
        'Email (IMAP/SMTP), Gmail, Slack, GitHub, Nextcloud, Google Calendar / '
        'E-Mail, Gmail, Slack, GitHub, Nextcloud, Google Kalender',
  if (kFeatureServerTools)
    'Sandbox / Code':
        'Run Python or bash code in an isolated sandbox, read/write files in /home/sandbox / '
        'Python- oder Shell-Code in einer isolierten Sandbox ausführen, Dateien in /home/sandbox lesen/schreiben',
  'Device / Gerät':
      'Reminders, calendar events, alarms, timers, SMS drafts, GPS / '
      'Erinnerungen, Kalendereinträge, Wecker, Timer, SMS, GPS',
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
        '**THE ONLY WAY TO UPDATE MEMORY OR USER INFO IS `notes(action=update_memory)` '
        'OR `notes(action=update_user)`. THERE IS NO `update_memory` TOOL AND NO '
        '`update_user` TOOL — THOSE NAMES WILL BE REJECTED. Same for soul: use '
        '`notes(action=update_soul)`, NOT a top-level `update_soul` tool.** '
        'Identity & memory system. You can read and write all three stores '
        '(Soul, User, Memory) by calling the `notes` tool with the matching '
        '`action`. '
        'SUPPORTED ACTIONS: '
        '"update_memory" | "update_user" | "update_soul" — replace full text. '
        '"patch_memory" | "patch_user" | "patch_soul" — apply targeted edits '
        'without rewriting the whole document (preferred for small changes). '
        '- update_*: provide "content" with the full replacement text. '
        '- patch_*: provide "edits" as a list of {old_str, new_str} pairs. '
        '  Each old_str must match exactly once. Max 5 edits per call. '
        '  Example: {"action":"patch_user","edits":[{"old_str":"Berlin","new_str":"Hamburg"}]}. '
        '- update_soul / patch_soul: MUST inform user of what changed and why. '
        'All three stores are always in context. Proactively update when you learn new facts. '
        'The app renders a visual diff showing what changed — no need to describe changes in text. '
        'CORRECT: <tool_call>{"name":"notes","arguments":{"action":"patch_memory",'
        '"edits":[{"old_str":"old text","new_str":"new text"}]}}</tool_call>. '
        'WRONG: <tool_call>{"name":"update_memory","arguments":{…}}</tool_call>.',
    parameters: {
      'action':
          'string (REQUIRED — one of: "update_memory" | "update_user" | '
          '"update_soul" | "patch_memory" | "patch_user" | "patch_soul")',
      'content': 'string (full replacement text — use with update_* actions)',
      'edits':
          'list of {old_str, new_str} objects — use with patch_* actions. '
          'Each old_str must appear exactly once in the current content.',
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
        'Chat history search with three actions. '
        '(1) find_chats: keyword search across all saved chats; returns '
        'matching chat IDs with up to 5 inlined message snippets per top hit '
        '(role + message index prefixed) — usually enough to answer without '
        'a follow-up call. The current chat is excluded from results. '
        '(2) search_in_chat: keyword search inside one chat_id; use only if '
        'find_chats snippets lack context. '
        '(3) recent_messages: return the last N messages from a chat_id '
        '(defaults to the current chat when chat_id is omitted), optionally '
        'filtered by role (user/assistant/all). Use this to review what the '
        'user or the AI recently said without needing a search term. '
        'Uses local plaintext cache for fast lookup and falls back to full '
        'chat loading when needed.',
    parameters: {
      'action':
          'string (optional: find_chats | search_in_chat | recent_messages. '
          'Defaults to search_in_chat when chat_id is provided with a query, '
          'else find_chats.)',
      'query':
          'string (required for find_chats and search_in_chat; ignored for '
          'recent_messages)',
      'chat_id':
          'string (required for search_in_chat; optional for recent_messages '
          '— defaults to the currently open chat)',
      'limit':
          'int (optional: max chats for find_chats default 10 / max 50; '
          'max messages for recent_messages default 10 / max 50)',
      'message_limit':
          'int (optional for search_in_chat: max matching messages to show, '
          'default 8, max 50)',
      'role':
          'string (optional for recent_messages: "user" | "assistant" | "ai" '
          '(alias for assistant) | "all". Default "all".)',
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
  ClientTool(
    name: 'skill',
    description:
        'Load a skill. Its full instructions are added to your system '
        'prompt under "## ACTIVE SKILL" and stay there for the rest of the '
        'conversation. Call this BEFORE doing the work the skill describes '
        '— loading is cheap, guessing the format is not. Valid names come '
        'from the SKILLS catalog; never invent one.',
    parameters: {
      'name':
          'string (required: exact skill name from the SKILLS catalog, '
          'e.g. "weather-cards")',
    },
    type: ToolType.builtin,
    // No tags on purpose: `skill` bypasses discovery and is always shown in
    // full, so it must never be a find_tools search hit.
    tags: [],
  ),

  // -- Web --
  ClientTool(
    name: 'web_search',
    description:
        'Search the web and return ranked results with links. Also auto-fetches '
        'readable content from top results to provide immediate context. Use '
        'web_crawl for deep fetch of a specific URL. '
        'IMAGE MODE: pass type="images" to get REAL photo URLs (actors, '
        'places, posters, products, events, celebrities, cars, animals, '
        'food). The app renders the returned image_url / thumbnail_url '
        'values inline automatically — DO NOT call fetch_image afterwards. '
        'Use this — NOT generate_image* — whenever the user wants a '
        'picture of something real. Only use generate_image* when the user '
        'explicitly asks for AI art, illustration, concept art, or a '
        'fictional/stylized image. '
        'NEWS MODE: pass type="news" to get recent news articles with '
        'publisher, age and thumbnail. Combine with freshness="pd" (24h), '
        '"pw" (week), "pm" (month) or "py" (year) when the user scopes a '
        'timeframe or uses words like "latest", "today", "breaking", '
        '"just released", "aktuell", "neu".',
    parameters: {
      'query': 'string (required: the search query)',
      'type':
          'string (optional: "web" (default), "images" for real photo URLs, '
          '"news" for recent articles)',
      'count': 'int (optional: number of search results, default 5, max 8)',
      'include_content':
          'bool (optional, web mode only: auto-fetch page content from top hits, default true)',
      'crawl_count':
          'int (optional, web mode only: number of top URLs to auto-fetch, default 2, max 3)',
      'crawl_max_chars':
          'int (optional, web mode only: max chars per auto-fetched page, default 3000, max 8000)',
      'extra_snippets':
          'bool (optional, web mode: up to 5 extra excerpts per result, '
          'default true — often removes the need for a separate web_crawl)',
      'freshness':
          'string (optional, web/news: "pd" (24h), "pw" (week), "pm" (month), '
          '"py" (year), or a "YYYY-MM-DDtoYYYY-MM-DD" range). Use when the '
          'query has a time component like "latest", "heute", "neu".',
      'country':
          'string (optional, web/news: ISO 3166-1 alpha-2 code like "DE" or "US")',
      'search_lang':
          'string (optional, web/news: language code like "de" or "en")',
      'ui_lang':
          'string (optional, web: response metadata language, e.g. "de-DE")',
      'safesearch':
          'string (optional: "off", "moderate" (web default) or "strict" '
          '(images default))',
      'units': 'string (optional, web: "metric" or "imperial")',
      'spellcheck':
          'bool (optional, web: run spell correction on the query, default true)',
      'goggles_id':
          'string (optional, web: custom Brave Goggles re-ranking profile)',
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
      'image',
      'images',
      'photo',
      'photos',
      'picture',
      'pictures',
      'bild',
      'bilder',
      'foto',
      'fotos',
      'poster',
      'cover',
      'schauspieler',
      'actor',
      'celebrity',
      'breaking',
      'latest',
      'today',
      'heute',
      'meldung',
      'schlagzeile',
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
        'Generate OR edit an image. ONE tool for all image models — pick the '
        'generator with the required "model" parameter:\n'
        '• turbo — Z-Image Turbo: fastest & cheapest (~0.01 EUR). Default for '
        'everyday images.\n'
        '• hunyuan — Hunyuan Image 3: high quality (~0.08 EUR).\n'
        '• flux — FLUX 2 Klein 9B: best photographic quality (~0.02 EUR).\n'
        '• ideogram — Ideogram v4: best text rendering & structured/JSON '
        'prompts, 2K output (~0.03–0.10 EUR by tier).\n'
        '• edit — Qwen Image Edit Plus: modify an EXISTING image; requires '
        '"image_url" (~0.03 EUR).\n'
        'Choose the cheapest model that meets the need; use turbo unless the '
        'user asks for higher quality, a specific model, text-in-image, or an '
        'edit. The image is displayed inline automatically — do NOT repeat the '
        'URL, dimensions, seed, or other technical details to the user. '
        'COST & PRIVACY: always mention the credit cost. turbo and flux run '
        'under a no-retention policy (inputs/outputs not stored or trained on) '
        '— no privacy warning needed. For hunyuan, ideogram, and edit, also '
        'warn the user that the image is processed on an external server, can '
        'be seen by the operator, and is NOT end-to-end encrypted like chat '
        'messages.',
    parameters: {
      'model': 'string (required: turbo | hunyuan | flux | ideogram | edit)',
      'prompt':
          'string (required: descriptive image prompt, or edit instruction '
          'when model=edit)',
      'image_url':
          'string (required ONLY when model=edit: URL of the image to edit)',
      'image_size':
          'string (optional preset for turbo/hunyuan/flux/edit: square_hd, '
          'square, portrait_4_3, portrait_16_9, landscape_4_3, '
          'landscape_16_9; edit also accepts auto)',
      'aspect_ratio':
          'string (optional for hunyuan/flux, overrides image_size: 1:1, '
          '16:9, 9:16, 3:2, 2:3, 4:3, 3:4, 5:4, 4:5, 21:9, 9:21)',
      'megapixels':
          'string (optional for flux: "0.25", "0.5", "1", "2", "4" — '
          'default "1")',
      'tier':
          'string (optional for ideogram: quality | balanced | turbo — '
          'default quality)',
      'resolution':
          'string (optional for ideogram: a native-2K preset like '
          '"2048x2048"; omit for auto)',
      'json_prompt':
          'string (optional for ideogram: structured JSON prompt for '
          'explicit layout/text/palette control)',
      'caption':
          'string (optional short subtitle shown under the image, e.g. '
          'subject name, scene — keep it under ~40 chars)',
    },
    type: ToolType.builtin,
    tags: [
      'image',
      'generate',
      'edit',
      'picture',
      'photo',
      'art',
      'bild',
      'grafik',
      'ai image',
      'hunyuan',
      'flux',
      'ideogram',
    ],
  ),
  ClientTool(
    name: 'fetch_image',
    description:
        'Download an image from a URL and store it in the chat. Use this '
        'to display an external image inline. Returns IMAGE_DATA metadata. '
        'Max size 4 MB.',
    parameters: {
      'url': 'string (required: direct image URL)',
      'caption':
          'string (optional short subtitle shown under the image, e.g. '
          'person name, place, product — keep it under ~40 chars)',
    },
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
    name: 'crypto_data',
    description:
        'Get cryptocurrency data from CoinGecko (free, no API key). Actions: '
        'price (current price + 24h change), markets (top coins with full '
        'stats: 24h range, 1h/24h/7d/30d changes, ATH, supply), '
        'history (time-series price data for charts — specify days), '
        'trending (trending coins right now), search (find a coin by '
        'name/symbol). Use CoinGecko coin IDs like "bitcoin", "ethereum", '
        '"solana" — search first if unsure.',
    parameters: {
      'action':
          'string (optional, default price: price, markets, history, '
          'trending, search)',
      'ids':
          'string or list (for price/markets/history: CoinGecko coin IDs, '
          'e.g. "bitcoin" or "bitcoin,ethereum,solana")',
      'currency': 'string (optional, default "usd": target currency)',
      'days':
          'string (for history: number of days, e.g. "1", "7", "30", "365")',
      'query': 'string (required for search: coin name or symbol to find)',
      'limit': 'int (optional for markets: number of results, default 20)',
    },
    type: ToolType.builtin,
    tags: [
      'crypto',
      'krypto',
      'bitcoin',
      'ethereum',
      'coin',
      'token',
      'price',
      'preis',
      'kurs',
      'market',
      'markt',
      'finance',
      'finanzen',
      'coingecko',
      'trending',
    ],
  ),

  // -- Maps --
  ClientTool(
    name: 'search_places',
    description:
        'Brave Local — places and POIs with rating, reviews, opening hours, '
        'phone, website, price range and a short description. Filter by '
        'query and optional city.',
    parameters: {
      'query': 'string (required, e.g. pharmacy, museum, cafe)',
      'city': 'string (optional city/region filter)',
      'limit': 'int (optional number of results, 1-20)',
    },
    type: ToolType.builtin,
    tags: ['map', 'place', 'poi', 'location', 'ort', 'karte', 'nearby'],
  ),
  ClientTool(
    name: 'search_restaurants',
    description:
        'Brave Local — restaurants with rating, reviews, opening hours, '
        'phone, website, price range and a short description. Filter by '
        'cuisine and optional city.',
    parameters: {
      'query': 'string (optional restaurant keyword)',
      'cuisine': 'string (optional cuisine, e.g. italian, sushi)',
      'city': 'string (optional city/region filter)',
      'limit': 'int (optional number of results, 1-20)',
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
        'PLAYLIST MANAGEMENT: create_playlist (name, optional uris list to pre-fill), '
        'add_to_playlist (playlist_id + uri/uris), remove_from_playlist, '
        'get_playlist_tracks (playlist_id). '
        'LIKES: like_track / unlike_track (optional uri, defaults to current track). '
        'For all liked songs: {"action": "play", "uri": "liked"}',
    parameters: {
      'action':
          'string (now_playing, play, pause, next, previous, volume, search, '
          'devices, shuffle, repeat, find_and_play, get_my_playlists, '
          'get_recently_liked, add_to_queue, create_playlist, get_my_playlists, '
          'get_playlist_tracks, add_to_playlist, remove_from_playlist, '
          'like_track, unlike_track)',
      'query': 'string (for search or find_and_play)',
      'volume': 'int (0-100 for volume)',
      'uri': 'string (spotify URI for play, add_to_playlist, like_track)',
      'uris':
          'list of strings (track URIs for create_playlist, add_to_playlist, '
          'remove_from_playlist)',
      'playlist_id':
          'string (for add_to_playlist, remove_from_playlist, '
          'get_playlist_tracks)',
      'state': 'string or boolean (shuffle on/off; repeat track/context/off)',
      'limit': 'int (for get_recently_liked / get_playlist_tracks, default 20)',
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
          'mail',
      'send',
      'senden',
      'inbox',
      'posteingang',
    ],
  ),

  // -- Device --
  ClientTool(
    name: 'device',
    description:
        'Create reminders, calendar events, alarms, timers, and email/SMS '
        'drafts directly on the user\'s device. Works on Android, Linux, '
        'Windows, and macOS. '
        'Actions: create_calendar_event, set_alarm, set_timer, cancel_alarm, '
        'list_alarms, sms_draft, email_draft, get_location, get_last_location, '
        'platform_info, distance. '
        'Use create_calendar_event for reminders and appointments — the user '
        'confirms before saving. Use set_alarm for wake-up alarms. Use '
        'set_timer for countdown timers (cooking, breaks). Use email_draft '
        'to compose emails opened in the default mail app. '
        'IMPORTANT: Calendar events, SMS, and email drafts require user '
        'confirmation — nothing is sent automatically.',
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

  // -- Calendar (standalone) --
  ClientTool(
    name: 'calendar',
    description:
        'Create a calendar event or reminder. Opens the system calendar app '
        'for the user to confirm. Works on Android (native), Linux (.ics file), '
        'Windows (.ics file), and macOS (native). '
        'Use this for appointments, meetings, reminders, deadlines, birthdays.',
    parameters: {
      'title': 'string (required — event title)',
      'start': 'string (required — ISO datetime, e.g. "2026-03-20T14:00:00")',
      'end': 'string (required — ISO datetime for event end)',
      'description': 'string (optional — event details)',
      'location': 'string (optional — event location)',
      'all_day': 'boolean (optional — true for all-day events)',
    },
    type: ToolType.builtin,
    tags: [
      'calendar',
      'kalender',
      'reminder',
      'erinnerung',
      'termin',
      'event',
      'meeting',
      'appointment',
      'deadline',
      'birthday',
      'geburtstag',
    ],
  ),

  // -- Reminder / Alarm / Timer (standalone) --
  ClientTool(
    name: 'reminder',
    description:
        'Set alarms, timers, and reminders with notifications. '
        'Actions: set_alarm (default), set_timer, cancel, list. '
        'Use set_alarm for reminders at a specific time. '
        'Use set_timer for countdown timers (e.g. 5 minutes). '
        'Notifications fire even when the app is in the background.',
    parameters: {
      'action':
          'string (optional, default "set_alarm": set_alarm, set_timer, cancel, list)',
      'title': 'string (alarm/timer name)',
      'time': 'string (ISO datetime for alarm, e.g. "2026-03-20T08:00:00")',
      'minutes': 'int (timer duration in minutes)',
      'seconds': 'int (timer duration in seconds)',
      'alarm_id': 'int (for cancel action)',
    },
    type: ToolType.builtin,
    tags: [
      'reminder',
      'erinnerung',
      'alarm',
      'wecker',
      'timer',
      'countdown',
      'notification',
      'benachrichtigung',
    ],
  ),

  // -- Weather --
  ClientTool(
    name: 'weather',
    description:
        'Weather via Brave Rich Callback. Actions: current, forecast, '
        'hourly. Provide "location" (city/place name) or lat/lon. Days/hours '
        'are hints baked into the natural-language query Brave receives.',
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

  // ── Workspace management ─────────────────────────────────────────────
  ClientTool(
    name: 'artifact_manager',
    description:
        'Create and update rich chat artifacts (code, markdown docs, HTML, '
        'Mermaid diagrams, SVG, technical drawings). Actions: create, update '
        '(old_str/new_str edits), rewrite (full content replace). Use for '
        'substantial outputs that should stay editable across messages. '
        'IDENTITY RULE: artifact_id and title MUST describe the CONTENT, not '
        'the format — "quantum-mechanics-intro" / "Quantenmechanik-Einführung", '
        'NOT "document", "test", "pdf", "output". Never reuse an existing id '
        'for a different topic (e.g. do not overwrite a quantum-physics '
        'artifact with an unrelated invoice). To edit an existing artifact: '
        'use that SAME id with action=update or rewrite — this bumps its '
        'version. To create a NEW, unrelated document: pick a DIFFERENT '
        'descriptive id so both coexist with independent version histories. '
        'The user can switch between them in the artifact panel.',
    parameters: {
      'action': 'string (required: create | update | rewrite)',
      'artifact_id':
          'string (required: stable, CONTENT-descriptive slug; letters/numbers/hyphens only. Bad: "doc", "test", "output". Good: "quantum-mechanics-intro", "invoice-acme-2026-04")',
      'title':
          'string (required for create, optional for rewrite; human-readable name that reflects the content, e.g. "Quantenmechanik-Einführung", not "Test-Dokument")',
      'type':
          'string (required for create; optional for rewrite: code|markdown|html|mermaid|svg|technical_drawing|excalidraw). '
          'For excalidraw|technical_drawing|typst|mermaid|svg call artifact_schema(type) FIRST to get the precise content shape.',
      'language':
          'string (optional for code artifacts, e.g. dart, python, ts, rust)',
      'content':
          'string (required for create/rewrite; full artifact content, max ~500KB)',
      'message_id':
          'string (optional: message identifier if you want to associate artifact with a message)',
      'edits':
          'array (required for update): list of {old_str,new_str} replacements; each old_str must be unique in current content',
    },
    type: ToolType.builtin,
    tags: [
      'artifact',
      'document',
      'code file',
      'markdown',
      'html',
      'mermaid',
      'svg',
      'technical_drawing',
      'excalidraw',
      'drawing',
      'rewrite',
      'edit',
      'replace',
      'version',
      'panel',
      'workspace',
    ],
  ),

  // ── Artifact schema reference ────────────────────────────────────────
  ClientTool(
    name: 'artifact_schema',
    description:
        'Return the precise JSON/content schema for a complex artifact '
        'type (excalidraw, technical_drawing, typst, mermaid, svg). '
        'MUST be called BEFORE creating an artifact of those types so '
        'your content field matches the renderer exactly — the app '
        'rejects malformed JSON silently otherwise. For simple types '
        '(code, markdown, html) no schema call is needed.',
    parameters: {
      'type':
          'string (required: excalidraw | technical_drawing | typst | mermaid | svg)',
    },
    type: ToolType.builtin,
    tags: [
      'schema',
      'artifact',
      'excalidraw',
      'diagram',
      'flowchart',
      'sketch',
      'whiteboard',
      'technical_drawing',
      'blueprint',
      'typst',
      'latex',
      'mermaid',
      'svg',
    ],
  ),

  // -- Typst compile (server-sandboxed) --
  ClientTool(
    name: 'typst_compile',
    description:
        'Compile a Typst document to PDF and save it as an artifact. Use '
        'this for ANY text with math, tables, structured layout, cover '
        'pages, or reports — Typst is the modern alternative to LaTeX. '
        'The source is compiled inside a sandbox on the server; the '
        'rendered PDF is stored end-to-end encrypted in Supabase and the '
        'source is saved as the artifact. If the same `artifact_id` '
        'already exists, the call UPDATES it (new version + new PDF). '
        'Always use this tool — never artifact_manager — for typst '
        'artifacts, so the compile step validates the source. If compile '
        'fails, the full compiler error is returned; fix the source and '
        'retry in the same turn. '
        'IDENTITY RULE: artifact_id and title MUST describe the CONTENT, not '
        'the format. Bad: "test-dokument", "pdf", "report". Good: '
        '"quartalsbericht-q1-2026", "einstein-relativity-notes". Do NOT '
        'reuse an unrelated existing id — create a new descriptive slug so '
        'each document has its own version history. '
        'Start with `#set page(paper: "a4")` and write normal Typst '
        r'markup. Math: `$ a^2 + b^2 = c^2 $`. Headings: `= Title`. '
        'Each compile result reports `PDF: N pages; last page ~X% filled` '
        '— if the last page is an orphan (only a small slice spills over) '
        'the result also explicitly says so. When you see that, retry with '
        'a tighter layout so the content fits on N-1 pages: shrink margins '
        '(`#set page(margin: 1.5cm)`), reduce font size '
        '(`#set text(size: 10pt)`), tighten leading '
        '(`#set par(leading: 0.55em)`), or trim filler. Reuse the same '
        '`artifact_id` so the version updates in place.',
    parameters: {
      'source': 'string (required: full Typst document source, max ~256KB)',
      'artifact_id':
          'string (required: stable, CONTENT-descriptive slug; letters/numbers/hyphens. Bad: "pdf", "test", "document". Good: "invoice-2026-04", "lecture-notes-linalg")',
      'title':
          'string (optional: human-readable title describing the CONTENT, not the format)',
      'message_id':
          'string (optional: associate artifact with a specific message)',
    },
    type: ToolType.builtin,
    tags: [
      'typst',
      'pdf',
      'latex',
      'document',
      'report',
      'math',
      'mathe',
      'formel',
      'bericht',
      'paper',
      'compile',
      'render',
      'dokument',
    ],
  ),

  ClientTool(
    name: 'update_project',
    description:
        'Update the active workspace\'s custom instructions/system prompt. '
        'Use this to save new or revised instructions that will apply to '
        'all future chats in this workspace. Can also update the workspace '
        'name and description. At least one of instructions, name, or '
        'description must be provided.',
    parameters: {
      'instructions':
          'string (optional: new custom system prompt / instructions for the workspace)',
      'name': 'string (optional: new workspace name)',
      'description': 'string (optional: new workspace description)',
    },
    type: ToolType.builtin,
    tags: [
      'workspace',
      'instructions',
      'system prompt',
      'update',
      'settings',
      'projekt',
      'anweisungen',
    ],
  ),

  // -- Sandbox: code execution in an isolated Docker container --
  ClientTool(
    name: 'code_run',
    description:
        'Run code in an isolated Docker sandbox on the server. Python by default; '
        'pass language="bash" for shell commands. The sandbox has pandas, numpy, scipy, '
        'scikit-learn, matplotlib, pillow, opencv, ffmpeg, yt-dlp, pypdf, typst, '
        'pandoc and ~30 other common tools preinstalled. Files persist between '
        'calls in /home/sandbox (read/write via sandbox_read / sandbox_write). '
        'Network egress is restricted to an allowlist (github, pypi, wikipedia, '
        'youtube, groq, etc) — arbitrary HTTP is BLOCKED. The sandbox is created '
        'on first call and reused for the rest of this chat; files survive across '
        'calls and a 3-day snapshot keeps them between sessions. '
        'Prefer typst_compile for PDF/document generation, web_crawl for fetching '
        'URLs, weather/crypto/search tools for their data, and the dedicated '
        'image tools for image generation/editing — use code_run only when '
        'computation, file manipulation, or library calls (pandas/numpy/'
        'matplotlib/yt-dlp/pypdf) are required. '
        'GitHub: if the user has connected their account via Settings → GitHub, '
        '`git` and `gh` work without prompts. You can `git clone` private repos, '
        'create branches, commit, push, and `gh pr create` — all under the '
        'user\'s identity. If a git/gh command says "authentication required", '
        'the user has not connected GitHub yet; ask them to do so before '
        'retrying. Always confirm with the user before destructive actions: '
        'force-push, branch deletion, closing PRs, repo deletion. '
        'Exec timeout 5 min, 512MB RAM, 50%% of one CPU core. Returns stdout, '
        'stderr, exit code and duration.',
    parameters: {
      'code': 'string (required: source code to execute)',
      'language': 'string (optional: "python" (default) or "bash")',
      'timeout':
          'int (optional: per-execution seconds, 1..300; omit for the '
          'server default — usually adequate).',
    },
    type: ToolType.builtin,
    tags: [
      // 'shell' kept as a discovery tag for legacy phrasing; 'bash'
      // is now the canonical language name in code_run params.
      'code', 'python', 'bash', 'shell', 'execute', 'run',
      'sandbox', 'compute', 'script', 'data', 'analysis',
      'plot', 'matplotlib', 'pandas', 'numpy', 'jupyter',
    ],
  ),
  ClientTool(
    name: 'sandbox_list',
    description:
        'List files in the sandbox at /home/sandbox (or a subdirectory). '
        'Use after code_run to see what files were created.',
    parameters: {
      'path': 'string (optional: must be under /home/sandbox, defaults there)',
    },
    type: ToolType.builtin,
    tags: ['sandbox', 'list', 'ls', 'files'],
  ),
  ClientTool(
    name: 'sandbox_read',
    description:
        'Read a file from the sandbox /home/sandbox. Returns text inline for '
        'small text files (<=64KB UTF-8); for binary files returns a metadata '
        'line with a hint to have code_run base64-encode the bytes so you can '
        'still inspect them. Use to look at output files created by code_run.',
    parameters: {
      'path': 'string (required: absolute path under /home/sandbox)',
    },
    type: ToolType.builtin,
    tags: ['sandbox', 'read', 'cat', 'open', 'file'],
  ),
  ClientTool(
    name: 'sandbox_write',
    description:
        'Write a file into the sandbox /home/sandbox. Use for seeding input '
        'data before calling code_run. For text data (CSV, JSON, markdown, '
        'source code, etc.) keep the default mode="text" and pass the raw '
        'string as content. For BINARY data (images, parquet, sqlite, pickle, '
        'pre-compiled bytes, etc.) set mode="base64" and pass the base64-'
        'encoded payload as content — otherwise the bytes will be mangled by '
        'UTF-8 encoding.',
    parameters: {
      'path': 'string (required: absolute path under /home/sandbox)',
      'content':
          'string (required: file contents — raw text in mode="text", '
          'base64-encoded bytes in mode="base64")',
      'mode': 'string (optional: "text" (default) or "base64")',
    },
    type: ToolType.builtin,
    tags: ['sandbox', 'write', 'save', 'file'],
  ),
  ClientTool(
    name: 'sandbox_reset',
    description:
        'Destroy the current chat\'s sandbox. The next code_run will create a '
        'fresh one (snapshot for this chat is still restored). Only call after '
        'code_run has failed twice with the same error that points at '
        'environment corruption (broken package, stuck process, weird state). '
        'Do NOT call before a fresh code_run "to start clean" — that destroys '
        'the persistent files in /home/sandbox unnecessarily.',
    parameters: const {},
    type: ToolType.builtin,
    tags: ['sandbox', 'reset', 'destroy', 'clean'],
  ),
  ClientTool(
    name: 'send_file_to_user',
    description:
        'Send a file from the sandbox directly to the user as a downloadable '
        'attachment in the chat. Use this AFTER the user has explicitly asked '
        'for a file you produced inside the sandbox (chart, PDF, CSV, image, '
        'ZIP, etc.). The file is uploaded encrypted to the user\'s private '
        'storage — only they can decrypt it; no public link is created. '
        'When NOT to use: do not call this for every file you create. Only '
        'call when the user has asked to receive the file. For very large or '
        'non-renderable files (e.g. multi-hundred-MB videos generated via '
        'ffmpeg), prefer using `code_run` with `curl` to upload to a '
        'temporary file host (0x0.st, transfer.sh, file.io) and give the '
        'user the temp link, since the chat UI cannot render those. '
        'Path must be under /home/sandbox.',
    parameters: {
      'path':
          'string (required: absolute path of the file inside the sandbox, '
          'e.g. /home/sandbox/report.pdf)',
      'display_name':
          'string (optional: override filename shown to the user; '
          'defaults to the last segment of `path`)',
    },
    type: ToolType.builtin,
    tags: [
      'sandbox',
      'send',
      'attach',
      'attachment',
      'download',
      'share',
      'file',
      'deliver',
      'artifact',
    ],
  ),
];

/// Whether the current platform is a mobile device (Android/iOS).
///
/// Uses the compile-time [kPlatformMobile] flag first, then falls back to
/// runtime detection via `dart:io` [Platform].
bool _isMobileRuntime() {
  if (kPlatformMobile) return true;
  if (kPlatformDesktop) return false;
  // Auto-detect at runtime.
  return Platform.isAndroid || Platform.isIOS;
}

/// Register all built-in tools from [builtinTools] into a [ToolExecutor].
void registerBuiltinTools(ToolExecutor executor) {
  final bool isMobile = _isMobileRuntime();

  for (final tool in builtinTools) {
    if (!kFeatureServerTools && _serverBackedToolNames.contains(tool.name)) {
      continue;
    }
    if (!kFeatureArtifacts && tool.name == 'artifact_manager') {
      continue;
    }
    // Skills: when off, the tool never registers, so the prompt never emits
    // the catalog and the feature costs exactly zero tokens.
    if (!kFeatureSkills && tool.name == 'skill') {
      continue;
    }
    // Spotify: the integration is dormant server-side. The tool definition
    // stays in the source so re-enabling later only needs the flag.
    if (!kFeatureSpotify && tool.name == 'spotify_control') {
      continue;
    }
    // Device tool: available on all platforms.
    // Some actions (SMS, GPS) are mobile-only — DeviceServices handles
    // capability checks at runtime via getPlatformCapabilities().
    // Bash sandbox is desktop-only.
    if (isMobile && tool.name == 'bash') {
      continue;
    }
    executor.registerTool(tool);
  }
}
