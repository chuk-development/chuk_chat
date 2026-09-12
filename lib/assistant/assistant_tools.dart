import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/tool_handlers/map_tools.dart';
import 'package:chuk_chat/tool_handlers/weather_tools.dart';

import 'assistant_bridge.dart';
import 'assistant_result.dart';

/// Everything a tool handler may use besides its own arguments.
class AssistantToolRuntime {
  const AssistantToolRuntime({
    required this.serverUrl,
    required this.serverHeaders,
    required this.describeScreenshot,
    required this.language,
    this.httpClient,
  });

  /// Base URL of the API proxy, e.g. `https://api.chuk.chat`.
  final String serverUrl;

  /// Authorization headers for that proxy (the Supabase JWT).
  final Map<String, String> serverHeaders;

  /// Sends a JPEG screenshot plus a question to the vision model and returns
  /// the description. Supplied by the session so the tool layer never has to
  /// know how a chat request is made.
  final Future<String> Function(String question, String base64Jpeg)
  describeScreenshot;

  /// ISO-639-1 language of the conversation, used for search localization.
  final String language;

  final http.Client? httpClient;

  String get country => switch (language) {
    'de' => 'DE',
    'en' => 'US',
    'es' => 'ES',
    'fr' => 'FR',
    'pt' => 'PT',
    _ => 'DE',
  };
}

typedef AssistantToolHandler =
    Future<AssistantToolOutcome> Function(
      Map<String, dynamic> args,
      AssistantToolRuntime runtime,
    );

/// One function the model may call, in the OpenAI tool schema.
class AssistantTool {
  const AssistantTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
    required this.label,
  });

  final String name;
  final String description;

  /// JSON Schema object for `function.parameters`.
  final Map<String, dynamic> parameters;
  final AssistantToolHandler handler;

  /// Short label the overlay shows while the tool runs.
  final String Function(Map<String, dynamic> args) label;

  Map<String, dynamic> toOpenAiFunction() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

Map<String, dynamic> _object(
  Map<String, dynamic> properties, {
  List<String> required = const <String>[],
}) => {'type': 'object', 'properties': properties, 'required': required};

Map<String, dynamic> _string(String description, {List<String>? values}) => {
  'type': 'string',
  'description': description,
  'enum': ?values,
};

Map<String, dynamic> _integer(String description) => {
  'type': 'integer',
  'description': description,
};

Map<String, dynamic> _number(String description) => {
  'type': 'number',
  'description': description,
};

/// Models send numbers as a number or as a string, so accept both.
double? _toDouble(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text.trim()),
  _ => null,
};

int _toInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _text(Map<String, dynamic> args, String key) =>
    (args[key] ?? '').toString().trim();

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

AssistantToolOutcome _plain(Object? value) => AssistantToolOutcome(value);

/// The complete assistant tool set: what the phone can do, plus the handful of
/// server lookups a spoken question actually needs.
///
/// This is deliberately NOT the chat tool registry. The overlay is a
/// latency-critical surface; artifacts, sandboxes, GitHub and the rest have no
/// place in a two-second spoken turn, and every extra schema is paid for in
/// every prompt.
final List<AssistantTool> assistantTools = <AssistantTool>[
  // --- Screen context ------------------------------------------------------
  AssistantTool(
    name: 'read_screen',
    description:
        'Liest den sichtbaren Text des gerade geoeffneten Bildschirms samt '
        'App-Paketname. Immer zuerst benutzen, wenn der Nutzer "das hier", '
        '"dieser Text", "diese Seite" oder aehnliches sagt.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Bildschirm lesen',
    handler: (args, runtime) async {
      final context = await AssistantBridge.getCurrentContext();
      return _plain({
        'package': context['packageName'],
        'screen': context['className'],
        'text': _clip(context['visibleText']?.toString() ?? '', 6000),
      });
    },
  ),
  AssistantTool(
    name: 'find_on_screen',
    description:
        'Sucht einen Begriff im aktuellen Bildschirm und scrollt dabei, wenn '
        'noetig. Benutzen, wenn read_screen den gesuchten Inhalt nicht zeigt.',
    parameters: _object(
      {'query': _string('Der gesuchte Text oder das gesuchte Thema.')},
      required: ['query'],
    ),
    label: (args) => 'Suche "${_text(args, 'query')}"',
    handler: (args, runtime) async {
      final result = await AssistantBridge.collectScrollableContext(
        query: _text(args, 'query'),
      );
      final text = result['text']?.toString() ?? result.toString();
      return _plain({'text': _clip(text, 8000)});
    },
  ),
  AssistantTool(
    name: 'look_at_screen',
    description:
        'Macht ein Bildschirmfoto und laesst es vom Bildmodell beschreiben. '
        'Benutzen fuer Bilder, Diagramme, Karten oder Layout-Fragen, also '
        'immer dann, wenn reiner Text nicht reicht.',
    parameters: _object(
      {'question': _string('Was genau soll auf dem Bild erkannt werden?')},
      required: ['question'],
    ),
    label: (_) => 'Bildschirm ansehen',
    handler: (args, runtime) async {
      final encoded = await AssistantBridge.captureScreenshotBase64();
      if (encoded == null || encoded.isEmpty) {
        return _plain({
          'error':
              'Bildschirmfoto nicht moeglich. Der Bedienungshilfen-Dienst ist '
              'aus oder Android ist aelter als 11.',
        });
      }
      final question = args['question']?.toString().trim();
      final description = await runtime.describeScreenshot(
        question == null || question.isEmpty
            ? 'Was ist auf dem Bild zu sehen?'
            : question,
        encoded,
      );
      return _plain({'description': description});
    },
  ),
  AssistantTool(
    name: 'tap_text',
    description:
        'Tippt auf ein sichtbares Bedienelement mit diesem Text. Nur benutzen, '
        'wenn der Nutzer eine Aktion in der offenen App verlangt.',
    parameters: _object(
      {'text': _string('Die Beschriftung des Elements.')},
      required: ['text'],
    ),
    label: (args) => 'Tippe "${_text(args, 'text')}"',
    handler: (args, runtime) async {
      final ok = await AssistantBridge.clickByText(_text(args, 'text'));
      return AssistantToolOutcome(
        {'tapped': ok},
        card: ok
            ? AssistantActionCard(
                icon: Icons.touch_app_outlined,
                label: 'Getippt',
                detail: _text(args, 'text'),
              )
            : null,
      );
    },
  ),
  AssistantTool(
    name: 'system_action',
    description: 'Fuehrt eine Android-Systemgeste aus.',
    parameters: _object(
      {
        'action': _string(
          'Die Geste.',
          values: const [
            'back',
            'home',
            'recents',
            'notifications',
            'quick_settings',
          ],
        ),
      },
      required: ['action'],
    ),
    label: (args) => 'System: ${_text(args, 'action')}',
    handler: (args, runtime) async {
      final ok = await AssistantBridge.performGlobalAction(
        _text(args, 'action'),
      );
      return _plain({'done': ok});
    },
  ),

  // --- Apps, places, navigation -------------------------------------------
  AssistantTool(
    name: 'open_app',
    description: 'Oeffnet eine installierte App anhand ihres Namens.',
    parameters: _object(
      {'name': _string('Der sichtbare App-Name, zum Beispiel "Spotify".')},
      required: ['name'],
    ),
    label: (args) => 'Oeffne ${_text(args, 'name')}',
    handler: (args, runtime) async {
      final result = await AssistantBridge.openApp(_text(args, 'name'));
      return AssistantToolOutcome(
        result,
        card: result['opened'] == true || result['launched'] == true
            ? AssistantActionCard(
                icon: Icons.open_in_new_rounded,
                label: 'App geoeffnet',
                detail: (result['label'] ?? _text(args, 'name')).toString(),
              )
            : null,
      );
    },
  ),
  AssistantTool(
    name: 'open_maps',
    description:
        'Zeigt einen Ort, eine Adresse oder ein Ziel in der Karten-App des '
        'Geraets und startet dort die Navigation. Immer dafuer benutzen und '
        'nicht open_app: jedes Geraet hat eine andere Karten-App als Standard.',
    parameters: _object(
      {
        'query': _string(
          'Ort, Adresse oder Suchbegriff, zum Beispiel "Hauptbahnhof Kiel".',
        ),
        'latitude': _number('Breitengrad, wenn die Koordinate bekannt ist.'),
        'longitude': _number('Laengengrad, wenn die Koordinate bekannt ist.'),
      },
      required: ['query'],
    ),
    label: (args) => 'Karte: ${_text(args, 'query')}',
    handler: (args, runtime) async {
      final result = await AssistantBridge.openMaps(
        query: _text(args, 'query'),
        latitude: _toDouble(args['latitude']),
        longitude: _toDouble(args['longitude']),
      );
      return AssistantToolOutcome(
        result,
        card: AssistantActionCard(
          icon: Icons.navigation_outlined,
          label: 'Navigation gestartet',
          detail: _text(args, 'query'),
        ),
      );
    },
  ),
  AssistantTool(
    name: 'list_apps',
    description:
        'Listet die installierten Apps. Benutzen, wenn open_app die App nicht '
        'findet.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Apps auflisten',
    handler: (args, runtime) async {
      final apps = await AssistantBridge.listInstalledApps();
      return _plain({
        'apps': apps.map((app) => app['label']).take(120).toList(),
      });
    },
  ),

  // --- Contacts and messages ----------------------------------------------
  AssistantTool(
    name: 'find_contact',
    description: 'Sucht einen Kontakt und gibt Name und Nummer zurueck.',
    parameters: _object(
      {'name': _string('Der gesuchte Kontaktname.')},
      required: ['name'],
    ),
    label: (args) => 'Kontakt ${_text(args, 'name')}',
    handler: (args, runtime) async =>
        _plain(await AssistantBridge.findContact(_text(args, 'name'))),
  ),
  AssistantTool(
    name: 'call_contact',
    description:
        'Oeffnet die Telefon-App mit der Nummer des Kontakts. Der Nutzer '
        'startet den Anruf selbst.',
    parameters: _object(
      {'name': _string('Der Kontaktname.')},
      required: ['name'],
    ),
    label: (args) => 'Anruf ${_text(args, 'name')}',
    handler: (args, runtime) async {
      final ok = await AssistantBridge.openDialerForContact(
        _text(args, 'name'),
      );
      return AssistantToolOutcome(
        {'dialer_open': ok},
        card: ok
            ? AssistantActionCard(
                icon: Icons.call_outlined,
                label: 'Telefon geoeffnet',
                detail: _text(args, 'name'),
              )
            : null,
      );
    },
  ),
  AssistantTool(
    name: 'send_sms',
    description:
        'Bereitet eine SMS an einen Kontakt vor. Die Nachricht wird nicht '
        'automatisch gesendet.',
    parameters: _object(
      {
        'name': _string('Der Kontaktname.'),
        'message': _string('Der Text der Nachricht.'),
      },
      required: ['name', 'message'],
    ),
    label: (args) => 'SMS an ${_text(args, 'name')}',
    handler: (args, runtime) async {
      final ok = await AssistantBridge.composeSmsForContact(
        name: _text(args, 'name'),
        message: _text(args, 'message'),
      );
      return AssistantToolOutcome(
        {'composer_open': ok},
        card: ok
            ? AssistantActionCard(
                icon: Icons.sms_outlined,
                label: 'SMS vorbereitet',
                detail: _text(args, 'message'),
              )
            : null,
      );
    },
  ),

  // --- Clock ---------------------------------------------------------------
  AssistantTool(
    name: 'set_timer',
    description: 'Stellt einen Kurzzeitwecker.',
    parameters: _object(
      {
        'seconds': _integer('Dauer in Sekunden.'),
        'label': _string('Beschriftung des Timers.'),
      },
      required: ['seconds'],
    ),
    label: (args) => 'Timer ${_toInt(args['seconds'])}s',
    handler: (args, runtime) async {
      final seconds = _toInt(args['seconds']);
      final ok = await AssistantBridge.setTimer(
        seconds: seconds,
        message: _text(args, 'label'),
      );
      return AssistantToolOutcome(
        {'started': ok},
        card: ok
            ? AssistantActionCard(
                icon: Icons.timer_outlined,
                label: 'Timer laeuft',
                detail: _formatDuration(seconds),
              )
            : null,
      );
    },
  ),
  AssistantTool(
    name: 'set_alarm',
    description: 'Stellt einen Wecker auf eine Uhrzeit.',
    parameters: _object(
      {
        'hour': _integer('Stunde, 0 bis 23.'),
        'minute': _integer('Minute, 0 bis 59.'),
        'label': _string('Beschriftung des Weckers.'),
      },
      required: ['hour', 'minute'],
    ),
    label: (args) =>
        'Wecker ${_toInt(args['hour'])}:'
        '${_toInt(args['minute']).toString().padLeft(2, '0')}',
    handler: (args, runtime) async {
      final hour = _toInt(args['hour']);
      final minute = _toInt(args['minute']);
      final ok = await AssistantBridge.setAlarm(
        hour: hour,
        minutes: minute,
        message: _text(args, 'label'),
      );
      return AssistantToolOutcome(
        {'set': ok},
        card: ok
            ? AssistantActionCard(
                icon: Icons.alarm_outlined,
                label: 'Wecker gestellt',
                detail:
                    '${hour.toString().padLeft(2, '0')}:'
                    '${minute.toString().padLeft(2, '0')}',
              )
            : null,
      );
    },
  ),
  AssistantTool(
    name: 'clock_action',
    description: 'Zeigt oder beendet laufende Timer und Wecker.',
    parameters: _object(
      {
        'action': _string(
          'Die Aktion.',
          values: const [
            'show_timers',
            'show_alarms',
            'dismiss_timer',
            'dismiss_alarm',
          ],
        ),
      },
      required: ['action'],
    ),
    label: (args) => 'Uhr: ${_text(args, 'action')}',
    handler: (args, runtime) async {
      final ok = switch (_text(args, 'action')) {
        'show_timers' => await AssistantBridge.showTimers(),
        'show_alarms' => await AssistantBridge.showAlarms(),
        'dismiss_timer' => await AssistantBridge.dismissTimer(),
        'dismiss_alarm' => await AssistantBridge.dismissAlarm(),
        _ => false,
      };
      return _plain({'done': ok});
    },
  ),

  // --- Media and volume ----------------------------------------------------
  AssistantTool(
    name: 'media_control',
    description: 'Steuert die laufende Wiedergabe auf dem Geraet.',
    parameters: _object(
      {
        'command': _string(
          'Der Befehl.',
          values: const ['play', 'pause', 'toggle', 'next', 'previous', 'stop'],
        ),
      },
      required: ['command'],
    ),
    label: (args) => 'Wiedergabe: ${_text(args, 'command')}',
    handler: (args, runtime) async {
      final ok = await AssistantBridge.mediaCommand(_text(args, 'command'));
      return _plain({'done': ok});
    },
  ),
  AssistantTool(
    name: 'now_playing',
    description: 'Gibt Titel, Interpret und Player der laufenden Wiedergabe.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Laeuft gerade',
    handler: (args, runtime) async {
      final playing = await AssistantBridge.getNowPlaying();
      final title = (playing['title'] ?? '').toString().trim();
      final artist = (playing['artist'] ?? '').toString().trim();
      return AssistantToolOutcome(
        playing,
        card: title.isEmpty
            ? null
            : AssistantFactsCard(
                icon: Icons.music_note_outlined,
                title: title,
                body: artist,
              ),
      );
    },
  ),
  AssistantTool(
    name: 'volume',
    description: 'Liest oder setzt die Medienlautstaerke.',
    parameters: _object({
      'percent': _integer('Ziel in Prozent, 0 bis 100. Leer lassen zum Lesen.'),
      'direction': _string(
        'Schrittweise Aenderung statt fester Prozentzahl.',
        values: const ['up', 'down', 'mute', 'unmute', 'toggle_mute'],
      ),
    }),
    label: (_) => 'Lautstaerke',
    handler: (args, runtime) async {
      if (args['percent'] != null) {
        await AssistantBridge.volumeSet(_toInt(args['percent']));
      } else if (args['direction'] != null) {
        await AssistantBridge.volumeAdjust(_text(args, 'direction'));
      }
      return _plain(await AssistantBridge.volumeGet());
    },
  ),

  // --- Device state --------------------------------------------------------
  AssistantTool(
    name: 'get_location',
    description:
        'Gibt den letzten bekannten Standort. Zuerst aufrufen, bevor nach '
        'Orten "in der Naehe" gesucht wird.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Standort',
    handler: (args, runtime) async =>
        _plain(await AssistantBridge.getLastKnownLocation()),
  ),
  AssistantTool(
    name: 'recent_notifications',
    description: 'Listet die zuletzt eingegangenen Benachrichtigungen.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Benachrichtigungen',
    handler: (args, runtime) async {
      final items = await AssistantBridge.getRecentNotifications();
      return _plain({'notifications': items.take(20).toList()});
    },
  ),
  AssistantTool(
    name: 'get_time',
    description: 'Gibt Datum und Uhrzeit des Geraets.',
    parameters: _object(const <String, dynamic>{}),
    label: (_) => 'Uhrzeit',
    handler: (args, runtime) async {
      final now = DateTime.now();
      return _plain({
        'iso': now.toIso8601String(),
        'weekday': now.weekday,
        'timezone_offset_minutes': now.timeZoneOffset.inMinutes,
      });
    },
  ),

  // --- Lookups through the API proxy --------------------------------------
  AssistantTool(
    name: 'web_search',
    description:
        'Sucht im Web und gibt die besten Treffer mit Titel, Link und '
        'Kurzbeschreibung. Fuer Fakten, Nachrichten, Oeffnungszeiten, Preise '
        'und alles, was nicht auf dem Geraet steht.',
    parameters: _object(
      {
        'query': _string('Die Suchanfrage.'),
        'count': _integer('Anzahl Treffer, 1 bis 10. Standard 5.'),
      },
      required: ['query'],
    ),
    label: (args) => 'Web: ${_text(args, 'query')}',
    handler: _webSearch,
  ),
  AssistantTool(
    name: 'search_places',
    description:
        'Findet Orte in der Naehe: Geschaefte, Apotheken, Tankstellen, '
        'Sehenswuerdigkeiten. Liefert Adresse, Bewertung und Oeffnungszeiten.',
    parameters: _object(
      {
        'query': _string('Was gesucht wird, zum Beispiel "Apotheke".'),
        'city': _string('Stadt oder Stadtteil, wenn bekannt.'),
        'limit': _integer('Anzahl Treffer, 1 bis 10. Standard 6.'),
      },
      required: ['query'],
    ),
    label: (args) => 'Orte: ${_text(args, 'query')}',
    handler: (args, runtime) =>
        _places(args, runtime, restaurants: false),
  ),
  AssistantTool(
    name: 'search_restaurants',
    description:
        'Findet Restaurants, Cafes und Bars in der Naehe, mit Kueche, '
        'Preisklasse, Bewertung und Oeffnungszeiten.',
    parameters: _object(
      {
        'query': _string('Freitext, zum Beispiel "Sushi".'),
        'cuisine': _string('Kuechenart, zum Beispiel "italienisch".'),
        'city': _string('Stadt oder Stadtteil, wenn bekannt.'),
        'limit': _integer('Anzahl Treffer, 1 bis 10. Standard 6.'),
      },
    ),
    label: (args) {
      final what = _text(args, 'query').isNotEmpty
          ? _text(args, 'query')
          : _text(args, 'cuisine');
      return what.isEmpty ? 'Restaurants' : 'Restaurants: $what';
    },
    handler: (args, runtime) => _places(args, runtime, restaurants: true),
  ),
  AssistantTool(
    name: 'weather',
    description: 'Aktuelles Wetter und Vorhersage fuer einen Ort.',
    parameters: _object({
      'location': _string('Ortsname. Leer lassen, um Koordinaten zu nutzen.'),
      'latitude': _number('Breitengrad.'),
      'longitude': _number('Laengengrad.'),
    }),
    label: (args) {
      final where = _text(args, 'location');
      return where.isEmpty ? 'Wetter' : 'Wetter: $where';
    },
    handler: (args, runtime) async {
      final text = await executeWeather(
        serverHttpUrl: runtime.serverUrl,
        serverHeaders: runtime.serverHeaders,
        args: args,
        client: runtime.httpClient,
      );
      final where = _text(args, 'location');
      return AssistantToolOutcome(
        {'weather': text},
        card: text.startsWith('Error')
            ? null
            : AssistantFactsCard(
                icon: Icons.wb_sunny_outlined,
                title: where.isEmpty ? 'Wetter' : where,
                body: text,
              ),
      );
    },
  ),
];

Future<AssistantToolOutcome> _webSearch(
  Map<String, dynamic> args,
  AssistantToolRuntime runtime,
) async {
  final query = _text(args, 'query');
  if (query.isEmpty) {
    return _plain({'error': 'Keine Suchanfrage angegeben.'});
  }
  final count = args['count'] == null ? 5 : _toInt(args['count']).clamp(1, 10);
  final client = runtime.httpClient ?? http.Client();
  try {
    final response = await client
        .post(
          Uri.parse('${runtime.serverUrl}/v1/tools/brave/search'),
          headers: {'Content-Type': 'application/json', ...runtime.serverHeaders},
          body: jsonEncode({
            'query': query,
            'count': count,
            'country': runtime.country,
            'search_lang': runtime.language,
            'extra_snippets': false,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      return _plain({'error': 'Websuche fehlgeschlagen (${response.statusCode}).'});
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final raw = decoded is Map ? decoded['results'] : null;
    final results = <AssistantLink>[];
    final forModel = <Map<String, String>>[];
    for (final item in (raw as List? ?? const <dynamic>[])) {
      if (item is! Map) continue;
      final title = (item['title'] ?? '').toString().trim();
      final url = (item['url'] ?? '').toString().trim();
      final description = (item['description'] ?? '').toString().trim();
      if (title.isEmpty && url.isEmpty) continue;
      results.add(
        AssistantLink(title: title, url: url, snippet: description),
      );
      forModel.add({
        'title': title,
        'url': url,
        'snippet': _clip(description, 400),
      });
      if (results.length >= count) break;
    }
    if (results.isEmpty) {
      return _plain({'results': const <dynamic>[], 'note': 'Keine Treffer.'});
    }
    return AssistantToolOutcome(
      {'results': forModel},
      card: AssistantLinksCard(title: query, links: results),
    );
  } catch (error, stack) {
    if (kDebugMode) debugPrint('assistant web_search failed: $error\n$stack');
    return _plain({'error': 'Websuche fehlgeschlagen: $error'});
  } finally {
    if (runtime.httpClient == null) client.close();
  }
}

Future<AssistantToolOutcome> _places(
  Map<String, dynamic> args,
  AssistantToolRuntime runtime, {
  required bool restaurants,
}) async {
  final effectiveArgs = <String, dynamic>{
    ...args,
    'limit': args['limit'] == null ? 6 : _toInt(args['limit']).clamp(1, 10),
    'country': runtime.country,
    'search_lang': runtime.language,
  };
  final result = restaurants
      ? await searchRestaurantsWithMap(
          serverHttpUrl: runtime.serverUrl,
          serverHeaders: runtime.serverHeaders,
          args: effectiveArgs,
          client: runtime.httpClient,
        )
      : await searchPlacesWithMap(
          serverHttpUrl: runtime.serverUrl,
          serverHeaders: runtime.serverHeaders,
          args: effectiveArgs,
          client: runtime.httpClient,
        );

  final title = _text(args, 'query').isNotEmpty
      ? _text(args, 'query')
      : (_text(args, 'cuisine').isNotEmpty
            ? _text(args, 'cuisine')
            : (restaurants ? 'Restaurants' : 'Orte'));

  return AssistantToolOutcome(
    {'places': result.text},
    card: result.places.isEmpty
        ? null
        : AssistantPlacesCard(
            title: title,
            places: result.places
                .map(AssistantPlace.fromBrave)
                .where((place) => place.name.isNotEmpty)
                .toList(growable: false),
          ),
  );
}

String _formatDuration(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (minutes < 60) {
    return rest == 0 ? '$minutes min' : '$minutes min $rest s';
  }
  final hours = minutes ~/ 60;
  return '$hours h ${minutes % 60} min';
}

final Map<String, AssistantTool> assistantToolsByName = {
  for (final tool in assistantTools) tool.name: tool,
};

final List<Map<String, dynamic>> assistantToolSchemas = assistantTools
    .map((tool) => tool.toOpenAiFunction())
    .toList(growable: false);

/// Result of one tool call: the JSON string the model reads back, plus the
/// card the overlay draws.
class AssistantToolRun {
  AssistantToolRun({required this.name, required this.label});

  final String name;
  final String label;
  bool done = false;
  bool failed = false;
  String content = '';
  AssistantCard? card;
}

/// Runs one tool call and always produces a JSON string — the `tool` message
/// content has to be a string in the OpenAI format.
Future<void> runAssistantTool({
  required AssistantToolRun run,
  required Map<String, dynamic> args,
  required AssistantToolRuntime runtime,
}) async {
  final tool = assistantToolsByName[run.name];
  if (tool == null) {
    run
      ..done = true
      ..failed = true
      ..content = jsonEncode({'error': 'Unbekanntes Werkzeug: ${run.name}'});
    return;
  }
  try {
    final outcome = await tool.handler(args, runtime);
    final value = outcome.modelResult ?? const {'ok': true};
    run
      ..done = true
      ..failed = value is Map && value['error'] != null
      ..content = jsonEncode(value)
      ..card = outcome.card;
  } catch (error, stack) {
    if (kDebugMode) {
      debugPrint('assistant tool ${run.name} failed: $error\n$stack');
    }
    run
      ..done = true
      ..failed = true
      ..content = jsonEncode({'error': error.toString()});
  }
}
