// A fake app for the agent driver tests. Records every call.

import 'dart:convert';

import '../../tool/agent_driver/src/app_session.dart';

/// A 1x1 transparent PNG.
const String onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
    '60e6kgAAAABJRU5ErkJggg==';

class FakeApp implements AppControl {
  final List<Map<String, String>> driverCalls = <Map<String, String>>[];
  final List<String> extensionCalls = <String>[];
  final List<Map<String, String>> extensionArgs = <Map<String, String>>[];
  String? failDriverWith;
  bool started = false;

  @override
  bool get running => started;

  @override
  Future<Map<String, Object?>> start({
    required bool headless,
    required bool fresh,
    String? definesFile,
  }) async {
    started = true;
    return <String, Object?>{
      'running': true,
      'headless': headless,
      'fresh': fresh,
    };
  }

  @override
  Future<Map<String, Object?>> stop() async {
    started = false;
    return <String, Object?>{'stopped': true};
  }

  @override
  Map<String, Object?> status() => <String, Object?>{'running': started};

  @override
  List<String> logs(int lines) =>
      <String>['line 1', 'line 2'].take(lines).toList();

  @override
  Future<Object?> driver(Map<String, String> params) async {
    driverCalls.add(params);
    final String? fail = failDriverWith;
    if (fail != null) throw DriverCommandError(fail);
    return <String, Object?>{};
  }

  @override
  Future<Map<String, Object?>> extension(
    String method, [
    Map<String, String> args = const <String, String>{},
  ]) async {
    extensionCalls.add(method);
    extensionArgs.add(args);
    if (method == 'ext.chuk.agent.screenshot') {
      return <String, Object?>{'width': 1, 'height': 1, 'png': onePixelPng};
    }
    if (method == 'ext.chuk.agent.state') {
      return jsonDecode('{"texts":[{"text":"Hi"}]}') as Map<String, Object?>;
    }
    return <String, Object?>{'ok': true};
  }

  @override
  Future<Map<String, Object?>> hotReload({required bool fullRestart}) async =>
      <String, Object?>{
        'result': <String, Object?>{'code': 0},
      };
}
