import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/weather_widget.dart';

void main() {
  runApp(const _WeatherPreviewApp());
}

class _WeatherPreviewApp extends StatefulWidget {
  const _WeatherPreviewApp();

  @override
  State<_WeatherPreviewApp> createState() => _WeatherPreviewAppState();
}

class _WeatherPreviewAppState extends State<_WeatherPreviewApp> {
  ThemeMode _mode = ThemeMode.dark;

  static final Map<String, Map<String, dynamic>> _fakes = {
    'Sunny (Kiel)': {
      'location': 'Kiel, Schleswig-Holstein, Germany',
      'current': {
        'temp': 22,
        'feels_like': 21,
        'condition': 'Clear sky',
        'code': 0,
        'humidity': 48,
        'wind_speed': 11,
        'wind_dir': 'NW',
        'precipitation': 0,
        'unit_temp': 'C',
        'unit_wind': 'km/h',
        'unit_precip': 'mm',
      },
      'hourly': [
        {'time': '12:00', 'code': 0, 'temp': 22, 'precip_prob': 0},
        {'time': '13:00', 'code': 1, 'temp': 23, 'precip_prob': 0},
        {'time': '14:00', 'code': 1, 'temp': 24, 'precip_prob': 5},
        {'time': '15:00', 'code': 2, 'temp': 24, 'precip_prob': 10},
        {'time': '16:00', 'code': 2, 'temp': 23, 'precip_prob': 10},
        {'time': '17:00', 'code': 2, 'temp': 22, 'precip_prob': 15},
      ],
      'daily': [
        {
          'date': '2026-04-24',
          'code': 0,
          'temp_max': 24,
          'temp_min': 12,
          'precip_prob': 10,
          'condition': 'Sunny',
        },
        {
          'date': '2026-04-25',
          'code': 2,
          'temp_max': 21,
          'temp_min': 11,
          'precip_prob': 20,
          'condition': 'Partly cloudy',
        },
        {
          'date': '2026-04-26',
          'code': 61,
          'temp_max': 17,
          'temp_min': 9,
          'precip_prob': 70,
          'condition': 'Rain',
        },
        {
          'date': '2026-04-27',
          'code': 3,
          'temp_max': 16,
          'temp_min': 8,
          'precip_prob': 40,
          'condition': 'Overcast',
        },
        {
          'date': '2026-04-28',
          'code': 1,
          'temp_max': 18,
          'temp_min': 7,
          'precip_prob': 15,
          'condition': 'Mainly clear',
        },
      ],
    },
    'Rainy (Berlin)': {
      'location': 'Berlin, Germany',
      'current': {
        'temp': 9,
        'feels_like': 6,
        'condition': 'Moderate rain',
        'code': 63,
        'humidity': 88,
        'wind_speed': 24,
        'wind_dir': 'SW',
        'precipitation': 4.2,
        'unit_temp': 'C',
        'unit_wind': 'km/h',
        'unit_precip': 'mm',
      },
      'hourly': [
        {'time': '09:00', 'code': 61, 'temp': 8, 'precip_prob': 85},
        {'time': '10:00', 'code': 63, 'temp': 8, 'precip_prob': 90},
        {'time': '11:00', 'code': 63, 'temp': 9, 'precip_prob': 95},
        {'time': '12:00', 'code': 65, 'temp': 9, 'precip_prob': 95},
        {'time': '13:00', 'code': 63, 'temp': 10, 'precip_prob': 80},
        {'time': '14:00', 'code': 61, 'temp': 10, 'precip_prob': 65},
      ],
      'daily': [
        {
          'date': '2026-04-24',
          'code': 63,
          'temp_max': 11,
          'temp_min': 6,
          'precip_prob': 95,
          'condition': 'Rainy',
        },
        {
          'date': '2026-04-25',
          'code': 61,
          'temp_max': 13,
          'temp_min': 7,
          'precip_prob': 70,
          'condition': 'Light rain',
        },
        {
          'date': '2026-04-26',
          'code': 3,
          'temp_max': 15,
          'temp_min': 7,
          'precip_prob': 35,
          'condition': 'Overcast',
        },
      ],
    },
    'Snow (Munich)': {
      'location': 'München, Bayern, Germany',
      'current': {
        'temp': -2,
        'feels_like': -7,
        'condition': 'Heavy snow',
        'code': 75,
        'humidity': 92,
        'wind_speed': 18,
        'wind_dir': 'N',
        'precipitation': 3.5,
        'unit_temp': 'C',
        'unit_wind': 'km/h',
        'unit_precip': 'mm',
      },
      'hourly': [
        {'time': '08:00', 'code': 71, 'temp': -3, 'precip_prob': 80},
        {'time': '09:00', 'code': 73, 'temp': -2, 'precip_prob': 90},
        {'time': '10:00', 'code': 75, 'temp': -2, 'precip_prob': 95},
        {'time': '11:00', 'code': 75, 'temp': -1, 'precip_prob': 90},
        {'time': '12:00', 'code': 73, 'temp': 0, 'precip_prob': 75},
      ],
      'daily': [
        {
          'date': '2026-04-24',
          'code': 75,
          'temp_max': 0,
          'temp_min': -5,
          'precip_prob': 90,
          'condition': 'Heavy snow',
        },
        {
          'date': '2026-04-25',
          'code': 71,
          'temp_max': 2,
          'temp_min': -3,
          'precip_prob': 60,
          'condition': 'Light snow',
        },
        {
          'date': '2026-04-26',
          'code': 45,
          'temp_max': 4,
          'temp_min': -2,
          'precip_prob': 20,
          'condition': 'Fog',
        },
      ],
    },
    'Thunderstorm (Hamburg)': {
      'location': 'Hamburg, Germany',
      'current': {
        'temp': 19,
        'feels_like': 20,
        'condition': 'Thunderstorm',
        'code': 95,
        'humidity': 78,
        'wind_speed': 38,
        'wind_dir': 'SW',
        'precipitation': 12.4,
        'unit_temp': 'C',
        'unit_wind': 'km/h',
        'unit_precip': 'mm',
      },
      'hourly': [
        {'time': '16:00', 'code': 95, 'temp': 19, 'precip_prob': 95},
        {'time': '17:00', 'code': 99, 'temp': 18, 'precip_prob': 100},
        {'time': '18:00', 'code': 95, 'temp': 17, 'precip_prob': 90},
      ],
      'daily': [
        {
          'date': '2026-04-24',
          'code': 95,
          'temp_max': 20,
          'temp_min': 14,
          'precip_prob': 95,
          'condition': 'Thunderstorm',
        },
      ],
    },
  };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weather Widget Preview',
      themeMode: _mode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('Weather Widget Preview'),
            actions: [
              IconButton(
                tooltip: 'Toggle theme',
                icon: Icon(
                  _mode == ThemeMode.dark
                      ? Icons.light_mode
                      : Icons.dark_mode,
                ),
                onPressed: () => setState(() {
                  _mode = _mode == ThemeMode.dark
                      ? ThemeMode.light
                      : ThemeMode.dark;
                }),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final entry in _fakes.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 12,
                        bottom: 4,
                        left: 4,
                      ),
                      child: Text(
                        entry.key,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    WeatherBlockWidget(data: entry.value),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
