/// Read receipts — the ticks in the corner of a bubble.
///
/// ## What a tick means here, and when there is none
///
/// A messenger shows ticks because the reader wants to know whether the OTHER
/// side got the message. That question only exists for what the user sends, so:
///
///  * a USER bubble carries a receipt: a clock while the message waits in the
///    offline queue, one tick once the host has it, two muted ticks once the
///    coworker picked the turn up, two accent ticks once it answered, and an
///    error glyph when the send gave up;
///  * a COWORKER bubble carries NO receipt at all. The agent is the sender
///    there, and the app cannot say anything about "did the user read it" that
///    it actually knows. So the ticks fall away and only the time is left.
///
/// [ReceiptState] is what the bubble renders; [receiptStateFor] maps CoWork's
/// own [ChatMessageStatus] plus the two facts the thread knows (was the turn
/// picked up, did an answer arrive) onto it. Nothing here invents a state the
/// app cannot observe.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/chat_message.dart' show ChatMessageStatus;

/// What the receipt badge shows.
enum ReceiptState {
  /// In the offline queue, not sent yet.
  sending,

  /// The host has the message.
  sent,

  /// The coworker started working on this turn.
  delivered,

  /// The coworker answered.
  read,

  /// The send gave up.
  failed,
}

/// Maps CoWork's own delivery status onto a receipt.
///
/// [pickedUp] is true once the coworker started the turn (a run is in flight or
/// the stream opened); [answered] is true once a coworker message follows this
/// one in the thread.
ReceiptState receiptStateFor({
  required ChatMessageStatus? status,
  required bool pickedUp,
  required bool answered,
}) {
  switch (status) {
    case ChatMessageStatus.pending:
      return ReceiptState.sending;
    case ChatMessageStatus.failed:
      return ReceiptState.failed;
    case ChatMessageStatus.interrupted:
    case ChatMessageStatus.sent:
    case null:
      if (answered) return ReceiptState.read;
      if (pickedUp) return ReceiptState.delivered;
      return ReceiptState.sent;
  }
}

/// The interchangeable looks for the badge. The app uses one; the others are
/// kept because switching the whole app is a one-line change.
enum CheckStyle {
  /// An outlined circle per tick that fills with the accent once read.
  circles,

  /// The Signal look: the right tick on top and a touch higher.
  signalStack,

  /// A rounded double tick, the second overlapping the first.
  overlap,

  /// One chunky oversized glyph.
  bold,
}

/// The look used app-wide.
const CheckStyle kActiveCheckStyle = CheckStyle.circles;

/// Builds the badge (the ticks only — the time text is added by the caller).
///
/// [fg] is the muted foreground, [accent] the colour once read, [onAccent] the
/// tick colour on a filled accent, and [bg] the colour behind the badge so two
/// overlapping circles occlude each other instead of showing through.
Widget buildReceiptCheck(
  CheckStyle style,
  ReceiptState state, {
  required Color fg,
  required Color accent,
  required Color onAccent,
  Color bg = Colors.transparent,
  Color? errorColor,
}) {
  if (state == ReceiptState.sending) {
    return Icon(Icons.schedule_rounded, size: 15, color: fg);
  }
  if (state == ReceiptState.failed) {
    return Icon(
      Icons.error_outline_rounded,
      size: 15,
      color: errorColor ?? fg,
    );
  }
  final bool read = state == ReceiptState.read;
  final bool two = state != ReceiptState.sent;
  final Color muted = fg.withValues(alpha: 0.9);
  final Color color = read ? accent : muted;

  switch (style) {
    case CheckStyle.circles:
      Widget circle() => Container(
        width: 15,
        height: 15,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: read ? accent : bg,
          border: Border.all(
            color: read ? accent : fg.withValues(alpha: 0.7),
            width: 1.3,
          ),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 9,
          height: 9,
          child: CustomPaint(
            painter: _TickPainter(color: read ? onAccent : muted, stroke: 1.8),
          ),
        ),
      );
      if (!two) return circle();
      return SizedBox(
        height: 15,
        width: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, top: 0, child: circle()), // behind
            Positioned(left: 7, top: 0, child: circle()), // on top, occluding
          ],
        ),
      );

    case CheckStyle.signalStack:
      Widget chk() => Icon(Icons.check_rounded, size: 15, color: color);
      if (!two) return SizedBox(height: 16, width: 12, child: chk());
      return SizedBox(
        height: 16,
        width: 16,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, top: 4, child: chk()),
            Positioned(left: 3, top: 0, child: chk()),
          ],
        ),
      );

    case CheckStyle.overlap:
      final Widget check = Icon(Icons.check_rounded, size: 14, color: color);
      if (!two) return SizedBox(height: 15, child: check);
      return SizedBox(
        height: 15,
        width: 20,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, child: check),
            Positioned(left: 6, child: check),
          ],
        ),
      );

    case CheckStyle.bold:
      return Icon(
        two ? Icons.done_all_rounded : Icons.check_rounded,
        size: 18,
        color: color,
      );
  }
}

/// The footer inside a bubble: the time on the left and, for a user message,
/// the receipt on the right. A coworker bubble passes [showCheck] false and so
/// shows the time alone.
class MessageReceipt extends StatelessWidget {
  const MessageReceipt({
    super.key,
    required this.state,
    required this.age,
    required this.fg,
    required this.accent,
    required this.onAccent,
    this.bg = Colors.transparent,
    this.showCheck = true,
    this.edited = false,
    this.errorColor,
  });

  final ReceiptState state;

  /// The already formatted time or age ("14:03", "2 min").
  final String age;
  final bool showCheck;
  final bool edited;

  /// Time text and tick outline colour.
  final Color fg;

  /// Fill colour once the message is read.
  final Color accent;

  /// Tick colour when the badge is filled.
  final Color onAccent;

  /// The colour behind the badge (the bubble fill).
  final Color bg;

  final Color? errorColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (edited) ...[
          Text(
            'edited',
            style: TextStyle(
              color: fg.withValues(alpha: 0.7),
              fontSize: 11,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          age,
          style: TextStyle(
            color: fg.withValues(alpha: 0.85),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (showCheck) ...[
          const SizedBox(width: 5),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(
              key: ValueKey<ReceiptState>(state),
              child: buildReceiptCheck(
                kActiveCheckStyle,
                state,
                fg: fg,
                accent: accent,
                onAccent: onAccent,
                bg: bg,
                errorColor: errorColor,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Draws a tick with a configurable [stroke], so it can be made fatter without
/// growing the glyph.
class _TickPainter extends CustomPainter {
  _TickPainter({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final double w = size.width;
    final double h = size.height;
    final Path path = Path()
      ..moveTo(w * 0.20, h * 0.52)
      ..lineTo(w * 0.42, h * 0.73)
      ..lineTo(w * 0.82, h * 0.28);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_TickPainter old) =>
      old.color != color || old.stroke != stroke;
}
