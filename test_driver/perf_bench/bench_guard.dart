// Keeps the benchmark app away from everything real. It is installed as its
// own package with a fake session, but the API base is compiled in, so
// without this guard it talks to the production API over the phone's data.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

// Comes with url_launcher; only this benchmark needs to name it.
// ignore_for_file: depend_on_referenced_packages

import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Every dart:io HTTP request and WebSocket goes to a dead local proxy.
class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = ((Uri _) => 'PROXY 127.0.0.1:9');
}

/// Links do not open the browser; the crawler stays in the app.
class _NoBrowser extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async => true;
}

/// Registered after the app's observer, so it is asked last: a back that no
/// navigator took would close the app and restart the crawl.
class _StayAtRoot with WidgetsBindingObserver {
  @override
  Future<bool> didPopRoute() async => true;
}

void keepAppOnRootBack() =>
    WidgetsBinding.instance.addObserver(_StayAtRoot());

void installBenchGuard() {
  HttpOverrides.global = _NoNetwork();
  UrlLauncherPlatform.instance = _NoBrowser();
}
