/// The app's icon set: HugeIcons, shipped as SVG.
///
/// Material's glyphs and this set do not sit together — two line weights, two
/// corner languages, two ideas of what a file looks like — so the app uses one
/// set and this is it. The icons are generated into `assets/icons/hugeicons`
/// and checked in (MIT, see the LICENSE beside them): nothing is fetched at run
/// time, and no icon package is a dependency that could disappear.
///
/// Sizes and colours behave like [Icon]: pass what you would pass there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// One icon of the set. The name is the file stem, so `HugeIcons.message01`
/// is `assets/icons/hugeicons/message01.svg`.
@immutable
class HugeIconData {
  const HugeIconData(this.name);

  final String name;

  String get asset => 'assets/icons/hugeicons/$name.svg';
}

/// The icons this app uses. Adding one means generating its SVG into the asset
/// directory; a name with no file is a missing asset, not a silent blank.
abstract final class HugeIcons {
  static const HugeIconData message01 = HugeIconData('message01');
  static const HugeIconData album02 = HugeIconData('album02');
  static const HugeIconData folder03 = HugeIconData('folder03');
  static const HugeIconData settings01 = HugeIconData('settings01');
  static const HugeIconData user = HugeIconData('user');
  static const HugeIconData check = HugeIconData('check');
  static const HugeIconData plus = HugeIconData('plus');
  static const HugeIconData plusSign = HugeIconData('plus-sign');
  static const HugeIconData search01 = HugeIconData('search01');
  static const HugeIconData computer = HugeIconData('computer');
  static const HugeIconData arrowLeft01 = HugeIconData('arrow-left01');
  static const HugeIconData arrowLeft02 = HugeIconData('arrow-left02');
  static const HugeIconData download01 = HugeIconData('download01');
  static const HugeIconData download04 = HugeIconData('download04');
  static const HugeIconData share08 = HugeIconData('share08');
  static const HugeIconData cancel01 = HugeIconData('cancel01');
  static const HugeIconData moreHorizontal = HugeIconData('more-horizontal');

  // File kinds.
  static const HugeIconData sheet = HugeIconData('sheet');
  static const HugeIconData file01 = HugeIconData('file01');
  static const HugeIconData text = HugeIconData('text');
  static const HugeIconData pdf01 = HugeIconData('pdf01');
  static const HugeIconData sourceCode = HugeIconData('source-code');
  static const HugeIconData braces = HugeIconData('braces');
  static const HugeIconData terminal = HugeIconData('terminal');
  static const HugeIconData database01 = HugeIconData('database01');
  static const HugeIconData zip01 = HugeIconData('zip01');
  static const HugeIconData presentation01 = HugeIconData('presentation01');
  static const HugeIconData image01 = HugeIconData('image01');
  static const HugeIconData video01 = HugeIconData('video01');
  static const HugeIconData bookOpen01 = HugeIconData('book-open01');

  // Screens, people and the rest of the chrome.
  static const HugeIconData laptop = HugeIconData('laptop');
  static const HugeIconData pen01 = HugeIconData('pen01');
  static const HugeIconData share01 = HugeIconData('share01');
  static const HugeIconData key01 = HugeIconData('key01');
  static const HugeIconData info = HugeIconData('info');
  static const HugeIconData informationCircle = HugeIconData(
    'information-circle',
  );
  static const HugeIconData user02 = HugeIconData('user02');
  static const HugeIconData clock01 = HugeIconData('clock01');
  static const HugeIconData notification01 = HugeIconData('notification01');
  static const HugeIconData delete02 = HugeIconData('delete02');
  static const HugeIconData copy01 = HugeIconData('copy01');
  static const HugeIconData refresh = HugeIconData('refresh');
  static const HugeIconData mic01 = HugeIconData('mic01');
  static const HugeIconData sent = HugeIconData('sent');
  static const HugeIconData attachment01 = HugeIconData('attachment01');
  static const HugeIconData puzzle = HugeIconData('puzzle');
  static const HugeIconData robot01 = HugeIconData('robot01');
  static const HugeIconData sparkles = HugeIconData('sparkles');
  static const HugeIconData calendar01 = HugeIconData('calendar01');
}

/// An icon of the set, drawn like a Material [Icon].
class HugeIcon extends StatelessWidget {
  const HugeIcon(this.icon, {super.key, this.size, this.color});

  final HugeIconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    final double resolved = size ?? theme.size ?? 24;
    final Color paint =
        color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      icon.asset,
      width: resolved,
      height: resolved,
      colorFilter: ColorFilter.mode(paint, BlendMode.srcIn),
    );
  }
}
