// OpenUI Buttons, IconButton and FollowUpBlock.
//
// All taps go through `OpenUiAction.run`, so a tap inside a `Form`
// carries the form values. A target is disabled while its own statement
// still streams.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

// ---------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------

/// Builds `Buttons(buttons, direction?)`.
Widget buildOpenUiButtons(BuildContext context, OpenUiProps props) {
  final buttons = props.children('buttons');
  if (buttons.isEmpty) return const SizedBox.shrink();
  if (props.choice('direction', fallback: 'row') == 'column') {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < buttons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          buttons[i],
        ],
      ],
    );
  }
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: buttons,
  );
}

// ---------------------------------------------------------------------
// IconButton
// ---------------------------------------------------------------------

/// Builds `IconButton(name, icon, action?, variant?, size?, shape?)`.
Widget buildOpenUiIconButton(BuildContext context, OpenUiProps props) {
  final name = props.string('name').trim();
  return OpenUiIconButtonView(
    name: name,
    icon: props.child('icon'),
    action: props.action('action'),
    variant: props.choice('variant', fallback: 'secondary'),
    size: props.choice('size', fallback: 'medium'),
    circle: props.choice('shape', fallback: 'square') == 'circle',
    statementId: props.statementId,
  );
}

/// An icon-only button. [name] is the accessible label, the tooltip
/// and the action label.
class OpenUiIconButtonView extends StatelessWidget {
  /// Creates an icon button.
  const OpenUiIconButtonView({
    required this.name,
    this.icon,
    this.action,
    this.variant = 'secondary',
    this.size = 'medium',
    this.circle = false,
    this.statementId = '',
    super.key,
  });

  /// The label.
  final String name;

  /// The icon widget (an OpenUI `Icon`). It may be absent while the
  /// program streams; the button keeps its size.
  final Widget? icon;

  /// The action, or `null` (then a tap sends [name] to the assistant).
  final OpenUiAction? action;

  /// `primary`, `secondary` or `tertiary`.
  final String variant;

  /// `extra-small`, `small`, `medium` or `large`.
  final String size;

  /// Round instead of the app's rounded square.
  final bool circle;

  /// The statement of the button, to detect a still-streaming one.
  final String statementId;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    final enabled =
        name.isNotEmpty && !openUiStatementStreaming(context, statementId);
    final (double box, double glyph) = switch (size) {
      'extra-small' => (32.0, 16.0),
      'small' => (40.0, 18.0),
      'large' => (56.0, 24.0),
      _ => (48.0, 22.0),
    };
    final (Color fill, Color fg) = switch (variant) {
      'primary' => (scheme.primary, scheme.onPrimary),
      'tertiary' => (
        Colors.transparent,
        Theme.of(context).accentForegroundOn(scheme.surface),
      ),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    final ShapeBorder shape = circle
        ? const CircleBorder()
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(box * 0.34),
          );
    final ShapeBorder pressed = circle
        ? const CircleBorder()
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(box * 0.20),
          );
    Widget button = MorphTap(
      onTap: enabled ? () => _onTap(context) : null,
      color: fill,
      shape: shape,
      pressedShape: pressed,
      padding: EdgeInsets.all((box - glyph) / 2),
      child: SizedBox.square(
        dimension: glyph,
        child: icon == null
            ? null
            : IconTheme.merge(
                data: IconThemeData(color: fg, size: glyph),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: fg),
                  child: Center(child: icon),
                ),
              ),
      ),
    );
    if (name.isNotEmpty) {
      button = Tooltip(message: name, child: button);
    }
    // Its own size, also in a parent that stretches its children.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: name,
        excludeSemantics: true,
        child: Opacity(opacity: enabled ? 1 : 0.5, child: button),
      ),
    );
  }

  void _onTap(BuildContext context) {
    final a = action ?? OpenUiAction(implicitContinueConversationPlan(name));
    a.run(context, label: name);
  }
}

// ---------------------------------------------------------------------
// FollowUpBlock
// ---------------------------------------------------------------------

/// Builds `FollowUpBlock(items)`.
Widget buildOpenUiFollowUpBlock(BuildContext context, OpenUiProps props) {
  final items = <({String text, String statementId})>[
    for (final item in props.data('items', type: 'FollowUpItem'))
      if (item.string('text').trim().isNotEmpty)
        (text: item.string('text').trim(), statementId: item.statementId),
  ];
  if (items.isEmpty) return const SizedBox.shrink();
  return OpenUiFollowUpList(items: items, statementId: props.statementId);
}

/// The follow-up suggestions: one connected run of tiles (the app's
/// menu shape), each a tap that sends its text as the user's message.
class OpenUiFollowUpList extends StatelessWidget {
  /// Creates the list.
  const OpenUiFollowUpList({
    required this.items,
    this.statementId = '',
    super.key,
  });

  /// The suggestions and the statement each came from.
  final List<({String text, String statementId})> items;

  /// The statement of the block.
  final String statementId;

  static const double _outer = 18;
  static const double _inner = 6;
  static const double _gap = 3;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final blockStreaming = openUiStatementStreaming(context, statementId);
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final first = i == 0;
      final last = i == items.length - 1;
      final radius = BorderRadius.vertical(
        top: Radius.circular(first ? _outer : _inner),
        bottom: Radius.circular(last ? _outer : _inner),
      );
      final enabled =
          !blockStreaming &&
          !openUiStatementStreaming(context, item.statementId);
      if (i > 0) children.add(const SizedBox(height: _gap));
      children.add(
        _FollowUpTile(
          text: item.text,
          radius: radius,
          fill: t.sunkColor,
          enabled: enabled,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _FollowUpTile extends StatelessWidget {
  const _FollowUpTile({
    required this.text,
    required this.radius,
    required this.fill,
    required this.enabled,
  });

  final String text;
  final BorderRadius radius;
  final Color fill;
  final bool enabled;

  static const double _fontSize = 14.5;
  static const double _line = 20;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final iconColor = Theme.of(context).accentForegroundOn(fill);
    return Semantics(
      button: true,
      enabled: enabled,
      label: text,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Material(
          color: fill,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? () => _send(context) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      text,
                      style: t.bodyStyle.copyWith(
                        fontSize: _fontSize,
                        height: _line / _fontSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 18,
                    height: _line,
                    child: Center(
                      child: HugeIcon(
                        HugeIcons.arrowUpRight01,
                        size: 18,
                        color: iconColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _send(BuildContext context) {
    OpenUiAction(implicitContinueConversationPlan(text))
        .run(context, label: text);
  }
}
