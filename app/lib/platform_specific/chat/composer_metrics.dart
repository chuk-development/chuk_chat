// lib/platform_specific/chat/composer_metrics.dart

/// The numbers that make the mobile composer's action row read as one family.
class ComposerMetrics {
  const ComposerMetrics._();

  /// One size for every target in the composer action row: the plus, the mode
  /// pill, the microphone and send. The row reads as one family only if they
  /// share a number — a 36 here and a 38 there is visible, and the microphone
  /// turning into the stop target must not resize anything. Change this one
  /// constant, never a single call site.
  static const double targetSize = 38;

  /// The gap between two targets of that row. One number, so the spacing is
  /// even from the plus to send.
  static const double targetGap = 6;
}
