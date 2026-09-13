import 'package:flutter/widgets.dart';

/// Widget that exposes its child's size via a [ValueNotifier].
///
/// Inspired by: https://stackoverflow.com/a/58004112/373138
///
/// Agents fork: upstream measured once, in `initState`'s post-frame callback.
/// A framebuffer that changes size mid-session (desktop-size change, a
/// different Xvfb geometry) left the notifier stale, and with it the tap and
/// wheel coordinate mapping. The size is now re-read after every build and the
/// notifier only fires when it actually changed.
class SizeTrackingWidget extends StatefulWidget {
  final Widget _child;
  final ValueNotifier<Size> _sizeValueNotifier;

  const SizeTrackingWidget({
    super.key,
    required final ValueNotifier<Size> sizeValueNotifier,
    required final Widget child,
  })  : _child = child,
        _sizeValueNotifier = sizeValueNotifier;

  @override
  State<StatefulWidget> createState() => _SizeTackingState();
}

class _SizeTackingState extends State<SizeTrackingWidget> {
  void _measure() {
    if (!mounted) {
      return;
    }
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    if (widget._sizeValueNotifier.value != box.size) {
      widget._sizeValueNotifier.value = box.size;
    }
  }

  @override
  Widget build(final BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((final _) => _measure());
    return widget._child;
  }
}
