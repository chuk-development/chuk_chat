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
  static const HugeIconData archive02 = HugeIconData('archive02');
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
  static const HugeIconData inbox = HugeIconData('inbox');
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
  static const HugeIconData mail01 = HugeIconData('mail01');
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
  static const HugeIconData pencilEdit02 = HugeIconData(
    'pencil-edit02',
  );
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
  static const HugeIconData userBlock01 = HugeIconData('user-block01');
  static const HugeIconData userCheck01 = HugeIconData('user-check01');
  static const HugeIconData userGroup = HugeIconData('user-group');
  static const HugeIconData user02 = HugeIconData('user02');
  static const HugeIconData video01 = HugeIconData('video01');
  static const HugeIconData view = HugeIconData('view');
  static const HugeIconData viewOff = HugeIconData('view-off');
  static const HugeIconData wrench01 = HugeIconData('wrench01');
  static const HugeIconData zip01 = HugeIconData('zip01');

  // Added for one icon set on the Agents pages (UI audit 2026-10-05).
  static const HugeIconData callEnd01 = HugeIconData('call-end01');
  static const HugeIconData checkmarkBadge01 = HugeIconData(
    'checkmark-badge01',
  );
  static const HugeIconData clipboardPaste = HugeIconData('clipboard-paste');
  static const HugeIconData cloudOff = HugeIconData('cloud-off');
  static const HugeIconData code = HugeIconData('code');
  static const HugeIconData computerRemove = HugeIconData('computer-remove');
  static const HugeIconData creditCard = HugeIconData('credit-card');
  static const HugeIconData fingerPrint = HugeIconData('finger-print');
  static const HugeIconData id = HugeIconData('id');
  static const HugeIconData mortarboard01 = HugeIconData('mortarboard01');
  static const HugeIconData pauseCircle = HugeIconData('pause-circle');
  static const HugeIconData task01 = HugeIconData('task01');
  static const HugeIconData unlink01 = HugeIconData('unlink01');
  static const HugeIconData userCircle = HugeIconData('user-circle');

  // Added for the OpenUI Icon component (lib/openui/openui_icons.dart).
  static const HugeIconData tickDouble02 = HugeIconData('tick-double02');
  static const HugeIconData cancelCircle = HugeIconData('cancel-circle');
  static const HugeIconData addCircle = HugeIconData('add-circle');
  static const HugeIconData minusSign = HugeIconData('minus-sign');
  static const HugeIconData minusSignCircle = HugeIconData('minus-sign-circle');
  static const HugeIconData helpCircle = HugeIconData('help-circle');
  static const HugeIconData unavailable = HugeIconData('unavailable');
  static const HugeIconData shield01 = HugeIconData('shield01');
  static const HugeIconData securityCheck = HugeIconData('security-check');
  static const HugeIconData shieldAlert = HugeIconData('shield-alert');
  static const HugeIconData squareLock02 = HugeIconData('square-lock02');
  static const HugeIconData squareUnlock02 = HugeIconData('square-unlock02');
  static const HugeIconData slidersHorizontal = HugeIconData(
    'sliders-horizontal',
  );
  static const HugeIconData moreVertical = HugeIconData('more-vertical');
  static const HugeIconData notificationOff01 = HugeIconData(
    'notification-off01',
  );
  static const HugeIconData favourite = HugeIconData('favourite');
  static const HugeIconData thumbsUp = HugeIconData('thumbs-up');
  static const HugeIconData thumbsDown = HugeIconData('thumbs-down');
  static const HugeIconData flag01 = HugeIconData('flag01');
  static const HugeIconData tag01 = HugeIconData('tag01');
  static const HugeIconData award01 = HugeIconData('award01');
  static const HugeIconData champion = HugeIconData('champion');
  static const HugeIconData medal01 = HugeIconData('medal01');
  static const HugeIconData crown = HugeIconData('crown');
  static const HugeIconData fire = HugeIconData('fire');
  static const HugeIconData rocket01 = HugeIconData('rocket01');
  static const HugeIconData target01 = HugeIconData('target01');
  static const HugeIconData idea01 = HugeIconData('idea01');
  static const HugeIconData gift = HugeIconData('gift');
  static const HugeIconData record = HugeIconData('record');
  static const HugeIconData square = HugeIconData('square');
  static const HugeIconData undo02 = HugeIconData('undo02');
  static const HugeIconData redo02 = HugeIconData('redo02');
  static const HugeIconData clipboard = HugeIconData('clipboard');
  static const HugeIconData clipboardList = HugeIconData('clipboard-list');
  static const HugeIconData clipboardCheck = HugeIconData('clipboard-check');
  static const HugeIconData upload01 = HugeIconData('upload01');
  static const HugeIconData login01 = HugeIconData('login01');
  static const HugeIconData power = HugeIconData('power');
  static const HugeIconData checkList = HugeIconData('check-list');
  static const HugeIconData leftToRightListNumber = HugeIconData(
    'left-to-right-list-number',
  );
  static const HugeIconData dashboardSquare01 = HugeIconData(
    'dashboard-square01',
  );
  static const HugeIconData package = HugeIconData('package');
  static const HugeIconData folderOpen = HugeIconData('folder-open');
  static const HugeIconData camera01 = HugeIconData('camera01');
  static const HugeIconData musicNote01 = HugeIconData('music-note01');
  static const HugeIconData headphones = HugeIconData('headphones');
  static const HugeIconData volumeHigh = HugeIconData('volume-high');
  static const HugeIconData volumeMute01 = HugeIconData('volume-mute01');
  static const HugeIconData play = HugeIconData('play');
  static const HugeIconData pause = HugeIconData('pause');
  static const HugeIconData tv01 = HugeIconData('tv01');
  static const HugeIconData book02 = HugeIconData('book02');
  static const HugeIconData news = HugeIconData('news');
  static const HugeIconData paintBrush01 = HugeIconData('paint-brush01');
  static const HugeIconData serverStack01 = HugeIconData('server-stack01');
  static const HugeIconData cpu = HugeIconData('cpu');
  static const HugeIconData hardDrive = HugeIconData('hard-drive');
  static const HugeIconData quoteDown = HugeIconData('quote-down');
  static const HugeIconData hashtag = HugeIconData('hashtag');
  static const HugeIconData at = HugeIconData('at');
  static const HugeIconData userAdd01 = HugeIconData('user-add01');
  static const HugeIconData contact01 = HugeIconData('contact01');
  static const HugeIconData smile = HugeIconData('smile');
  static const HugeIconData sad01 = HugeIconData('sad01');
  static const HugeIconData baby01 = HugeIconData('baby01');
  static const HugeIconData briefcase01 = HugeIconData('briefcase01');
  static const HugeIconData building03 = HugeIconData('building03');
  static const HugeIconData factory = HugeIconData('factory');
  static const HugeIconData store01 = HugeIconData('store01');
  static const HugeIconData school = HugeIconData('school');
  static const HugeIconData hospital01 = HugeIconData('hospital01');
  static const HugeIconData stethoscope = HugeIconData('stethoscope');
  static const HugeIconData cardiogram01 = HugeIconData('cardiogram01');
  static const HugeIconData activity01 = HugeIconData('activity01');
  static const HugeIconData medicine01 = HugeIconData('medicine01');
  static const HugeIconData accessibility = HugeIconData('accessibility');
  static const HugeIconData hold01 = HugeIconData('hold01');
  static const HugeIconData agreement01 = HugeIconData('agreement01');
  static const HugeIconData calendar03 = HugeIconData('calendar03');
  static const HugeIconData calendarCheckIn01 = HugeIconData(
    'calendar-check-in01',
  );
  static const HugeIconData hourglass = HugeIconData('hourglass');
  static const HugeIconData alarmClock = HugeIconData('alarm-clock');
  static const HugeIconData workHistory = HugeIconData('work-history');
  static const HugeIconData smartWatch01 = HugeIconData('smart-watch01');
  static const HugeIconData euro = HugeIconData('euro');
  static const HugeIconData pound = HugeIconData('pound');
  static const HugeIconData bitcoin = HugeIconData('bitcoin');
  static const HugeIconData wallet01 = HugeIconData('wallet01');
  static const HugeIconData money03 = HugeIconData('money03');
  static const HugeIconData coins01 = HugeIconData('coins01');
  static const HugeIconData piggyBank = HugeIconData('piggy-bank');
  static const HugeIconData invoice01 = HugeIconData('invoice01');
  static const HugeIconData percent = HugeIconData('percent');
  static const HugeIconData calculator01 = HugeIconData('calculator01');
  static const HugeIconData bank = HugeIconData('bank');
  static const HugeIconData chartIncrease = HugeIconData('chart-increase');
  static const HugeIconData chartDecrease = HugeIconData('chart-decrease');
  static const HugeIconData chartLineData01 = HugeIconData('chart-line-data01');
  static const HugeIconData chartHistogram = HugeIconData('chart-histogram');
  static const HugeIconData pieChart = HugeIconData('pie-chart');
  static const HugeIconData chartAverage = HugeIconData('chart-average');
  static const HugeIconData dashboardSpeed01 = HugeIconData(
    'dashboard-speed01',
  );
  static const HugeIconData balanceScale = HugeIconData('balance-scale');
  static const HugeIconData shoppingCart01 = HugeIconData('shopping-cart01');
  static const HugeIconData shoppingBag01 = HugeIconData('shopping-bag01');
  static const HugeIconData shoppingBasket01 = HugeIconData(
    'shopping-basket01',
  );
  static const HugeIconData deliveryTruck01 = HugeIconData('delivery-truck01');
  static const HugeIconData ticket01 = HugeIconData('ticket01');
  static const HugeIconData qrCode = HugeIconData('qr-code');
  static const HugeIconData barcode = HugeIconData('barcode');
  static const HugeIconData scan = HugeIconData('scan');
  static const HugeIconData discount = HugeIconData('discount');
  static const HugeIconData maps = HugeIconData('maps');
  static const HugeIconData navigation03 = HugeIconData('navigation03');
  static const HugeIconData compass01 = HugeIconData('compass01');
  static const HugeIconData airplane01 = HugeIconData('airplane01');
  static const HugeIconData airplaneTakeOff01 = HugeIconData(
    'airplane-take-off01',
  );
  static const HugeIconData airplaneLanding01 = HugeIconData(
    'airplane-landing01',
  );
  static const HugeIconData car01 = HugeIconData('car01');
  static const HugeIconData bus01 = HugeIconData('bus01');
  static const HugeIconData train01 = HugeIconData('train01');
  static const HugeIconData bicycle01 = HugeIconData('bicycle01');
  static const HugeIconData boat = HugeIconData('boat');
  static const HugeIconData hotel01 = HugeIconData('hotel01');
  static const HugeIconData bed = HugeIconData('bed');
  static const HugeIconData luggage01 = HugeIconData('luggage01');
  static const HugeIconData mountain = HugeIconData('mountain');
  static const HugeIconData tent = HugeIconData('tent');
  static const HugeIconData route01 = HugeIconData('route01');
  static const HugeIconData fuelStation = HugeIconData('fuel-station');
  static const HugeIconData parkingAreaSquare = HugeIconData(
    'parking-area-square',
  );
  static const HugeIconData restaurant01 = HugeIconData('restaurant01');
  static const HugeIconData coffee01 = HugeIconData('coffee01');
  static const HugeIconData drink = HugeIconData('drink');
  static const HugeIconData pizza01 = HugeIconData('pizza01');
  static const HugeIconData anchor = HugeIconData('anchor');
  static const HugeIconData cloud = HugeIconData('cloud');
  static const HugeIconData cloudAngledRain = HugeIconData('cloud-angled-rain');
  static const HugeIconData cloudLittleRain = HugeIconData('cloud-little-rain');
  static const HugeIconData cloudSnow = HugeIconData('cloud-snow');
  static const HugeIconData cloudAngledZap = HugeIconData('cloud-angled-zap');
  static const HugeIconData sunCloud01 = HugeIconData('sun-cloud01');
  static const HugeIconData cloudFog = HugeIconData('cloud-fog');
  static const HugeIconData fastWind = HugeIconData('fast-wind');
  static const HugeIconData temperature = HugeIconData('temperature');
  static const HugeIconData droplet = HugeIconData('droplet');
  static const HugeIconData umbrella = HugeIconData('umbrella');
  static const HugeIconData snow = HugeIconData('snow');
  static const HugeIconData sunrise = HugeIconData('sunrise');
  static const HugeIconData sunset = HugeIconData('sunset');
  static const HugeIconData rainbow = HugeIconData('rainbow');
  static const HugeIconData tornado01 = HugeIconData('tornado01');
  static const HugeIconData pineTree = HugeIconData('pine-tree');
  static const HugeIconData tree06 = HugeIconData('tree06');
  static const HugeIconData leaf01 = HugeIconData('leaf01');
  static const HugeIconData flower = HugeIconData('flower');
  static const HugeIconData plant01 = HugeIconData('plant01');
  static const HugeIconData cat = HugeIconData('cat');
  static const HugeIconData recycle01 = HugeIconData('recycle01');
  static const HugeIconData wifi01 = HugeIconData('wifi01');
  static const HugeIconData bluetooth = HugeIconData('bluetooth');
  static const HugeIconData smartPhone01 = HugeIconData('smart-phone01');
  static const HugeIconData tablet01 = HugeIconData('tablet01');
  static const HugeIconData printer = HugeIconData('printer');
  static const HugeIconData rss = HugeIconData('rss');
  static const HugeIconData batteryFull = HugeIconData('battery-full');
  static const HugeIconData plug01 = HugeIconData('plug01');
  static const HugeIconData cursor01 = HugeIconData('cursor01');
  static const HugeIconData arrowRight02 = HugeIconData('arrow-right02');
  static const HugeIconData arrowUp02 = HugeIconData('arrow-up02');
  static const HugeIconData arrowDown02 = HugeIconData('arrow-down02');
  static const HugeIconData arrowDownRight01 = HugeIconData(
    'arrow-down-right01',
  );
  static const HugeIconData arrowDataTransferVertical = HugeIconData(
    'arrow-data-transfer-vertical',
  );
  static const HugeIconData arrowDataTransferHorizontal = HugeIconData(
    'arrow-data-transfer-horizontal',
  );
  static const HugeIconData repeat = HugeIconData('repeat');
  static const HugeIconData shuffle = HugeIconData('shuffle');
  static const HugeIconData maximize01 = HugeIconData('maximize01');
  static const HugeIconData minimize01 = HugeIconData('minimize01');
  static const HugeIconData move = HugeIconData('move');
  static const HugeIconData dumbbell01 = HugeIconData('dumbbell01');
  static const HugeIconData gameController01 = HugeIconData(
    'game-controller01',
  );
  static const HugeIconData football = HugeIconData('football');
  static const HugeIconData hammer = HugeIconData('hammer');
  static const HugeIconData scissor01 = HugeIconData('scissor01');
  static const HugeIconData microscope = HugeIconData('microscope');
  static const HugeIconData testTube = HugeIconData('test-tube');
  static const HugeIconData atom01 = HugeIconData('atom01');
  static const HugeIconData ruler = HugeIconData('ruler');
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
