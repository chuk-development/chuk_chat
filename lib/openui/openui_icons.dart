// The OpenUI `Icon` component names (lucide, kebab-case) mapped to the
// app's own icon set (HugeIcons, docs/DESIGN.md section 5).
//
// The model writes lucide names such as 'circle-check' or 'map-pin'.
// The app ships only its HugeIcons subset, so this file maps a name in
// four steps: the table, a normalised name (case, old lucide names,
// number and shape suffixes, shorter prefixes), the topical fallback of
// the category, then a neutral dot. A lookup never fails.
//
// Add a name: put it in [kOpenUiLucideIcons] with the file stem of a
// HugeIcon in assets/icons/hugeicons. When the icon is not in the app
// set yet, add it to WANTED in tool/generate_hugeicons.py first.

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// Lucide name to HugeIcons file stem (`assets/icons/hugeicons/<stem>.svg`).
///
/// Synonyms collapse on purpose: every "edit" is one pencil, every
/// "trash" one bin, as in the app's own icon table.
const Map<String, String> kOpenUiLucideIcons = <String, String>{
  // Status and ui.
  'check': 'tick02',
  'check-check': 'tick-double02',
  'circle-check': 'checkmark-circle02',
  'circle-check-big': 'checkmark-circle02',
  'badge-check': 'checkmark-badge01',
  'x': 'cancel01',
  'circle-x': 'cancel-circle',
  'plus': 'plus-sign',
  'circle-plus': 'add-circle',
  'minus': 'minus-sign',
  'circle-minus': 'minus-sign-circle',
  'info': 'information-circle',
  'circle-alert': 'alert-circle',
  'triangle-alert': 'alert02',
  'octagon-alert': 'alert01',
  'circle-help': 'help-circle',
  'help': 'help-circle',
  'ban': 'unavailable',
  'shield': 'shield01',
  'shield-check': 'security-check',
  'shield-alert': 'shield-alert',
  'lock': 'square-lock02',
  'lock-open': 'square-unlock02',
  'unlock': 'square-unlock02',
  'key': 'key01',
  'eye': 'view',
  'eye-off': 'view-off',
  'search': 'search01',
  'settings': 'settings01',
  'settings-2': 'settings02',
  'sliders-horizontal': 'sliders-horizontal',
  'sliders': 'sliders-horizontal',
  'filter': 'filter',
  'funnel': 'filter',
  'menu': 'menu01',
  'ellipsis': 'more-horizontal',
  'ellipsis-vertical': 'more-vertical',
  'house': 'home01',
  'home': 'home01',
  'bell': 'notification01',
  'bell-off': 'notification-off01',
  'star': 'star',
  'heart': 'favourite',
  'thumbs-up': 'thumbs-up',
  'thumbs-down': 'thumbs-down',
  'bookmark': 'bookmark01',
  'flag': 'flag01',
  'tag': 'tag01',
  'tags': 'tag01',
  'award': 'award01',
  'trophy': 'champion',
  'medal': 'medal01',
  'crown': 'crown',
  'zap': 'flash',
  'sparkles': 'sparkles',
  'sparkle': 'sparkles',
  'flame': 'fire',
  'rocket': 'rocket01',
  'target': 'target01',
  'lightbulb': 'idea01',
  'gift': 'gift',
  'circle': 'circle',
  'circle-dot': 'record',
  'dot': 'record',
  'square': 'square',
  'loader': 'loading03',
  'loader-circle': 'loading03',
  'refresh-cw': 'refresh',
  'rotate-cw': 'refresh',
  'rotate-ccw': 'undo02',
  'undo': 'undo02',
  'redo': 'redo02',
  'trash': 'delete02',
  'trash-2': 'delete02',
  'pencil': 'pencil-edit02',
  'pen': 'pencil-edit02',
  'square-pen': 'pencil-edit02',
  'edit': 'pencil-edit02',
  'copy': 'copy01',
  'clipboard': 'clipboard',
  'clipboard-list': 'clipboard-list',
  'clipboard-check': 'clipboard-check',
  'download': 'download01',
  'upload': 'upload01',
  'share': 'share08',
  'share-2': 'share08',
  'link': 'link01',
  'external-link': 'link-square02',
  'log-out': 'logout01',
  'log-in': 'login01',
  'power': 'power',
  'list': 'list-view',
  'list-checks': 'check-list',
  'list-ordered': 'left-to-right-list-number',
  'list-todo': 'task01',
  'layout-grid': 'grid-view',
  'grid': 'grid-view',
  'layout-dashboard': 'dashboard-square01',
  'layers': 'layers01',
  'layout': 'dashboard-square01',
  'package': 'package',
  'box': 'package',
  'archive': 'archive02',
  'inbox': 'inbox',
  'folder': 'folder01',
  'folder-open': 'folder-open',
  'file': 'file01',
  'file-text': 'file-text',
  'image': 'image01',
  'images': 'album02',
  'video': 'video01',
  'film': 'video01',
  'camera': 'camera01',
  'music': 'music-note01',
  'headphones': 'headphones',
  'mic': 'mic01',
  'volume-2': 'volume-high',
  'volume': 'volume-high',
  'volume-x': 'volume-mute01',
  'play': 'play',
  'pause': 'pause',
  'circle-play': 'play-circle',
  'tv': 'tv01',
  'book': 'book02',
  'book-open': 'book-open01',
  'newspaper': 'news',
  'palette': 'paint-board',
  'brush': 'paint-brush01',
  'code': 'code',
  'terminal': 'terminal',
  'database': 'database01',
  'server': 'server-stack01',
  'cpu': 'cpu',
  'hard-drive': 'hard-drive',
  'puzzle': 'puzzle',
  'bot': 'robot01',
  'brain': 'ai-brain01',
  'type': 'text',
  'quote': 'quote-down',
  'hash': 'hashtag',
  'at-sign': 'at',
  // People.
  'user': 'user',
  'users': 'user-group',
  'user-plus': 'user-add01',
  'user-check': 'user-check01',
  'user-x': 'user-block01',
  'circle-user': 'user-circle',
  'user-round': 'user',
  'contact': 'contact01',
  'smile': 'smile',
  'frown': 'sad01',
  'baby': 'baby01',
  'briefcase': 'briefcase01',
  'building': 'building03',
  'building-2': 'building03',
  'factory': 'factory',
  'store': 'store01',
  'graduation-cap': 'mortarboard01',
  'school': 'school',
  'hospital': 'hospital01',
  'stethoscope': 'stethoscope',
  'heart-pulse': 'cardiogram01',
  'activity': 'activity01',
  'pill': 'medicine01',
  'accessibility': 'accessibility',
  'hand': 'hold01',
  'handshake': 'agreement01',
  // Time.
  'clock': 'clock01',
  'calendar': 'calendar01',
  'calendar-days': 'calendar03',
  'calendar-check': 'calendar-check-in01',
  'calendar-clock': 'calendar01',
  'timer': 'timer01',
  'hourglass': 'hourglass',
  'alarm-clock': 'alarm-clock',
  'history': 'work-history',
  'watch': 'smart-watch01',
  // Finance.
  'dollar-sign': 'dollar01',
  'circle-dollar-sign': 'dollar01',
  'euro': 'euro',
  'pound-sterling': 'pound',
  'bitcoin': 'bitcoin',
  'wallet': 'wallet01',
  'credit-card': 'credit-card',
  'banknote': 'money03',
  'coins': 'coins01',
  'piggy-bank': 'piggy-bank',
  'receipt': 'invoice01',
  'percent': 'percent',
  'calculator': 'calculator01',
  'landmark': 'bank',
  'trending-up': 'chart-increase',
  'trending-down': 'chart-decrease',
  'chart-line': 'chart-line-data01',
  'line-chart': 'chart-line-data01',
  'chart-bar': 'chart-histogram',
  'bar-chart': 'chart-histogram',
  'chart-column': 'chart-histogram',
  'chart-pie': 'pie-chart',
  'pie-chart': 'pie-chart',
  'chart-area': 'chart-average',
  'chart-no-axes-column': 'chart-histogram',
  'gauge': 'dashboard-speed01',
  'scale': 'balance-scale',
  // Commerce.
  'shopping-cart': 'shopping-cart01',
  'shopping-bag': 'shopping-bag01',
  'shopping-basket': 'shopping-basket01',
  'truck': 'delivery-truck01',
  'ticket': 'ticket01',
  'qr-code': 'qr-code',
  'barcode': 'barcode',
  'scan': 'scan',
  'badge-percent': 'discount',
  'store-front': 'store01',
  // Travel and places.
  'map': 'maps',
  'map-pin': 'map-pin',
  'map-pinned': 'map-pin',
  'locate': 'location01',
  'navigation': 'navigation03',
  'compass': 'compass01',
  'globe': 'globe02',
  'earth': 'globe02',
  'plane': 'airplane01',
  'plane-takeoff': 'airplane-take-off01',
  'plane-landing': 'airplane-landing01',
  'car': 'car01',
  'bus': 'bus01',
  'train': 'train01',
  'train-front': 'train01',
  'bike': 'bicycle01',
  'bicycle': 'bicycle01',
  'ship': 'boat',
  'sailboat': 'boat',
  'hotel': 'hotel01',
  'bed': 'bed',
  'bed-double': 'bed',
  'luggage': 'luggage01',
  'mountain': 'mountain',
  'tent': 'tent',
  'route': 'route01',
  'fuel': 'fuel-station',
  'parking': 'parking-area-square',
  'utensils': 'restaurant01',
  'utensils-crossed': 'restaurant01',
  'coffee': 'coffee01',
  'wine': 'drink',
  'beer': 'drink',
  'pizza': 'pizza01',
  'cooking-pot': 'restaurant01',
  'anchor': 'anchor',
  // Weather and nature.
  'sun': 'sun01',
  'moon': 'moon02',
  'cloud': 'cloud',
  'cloud-rain': 'cloud-angled-rain',
  'cloud-drizzle': 'cloud-little-rain',
  'cloud-snow': 'cloud-snow',
  'cloud-lightning': 'cloud-angled-zap',
  'cloud-sun': 'sun-cloud01',
  'cloud-fog': 'cloud-fog',
  'wind': 'fast-wind',
  'thermometer': 'temperature',
  'droplet': 'droplet',
  'droplets': 'droplet',
  'umbrella': 'umbrella',
  'snowflake': 'snow',
  'sunrise': 'sunrise',
  'sunset': 'sunset',
  'rainbow': 'rainbow',
  'tornado': 'tornado01',
  'tree-pine': 'pine-tree',
  'tree': 'tree06',
  'trees': 'tree06',
  'leaf': 'leaf01',
  'flower': 'flower',
  'sprout': 'plant01',
  'cat': 'cat',
  'dog': 'cat',
  'paw-print': 'cat',
  'bug': 'bug01',
  'recycle': 'recycle01',
  // Communication and devices.
  'mail': 'mail01',
  'message-square': 'message01',
  'message-circle': 'comment01',
  'messages-square': 'chatting01',
  'phone': 'call02',
  'send': 'sent',
  'wifi': 'wifi01',
  'bluetooth': 'bluetooth',
  'smartphone': 'smart-phone01',
  'laptop': 'laptop',
  'monitor': 'computer',
  'tablet': 'tablet01',
  'printer': 'printer',
  'rss': 'rss',
  'battery': 'battery-full',
  'plug': 'plug01',
  'mouse-pointer': 'cursor01',
  // Arrows.
  'arrow-right': 'arrow-right02',
  'arrow-left': 'arrow-left02',
  'arrow-up': 'arrow-up02',
  'arrow-down': 'arrow-down02',
  'chevron-right': 'arrow-right01',
  'chevron-left': 'arrow-left01',
  'chevron-up': 'arrow-up01',
  'chevron-down': 'arrow-down01',
  'arrow-up-right': 'arrow-up-right01',
  'arrow-down-right': 'arrow-down-right01',
  'arrow-up-down': 'arrow-data-transfer-vertical',
  'arrow-left-right': 'arrow-data-transfer-horizontal',
  'repeat': 'repeat',
  'shuffle': 'shuffle',
  'maximize': 'maximize01',
  'minimize': 'minimize01',
  'move': 'move',
  // Sports and play.
  'dumbbell': 'dumbbell01',
  'gamepad': 'game-controller01',
  'gamepad-2': 'game-controller01',
  'volleyball': 'football',
  'football': 'football',
  // Tools and science.
  'wrench': 'wrench01',
  'hammer': 'hammer',
  'scissors': 'scissor01',
  'microscope': 'microscope',
  'flask-conical': 'test-tube',
  'atom': 'atom01',
  'ruler': 'ruler',
};

/// Upstream category name to the lucide name of its topical icon. A name
/// that does not resolve falls back to the icon of its category.
const Map<String, String> kOpenUiIconCategories = <String, String>{
  'accessibility': 'accessibility',
  'account': 'user',
  'animals': 'cat',
  'arrows': 'arrow-right',
  'brands': 'box',
  'buildings': 'building',
  'charts': 'chart-line',
  'communication': 'message-square',
  'connectivity': 'wifi',
  'cursors': 'mouse-pointer',
  'design': 'palette',
  'development': 'code',
  'devices': 'smartphone',
  'emoji': 'smile',
  'files': 'file',
  'finance': 'dollar-sign',
  'food-beverage': 'cooking-pot',
  'gaming': 'gamepad',
  'home': 'house',
  'layout': 'layout',
  'mail': 'mail',
  'math': 'calculator',
  'medical': 'heart-pulse',
  'multimedia': 'music',
  'nature': 'tree-pine',
  'navigation': 'map-pin',
  'notifications': 'bell',
  'people': 'users',
  'photography': 'camera',
  'science': 'microscope',
  'seasons': 'sun',
  'security': 'shield',
  'shapes': 'circle',
  'shopping': 'shopping-cart',
  'social': 'share-2',
  'sports': 'trophy',
  'sustainability': 'leaf',
  'text': 'type',
  'time': 'clock',
  'tools': 'wrench',
  'transportation': 'car',
  'travel': 'plane',
  'weather': 'cloud',
};

/// The lucide name drawn when neither the name nor the category resolves.
const String kOpenUiDefaultIcon = 'circle-dot';

/// The shape words lucide writes as a prefix now and wrote as a suffix
/// before (`check-circle` is now `circle-check`).
const Set<String> _shapeWords = <String>{
  'circle',
  'square',
  'triangle',
  'octagon',
  'badge',
};

/// The app icon for the lucide [name], or `null` when no step of the
/// name lookup finds one (the category is not used here).
String? openUiIconStem(String? name) {
  final normal = normaliseOpenUiIconName(name);
  if (normal.isEmpty) return null;
  for (final candidate in _candidates(normal)) {
    final stem = kOpenUiLucideIcons[candidate];
    if (stem != null) return stem;
  }
  return null;
}

/// The app icon for the lucide [name]. When the name does not resolve,
/// the icon of [category], else a neutral dot. Never fails.
HugeIconData openUiIcon(String? name, [String? category]) {
  final stem =
      openUiIconStem(name) ??
      kOpenUiLucideIcons[kOpenUiIconCategories[normaliseOpenUiIconName(
        category,
      )]] ??
      kOpenUiLucideIcons[kOpenUiDefaultIcon]!;
  return HugeIconData(stem);
}

/// [name] in lucide kebab-case: trimmed, lower case, `CircleCheck` and
/// `circle_check` become `circle-check`, a `lucide-` prefix and an
/// `-icon` suffix go away.
String normaliseOpenUiIconName(String? name) {
  if (name == null) return '';
  var n = name.trim();
  if (n.isEmpty) return '';
  n = n
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (m) => '${m.group(1)}-${m.group(2)}',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_.:/]+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9-]'), '')
      .replaceAll(RegExp(r'-+'), '-');
  for (final prefix in const <String>['lucide-', 'icon-', 'lu-']) {
    if (n.startsWith(prefix)) n = n.substring(prefix.length);
  }
  if (n.endsWith('-icon')) n = n.substring(0, n.length - 5);
  return n.replaceAll(RegExp(r'^-+|-+$'), '');
}

/// The names to try for [n], best first.
Iterable<String> _candidates(String n) sync* {
  yield n;
  final parts = n.split('-').where((p) => p.isNotEmpty).toList();
  // Drop number segments: share-2, bar-chart-3, calendar-1.
  final noNumbers = parts.where((p) => int.tryParse(p) == null).toList();
  // Old lucide names: check-circle -> circle-check.
  final variants = <List<String>>[noNumbers];
  if (noNumbers.length > 1 && _shapeWords.contains(noNumbers.last)) {
    variants.add(<String>[
      noNumbers.last,
      ...noNumbers.sublist(0, noNumbers.length - 1),
    ]);
    variants.add(noNumbers.sublist(0, noNumbers.length - 1));
  }
  if (noNumbers.length > 1 && _shapeWords.contains(noNumbers.first)) {
    variants.add(noNumbers.sublist(1));
  }
  // Each whole variant first.
  for (final v in variants) {
    if (v.isNotEmpty) yield v.join('-');
  }
  // The first and the last word: arrow-big-right -> arrow-right.
  for (final v in variants) {
    if (v.length > 2) yield '${v.first}-${v.last}';
  }
  // Then ever shorter prefixes: map-pin-check -> map-pin,
  // calendar-clock -> calendar.
  for (final v in variants) {
    for (var end = v.length - 1; end > 0; end--) {
      yield v.sublist(0, end).join('-');
    }
  }
}

/// The size and colour an [OpenUiIcon] takes when its caller does not
/// set them. A tag or an icon badge puts one above its `Icon` child.
class OpenUiIconStyle extends InheritedWidget {
  /// Sets [size] and [color] for the [OpenUiIcon]s below.
  const OpenUiIconStyle({
    required super.child,
    this.size,
    this.color,
    super.key,
  });

  /// The icon box size in logical pixels.
  final double? size;

  /// The icon colour.
  final Color? color;

  /// The nearest style, or `null`.
  static OpenUiIconStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OpenUiIconStyle>();

  @override
  bool updateShouldNotify(OpenUiIconStyle oldWidget) =>
      size != oldWidget.size || color != oldWidget.color;
}

/// An OpenUI icon: a lucide [name] drawn as the matching app icon.
class OpenUiIcon extends StatelessWidget {
  /// Draws the app icon for [name], with the [category] fallback.
  const OpenUiIcon(
    this.name, {
    this.category,
    this.size,
    this.color,
    this.semanticLabel,
    super.key,
  });

  /// The lucide name, for example `circle-check`.
  final String name;

  /// The upstream category of the topical fallback, for example `travel`.
  final String? category;

  /// The size. Default: the [OpenUiIconStyle] above, else an
  /// [IconTheme] that a parent set (a button), else 18.
  final double? size;

  /// The colour. Default: the [OpenUiIconStyle] above, else an
  /// [IconTheme] that a parent set (a button), else the text colour.
  final Color? color;

  /// The text a screen reader reads. Default: none (decorative).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final style = OpenUiIconStyle.maybeOf(context);
    final local = _localIconTheme(context);
    final icon = HugeIcon(
      openUiIcon(name, category),
      size: size ?? style?.size ?? local?.size ?? 18,
      color:
          color ??
          style?.color ??
          local?.color ??
          Theme.of(context).colorScheme.onSurface,
    );
    final label = semanticLabel;
    if (label == null || label.isEmpty) return ExcludeSemantics(child: icon);
    return Semantics(
      label: label,
      child: ExcludeSemantics(child: icon),
    );
  }
}

/// The [IconTheme] a parent set on purpose (`IconTheme.merge` in a
/// button), or `null` when the nearest one is the app theme's own.
/// `OpenUiView` puts the app's icon theme back at its root, so an icon
/// theme from the chat around a program does not leak in.
IconThemeData? _localIconTheme(BuildContext context) {
  final data = context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data;
  if (data == null || data == Theme.of(context).iconTheme) return null;
  return data;
}
