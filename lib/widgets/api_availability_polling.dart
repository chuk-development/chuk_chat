// lib/widgets/api_availability_polling.dart

import 'dart:async';

import 'package:chuk_chat/services/api_status_service.dart';
import 'package:flutter/widgets.dart';

/// Retries a failed model fetch once the API answers again.
///
/// When the model list fails to load, the screen shows an error and starts
/// polling. The moment the API is reachable the poll stops and [onApiReachable]
/// reloads — the user never has to press retry.
mixin ApiAvailabilityPolling<T extends StatefulWidget> on State<T> {
  static const Duration _pollInterval = Duration(seconds: 8);

  Timer? _apiAvailabilityTimer;
  bool _probeInFlight = false;

  /// The API base URL to probe.
  String get apiPollBaseUrl;

  /// Runs once the API answers again. Implementations reload their models.
  Future<void> onApiReachable();

  void startApiAvailabilityPolling() {
    _apiAvailabilityTimer ??= Timer.periodic(_pollInterval, (_) async {
      // Timer.periodic does not wait for an async callback. A probe that
      // takes longer than the interval would otherwise stack, and two
      // successful ones would reload the same screen twice.
      if (_probeInFlight) return;
      _probeInFlight = true;
      try {
        final bool reachable = await ApiStatusService.isApiReachable(
          baseUrl: apiPollBaseUrl,
        );
        if (!reachable || !mounted) return;
        stopApiAvailabilityPolling();
        await onApiReachable();
      } finally {
        _probeInFlight = false;
      }
    });
  }

  void stopApiAvailabilityPolling() {
    _apiAvailabilityTimer?.cancel();
    _apiAvailabilityTimer = null;
    _probeInFlight = false;
  }
}
