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
      'passwords, UUIDs, notes and QR codes / '
      'Rechnen, Uhrzeit, Zufallszahlen, Passwörter, UUIDs, Notizen, QR',
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
        'Persistent key-value notes memory. Actions: save, get, list, '
        'delete, clear. Use for storing user facts/preferences across turns.',
    parameters: {
      'action': 'string (save, get, list, delete, clear)',
      'key': 'string (note key for save/get/delete)',
      'content': 'string (note body for save)',
    },
    type: ToolType.builtin,
    tags: ['notes', 'note', 'memory', 'memo', 'notiz', 'merken'],
  ),
  ClientTool(
    name: 'generate_qr',
    description:
        'Generate a QR-code PNG from text/URL and return IMAGE_DATA for '
        'display.',
    parameters: {
      'data': 'string (required: text or URL to encode)',
      'size': 'int (optional: image size, 100-1000)',
    },
    type: ToolType.builtin,
    tags: ['qr', 'qrcode', 'barcode', 'scan', 'link', 'url'],
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
        'Search the web for current/external information and return snippet '
        'results with links. Use this for discovery; use web_crawl when full '
        'page content is required.',
    parameters: {'query': 'string (required: the search query)'},
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
        'Generate an image from a text prompt. Returns image metadata '
        '(URL, dimensions, seed). Costs credits (~0.01 EUR per image). '
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
