import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/api_config_service.dart';

/// One model the account may use, as returned by `/v1/models_info`.
class AccountModel {
  const AccountModel({required this.id, required this.name});

  /// Model slug used by the API (e.g. `openai/gpt-4o`).
  final String id;

  /// Human-readable display name. Falls back to [id] when absent.
  final String name;

  factory AccountModel.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?) ?? '';
    final name = (json['name'] as String?) ?? id;
    return AccountModel(id: id, name: name);
  }
}

/// Raised when the model list cannot be fetched.
class ModelsFetchException implements Exception {
  const ModelsFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches the account's available models from `{apiBaseUrl}/v1/models_info`,
/// authenticated with the account's access token.
///
/// This is the proof that the captured session token actually works against
/// the real backend: a 200 with the account's model list means the executor
/// would be able to spend the account's models and credits with the same token.
///
/// The HTTP client is injectable so the fetch is testable without a network.
class ModelsService {
  ModelsService({
    required AccountSessionSource sessionSource,
    http.Client? httpClient,
    String? apiBaseUrl,
  }) : _sessionSource = sessionSource,
       _http = httpClient ?? http.Client(),
       _apiBaseUrl = apiBaseUrl ?? ApiConfigService.apiBaseUrl;

  final AccountSessionSource _sessionSource;
  final http.Client _http;
  final String _apiBaseUrl;

  /// Fetches the model list. On a 401 the session is refreshed once and the
  /// request is retried with the fresh access token.
  Future<List<AccountModel>> fetchModels() async {
    var session = _sessionSource.current();
    if (session == null) {
      throw const ModelsFetchException('Not signed in.');
    }

    var response = await _get(session.accessToken);

    if (response.statusCode == 401) {
      session = await _sessionSource.refresh();
      if (session == null) {
        throw const ModelsFetchException('Session expired. Sign in again.');
      }
      response = await _get(session.accessToken);
    }

    if (response.statusCode != 200) {
      throw ModelsFetchException(
        'Could not load models (HTTP ${response.statusCode}).',
      );
    }

    final dynamic decoded = response.body.isNotEmpty
        ? json.decode(response.body)
        : const <dynamic>[];
    if (decoded is! List) {
      throw const ModelsFetchException('Unexpected models response.');
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(AccountModel.fromJson)
        .where((model) => model.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<http.Response> _get(String accessToken) {
    return _http.get(
      Uri.parse('$_apiBaseUrl/v1/models_info'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
  }
}
