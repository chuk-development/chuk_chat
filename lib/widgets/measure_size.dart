import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Callback invoked whenever the measured child changes size.
typedef OnWidgetSizeChange = void Function(Size size);

/// Reports its child's laid-out size via [onChange] after every layout in which
/// the size actually changed. Used to feed a variable-height composer's real
/// height back into the message list padding so content never hides behind it.
///
/// The callback fires in a post-frame callback (safe to call setState from it).
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({
    super.key,
    required this.onChange,
    required Widget super.child,
  });

  final OnWidgetSizeChange onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _MeasureSizeRenderObject).onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  OnWidgetSizeChange onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final Size newSize = child?.size ?? Size.zero;
    if (_oldSize == newSize) return;
    _oldSize = newSize;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      onChange(newSize);
    });
  }
}
