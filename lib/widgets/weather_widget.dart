import 'package:flutter/material.dart';

/// Renders `<weather>` JSON blocks emitted by the AI as a polished weather card.
///
/// Expected JSON schema:
/// ```json
/// {
///   "location": "Kiel, Germany",
///   "current": {
///     "temp": 8, "feels_like": 5, "condition": "Partly cloudy", "code": 2,
///     "humidity": 72, "wind_speed": 14, "wind_dir": "W",
///     "precipitation": 0, "unit_temp": "C", "unit_wind": "km/h",
///     "unit_precip": "mm"
///   },
///   "daily": [ {"date":"2026-04-24","code":2,"temp_max":10,"temp_min":3,
///               "precip_prob":20,"condition":"..."}, ... ],
///   "hourly": [ {"time":"14:00","code":2,"temp":8,"precip_prob":10}, ... ]
/// }
/// ```
class WeatherBlockWidget extends StatelessWidget {
  final Map<String, dynamic> data;

  const WeatherBlockWidget({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final location = _asStr(data['location']) ?? '';
    final current = _asMap(data['current']);
    final daily = _asList(data['daily']);
    final hourly = _asList(data['hourly']);

    final code = _asInt(current['code']) ?? 0;
    final gradient = _gradientForCode(code, Theme.of(context).brightness);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: gradient,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCurrent(location, current),
          if (hourly.isNotEmpty) _buildHourly(hourly),
          if (daily.isNotEmpty) _buildDaily(daily),
        ],
      ),
    );
  }

  // -- Current section ------------------------------------------------------

  Widget _buildCurrent(String location, Map<String, dynamic> current) {
    final temp = _asNum(current['temp']);
    final feelsLike = _asNum(current['feels_like']);
    final condition = _asStr(current['condition']) ?? '';
    final code = _asInt(current['code']) ?? 0;
    final unitTemp = _normalizeTempUnit(current['unit_temp']);
    final humidity = _asNum(current['humidity']);
    final windSpeed = _asNum(current['wind_speed']);
    final windDir = _asStr(current['wind_dir']) ?? '';
    final unitWind = _asStr(current['unit_wind']) ?? 'km/h';
    final precip = _asNum(current['precipitation']);
    final unitPrecip = _asStr(current['unit_precip']) ?? 'mm';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (location.isNotEmpty)
            Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 16,
                  color: Colors.white70,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    location,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                _iconForCode(code),
                size: 64,
                color: Colors.white,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (temp != null)
                      Text(
                        '${_fmtNum(temp)}$unitTemp',
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w300,
                          color: Colors.white,
                          height: 1.0,
                        ),
                      ),
                    const SizedBox(height: 4),
                    if (condition.isNotEmpty)
                      Text(
                        condition,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (feelsLike != null)
                      Text(
                        'Feels like ${_fmtNum(feelsLike)}$unitTemp',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              if (humidity != null)
                _stat(
                  Icons.water_drop_outlined,
                  '${_fmtNum(humidity)}%',
                  'Humidity',
                ),
              if (windSpeed != null)
                _stat(
                  Icons.air,
                  '${_fmtNum(windSpeed)} $unitWind${windDir.isNotEmpty ? ' $windDir' : ''}',
                  'Wind',
                ),
              if (precip != null)
                _stat(
                  Icons.umbrella_outlined,
                  '${_fmtNum(precip)} $unitPrecip',
                  'Precip',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -- Hourly strip ---------------------------------------------------------

  Widget _buildHourly(List<dynamic> hourly) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: hourly.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, i) {
            final h = _asMap(hourly[i]);
            final time = _asStr(h['time']) ?? '';
            final temp = _asNum(h['temp']);
            final code = _asInt(h['code']) ?? 0;
            final precipProb = _asNum(h['precip_prob']);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _shortTime(time),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Icon(_iconForCode(code), size: 22, color: Colors.white),
                const SizedBox(height: 4),
                if (temp != null)
                  Text(
                    '${_fmtNum(temp)}°',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (precipProb != null && precipProb > 0)
                  Text(
                    '${_fmtNum(precipProb)}%',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.lightBlueAccent,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // -- Daily forecast list --------------------------------------------------

  Widget _buildDaily(List<dynamic> daily) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: Column(
        children: [
          for (final d in daily) _buildDailyRow(_asMap(d)),
        ],
      ),
    );
  }

  Widget _buildDailyRow(Map<String, dynamic> d) {
    final date = _asStr(d['date']) ?? '';
    final code = _asInt(d['code']) ?? 0;
    final tempMax = _asNum(d['temp_max']);
    final tempMin = _asNum(d['temp_min']);
    final precipProb = _asNum(d['precip_prob']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              _dayLabel(date),
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(_iconForCode(code), size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: precipProb != null && precipProb > 0
                ? Row(
                    children: [
                      const Icon(
                        Icons.water_drop_outlined,
                        size: 12,
                        color: Colors.lightBlueAccent,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${_fmtNum(precipProb)}%',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.lightBlueAccent,
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (tempMin != null)
            Text(
              '${_fmtNum(tempMin)}°',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white70,
              ),
            ),
          const SizedBox(width: 10),
          if (tempMax != null)
            Text(
              '${_fmtNum(tempMax)}°',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  // -- Helpers --------------------------------------------------------------

  Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const <String, dynamic>{};
  }

  List<dynamic> _asList(dynamic v) {
    if (v is List) return v;
    return const <dynamic>[];
  }

  num? _asNum(dynamic v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  String? _asStr(dynamic v) => v is String ? v : null;

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  String _fmtNum(num v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }

  String _normalizeTempUnit(dynamic raw) {
    final s = raw is String ? raw.trim() : 'C';
    final stripped = s.replaceAll(RegExp(r'^°'), '');
    return '°$stripped';
  }

  String _shortTime(String t) {
    if (t.contains('T')) {
      final parts = t.split('T');
      if (parts.length == 2) return parts[1].substring(0, 5);
    }
    if (t.length >= 5 && t.contains(':')) return t.substring(0, 5);
    return t;
  }

  String _dayLabel(String date) {
    if (date.isEmpty) return '';
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(parsed.year, parsed.month, parsed.day);
    final diff = target.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return days[(parsed.weekday - 1) % 7];
  }

  /// Map WMO weather code -> Material icon.
  IconData _iconForCode(int code) {
    if (code == 0) return Icons.wb_sunny;
    if (code == 1) return Icons.wb_sunny_outlined;
    if (code == 2) return Icons.cloud_queue;
    if (code == 3) return Icons.cloud;
    if (code == 45 || code == 48) return Icons.foggy;
    if (code >= 51 && code <= 57) return Icons.grain;
    if (code >= 61 && code <= 67) return Icons.water_drop;
    if (code >= 71 && code <= 77) return Icons.ac_unit;
    if (code >= 80 && code <= 82) return Icons.umbrella;
    if (code == 85 || code == 86) return Icons.ac_unit;
    if (code >= 95 && code <= 99) return Icons.thunderstorm;
    return Icons.cloud_outlined;
  }

  /// Gradient background keyed on WMO code & light/dark mode.
  LinearGradient _gradientForCode(int code, Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    // Thunderstorm
    if (code >= 95 && code <= 99) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF2C3E50), Color(0xFF1A1A2E)]
            : const [Color(0xFF4B6584), Color(0xFF2C3E50)],
      );
    }
    // Snow
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF4A6572), Color(0xFF232F34)]
            : const [Color(0xFF83A4D4), Color(0xFFB6FBFF)],
      );
    }
    // Rain / showers
    if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF355C7D), Color(0xFF2C3E50)]
            : const [Color(0xFF4A6FA5), Color(0xFF6B90BE)],
      );
    }
    // Fog
    if (code == 45 || code == 48) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF3E4247), Color(0xFF2A2D33)]
            : const [Color(0xFF8E9BA9), Color(0xFFB4C5D6)],
      );
    }
    // Overcast
    if (code == 3) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF3C4A5E), Color(0xFF253142)]
            : const [Color(0xFF7B8FA8), Color(0xFFA5B5C9)],
      );
    }
    // Partly cloudy
    if (code == 1 || code == 2) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF3A5683), Color(0xFF1E3A5F)]
            : const [Color(0xFF5A9BD4), Color(0xFF81B7DE)],
      );
    }
    // Clear / default (code 0)
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [Color(0xFF1E3A5F), Color(0xFF0F1E2F)]
          : const [Color(0xFF4A90E2), Color(0xFF7FB3E7)],
    );
  }
}
