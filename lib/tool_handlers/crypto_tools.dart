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
      case 'trending':
        return await _executeTrending(effectiveClient);
      case 'search':
        return await _executeSearch(effectiveClient, args);
      default:
        return 'Error: Unknown action "$action". Supported: price, markets, '
            'trending, search';
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
      buf.writeln('  Price: ${_formatNumber(price, currency)}');
    }
    if (change24h != null) {
      buf.writeln(
        '  24h change: ${change24h >= 0 ? '+' : ''}'
        '${change24h.toStringAsFixed(2)}%',
      );
    }
    if (marketCap != null) {
      buf.writeln('  Market cap: ${_formatLargeNumber(marketCap, currency)}');
    }
    if (volume24h != null) {
      buf.writeln('  24h volume: ${_formatLargeNumber(volume24h, currency)}');
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
      '&price_change_percentage=1h,24h,7d';

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
    final change24h =
        _coerceDouble(coin['price_change_percentage_24h_in_currency'] ??
            coin['price_change_percentage_24h']);
    final marketCap = _coerceDouble(coin['market_cap']);

    final rankStr = rank != null ? '#$rank ' : '';
    buf.write('$rankStr$name ($symbol)');
    if (price != null) {
      buf.write(': ${_formatNumber(price, currency)}');
    }
    if (change24h != null) {
      buf.write(
        ' (${change24h >= 0 ? '+' : ''}${change24h.toStringAsFixed(2)}%)',
      );
    }
    if (marketCap != null) {
      buf.write(' | MCap: ${_formatLargeNumber(marketCap, currency)}');
    }
    buf.writeln();
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
    if (price != null) buf.write(' \$${_formatNumber(price, 'usd')}');
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
  buf.writeln('Use the coin id with action "price" or "markets" for details.');

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

String _formatNumber(double value, String currency) {
  if (value >= 1) {
    return value.toStringAsFixed(2);
  } else if (value >= 0.01) {
    return value.toStringAsFixed(4);
  } else {
    return value.toStringAsFixed(8);
  }
}

String _formatLargeNumber(double value, String currency) {
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
