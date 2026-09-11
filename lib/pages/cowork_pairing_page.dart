/// Adding your computer — the one screen the user ever sees about connecting.
///
/// On a phone it OPENS THE CAMERA. That is the whole flow: point it at the code
/// on the computer screen and the app is linked, for good. There is no host
/// address, no port, no protocol word and no jargon anywhere on it, because the
/// person doing this is not expected to know what any of that means.
///
/// The typed code is the fallback, one tap away, for a camera that is blocked or
/// missing and for a desktop, which has no camera worth using and gets the field
/// straight away. A denied permission lands on the same field with one plain
/// sentence — never a dead black rectangle.
///
/// The screen produces a [CoworkPairingInvite] and nothing else; who dials it
/// and what is persisted afterwards belongs to the caller.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/services/cowork/cowork_pairing_uri.dart';

/// Builds the live camera view. Injected so a widget test can drive the screen
/// with no camera and no platform channel.
///
/// [onCode] takes the raw scanned text; [onUnavailable] says the camera cannot
/// be used (no permission, no camera, a driver that failed) and carries the one
/// sentence to show.
typedef CoworkQrViewBuilder =
    Widget Function(
      BuildContext context, {
      required ValueChanged<String> onCode,
      required ValueChanged<String> onUnavailable,
    });

/// True on the platforms where opening a camera is the right default.
bool coworkCameraIsDefault() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

class CoworkPairingPage extends StatefulWidget {
  const CoworkPairingPage({
    super.key,
    this.qrViewBuilder,
    this.cameraAvailable,
  });

  /// Overrides the camera view. Null uses [MobileScanner].
  final CoworkQrViewBuilder? qrViewBuilder;

  /// Overrides the platform check. Null asks [coworkCameraIsDefault].
  final bool? cameraAvailable;

  /// Opens the screen and hands back what the user scanned or typed, or null
  /// when they backed out.
  static Future<CoworkPairingInvite?> show(BuildContext context) {
    return Navigator.of(context).push<CoworkPairingInvite>(
      MaterialPageRoute<CoworkPairingInvite>(
        builder: (_) => const CoworkPairingPage(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<CoworkPairingPage> createState() => _CoworkPairingPageState();
}

class _CoworkPairingPageState extends State<CoworkPairingPage> {
  final TextEditingController _code = TextEditingController();

  late bool _scanning = widget.cameraAvailable ?? coworkCameraIsDefault();

  /// One plain sentence, or null. Shown under whichever view is up.
  String? _message;

  /// A scan resolves once. Without this the detector fires many times a second
  /// and would pop the route repeatedly.
  bool _handled = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _accept(CoworkPairingInvite invite) {
    if (_handled) return;
    _handled = true;
    Navigator.of(context).pop(invite);
  }

  /// The scanner found a code. Anything that is not one of ours is ignored
  /// quietly — a person pointing a camera around will hit other QR codes, and
  /// that is not an error worth a red box.
  void _onScanned(String raw) {
    if (_handled) return;
    final invite = CoworkPairingInvite.tryParse(raw);
    if (invite == null) {
      // The scanned text is never shown or logged: a near miss can still be
      // most of a real code.
      if (mounted && _message == null) {
        setState(
          () => _message =
              'That is not a CoWork code. Keep the camera '
              'on the code your computer shows.',
        );
      }
      return;
    }
    _accept(invite);
  }

  /// The camera cannot be used. Fall straight through to the field the user can
  /// always reach, with the reason in one sentence.
  void _onCameraUnavailable(String reason) {
    if (!mounted || _handled) return;
    setState(() {
      _scanning = false;
      _message = reason;
    });
  }

  void _submitCode() {
    final invite = CoworkPairingInvite.tryParse(_code.text);
    if (invite == null) {
      setState(
        () => _message =
            'That code is not complete. Copy the whole line your '
            'computer shows.',
      );
      return;
    }
    _accept(invite);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpressiveScreen(
      title: 'Add your computer',
      builder: (BuildContext context) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _scanning ? _buildScanner() : _buildCodeForm()),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  _message!,
                  key: const ValueKey<String>('cowork-pairing-message'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: _scanning
                  ? TextButton(
                      key: const ValueKey<String>('cowork-pairing-use-code'),
                      onPressed: () => setState(() {
                        _scanning = false;
                        _message = null;
                      }),
                      child: const Text('Enter the code instead'),
                    )
                  : TextButton(
                      key: const ValueKey<String>('cowork-pairing-use-camera'),
                      onPressed:
                          (widget.cameraAvailable ?? coworkCameraIsDefault())
                          ? () => setState(() {
                              _scanning = true;
                              _message = null;
                            })
                          : null,
                      child: const Text('Use the camera'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanner() {
    final builder = widget.qrViewBuilder ?? _defaultQrView;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        builder(
          context,
          onCode: _onScanned,
          onUnavailable: _onCameraUnavailable,
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Point the camera at the code on your computer.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                shadows: const <Shadow>[Shadow(blurRadius: 8)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCodeForm() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Your computer shows a code when CoWork runs on it. Type or paste '
            'it here.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey<String>('cowork-pairing-code-field'),
            controller: _code,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Code from your computer',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submitCode(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey<String>('cowork-pairing-connect'),
            onPressed: _submitCode,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  /// The real camera. Every failure the scanner can report — a refused
  /// permission first of all — is turned into the code field plus a sentence.
  Widget _defaultQrView(
    BuildContext context, {
    required ValueChanged<String> onCode,
    required ValueChanged<String> onUnavailable,
  }) {
    return MobileScanner(
      onDetect: (BarcodeCapture capture) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value != null && value.isNotEmpty) {
            onCode(value);
            return;
          }
        }
      },
      onDetectError: (Object _, StackTrace _) {},
      errorBuilder: (BuildContext context, MobileScannerException error) {
        // Deferred: the builder runs during layout, and switching views from
        // inside it would rebuild the tree mid-frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onUnavailable(_cameraErrorText(error));
        });
        return const ColoredBox(color: Colors.black);
      },
    );
  }

  static String _cameraErrorText(MobileScannerException error) {
    return switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'This app is not allowed to use the camera. Enter the code instead, '
            'or turn the camera on for CoWork in your phone settings.',
      MobileScannerErrorCode.unsupported =>
        'This device has no camera the app can use. Enter the code instead.',
      _ => 'The camera did not start. Enter the code instead.',
    };
  }
}
