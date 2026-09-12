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
/// How much of its box an icon's drawing takes.
///
/// A Material glyph carries about a tenth of its box as padding; these SVGs
/// draw to the edge of a 24 px viewBox. Without the inset every icon reads
/// heavier than the ones it replaced and crowds its container.
const double _opticalInset = 0.86;

abstract final class HugeIcons {
  // Generated names for every asset in assets/icons/hugeicons.
  // Add an icon by naming it in tool/generate_hugeicons.py and running it.

  static const HugeIconData add01 = HugeIconData('add01');
  static const HugeIconData aiBrain01 = HugeIconData('ai-brain01');
  static const HugeIconData album01 = HugeIconData('album01');
  static const HugeIconData album02 = HugeIconData('album02');
  static const HugeIconData alertCircle = HugeIconData('alert-circle');
  static const HugeIconData alert01 = HugeIconData('alert01');
  static const HugeIconData alert02 = HugeIconData('alert02');
  static const HugeIconData arrowDown01 = HugeIconData('arrow-down01');
  static const HugeIconData arrowLeft01 = HugeIconData('arrow-left01');
  static const HugeIconData arrowLeft02 = HugeIconData('arrow-left02');
  static const HugeIconData arrowRight01 = HugeIconData('arrow-right01');
  static const HugeIconData arrowUpRight01 = HugeIconData('arrow-up-right01');
  static const HugeIconData arrowUp01 = HugeIconData('arrow-up01');
  static const HugeIconData attachment01 = HugeIconData('attachment01');
  static const HugeIconData blockchain01 = HugeIconData('blockchain01');
  static const HugeIconData bookOpen01 = HugeIconData('book-open01');
  static const HugeIconData bookmark01 = HugeIconData('bookmark01');
  static const HugeIconData braces = HugeIconData('braces');
  static const HugeIconData bug01 = HugeIconData('bug01');
  static const HugeIconData calendar01 = HugeIconData('calendar01');
  static const HugeIconData call02 = HugeIconData('call02');
  static const HugeIconData cancel01 = HugeIconData('cancel01');
  static const HugeIconData cancel02 = HugeIconData('cancel02');
  static const HugeIconData chatting01 = HugeIconData('chatting01');
  static const HugeIconData check = HugeIconData('check');
  static const HugeIconData checkmarkCircle01 = HugeIconData(
    'checkmark-circle01',
  );
  static const HugeIconData checkmarkCircle02 = HugeIconData(
    'checkmark-circle02',
  );
  static const HugeIconData circle = HugeIconData('circle');
  static const HugeIconData clock01 = HugeIconData('clock01');
  static const HugeIconData comment01 = HugeIconData('comment01');
  static const HugeIconData computer = HugeIconData('computer');
  static const HugeIconData copy01 = HugeIconData('copy01');
  static const HugeIconData database01 = HugeIconData('database01');
  static const HugeIconData delete02 = HugeIconData('delete02');
  static const HugeIconData dollar01 = HugeIconData('dollar01');
  static const HugeIconData download01 = HugeIconData('download01');
  static const HugeIconData download04 = HugeIconData('download04');
  static const HugeIconData edit02 = HugeIconData('edit02');
  static const HugeIconData fileCode = HugeIconData('file-code');
  static const HugeIconData fileEdit = HugeIconData('file-edit');
  static const HugeIconData fileScript = HugeIconData('file-script');
  static const HugeIconData fileSpreadsheet = HugeIconData('file-spreadsheet');
  static const HugeIconData fileText = HugeIconData('file-text');
  static const HugeIconData file01 = HugeIconData('file01');
  static const HugeIconData file02 = HugeIconData('file02');
  static const HugeIconData filter = HugeIconData('filter');
  static const HugeIconData flash = HugeIconData('flash');
  static const HugeIconData folder01 = HugeIconData('folder01');
  static const HugeIconData folder03 = HugeIconData('folder03');
  static const HugeIconData globe02 = HugeIconData('globe02');
  static const HugeIconData gridView = HugeIconData('grid-view');
  static const HugeIconData home01 = HugeIconData('home01');
  static const HugeIconData imageNotFound01 = HugeIconData('image-not-found01');
  static const HugeIconData image01 = HugeIconData('image01');
  static const HugeIconData info = HugeIconData('info');
  static const HugeIconData informationCircle = HugeIconData(
    'information-circle',
  );
  static const HugeIconData key01 = HugeIconData('key01');
  static const HugeIconData laptop = HugeIconData('laptop');
  static const HugeIconData layers01 = HugeIconData('layers01');
  static const HugeIconData linkSquare02 = HugeIconData('link-square02');
  static const HugeIconData link01 = HugeIconData('link01');
  static const HugeIconData listView = HugeIconData('list-view');
  static const HugeIconData loading03 = HugeIconData('loading03');
  static const HugeIconData location01 = HugeIconData('location01');
  static const HugeIconData logout01 = HugeIconData('logout01');
  static const HugeIconData mapPin = HugeIconData('map-pin');
  static const HugeIconData menu01 = HugeIconData('menu01');
  static const HugeIconData message01 = HugeIconData('message01');
  static const HugeIconData mic01 = HugeIconData('mic01');
  static const HugeIconData mic02 = HugeIconData('mic02');
  static const HugeIconData moon02 = HugeIconData('moon02');
  static const HugeIconData moreHorizontal = HugeIconData('more-horizontal');
  static const HugeIconData note01 = HugeIconData('note01');
  static const HugeIconData notification01 = HugeIconData('notification01');
  static const HugeIconData paintBoard = HugeIconData('paint-board');
  static const HugeIconData pdf01 = HugeIconData('pdf01');
  static const HugeIconData pen01 = HugeIconData('pen01');
  static const HugeIconData playCircle = HugeIconData('play-circle');
  static const HugeIconData plus = HugeIconData('plus');
  static const HugeIconData plusSign = HugeIconData('plus-sign');
  static const HugeIconData presentation01 = HugeIconData('presentation01');
  static const HugeIconData puzzle = HugeIconData('puzzle');
  static const HugeIconData refresh = HugeIconData('refresh');
  static const HugeIconData remove01 = HugeIconData('remove01');
  static const HugeIconData robot01 = HugeIconData('robot01');
  static const HugeIconData search01 = HugeIconData('search01');
  static const HugeIconData sendHorizontal = HugeIconData('send-horizontal');
  static const HugeIconData sent = HugeIconData('sent');
  static const HugeIconData settings01 = HugeIconData('settings01');
  static const HugeIconData settings02 = HugeIconData('settings02');
  static const HugeIconData share01 = HugeIconData('share01');
  static const HugeIconData share08 = HugeIconData('share08');
  static const HugeIconData sheet = HugeIconData('sheet');
  static const HugeIconData sorting01 = HugeIconData('sorting01');
  static const HugeIconData sourceCode = HugeIconData('source-code');
  static const HugeIconData sparkles = HugeIconData('sparkles');
  static const HugeIconData star = HugeIconData('star');
  static const HugeIconData stop = HugeIconData('stop');
  static const HugeIconData stopCircle = HugeIconData('stop-circle');
  static const HugeIconData sun01 = HugeIconData('sun01');
  static const HugeIconData terminal = HugeIconData('terminal');
  static const HugeIconData text = HugeIconData('text');
  static const HugeIconData tick02 = HugeIconData('tick02');
  static const HugeIconData timer01 = HugeIconData('timer01');
  static const HugeIconData user = HugeIconData('user');
  static const HugeIconData userGroup = HugeIconData('user-group');
  static const HugeIconData user02 = HugeIconData('user02');
  static const HugeIconData video01 = HugeIconData('video01');
  static const HugeIconData view = HugeIconData('view');
  static const HugeIconData viewOff = HugeIconData('view-off');
  static const HugeIconData wrench01 = HugeIconData('wrench01');
  static const HugeIconData zip01 = HugeIconData('zip01');
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
    // The box is the size, and the drawing sits centred inside it, smaller by
    // [_opticalInset]. Two reasons for the inner box:
    //
    // 1. A Material glyph keeps about a tenth of its em box empty on every
    //    side; these SVGs draw to the edge of a 24 px viewBox. Drawn at the
    //    same nominal size they read much heavier and crowd their container.
    // 2. A parent with tight constraints — the 42 px tile in the settings
    //    rows, for one — forces a plain SizedBox to the parent's size, and
    //    BoxFit.contain then blew the drawing up to fill the whole tile. The
    //    inner box takes its size from what the caller asked for, so the
    //    drawing keeps that size whatever the parent does.
    //
    // Passing width and height to SvgPicture alone left the raw picture
    // reporting the asset's own 24 px, which is how an 18 px icon ended up
    // three pixels past a reading column.
    final double drawn = resolved * _opticalInset;
    return SizedBox(
      width: resolved,
      height: resolved,
      child: Center(
        child: SizedBox(
          width: drawn,
          height: drawn,
          child: SvgPicture.asset(
            icon.asset,
            width: drawn,
            height: drawn,
            fit: BoxFit.contain,
            colorFilter: ColorFilter.mode(paint, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }
}
