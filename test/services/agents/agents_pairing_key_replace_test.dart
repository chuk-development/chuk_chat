// A reinstalled computer keeps its device id and gets a new key. A fresh
// §15 ceremony may replace the old approval; a reconnect may not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_approved_devices.dart';
import 'package:chuk_chat/services/agents/agents_controller_session.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_pairing.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';

void main() {
  const int ts = 1723478400000;
  int fixedClock() => ts;

  Future<SimplePublicKey> newKey() async =>
      (await AgentsDeviceKeys.generate()).extractPublicKey();

  group('AgentsApprovedDevices', () {
    test('approve still refuses a different key for an approved id', () async {
      final store = AgentsApprovedDevices.empty()
        ..approve('host', await newKey());
      expect(
        () async => store.approve('host', await newKey()),
        throwsA(isA<StateError>()),
      );
    });

    test('replaceAfterPairing swaps the key and returns the old one', () async {
      final SimplePublicKey oldKey = await newKey();
      final SimplePublicKey fresh = await newKey();
      final store = AgentsApprovedDevices.empty()..approve('host', oldKey);
      final SimplePublicKey? replaced = store.replaceAfterPairing(
        'host',
        fresh,
      );
      expect(replaced!.bytes, oldKey.bytes);
      expect(store.lookup('host')!.bytes, fresh.bytes);
    });

    test(
      'replaceAfterPairing with an invalid key leaves the store as it was',
      () async {
        final SimplePublicKey oldKey = await newKey();
        final store = AgentsApprovedDevices.empty()..approve('host', oldKey);
        expect(
          () => store.replaceAfterPairing(
            'host',
            SimplePublicKey(<int>[1, 2, 3], type: KeyPairType.ed25519),
          ),
          throwsArgumentError,
        );
        expect(store.lookup('host')!.bytes, oldKey.bytes);
      },
    );
  });

  group('the ceremony', () {
    /// Runs a full ceremony: host `host-01` (initiator) and this app
    /// (joiner), with [appStore] as the app's approved devices. Returns the
    /// joiner and the host's new public key.
    Future<(AgentsPairing, SimplePublicKey)> ceremony(
      AgentsApprovedDevices appStore,
    ) async {
      final SimpleKeyPair hostKey = await AgentsDeviceKeys.generate();
      final initiator = await AgentsPairing.initiator(
        deviceId: 'host-01',
        deviceKeyPair: hostKey,
        nowMs: fixedClock,
        channelId: 'chan0001',
        digits: '42891377',
        sasDigits: 8,
        approvedDevices: AgentsApprovedDevices.empty(),
      );
      final joiner = await AgentsPairing.joiner(
        deviceId: 'app-01',
        deviceKeyPair: await AgentsDeviceKeys.generate(),
        pairingCode: initiator.pairingCode,
        nowMs: fixedClock,
        approvedDevices: appStore,
      );
      joiner.onCommit(initiator.createCommit());
      final reveal = await initiator.onPubkey(joiner.createPubkey());
      final confirmD = await joiner.onReveal(reveal);
      final confirmC = await initiator.onConfirmD(confirmD);
      await joiner.onConfirmC(confirmC);
      await initiator.onPeerDeviceKey(await joiner.createDeviceKey());
      await joiner.onPeerDeviceKey(await initiator.createDeviceKey());
      expect(joiner.state, AgentsPairingState.completed);
      return (joiner, await hostKey.extractPublicKey());
    }

    test(
      'a fresh ceremony replaces an old key for the same device id',
      () async {
        final SimplePublicKey oldKey = await newKey();
        final store = AgentsApprovedDevices.empty()..approve('host-01', oldKey);
        final (_, SimplePublicKey hostKey) = await ceremony(store);
        expect(store.lookup('host-01')!.bytes, hostKey.bytes);
      },
    );

    test('rollback restores the key the ceremony replaced', () async {
      final SimplePublicKey oldKey = await newKey();
      final store = AgentsApprovedDevices.empty()..approve('host-01', oldKey);
      final (AgentsPairing joiner, _) = await ceremony(store);
      joiner.rollbackPeerApproval();
      expect(store.lookup('host-01')!.bytes, oldKey.bytes);
      // A second call changes nothing.
      joiner.rollbackPeerApproval();
      expect(store.lookup('host-01')!.bytes, oldKey.bytes);
    });

    test('rollback of a first pairing leaves no approval', () async {
      final store = AgentsApprovedDevices.empty();
      final (AgentsPairing joiner, _) = await ceremony(store);
      expect(store.isApproved('host-01'), isTrue);
      joiner.rollbackPeerApproval();
      expect(store.isEmpty, isTrue);
    });
  });

  group('a reconnect is not a ceremony', () {
    test(
      'a host that signs with another key than the stored one is refused',
      () async {
        final SimpleKeyPair storedHostKey = await AgentsDeviceKeys.generate();
        final SimpleKeyPair otherHostKey = await AgentsDeviceKeys.generate();
        final SimpleKeyPair appKey = await AgentsDeviceKeys.generate();
        final trust = AgentsStoredPairing(
          hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=h'),
          channelId: 'chan0001',
          channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
          peerDeviceId: 'host-01',
          peerPublicKey: await storedHostKey.extractPublicKey(),
        );
        final session = AgentsControllerSession('app-01', appKey, trust);
        final resume = await session.resume();
        final String hostNonce = base64Encode(List<int>.filled(32, 7));
        final signed = utf8.encode(
          jsonEncode(<Object?>[
            trust.channelId,
            'app-01',
            resume['public_key'],
            resume['client_nonce'],
            hostNonce,
          ]),
        );
        // Signed by the reinstalled host's NEW key, not the stored one.
        final signature = await Ed25519().sign(<int>[
          ...utf8.encode('cowork/controller/host/'),
          ...signed,
        ], keyPair: otherHostKey);
        await expectLater(
          session.challenge(<String, dynamic>{
            'device_id': 'app-01',
            'client_nonce': resume['client_nonce'],
            'host_nonce': hostNonce,
            'connection': 'c1',
            'signature': base64Encode(signature.bytes),
          }),
          throwsA(isA<FormatException>()),
        );
        expect(session.authenticated, isFalse);
      },
    );
  });
}
