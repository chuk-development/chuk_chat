import 'dart:convert';

import 'package:http/http.dart' as http;

const String _baseUrl = 'https://api.coingecko.com/api/v3';

Future<String> executeCryptoData(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final action = (args['action'] as String? ?? 'price').trim().toLowerCase();
  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    switch (action) {
      case 'price':
        return await _executePrice(effectiveClient, args);
      case 'markets':
        return await _executeMarkets(effectiveClient, args);
      case 'history':
        return await _executeHistory(effectiveClient, args);
      case 'trending':
        return await _executeTrending(effectiveClient);
      case 'search':
        return await _executeSearch(effectiveClient, args);
      default:
        return 'Error: Unknown action "$action". Supported: price, markets, '
            'history, trending, search';
    }
  } catch (error) {
    return 'Crypto data error: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> _executePrice(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final ids = _coerceIds(args['ids'] ?? args['id'] ?? args['coin']);
  if (ids.isEmpty) {
    return 'Error: "ids" parameter required (e.g. "bitcoin" or '
        '"bitcoin,ethereum")';
  }

  final currency =
      (args['currency'] as String? ?? 'usd').trim().toLowerCase();

  final uri = Uri.parse(
    '$_baseUrl/simple/price'
    '?ids=${Uri.encodeQueryComponent(ids.join(','))}'
    '&vs_currencies=${Uri.encodeQueryComponent(currency)}'
    '&include_24hr_change=true'
    '&include_market_cap=true'
    '&include_24hr_vol=true',
  );

  final body = await _fetch(client, uri);
  if (body == null) {
    return 'Error: Could not fetch price data for ${ids.join(', ')}';
  }

  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic> || decoded.isEmpty) {
    return 'Error: No price data found for ${ids.join(', ')}';
  }

  final buf = StringBuffer();
  for (final id in ids) {
    final coin = decoded[id];
    if (coin is! Map<String, dynamic>) {
      buf.writeln('$id: no data available');
      continue;
    }

    final price = _coerceDouble(coin[currency]);
    final change24h = _coerceDouble(coin['${currency}_24h_change']);
    final marketCap = _coerceDouble(coin['${currency}_market_cap']);
    final volume24h = _coerceDouble(coin['${currency}_24h_vol']);

    buf.writeln('$id (${currency.toUpperCase()}):');
    if (price != null) {
      buf.writeln('  Price: ${_formatNumber(price)}');
    }
    if (change24h != null) {
      buf.writeln(
        '  24h change: ${change24h >= 0 ? '+' : ''}'
        '${change24h.toStringAsFixed(2)}%',
      );
    }
    if (marketCap != null) {
      buf.writeln('  Market cap: ${_formatLargeNumber(marketCap)}');
    }
    if (volume24h != null) {
      buf.writeln('  24h volume: ${_formatLargeNumber(volume24h)}');
    }
  }

  return buf.toString().trimRight();
}

Future<String> _executeMarkets(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final currency =
      (args['currency'] as String? ?? 'usd').trim().toLowerCase();
  final ids = _coerceIds(args['ids'] ?? args['id'] ?? args['coin']);
  final perPage = _coerceInt(args['limit'] ?? args['per_page'], fallback: 20)
      .clamp(1, 100);
  final page = _coerceInt(args['page'], fallback: 1);

  var url = '$_baseUrl/coins/markets'
      '?vs_currency=${Uri.encodeQueryComponent(currency)}'
      '&order=market_cap_desc'
      '&per_page=$perPage'
      '&page=$page'
      '&sparkline=false'
      '&price_change_percentage=1h,24h,7d,30d';

  if (ids.isNotEmpty) {
    url += '&ids=${Uri.encodeQueryComponent(ids.join(','))}';
  }

  final body = await _fetch(client, Uri.parse(url));
  if (body == null) {
    return 'Error: Could not fetch market data';
  }

  final decoded = jsonDecode(body);
  if (decoded is! List || decoded.isEmpty) {
    return 'No market data found';
  }

  final buf = StringBuffer();
  buf.writeln(
    'Crypto markets (${currency.toUpperCase()}, '
    '${decoded.length} coins):',
  );
  buf.writeln();

  for (final coin in decoded) {
    if (coin is! Map<String, dynamic>) continue;

    final name = coin['name'] ?? '';
    final symbol = (coin['symbol'] as String? ?? '').toUpperCase();
    final rank = coin['market_cap_rank'];
    final price = _coerceDouble(coin['current_price']);
    final high24h = _coerceDouble(coin['high_24h']);
    final low24h = _coerceDouble(coin['low_24h']);
    final marketCap = _coerceDouble(coin['market_cap']);
    final volume = _coerceDouble(coin['total_volume']);
    final supply = _coerceDouble(coin['circulating_supply']);
    final totalSupply = _coerceDouble(coin['total_supply']);
    final ath = _coerceDouble(coin['ath']);
    final athChange = _coerceDouble(coin['ath_change_percentage']);
    final atl = _coerceDouble(coin['atl']);

    final change1h = _coerceDouble(
      coin['price_change_percentage_1h_in_currency'],
    );
    final change24h = _coerceDouble(
      coin['price_change_percentage_24h_in_currency'] ??
          coin['price_change_percentage_24h'],
    );
    final change7d = _coerceDouble(
      coin['price_change_percentage_7d_in_currency'],
    );
    final change30d = _coerceDouble(
      coin['price_change_percentage_30d_in_currency'],
    );

    final rankStr = rank != null ? '#$rank ' : '';
    buf.writeln('$rankStr$name ($symbol):');
    if (price != null) {
      buf.writeln('  Price: ${_formatNumber(price)}');
    }
    if (high24h != null && low24h != null) {
      buf.writeln(
        '  24h range: ${_formatNumber(low24h)} - ${_formatNumber(high24h)}',
      );
    }

    // Price changes
    final changes = <String>[];
    if (change1h != null) {
      changes.add('1h: ${_fmtPct(change1h)}');
    }
    if (change24h != null) {
      changes.add('24h: ${_fmtPct(change24h)}');
    }
    if (change7d != null) {
      changes.add('7d: ${_fmtPct(change7d)}');
    }
    if (change30d != null) {
      changes.add('30d: ${_fmtPct(change30d)}');
    }
    if (changes.isNotEmpty) {
      buf.writeln('  Changes: ${changes.join(', ')}');
    }

    if (marketCap != null) {
      buf.writeln('  Market cap: ${_formatLargeNumber(marketCap)}');
    }
    if (volume != null) {
      buf.writeln('  24h volume: ${_formatLargeNumber(volume)}');
    }
    if (supply != null) {
      buf.write('  Supply: ${_formatLargeNumber(supply)}');
      if (totalSupply != null) {
        buf.write(' / ${_formatLargeNumber(totalSupply)}');
      }
      buf.writeln();
    }
    if (ath != null) {
      buf.write('  ATH: ${_formatNumber(ath)}');
      if (athChange != null) {
        buf.write(' (${_fmtPct(athChange)})');
      }
      buf.writeln();
    }
    if (atl != null) {
      buf.writeln('  ATL: ${_formatNumber(atl)}');
    }
    buf.writeln();
  }

  return buf.toString().trimRight();
}

/// Fetch historical price time-series for chart rendering.
///
/// Uses /coins/{id}/market_chart which returns [timestamp, price] arrays.
Future<String> _executeHistory(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final ids = _coerceIds(args['ids'] ?? args['id'] ?? args['coin']);
  if (ids.isEmpty) {
    return 'Error: "ids" parameter required (e.g. "bitcoin")';
  }

  final id = ids.first; // market_chart only supports one coin at a time.
  final currency =
      (args['currency'] as String? ?? 'usd').trim().toLowerCase();
  final days = (args['days'] as Object?)?.toString().trim() ?? '1';

  final uri = Uri.parse(
    '$_baseUrl/coins/${Uri.encodeComponent(id)}/market_chart'
    '?vs_currency=${Uri.encodeQueryComponent(currency)}'
    '&days=${Uri.encodeQueryComponent(days)}',
  );

  final body = await _fetch(client, uri);
  if (body == null) {
    return 'Error: Could not fetch history for $id';
  }

  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    return 'Error: Unexpected response format';
  }

  final prices = decoded['prices'] as List? ?? [];
  final volumes = decoded['total_volumes'] as List? ?? [];
  final marketCaps = decoded['market_caps'] as List? ?? [];

  if (prices.isEmpty) {
    return 'No historical price data available for $id';
  }

  // Build structured output the LLM can use for <chart> tags.
  final buf = StringBuffer();
  buf.writeln(
    'Price history for $id (${currency.toUpperCase()}, '
    'last $days day(s), ${prices.length} data points):',
  );
  buf.writeln();

  // Summary stats.
  final firstPrice = _pointValue(prices.first);
  final lastPrice = _pointValue(prices.last);
  double? highPrice;
  double? lowPrice;
  for (final point in prices) {
    final v = _pointValue(point);
    if (v == null) continue;
    if (highPrice == null || v > highPrice) highPrice = v;
    if (lowPrice == null || v < lowPrice) lowPrice = v;
  }

  if (firstPrice != null && lastPrice != null) {
    final change = lastPrice - firstPrice;
    final changePct =
        firstPrice != 0 ? (change / firstPrice) * 100 : 0.0;
    buf.writeln('Start: ${_formatNumber(firstPrice)}');
    buf.writeln('End: ${_formatNumber(lastPrice)}');
    buf.writeln(
      'Change: ${change >= 0 ? '+' : ''}${_formatNumber(change)} '
      '(${_fmtPct(changePct)})',
    );
  }
  if (highPrice != null) {
    buf.writeln('High: ${_formatNumber(highPrice)}');
  }
  if (lowPrice != null) {
    buf.writeln('Low: ${_formatNumber(lowPrice)}');
  }

  buf.writeln();
  buf.writeln('Time-series data (timestamp_ms, price):');

  // Output all points so the LLM can build a chart. For very long series,
  // downsample to keep output reasonable (max ~100 points).
  final step = prices.length > 100 ? (prices.length / 100).ceil() : 1;
  for (var i = 0; i < prices.length; i += step) {
    final point = prices[i];
    if (point is! List || point.length < 2) continue;
    final ts = _coerceInt(point[0], fallback: 0);
    final price = _coerceDouble(point[1]);
    if (price == null) continue;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true);
    buf.writeln('${dt.toIso8601String()}: ${_formatNumber(price)}');
  }
  // Always include last point.
  if (step > 1 && prices.isNotEmpty) {
    final last = prices.last;
    if (last is List && last.length >= 2) {
      final ts = _coerceInt(last[0], fallback: 0);
      final price = _coerceDouble(last[1]);
      if (price != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true);
        buf.writeln('${dt.toIso8601String()}: ${_formatNumber(price)}');
      }
    }
  }

  // Volume summary.
  if (volumes.isNotEmpty) {
    final lastVol = _pointValue(volumes.last);
    if (lastVol != null) {
      buf.writeln();
      buf.writeln('Latest volume: ${_formatLargeNumber(lastVol)}');
    }
  }

  // Market cap summary.
  if (marketCaps.isNotEmpty) {
    final lastMcap = _pointValue(marketCaps.last);
    if (lastMcap != null) {
      buf.writeln('Latest market cap: ${_formatLargeNumber(lastMcap)}');
    }
  }

  return buf.toString().trimRight();
}

Future<String> _executeTrending(http.Client client) async {
  final body = await _fetch(client, Uri.parse('$_baseUrl/search/trending'));
  if (body == null) {
    return 'Error: Could not fetch trending data';
  }

  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    return 'Error: Unexpected response format';
  }

  final coins = decoded['coins'] as List? ?? [];
  if (coins.isEmpty) {
    return 'No trending coins found';
  }

  final buf = StringBuffer();
  buf.writeln('Trending coins:');
  buf.writeln();

  for (var i = 0; i < coins.length && i < 15; i++) {
    final item = coins[i];
    final coin = item is Map<String, dynamic>
        ? item['item'] as Map<String, dynamic>?
        : null;
    if (coin == null) continue;

    final name = coin['name'] ?? '';
    final symbol = (coin['symbol'] as String? ?? '').toUpperCase();
    final rank = coin['market_cap_rank'];
    final price = _coerceDouble(
      (coin['data'] as Map<String, dynamic>?)?['price'],
    );
    final change24h = _coerceDouble(
      (coin['data'] as Map<String, dynamic>?)?['price_change_percentage_24h']
              is Map
          ? ((coin['data'] as Map<String, dynamic>)
              ['price_change_percentage_24h'] as Map)['usd']
          : null,
    );

    buf.write('${i + 1}. $name ($symbol)');
    if (rank != null) buf.write(' #$rank');
    if (price != null) buf.write(' \$${_formatNumber(price)}');
    if (change24h != null) {
      buf.write(
        ' ${change24h >= 0 ? '+' : ''}${change24h.toStringAsFixed(2)}%',
      );
    }
    buf.writeln();
  }

  return buf.toString().trimRight();
}

Future<String> _executeSearch(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final query = (args['query'] as String? ?? '').trim();
  if (query.isEmpty) {
    return 'Error: "query" parameter required';
  }

  final uri = Uri.parse(
    '$_baseUrl/search?query=${Uri.encodeQueryComponent(query)}',
  );

  final body = await _fetch(client, uri);
  if (body == null) {
    return 'Error: Could not search for "$query"';
  }

  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    return 'Error: Unexpected response format';
  }

  final coins = decoded['coins'] as List? ?? [];
  if (coins.isEmpty) {
    return 'No coins found matching "$query"';
  }

  final buf = StringBuffer();
  buf.writeln('Search results for "$query":');
  buf.writeln();

  final limit = coins.length > 10 ? 10 : coins.length;
  for (var i = 0; i < limit; i++) {
    final coin = coins[i] as Map<String, dynamic>? ?? {};
    final name = coin['name'] ?? '';
    final symbol = (coin['symbol'] as String? ?? '').toUpperCase();
    final id = coin['id'] ?? '';
    final rank = coin['market_cap_rank'];

    buf.write('${i + 1}. $name ($symbol)');
    if (rank != null) buf.write(' #$rank');
    buf.writeln(' [id: $id]');
  }

  buf.writeln();
  buf.writeln('Use the coin id with action "price", "markets", or '
      '"history" for details.');

  return buf.toString().trimRight();
}

// ─── Helpers ────────────────────────────────────────────────────────────────

Future<String?> _fetch(http.Client client, Uri uri) async {
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
  return response.body;
}

/// Extract the value from a [timestamp, value] pair.
double? _pointValue(dynamic point) {
  if (point is List && point.length >= 2) {
    return _coerceDouble(point[1]);
  }
  return null;
}

List<String> _coerceIds(dynamic value) {
  if (value == null) return const [];
  if (value is List) {
    return value
        .map((e) => e.toString().trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return value
      .toString()
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
}

double? _coerceDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim());
}

int _coerceInt(dynamic value, {required int fallback}) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim()) ?? fallback;
}

String _fmtPct(double value) {
  return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}%';
}

String _formatNumber(double value) {
  if (value >= 1) {
    return value.toStringAsFixed(2);
  } else if (value >= 0.01) {
    return value.toStringAsFixed(4);
  } else {
    return value.toStringAsFixed(8);
  }
}

String _formatLargeNumber(double value) {
  if (value >= 1e12) {
    return '${(value / 1e12).toStringAsFixed(2)}T';
  } else if (value >= 1e9) {
    return '${(value / 1e9).toStringAsFixed(2)}B';
  } else if (value >= 1e6) {
    return '${(value / 1e6).toStringAsFixed(2)}M';
  } else if (value >= 1e3) {
    return '${(value / 1e3).toStringAsFixed(1)}K';
  }
  return value.toStringAsFixed(2);
}
