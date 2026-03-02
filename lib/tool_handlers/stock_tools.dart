import 'dart:convert';

import 'package:http/http.dart' as http;

Future<String> executeStockData(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final action = (args['action'] as String? ?? 'quote').trim().toLowerCase();
  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    switch (action) {
      case 'quote':
        return _executeQuote(effectiveClient, args);
      case 'history':
        return _executeHistory(effectiveClient, args);
      case 'compare':
        return _executeCompare(effectiveClient, args);
      default:
        return 'Error: Unknown action "$action". Supported: quote, history, '
            'compare';
    }
  } catch (error) {
    return 'Stock data error: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> _executeQuote(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final symbol = _coerceSymbol(args['symbol']);
  if (symbol == null) {
    return 'Error: "symbol" parameter required';
  }

  final chart = await _fetchChartData(
    client,
    symbol: symbol,
    range: '1d',
    interval: '5m',
  );
  if (chart == null) {
    return 'Error: Could not fetch quote for $symbol';
  }

  final meta = chart['meta'] as Map<String, dynamic>? ?? const {};
  final latest = _latestQuoteFromChart(chart);
  if (latest == null) {
    return 'Error: No quote data available for $symbol';
  }

  final currency = (meta['currency'] as String? ?? 'USD').trim();
  final exchange = (meta['exchangeName'] as String? ?? '').trim();
  final previousClose = _coerceDouble(meta['previousClose']);

  final close = latest['close']!;
  final open = latest['open'];
  final high = latest['high'];
  final low = latest['low'];
  final volume = latest['volume'];

  final change = previousClose != null ? close - previousClose : null;
  final changePct = (previousClose != null && previousClose != 0)
      ? (change! / previousClose) * 100
      : null;

  final buf = StringBuffer();
  buf.writeln('Quote for $symbol${exchange.isEmpty ? '' : ' ($exchange)'}:');
  buf.writeln('Price: ${close.toStringAsFixed(2)} $currency');
  if (change != null && changePct != null) {
    buf.writeln(
      'Change: ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} '
      '(${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%)',
    );
  }
  if (open != null) {
    buf.writeln('Open: ${open.toStringAsFixed(2)}');
  }
  if (high != null && low != null) {
    buf.writeln(
      'Day range: ${low.toStringAsFixed(2)} - ${high.toStringAsFixed(2)}',
    );
  }
  if (volume != null) {
    buf.writeln('Volume: ${volume.toStringAsFixed(0)}');
  }

  return buf.toString().trimRight();
}

Future<String> _executeHistory(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final symbol = _coerceSymbol(args['symbol']);
  if (symbol == null) {
    return 'Error: "symbol" parameter required';
  }

  final range = (args['period'] as String? ?? '1mo').trim();
  final interval = (args['interval'] as String? ?? '1d').trim();

  final chart = await _fetchChartData(
    client,
    symbol: symbol,
    range: range,
    interval: interval,
  );
  if (chart == null) {
    return 'Error: Could not fetch historical data for $symbol';
  }

  final points = _historyPointsFromChart(chart);
  if (points.isEmpty) {
    return 'No historical data available for $symbol';
  }

  final buf = StringBuffer();
  buf.writeln(
    'History for $symbol (period: $range, interval: $interval, '
    '${points.length} points):',
  );
  buf.writeln();

  final rowsToShow = points.length > 20
      ? [...points.take(10), ...points.skip(points.length - 10)]
      : points;

  for (final point in rowsToShow) {
    final ts = point['timestamp'] as DateTime;
    final open = point['open'] as double;
    final close = point['close'] as double;
    final high = point['high'] as double;
    final low = point['low'] as double;
    final volume = point['volume'] as double?;

    buf.writeln(
      '${ts.toIso8601String()}: open=${open.toStringAsFixed(2)}, '
      'close=${close.toStringAsFixed(2)}, high=${high.toStringAsFixed(2)}, '
      'low=${low.toStringAsFixed(2)}, '
      'vol=${volume?.toStringAsFixed(0) ?? 'n/a'}',
    );
  }

  if (points.length > 20) {
    buf.writeln();
    buf.writeln('... truncated (showing first/last 10 points) ...');
  }

  final firstClose = points.first['close'] as double;
  final lastClose = points.last['close'] as double;
  final change = lastClose - firstClose;
  final changePct = firstClose == 0 ? 0 : (change / firstClose) * 100;

  final highs = points.map((p) => p['high'] as double).toList();
  final lows = points.map((p) => p['low'] as double).toList();
  highs.sort();
  lows.sort();

  buf.writeln();
  buf.writeln('Summary:');
  buf.writeln('Start: ${firstClose.toStringAsFixed(2)}');
  buf.writeln('End: ${lastClose.toStringAsFixed(2)}');
  buf.writeln(
    'Change: ${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} '
    '(${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%)',
  );
  buf.writeln('Period high: ${highs.last.toStringAsFixed(2)}');
  buf.writeln('Period low: ${lows.first.toStringAsFixed(2)}');

  return buf.toString().trimRight();
}

Future<String> _executeCompare(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final symbols = _coerceSymbols(args['symbols'], single: args['symbol']);
  if (symbols.isEmpty) {
    return 'Error: "symbols" parameter required (e.g. "AAPL,MSFT,GOOGL")';
  }

  final cappedSymbols = symbols.take(8).toList();
  final buf = StringBuffer();
  buf.writeln('Stock comparison:');
  buf.writeln();

  for (final symbol in cappedSymbols) {
    final chart = await _fetchChartData(
      client,
      symbol: symbol,
      range: '1d',
      interval: '5m',
    );

    if (chart == null) {
      buf.writeln('- $symbol: unavailable');
      continue;
    }

    final meta = chart['meta'] as Map<String, dynamic>? ?? const {};
    final latest = _latestQuoteFromChart(chart);
    if (latest == null) {
      buf.writeln('- $symbol: no price data');
      continue;
    }

    final close = latest['close']!;
    final previousClose = _coerceDouble(meta['previousClose']);
    final change = previousClose != null ? close - previousClose : null;
    final changePct = (previousClose != null && previousClose != 0)
        ? (change! / previousClose) * 100
        : null;

    final currency = (meta['currency'] as String? ?? 'USD').trim();
    final line = StringBuffer(
      '- $symbol: ${close.toStringAsFixed(2)} $currency',
    );
    if (change != null && changePct != null) {
      line.write(
        ' (${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}, '
        '${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%)',
      );
    }
    buf.writeln(line.toString());
  }

  return buf.toString().trimRight();
}

Future<Map<String, dynamic>?> _fetchChartData(
  http.Client client, {
  required String symbol,
  required String range,
  required String interval,
}) async {
  final uri = Uri.parse(
    'https://query1.finance.yahoo.com/v8/finance/chart/${Uri.encodeComponent(symbol)}'
    '?range=${Uri.encodeQueryComponent(range)}'
    '&interval=${Uri.encodeQueryComponent(interval)}',
  );

  final response = await client
      .get(
        uri,
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'chuk-chat/1.0',
        },
      )
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    return null;
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }

  final chart = decoded['chart'];
  if (chart is! Map<String, dynamic>) {
    return null;
  }
  if (chart['error'] != null) {
    return null;
  }

  final resultList = chart['result'];
  if (resultList is! List || resultList.isEmpty) {
    return null;
  }

  final first = resultList.first;
  if (first is! Map<String, dynamic>) {
    return null;
  }

  return first;
}

Map<String, double?>? _latestQuoteFromChart(Map<String, dynamic> chart) {
  final timestamps = (chart['timestamp'] as List?)?.cast<dynamic>() ?? const [];
  final indicators = chart['indicators'] as Map<String, dynamic>?;
  final quoteList =
      (indicators?['quote'] as List?)?.cast<dynamic>() ?? const [];
  if (timestamps.isEmpty || quoteList.isEmpty) {
    return null;
  }

  final quote = quoteList.first as Map<String, dynamic>? ?? const {};
  final opens = (quote['open'] as List?)?.cast<dynamic>() ?? const [];
  final closes = (quote['close'] as List?)?.cast<dynamic>() ?? const [];
  final highs = (quote['high'] as List?)?.cast<dynamic>() ?? const [];
  final lows = (quote['low'] as List?)?.cast<dynamic>() ?? const [];
  final volumes = (quote['volume'] as List?)?.cast<dynamic>() ?? const [];

  for (var i = closes.length - 1; i >= 0; i--) {
    final close = _coerceDouble(closes[i]);
    if (close == null) {
      continue;
    }

    return {
      'open': i < opens.length ? _coerceDouble(opens[i]) : null,
      'close': close,
      'high': i < highs.length ? _coerceDouble(highs[i]) : null,
      'low': i < lows.length ? _coerceDouble(lows[i]) : null,
      'volume': i < volumes.length ? _coerceDouble(volumes[i]) : null,
    };
  }

  return null;
}

List<Map<String, dynamic>> _historyPointsFromChart(Map<String, dynamic> chart) {
  final timestamps = (chart['timestamp'] as List?)?.cast<dynamic>() ?? const [];
  final indicators = chart['indicators'] as Map<String, dynamic>?;
  final quoteList =
      (indicators?['quote'] as List?)?.cast<dynamic>() ?? const [];
  if (timestamps.isEmpty || quoteList.isEmpty) {
    return const <Map<String, dynamic>>[];
  }

  final quote = quoteList.first as Map<String, dynamic>? ?? const {};
  final opens = (quote['open'] as List?)?.cast<dynamic>() ?? const [];
  final closes = (quote['close'] as List?)?.cast<dynamic>() ?? const [];
  final highs = (quote['high'] as List?)?.cast<dynamic>() ?? const [];
  final lows = (quote['low'] as List?)?.cast<dynamic>() ?? const [];
  final volumes = (quote['volume'] as List?)?.cast<dynamic>() ?? const [];

  final points = <Map<String, dynamic>>[];
  final limit = [
    timestamps.length,
    opens.length,
    closes.length,
    highs.length,
    lows.length,
  ].reduce((a, b) => a < b ? a : b);

  for (var i = 0; i < limit; i++) {
    final timestamp = _coerceInt(timestamps[i]);
    final open = _coerceDouble(opens[i]);
    final close = _coerceDouble(closes[i]);
    final high = _coerceDouble(highs[i]);
    final low = _coerceDouble(lows[i]);
    final volume = i < volumes.length ? _coerceDouble(volumes[i]) : null;
    if (timestamp == null ||
        open == null ||
        close == null ||
        high == null ||
        low == null) {
      continue;
    }

    points.add({
      'timestamp': DateTime.fromMillisecondsSinceEpoch(
        timestamp * 1000,
        isUtc: true,
      ),
      'open': open,
      'close': close,
      'high': high,
      'low': low,
      'volume': volume,
    });
  }

  return points;
}

String? _coerceSymbol(dynamic value) {
  if (value == null) {
    return null;
  }

  final symbol = value.toString().trim().toUpperCase();
  if (symbol.isEmpty) {
    return null;
  }
  return symbol;
}

List<String> _coerceSymbols(dynamic value, {dynamic single}) {
  final result = <String>[];

  void addSymbol(dynamic symbolValue) {
    final symbol = _coerceSymbol(symbolValue);
    if (symbol != null && !result.contains(symbol)) {
      result.add(symbol);
    }
  }

  if (value is List) {
    for (final entry in value) {
      addSymbol(entry);
    }
  } else if (value != null) {
    for (final part in value.toString().split(',')) {
      addSymbol(part);
    }
  }

  if (result.isEmpty && single != null) {
    addSymbol(single);
  }

  return result;
}

double? _coerceDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value.toString().trim());
}

int? _coerceInt(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString().trim());
}
