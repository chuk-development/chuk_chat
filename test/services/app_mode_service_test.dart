import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/app_mode_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('with nothing remembered, a paired device opens on Agents', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    await mode.load(hasPairing: () async => true);
    expect(mode.value, AppMode.agents);
    expect(mode.loaded, isTrue);
  });

  test('with nothing remembered, an unpaired device opens on Chat', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    await mode.load(hasPairing: () async => false);
    expect(mode.value, AppMode.chat);
  });

  test('the default is not written: only a choice is', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    await mode.load(hasPairing: () async => false);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeService.prefsKey), isNull);
  });

  test('a remembered choice wins over the pairing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppModeService.prefsKey: 'chat',
    });
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    int asked = 0;
    await mode.load(
      hasPairing: () async {
        asked++;
        return true;
      },
    );
    expect(mode.value, AppMode.chat);
    expect(asked, 0, reason: 'the pairing store is not opened for nothing');
  });

  test('select shows the half at once and remembers it', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    final List<AppMode> seen = <AppMode>[];
    mode.addListener(() => seen.add(mode.value));
    final Future<void> write = mode.select(AppMode.chat);
    expect(mode.value, AppMode.chat, reason: 'before the write lands');
    await write;
    expect(seen, <AppMode>[AppMode.chat]);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppModeService.prefsKey), 'chat');

    // The next launch reads it back.
    final AppModeService next = AppModeService();
    addTearDown(next.dispose);
    await next.load(hasPairing: () async => true);
    expect(next.value, AppMode.chat);
  });

  test('a choice made while the default is still loading wins', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    final Completer<bool> pairing = Completer<bool>();
    final Future<void> load = mode.load(hasPairing: () => pairing.future);
    await mode.select(AppMode.agents);
    pairing.complete(false);
    await load;
    expect(mode.value, AppMode.agents);
    expect(mode.loaded, isTrue);
  });

  test('a pairing store that fails keeps what is shown', () async {
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    await mode.load(hasPairing: () async => throw StateError('locked'));
    expect(mode.value, AppMode.agents);
    expect(mode.loaded, isTrue);
  });

  test('a damaged stored value falls back to the default', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppModeService.prefsKey: 'sideways',
    });
    final AppModeService mode = AppModeService();
    addTearDown(mode.dispose);
    await mode.load(hasPairing: () async => false);
    expect(mode.value, AppMode.chat);
  });

  test('a load that lands after dispose does nothing', () async {
    final AppModeService mode = AppModeService();
    final Completer<bool> pairing = Completer<bool>();
    final Future<void> load = mode.load(hasPairing: () => pairing.future);
    mode.dispose();
    pairing.complete(false);
    await load;
    expect(mode.loaded, isFalse);
  });

  test('parse', () {
    expect(AppModeService.parse('chat'), AppMode.chat);
    expect(AppModeService.parse('agents'), AppMode.agents);
    expect(AppModeService.parse(null), isNull);
    expect(AppModeService.parse(''), isNull);
  });
}
