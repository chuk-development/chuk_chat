// lib/widgets/visual_answer_blocks.dart
//
// Part of markdown_message.dart: the visual answer modules — `::: bars`,
// `::: kpi`, `::: tiles`, `::: cards` and `::: ask`. The parse
// half lives in `lib/utils/answer_blocks_parser.dart`; the look follows the
// KI-Chat building-block design (soft accent-tinted module cards, flat fills,
// hairlines — no glow and no coloured shadow, docs/DESIGN.md §8). Like the
// static blocks in answer_blocks.dart, everything derives its colours from the
// surrounding message, so the modules read correctly in either theme.

part of 'markdown_message.dart';

// ---------------------------------------------------------------------------
// shared pieces

/// Icon aliases a model may write in a block (`| droplet`, `| wind`, ...).
/// One alias per idea; anything unmapped renders without an icon rather than
/// with a wrong one.
const Map<String, HugeIconData> _kBlockIcons = <String, HugeIconData>{
  'droplet': HugeIcons.droplet,
  'water': HugeIcons.droplet,
  'tropfen': HugeIcons.droplet,
  'wind': HugeIcons.fastWind,
  'temperature': HugeIcons.temperature,
  'temp': HugeIcons.temperature,
  'thermometer': HugeIcons.temperature,
  'sun': HugeIcons.sun01,
  'sonne': HugeIcons.sun01,
  'cloud': HugeIcons.cloud,
  'wolke': HugeIcons.cloud,
  'rain': HugeIcons.cloudLittleRain,
  'regen': HugeIcons.cloudLittleRain,
  'shower': HugeIcons.cloudAngledRain,
  'snow': HugeIcons.snow,
  'schnee': HugeIcons.snow,
  'storm': HugeIcons.cloudAngledZap,
  'gewitter': HugeIcons.cloudAngledZap,
  'partly': HugeIcons.sunCloud01,
  'fog': HugeIcons.cloudFog,
  'nebel': HugeIcons.cloudFog,
  'moon': HugeIcons.moon02,
  'mond': HugeIcons.moon02,
  'umbrella': HugeIcons.umbrella,
  'star': HugeIcons.star,
  'stern': HugeIcons.star,
  'heart': HugeIcons.favourite,
  'users': HugeIcons.userGroup,
  'user': HugeIcons.user02,
  'clock': HugeIcons.clock01,
  'uhr': HugeIcons.clock01,
  'time': HugeIcons.clock01,
  'calendar': HugeIcons.calendar01,
  'kalender': HugeIcons.calendar01,
  'battery': HugeIcons.batteryFull,
  'akku': HugeIcons.batteryFull,
  'cpu': HugeIcons.cpu,
  'chip': HugeIcons.cpu,
  'speed': HugeIcons.dashboardSpeed01,
  'gauge': HugeIcons.dashboardSpeed01,
  'euro': HugeIcons.euro,
  'dollar': HugeIcons.dollar01,
  'percent': HugeIcons.percent,
  'prozent': HugeIcons.percent,
  'download': HugeIcons.download01,
  'upload': HugeIcons.upload01,
  'shield': HugeIcons.shield01,
  'sicherheit': HugeIcons.shield01,
  'lock': HugeIcons.squareLock02,
  'check': HugeIcons.tick02,
  'fire': HugeIcons.fire,
  'feuer': HugeIcons.fire,
  'leaf': HugeIcons.leaf01,
  'mountain': HugeIcons.mountain,
  'berg': HugeIcons.mountain,
  'hotel': HugeIcons.hotel01,
  'bed': HugeIcons.bed,
  'cart': HugeIcons.shoppingCart01,
  'bag': HugeIcons.shoppingBag01,
  'truck': HugeIcons.deliveryTruck01,
  'plane': HugeIcons.airplane01,
  'flug': HugeIcons.airplane01,
  'train': HugeIcons.train01,
  'zug': HugeIcons.train01,
  'car': HugeIcons.car01,
  'auto': HugeIcons.car01,
  'bus': HugeIcons.bus01,
  'bike': HugeIcons.bicycle01,
  'boat': HugeIcons.boat,
  'wifi': HugeIcons.wifi01,
  'eye': HugeIcons.view,
  'pin': HugeIcons.mapPin,
  'ort': HugeIcons.mapPin,
  'location': HugeIcons.mapPin,
  'navigation': HugeIcons.navigation03,
  'compass': HugeIcons.compass01,
  'route': HugeIcons.route01,
  'flash': HugeIcons.flash,
  'bolt': HugeIcons.flash,
  'chart': HugeIcons.chartIncrease,
  'chart-up': HugeIcons.chartIncrease,
  'chart-down': HugeIcons.chartDecrease,
  'trend': HugeIcons.chartLineData01,
  'activity': HugeIcons.activity01,
  'pulse': HugeIcons.activity01,
  'timer': HugeIcons.timer01,
  'hourglass': HugeIcons.hourglass,
  'book': HugeIcons.bookOpen01,
  'buch': HugeIcons.bookOpen01,
  'school': HugeIcons.school,
  'work': HugeIcons.briefcase01,
  'home': HugeIcons.home01,
  'building': HugeIcons.building03,
  'hospital': HugeIcons.hospital01,
  'store': HugeIcons.store01,
  'coffee': HugeIcons.coffee01,
  'food': HugeIcons.restaurant01,
  'essen': HugeIcons.restaurant01,
  'pizza': HugeIcons.pizza01,
  'sunrise': HugeIcons.sunrise,
  'sunset': HugeIcons.sunset,
  'rocket': HugeIcons.rocket01,
  'target': HugeIcons.target01,
  'medal': HugeIcons.medal01,
  'crown': HugeIcons.crown,
  'gift': HugeIcons.gift,
  'wallet': HugeIcons.wallet01,
  'coins': HugeIcons.coins01,
  'piggy': HugeIcons.piggyBank,
  'card': HugeIcons.creditCard,
  'calculator': HugeIcons.calculator01,
  'ticket': HugeIcons.ticket01,
  'luggage': HugeIcons.luggage01,
  'tent': HugeIcons.tent,
  'fuel': HugeIcons.fuelStation,
  'parking': HugeIcons.parkingAreaSquare,
  'phone': HugeIcons.smartPhone01,
  'laptop': HugeIcons.laptop,
  'tv': HugeIcons.tv01,
  'camera': HugeIcons.camera01,
  'music': HugeIcons.musicNote01,
  'headphones': HugeIcons.headphones,
  'game': HugeIcons.gameController01,
  'fitness': HugeIcons.dumbbell01,
  'ball': HugeIcons.football,
  'tool': HugeIcons.wrench01,
  'bug': HugeIcons.bug01,
  'code': HugeIcons.sourceCode,
  'terminal': HugeIcons.terminal,
  'database': HugeIcons.database01,
  'server': HugeIcons.serverStack01,
  'rss': HugeIcons.rss,
  'news': HugeIcons.news,
  'art': HugeIcons.paintBrush01,
  'file': HugeIcons.fileText,
  'note': HugeIcons.note01,
  'key': HugeIcons.key01,
  'fingerprint': HugeIcons.fingerPrint,
  'brain': HugeIcons.aiBrain01,
  'ai': HugeIcons.aiBrain01,
  'ki': HugeIcons.aiBrain01,
  'sparkles': HugeIcons.sparkles,
  'robot': HugeIcons.robot01,
  'chat': HugeIcons.chatting01,
  'message': HugeIcons.message01,
  'mail': HugeIcons.mail01,
  'search': HugeIcons.search01,
  'suche': HugeIcons.search01,
  'filter': HugeIcons.filter,
  'layers': HugeIcons.layers01,
  'puzzle': HugeIcons.puzzle,
  'package': HugeIcons.package,
  'recycle': HugeIcons.recycle01,
  'plant': HugeIcons.plant01,
  'tree': HugeIcons.tree06,
  'flower': HugeIcons.flower,
  'cat': HugeIcons.cat,
  'baby': HugeIcons.baby01,
  'smile': HugeIcons.smile,
  'quote': HugeIcons.quoteDown,
  'idea': HugeIcons.idea01,
  'idea01': HugeIcons.idea01,
  'sound': HugeIcons.volumeHigh,
  'anc': HugeIcons.volumeMute01,
  'quiet': HugeIcons.volumeMute01,
  'mic': HugeIcons.mic01,
  'microphone': HugeIcons.mic01,
  'computer': HugeIcons.computer,
  'monitor': HugeIcons.computer,
  'wellness': HugeIcons.sparkles,
  'spa': HugeIcons.sparkles,
  'hike': HugeIcons.mountain,
  'wandern': HugeIcons.mountain,
  'bank': HugeIcons.bank,
  'help': HugeIcons.helpCircle,
  'info': HugeIcons.informationCircle,
  'warning': HugeIcons.alert02,
  'link': HugeIcons.link01,
  'flag': HugeIcons.flag01,
  'smoke': HugeIcons.cloudFog,
  'ruler': HugeIcons.ruler,
  'scale': HugeIcons.balanceScale,
  'tag': HugeIcons.tag01,
  'discount': HugeIcons.discount,
  'list': HugeIcons.checkList,
  'globe': HugeIcons.globe02,
  'video': HugeIcons.video01,
  'image': HugeIcons.image01,
};

HugeIconData? _blockIcon(String name) {
  final String key = name.trim().toLowerCase();
  if (key.isEmpty) return null;
  return _kBlockIcons[key] ?? _kBlockIcons[key.replaceAll('_', '-')];
}

/// The soft module card every visual block sits in.
class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.s, required this.child, this.padding});

  final _AnswerBlockStyle s;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: s.cardFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

/// The small label chip above a module title (`tag: …`).
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.s});

  final String tag;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: s.tileFill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: s.accent,
            fontSize: s.baseFontSize * 0.84,
            fontWeight: FontWeight.w700,
            height: 1.25,
            fontFamily: s.fontFamily,
          ),
        ),
      ),
    );
  }
}

/// Title + optional tag, the shared head of a module card.
Widget _moduleHead(String tag, String title, _AnswerBlockStyle s) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (tag.isNotEmpty) ...<Widget>[_TagChip(tag: tag, s: s), const SizedBox(height: 10)],
      if (title.isNotEmpty)
        s.markdown(
          title,
          fontSize: s.baseFontSize * 1.32,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
    ],
  );
}

/// Opens an https(s) URL from a block, behind the same confirmation the
/// Markdown link tap uses (markdown_message `_onTapLink`): the reader sees
/// the destination before anything leaves the app. Anything but http(s) is
/// dropped, mirroring the bubble's own card handling (message_bubble/cards.dart).
Future<void> _openBlockUrl(BuildContext context, String url) async {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return;
  if (!const <String>{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    return;
  }
  final bool? shouldOpen = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Open Link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Do you really want to leave the app and open:'),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(url),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (shouldOpen == true && await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Whether a card may load an image from [url] at all. HTTPS only, and hosts
/// that name the local machine or a private network are refused — including
/// CGNAT (100.64/10) and digit-only hosts (`https://2130706433/`): the model
/// must not be able to make the app knock on loopback or LAN addresses just
/// by rendering an answer. A name that resolves to a private address is
/// caught by the fetch tools' public-only client, not here; this static
/// filter is the cheap first gate.
bool _isPublicImageUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.scheme.toLowerCase().startsWith('https')) return false;
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
    return false;
  }
  // An IPv6 literal (Uri.host keeps the colons, brackets gone) or anything
  // else with a colon in the host is never a public image host; the
  // connect-time check in the loader is the second gate either way.
  if (host.contains(':')) return false;
  if (!host.contains('.') && RegExp(r'^\d+$').hasMatch(host)) return false;
  final RegExp ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  final RegExpMatch? m = ipv4.firstMatch(host);
  if (m != null) {
    final List<int> octets = m.groups(const <int>[1, 2, 3, 4])
        .map((String? g) => int.parse(g!))
        .toList(growable: false);
    if (octets.any((int o) => o > 255)) return false;
    final int a = octets[0];
    final int b = octets[1];
    if (a == 127 || a == 10 || a == 0) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a >= 224) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// bars — labelled horizontal bar comparison

class _BarsBlock extends StatelessWidget {
  const _BarsBlock({required this.spec, required this.s});

  final BarsSpec spec;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    if (spec.rows.isEmpty) {
      return spec.note.isEmpty
          ? const SizedBox.shrink()
          : _ModuleCard(s: s, child: _notePill());
    }
    double max = 0;
    for (final BarRow row in spec.rows) {
      final double? v = row.value;
      if (v != null && v > max) max = v;
    }

    final List<Widget> children = <Widget>[
      if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _moduleHead(spec.tag, spec.title, s),
        ),
      for (int i = 0; i < spec.rows.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: 14),
        _row(spec.rows[i], max),
      ],
      if (spec.note.isNotEmpty) ...<Widget>[const SizedBox(height: 12), _notePill()],
    ];

    return _ModuleCard(
      s: s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _row(BarRow row, double max) {
    // A row without a parseable number gets no comparison bar at all — an
    // "N/A" must not read as "as big as the largest". Zero gets a zero bar.
    final bool hasValue = row.value != null;
    double fraction = 0;
    if (hasValue && max > 0) {
      fraction = row.value! <= 0 ? 0.0 : (row.value! / max).clamp(0.04, 1.0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: s.markdown(row.label, fontWeight: FontWeight.w600),
            ),
            if (row.valueText.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              SelectionContainer.disabled(
                child: Text(
                  row.valueText,
                  maxLines: 1,
                  style: TextStyle(
                    color: s.accent,
                    fontSize: s.baseFontSize * 0.95,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    fontFamily: s.fontFamily,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (hasValue)
          SelectionContainer.disabled(
            child: Container(
              height: 9,
              decoration: BoxDecoration(
                color: s.tileFill,
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  decoration: BoxDecoration(
                    color: s.accent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
          ),
        if (row.sub.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            row.sub,
            style: TextStyle(
              color: s.muted,
              fontSize: s.baseFontSize * 0.88,
              height: 1.35,
              fontFamily: s.fontFamily,
            ),
          ),
        ],
      ],
    );
  }

  Widget _notePill() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: s.tileFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: s.markdown(spec.note, fontSize: s.baseFontSize * 0.94),
    );
  }
}

// ---------------------------------------------------------------------------
// kpi — stat tiles

class _KpiBlock extends StatelessWidget {
  const _KpiBlock({required this.spec, required this.s});

  final KpiSpec spec;
  final _AnswerBlockStyle s;

  @override
  Widget build(BuildContext context) {
    if (spec.tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        const double gap = 10;
        // The LayoutBuilder wraps the module card, whose padding takes 28 of
        // the width — the tiles must fit inside it.
        final double tileWidth =
            ((c.maxWidth - 28 - gap) / 2).clamp(90.0, 260.0);
        final List<Widget> children = <Widget>[
          if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _moduleHead(spec.tag, spec.title, s),
            ),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final KpiTile tile in spec.tiles)
                SizedBox(width: tileWidth, child: _tile(tile)),
            ],
          ),
        ];
        return _ModuleCard(
          s: s,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      },
    );
  }

  Widget _tile(KpiTile tile) {
    final HugeIconData? icon = _blockIcon(tile.icon);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: s.tileFill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            SelectionContainer.disabled(
              child: HugeIcon(icon, size: 21, color: s.accent),
            ),
            const SizedBox(height: 9),
          ],
          SelectionContainer.disabled(
            child: Text(
              tile.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: s.textColor,
                fontSize: s.baseFontSize * 1.42,
                fontWeight: FontWeight.w800,
                height: 1.15,
                fontFamily: s.fontFamily,
              ),
            ),
          ),
          if (tile.label.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              tile.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: s.muted,
                fontSize: s.baseFontSize * 0.9,
                height: 1.3,
                fontFamily: s.fontFamily,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// tiles — icon tiles

class _TilesBlock extends StatelessWidget {
  const _TilesBlock({required this.spec, required this.s});

  final TilesSpec spec;
  final _AnswerBlockStyle s;

  /// A grid cell narrower than this cannot hold a label beside nothing but
  /// its icon; the block then lays its tiles out as rows.
  static const double _minGridCell = 96;

  /// Labels longer than this are not tile labels but sentences.
  static const int _maxGridLabel = 18;

  @override
  Widget build(BuildContext context) {
    if (spec.tiles.isEmpty) return const SizedBox.shrink();
    final List<_TileView> tiles = spec.tiles.map(_TileView.from).toList();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        const double gap = 10;
        // Inside the module card: its padding takes 28 of the width.
        final double inner = c.maxWidth - 28;
        final int perRow = tiles.length == 1
            ? 1
            : (tiles.length == 2 || tiles.length == 4 ? 2 : 3);
        final double cell = (inner - gap * (perRow - 1)) / perRow;
        // Centred icon tiles only work for short labels. Anything with a
        // subline or a long label reads as a list, so it is drawn as one:
        // icon left, text beside it, every row on the same left edge.
        // Large text needs the same room a longer label does.
        final double scale = MediaQuery.textScalerOf(context).scale(1);
        final bool asRows =
            cell < _minGridCell * scale ||
            tiles.any(
              (_TileView t) =>
                  t.sub.isNotEmpty || t.label.length * scale > _maxGridLabel,
            );
        return _ModuleCard(
          s: s,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (spec.tag.isNotEmpty || spec.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _moduleHead(spec.tag, spec.title, s),
                ),
              if (asRows)
                for (int i = 0; i < tiles.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 12),
                  _row(tiles[i]),
                ]
              else
                for (int r = 0; r < tiles.length; r += perRow) ...<Widget>[
                  if (r > 0) const SizedBox(height: gap),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (int i = r; i < r + perRow; i++) ...<Widget>[
                        if (i > r) const SizedBox(width: gap),
                        Expanded(
                          child: i < tiles.length
                              ? _cell(tiles[i])
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ],
            ],
          ),
        );
      },
    );
  }

  Widget _iconChip(HugeIconData icon, double size) {
    return SelectionContainer.disabled(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.tileFill,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: HugeIcon(icon, size: size * 0.46, color: s.accent),
      ),
    );
  }

  TextStyle get _labelStyle => TextStyle(
    color: s.textColor,
    fontSize: s.baseFontSize * 0.95,
    fontWeight: FontWeight.w600,
    height: 1.3,
    fontFamily: s.fontFamily,
  );

  TextStyle get _subStyle => TextStyle(
    color: s.muted,
    fontSize: s.baseFontSize * 0.87,
    height: 1.35,
    fontFamily: s.fontFamily,
  );

  /// One tile as a list row: icon chip, then label over subline.
  Widget _row(_TileView tile) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (tile.icon != null) ...<Widget>[
          _iconChip(tile.icon!, 40),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Padding(
            // Centre a one-line label on the 40 px chip.
            padding: EdgeInsets.only(top: tile.icon != null ? 2 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(tile.label, style: _labelStyle),
                if (tile.sub.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(tile.sub, style: _subStyle),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One tile as a grid cell: icon chip over a short centred label.
  Widget _cell(_TileView tile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (tile.icon != null) ...<Widget>[
          _iconChip(tile.icon!, 52),
          const SizedBox(height: 8),
        ],
        Text(
          tile.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _labelStyle,
        ),
      ],
    );
  }
}

/// A tile as it is drawn. The model sometimes writes the subline where the
/// icon name belongs (`Name | long text | shield`); a slot that is not a known
/// icon but reads like text is moved back into the subline.
class _TileView {
  const _TileView(this.label, this.icon, this.sub);

  factory _TileView.from(IconTile t) {
    HugeIconData? icon = _blockIcon(t.icon);
    final List<String> sub = <String>[];
    if (icon == null && t.icon.contains(' ')) {
      sub.add(t.icon);
    }
    if (t.sub.isNotEmpty) {
      // `long text · shield`: the trailing word may be the icon.
      final List<String> parts = t.sub.split(' · ');
      final HugeIconData? tail = icon == null ? _blockIcon(parts.last) : null;
      if (tail != null) {
        icon = tail;
        parts.removeLast();
      }
      sub.addAll(parts.where((String p) => p.isNotEmpty));
    }
    return _TileView(t.label, icon, sub.join(' · '));
  }

  final String label;
  final HugeIconData? icon;
  final String sub;
}

// ---------------------------------------------------------------------------
// cards — carousel of item cards

class _CardsBlock extends StatefulWidget {
  const _CardsBlock({required this.spec, required this.s, this.onFollowUp});

  final CardsSpec spec;
  final _AnswerBlockStyle s;

  /// Sends a card's `ask:` button as the reader's next message.
  final ValueChanged<String>? onFollowUp;

  @override
  State<_CardsBlock> createState() => _CardsBlockState();
}

class _CardsBlockState extends State<_CardsBlock> {
  PageController? _controller;
  double _controllerWidth = 0;
  int _page = 0;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<AnswerCard> cards = widget.spec.cards;
    if (cards.isEmpty) return const SizedBox.shrink();
    _inheritedFamily = DefaultTextStyle.of(context).style.fontFamily;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth;
        // Never wider than the column itself: below 233 px the 200 px floor
        // would make the card wider than its page and the content overflow.
        final double cardWidth =
            (w * 0.86).clamp(200.0, 340.0).toDouble().clamp(0.0, w).toDouble();
        if (_controller == null || (w - _controllerWidth).abs() > 24) {
          // The previous frame's PageView still holds this controller; the
          // detach happens after it is replaced, so dispose only then.
          final PageController? old = _controller;
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
          _page = _page.clamp(0, cards.length - 1);
          _controller = PageController(
            initialPage: _page,
            viewportFraction: (cardWidth / w).clamp(0.4, 1.0),
          );
          _controllerWidth = w;
        }
        final TextScaler scaler = MediaQuery.textScalerOf(context);
        // What the card content really gets: the page minus the 5 px page
        // padding on each side and the 12 px card padding (+2 slack).
        final double innerWidth = cardWidth - 10 - 26;
        _page = _page.clamp(0, cards.length - 1);
        final double height = _carouselHeight(cards, innerWidth, scaler);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: height,
              child: PageView.builder(
                controller: _controller,
                itemCount: cards.length,
                // padEnds would shrink the pages under our feet; the 5 px
                // page padding below is the only inset, so the card width
                // and the height estimate stay the same numbers.
                padEnds: false,
                onPageChanged: (int page) => setState(() => _page = page),
                itemBuilder: (BuildContext context, int index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _card(cards[index], innerWidth),
                    ),
                  );
                },
              ),
            ),
            if (cards.length > 1 || widget.spec.label.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _indicator(cards.length),
            ],
          ],
        );
      },
    );
  }

  /// Every part of a card is ellipsised to a fixed line count, so the height
  /// is computable: no card overflows, no PageView needs a different height.
  double _carouselHeight(List<AnswerCard> cards, double innerWidth, TextScaler scaler) {
    final _AnswerBlockStyle s = widget.s;
    // Line height of a block part: font size scaled, times its height factor.
    double lh(double fontSize, double heightFactor) =>
        scaler.scale(fontSize) * heightFactor;

    double maxCard = 120;
    for (final AnswerCard card in cards) {
      double h = 26; // vertical card padding, plus rounding slack
      if (card.image.isNotEmpty) {
        h += innerWidth * 0.55 + 12;
      }
      final double titleSize = s.baseFontSize * 1.24;
      h +=
          _lineCount(
            card.title,
            _styleFor(titleSize, FontWeight.w700, 1.25),
            innerWidth,
            scaler,
            cap: 2,
          ) *
              lh(titleSize, 1.25) +
          6;
      if (card.image.isEmpty && card.badge.isNotEmpty) {
        h += lh(s.baseFontSize * 0.84, 1.25) + 8 + 10;
      }
      if (card.subtitle.isNotEmpty) {
        h += lh(s.baseFontSize * 0.95, 1.3) + 3;
      }
      if (card.location.isNotEmpty) {
        h += lh(s.baseFontSize * 0.92, 1.35) + 4;
      }
      if (card.rating.isNotEmpty) {
        h += lh(s.baseFontSize * 0.9, 1.35) + 4;
      }
      for (int i = 0; i < card.metas.take(3).length; i++) {
        h += lh(s.baseFontSize * 0.9, 1.35) + 2;
      }
      if (card.chips.isNotEmpty) {
        final int rows = _chipRowCount(card.chips, innerWidth, scaler);
        final double chipHeight = lh(s.baseFontSize * 0.86, 1.2) + 14;
        h += rows * chipHeight + (rows - 1) * 8 + 10;
      }
      if (card.specs.isNotEmpty) {
        final int rows = (card.specs.take(4).length + 1) ~/ 2;
        final double specHeight = lh(s.baseFontSize * 0.86, 1.25) * 2 + 20;
        h += rows * specHeight + (rows - 1) * 8 + 10;
      }
      if (card.price.isNotEmpty) {
        h += lh(s.baseFontSize * 1.5, 1.2) + 10;
      }
      if (card.url.isNotEmpty || card.ask.isNotEmpty) {
        h += 46 + 12;
      }
      h += 10; // slack for descender leading and border rounding
      if (h > maxCard) maxCard = h;
    }
    return maxCard;
  }

  /// The family a card's text really renders in. With no prose family the
  /// Text widgets inherit the theme's; the height estimate must measure with
  /// that same family, or its TextPainters (engine default font) wrap titles
  /// and chips that fit on screen and the carousel gets a tall empty band.
  String? _inheritedFamily;

  TextStyle _styleFor(double size, FontWeight weight, double height) => TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height,
        fontFamily: widget.s.fontFamily ?? _inheritedFamily,
      );

  int _lineCount(
    String text,
    TextStyle style,
    double maxWidth,
    TextScaler scaler, {
    required int cap,
  }) {
    if (text.isEmpty) return 1;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: cap,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);
    final int lines = tp.computeLineMetrics().length;
    tp.dispose();
    return lines.clamp(1, cap);
  }

  int _chipRowCount(List<String> chips, double innerWidth, TextScaler scaler) {
    final TextStyle style = _styleFor(widget.s.baseFontSize * 0.86, FontWeight.w600, 1.2);
    double x = 0;
    int rows = 1;
    for (final String chip in chips) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: chip, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        textScaler: scaler,
      )..layout();
      final double chipWidth = tp.width + 22;
      tp.dispose();
      if (x == 0) {
        x = chipWidth;
      } else if (x + 8 + chipWidth <= innerWidth) {
        x += 8 + chipWidth;
      } else {
        rows++;
        x = chipWidth;
      }
    }
    return rows;
  }

  Widget _card(AnswerCard card, double innerWidth) {
    final _AnswerBlockStyle s = widget.s;

    final List<Widget> children = <Widget>[
      if (card.image.isNotEmpty) ...<Widget>[
        _cardImage(card, innerWidth),
        const SizedBox(height: 12),
      ] else if (card.badge.isNotEmpty) ...<Widget>[
        // No photo to sit on: the badge becomes the card's tag chip
        // ("Aktionstage": "Termin noch nicht bestätigt").
        _TagChip(tag: card.badge, s: s),
        const SizedBox(height: 10),
      ],
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          card.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _styleFor(s.baseFontSize * 1.24, FontWeight.w700, 1.25).copyWith(
            color: s.textColor,
          ),
        ),
      ),
    ];
    if (card.subtitle.isNotEmpty) {
      children.addAll(<Widget>[
        const SizedBox(height: 3),
        _line(card.subtitle, null, s.baseFontSize * 0.95, 1.3, s.secondary),
      ]);
    }
    if (card.location.isNotEmpty) {
      children.addAll(<Widget>[
        const SizedBox(height: 4),
        _line(card.location, HugeIcons.mapPin, s.baseFontSize * 0.92, 1.35, s.secondary),
      ]);
    }
    if (card.rating.isNotEmpty) {
      children.addAll(<Widget>[
        const SizedBox(height: 4),
        _line(card.rating, HugeIcons.star, s.baseFontSize * 0.9, 1.35, s.muted),
      ]);
    }
    for (final String meta in card.metas.take(3)) {
      children.addAll(<Widget>[
        const SizedBox(height: 2),
        _line(meta, null, s.baseFontSize * 0.9, 1.35, s.muted),
      ]);
    }
    if (card.chips.isNotEmpty) {
      children.addAll(<Widget>[
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final String chip in card.chips) _cardChip(chip, innerWidth),
          ],
        ),
      ]);
    }
    if (card.specs.isNotEmpty) {
      final double specWidth = (innerWidth - 8) / 2;
      children.addAll(<Widget>[
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final CardSpecItem spec in card.specs.take(4))
              SizedBox(width: specWidth, child: _cardSpec(spec)),
          ],
        ),
      ]);
    }
    if (card.price.isNotEmpty) {
      children.addAll(<Widget>[
        const SizedBox(height: 10),
        SelectionContainer.disabled(child: _price(card.price)),
      ]);
    }
    final bool hasOpen = card.url.isNotEmpty;
    final bool hasAsk = card.ask.isNotEmpty;
    if (hasOpen || hasAsk) {
      children.addAll(<Widget>[
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            if (hasOpen) Expanded(child: _cardButton(card)),
            if (hasOpen && hasAsk) const SizedBox(width: 10),
            if (hasAsk) Expanded(child: _askButton(card)),
          ],
        ),
      ]);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // A flat tinted surface, no outline (the Figma recommendation card).
        color: s.dark
            ? s.textColor.withValues(alpha: 0.07)
            : s.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// One fact line, with an optional leading icon one line high.
  Widget _line(
    String text,
    HugeIconData? icon,
    double fontSize,
    double height,
    Color color,
  ) {
    final Widget label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _styleFor(fontSize, FontWeight.w400, height).copyWith(color: color),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: icon == null
          ? label
          : Row(
              children: <Widget>[
                SelectionContainer.disabled(
                  child: HugeIcon(icon, size: fontSize * 1.05, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(child: label),
              ],
            ),
    );
  }

  /// `248 CHF / Nacht` → the amount big, the unit after it small and muted.
  Widget _price(String price) {
    final _AnswerBlockStyle s = widget.s;
    String value = price;
    String unit = '';
    for (final String sep in const <String>[' / ', ' · ', ' pro ', ' per ']) {
      final int at = price.indexOf(sep);
      if (at > 0) {
        value = price.substring(0, at);
        unit = price.substring(at);
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: value,
              style: _styleFor(s.baseFontSize * 1.5, FontWeight.w800, 1.2)
                  .copyWith(color: s.textColor),
            ),
            if (unit.isNotEmpty)
              TextSpan(
                text: unit,
                style: _styleFor(s.baseFontSize * 0.9, FontWeight.w400, 1.2)
                    .copyWith(color: s.muted),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _cardSpec(CardSpecItem spec) {
    final _AnswerBlockStyle s = widget.s;
    final HugeIconData? icon = _blockIcon(spec.icon);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: s.chipFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            SizedBox(
              height: s.baseFontSize * 0.86 * 1.25,
              child: Center(
                child: SelectionContainer.disabled(
                  child: HugeIcon(icon, size: 16, color: s.accent),
                ),
              ),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              spec.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _styleFor(s.baseFontSize * 0.86, FontWeight.w500, 1.25)
                  .copyWith(color: s.textColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardImage(AnswerCard card, double innerWidth) {
    final _AnswerBlockStyle s = widget.s;
    final String url = card.image;
    final Widget placeholder = Container(
      alignment: Alignment.center,
      color: s.tileFill,
      child: SelectionContainer.disabled(
        child: HugeIcon(HugeIcons.image01, size: 28, color: s.muted),
      ),
    );
    final bool safeUrl = _isPublicImageUrl(url);
    return SelectionContainer.disabled(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: double.infinity,
          height: innerWidth * 0.55,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              placeholder,
              if (safeUrl) _CardImage(url: url, fillColor: s.tileFill, iconColor: s.muted),
              if (card.badge.isNotEmpty)
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: s.backgroundColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    constraints: BoxConstraints(maxWidth: innerWidth - 20),
                    child: Text(
                      card.badge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _styleFor(s.baseFontSize * 0.82, FontWeight.w600, 1.2)
                          .copyWith(color: s.textColor),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardChip(String label, double innerWidth) {
    final _AnswerBlockStyle s = widget.s;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      constraints: BoxConstraints(maxWidth: innerWidth - 4),
      decoration: BoxDecoration(
        color: s.chipFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _styleFor(s.baseFontSize * 0.86, FontWeight.w500, 1.2)
            .copyWith(color: s.textColor),
      ),
    );
  }

  Widget _cardButton(AnswerCard card) {
    final _AnswerBlockStyle s = widget.s;
    return _pillButton(
      label: card.action.isEmpty ? 'Open' : card.action,
      fill: s.accent,
      fg: s.onAccent,
      onTap: () => _openBlockUrl(context, card.url),
    );
  }

  /// The tonal second button ("Vergleichen"): sends `ask: title` as the
  /// reader's next message, so the model knows which card was meant.
  Widget _askButton(AnswerCard card) {
    final _AnswerBlockStyle s = widget.s;
    final ValueChanged<String>? send = widget.onFollowUp;
    return _pillButton(
      label: card.ask,
      fill: s.accent.withValues(alpha: s.dark ? 0.24 : 0.16),
      fg: s.dark ? s.textColor : s.accent,
      onTap: send == null ? null : () => send('${card.ask}: ${card.title}'),
    );
  }

  Widget _pillButton({
    required String label,
    required Color fill,
    required Color fg,
    required VoidCallback? onTap,
  }) {
    final _AnswerBlockStyle s = widget.s;
    return SizedBox(
      height: 46,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(23),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _styleFor(s.baseFontSize * 0.95, FontWeight.w700, 1.2)
                      .copyWith(color: fg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _indicator(int count) {
    final _AnswerBlockStyle s = widget.s;
    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (int i = 0; i < count; i++)
                if (count > 1)
                  GestureDetector(
                    onTap: () => _controller?.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                    ),
                    child: SelectionContainer.disabled(
                      child: Container(
                        width: i == _page ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == _page ? s.accent : s.accent.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
        // Shrinks before it overflows a narrow column (the dots take a third).
        Expanded(
          flex: 2,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SelectionContainer.disabled(
              child: Text(
                widget.spec.label.isEmpty
                    ? '${_page + 1} / $count'
                    : '${_page + 1} / $count ${widget.spec.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: s.muted,
                  fontSize: s.baseFontSize * 0.86,
                  height: 1.2,
                  fontFamily: s.fontFamily,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        SelectionContainer.disabled(
          child: HugeIcon(HugeIcons.arrowRight01, size: 15, color: s.muted),
        ),
      ],
    );
  }
}

/// Width of one rendered text line, for the carousel's height estimate.

// ---------------------------------------------------------------------------
// card image loading

/// A card image loaded through the public-only HTTP client, bytes kept in a
/// small LRU cache so scrolling a long answer back does not re-download.
///
/// `Image.network` would resolve and connect on its own, so a model-supplied
/// host name could end up knocked at a private address. Here the connection
/// itself is held to the checked address (DNS rebinding included), the
/// response must declare or start with an image, and oversized bodies are
/// dropped. On web no such client exists; there the browser's own rules
/// apply, as with every other remote image in the app.
class _CardImage extends StatefulWidget {
  const _CardImage({
    required this.url,
    required this.fillColor,
    required this.iconColor,
  });

  final String url;
  final Color fillColor;
  final Color iconColor;

  @override
  State<_CardImage> createState() => _CardImageState();
}

class _CardImageState extends State<_CardImage> {
  static final LruByteCache _cache = LruByteCache(
    maxSizeBytes: 20 * 1024 * 1024,
  );

  static const int _maxBytes = 8 * 1024 * 1024;

  Uint8List? _bytes;
  bool _failed = false;

  /// Thrown when the streamed body runs past [_maxBytes]; the catch in
  /// [_load] turns it into the placeholder.
  static const _ImageTooLarge _imageTooLarge = _ImageTooLarge();
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final String url = widget.url;
    // A result that arrives after the url changed must not land: a late
    // response from the old host must not paint into the new card.
    bool current() => mounted && widget.url == url;

    final Uint8List? cached = _cache.get(url);
    if (cached != null) {
      if (current()) setState(() => _bytes = cached);
      return;
    }
    if (kIsWeb) {
      // No public-only client on the web build; the browser resolves and
      // fetches under its own rules, like every other remote image there.
      return;
    }
    final http.Client? client = publicOnlyHttpClient(isNonPublicIp);
    if (client == null) {
      if (current()) setState(() => _failed = true);
      return;
    }
    try {
      final http.StreamedResponse response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 15));
      final int? declared = response.contentLength;
      if (response.statusCode != 200 || (declared != null && declared > _maxBytes)) {
        if (current()) setState(() => _failed = true);
        return;
      }
      // Read the body with the cap enforced WHILE streaming: an endless
      // body never fills memory, it fails the load instead.
      final BytesBuilder buffer = BytesBuilder(copy: false);
      await for (final List<int> chunk
          in response.stream.timeout(const Duration(seconds: 15))) {
        buffer.add(chunk);
        if (buffer.length > _maxBytes) {
          throw _imageTooLarge;
        }
      }
      final Uint8List body = buffer.takeBytes();
      if (!_looksLikeImage(body, response.headers['content-type'])) {
        if (current()) setState(() => _failed = true);
        return;
      }
      _cache.put(url, body);
      if (current()) setState(() => _bytes = body);
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      client.close();
    }
  }

  /// Image bodies only: the declared type wins; else the magic bytes of the
  /// four formats a card thumbnail realistically has.
  bool _looksLikeImage(Uint8List bytes, String? contentType) {
    if (contentType != null &&
        contentType.toLowerCase().trim().startsWith('image/')) {
      return true;
    }
    if (bytes.lengthInBytes >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return true; // JPEG
    }
    if (bytes.lengthInBytes >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes.lengthInBytes >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return true; // GIF
    }
    if (bytes.lengthInBytes >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true; // WEBP (RIFF....WEBP)
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }
    if (kIsWeb && !_failed) {
      return Image.network(
        widget.url,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      alignment: Alignment.center,
      color: widget.fillColor,
      child: SelectionContainer.disabled(
        child: HugeIcon(HugeIcons.image01, size: 28, color: widget.iconColor),
      ),
    );
  }
}

/// Thrown when a card image body runs past the size cap mid-stream.
class _ImageTooLarge implements Exception {
  const _ImageTooLarge();
}

// ---------------------------------------------------------------------------
// ask — follow-up chips

class _AskBlock extends StatelessWidget {
  const _AskBlock({
    required this.spec,
    required this.s,
    required this.onFollowUp,
  });

  final AskSpec spec;
  final _AnswerBlockStyle s;
  final ValueChanged<String>? onFollowUp;

  @override
  Widget build(BuildContext context) {
    if (spec.chips.isEmpty && spec.question.isEmpty && spec.buttons.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String b in spec.buttons) ...<Widget>[
          _button(b),
          const SizedBox(height: 10),
        ],
        if (spec.question.isNotEmpty) s.markdown(spec.question),
        if (spec.chips.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (int i = 0; i < spec.chips.length; i++)
                _chip(spec.chips[i], _blockIcon(spec.iconAt(i))),
            ],
          ),
        ],
      ],
    );
  }

  /// A filled, full-width action ("Aktuelle Werte abrufen").
  Widget _button(String label) {
    return SizedBox(
      height: 46,
      child: Material(
        color: s.accent,
        borderRadius: BorderRadius.circular(23),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onFollowUp == null ? null : () => onFollowUp!(label),
          child: Semantics(
            button: true,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: s.onAccent,
                    fontSize: s.baseFontSize * 0.95,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    fontFamily: s.fontFamily,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, HugeIconData? icon) {
    final TextStyle style = TextStyle(
      color: s.textColor,
      fontSize: s.baseFontSize * 0.95,
      fontWeight: FontWeight.w600,
      height: 1.25,
      fontFamily: s.fontFamily,
    );
    final Widget text = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onFollowUp == null ? null : () => onFollowUp!(label),
        child: Semantics(
          button: true,
          child: Container(
            padding: EdgeInsets.fromLTRB(icon == null ? 14 : 12, 9, 14, 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: s.textColor.withValues(alpha: 0.24)),
            ),
            child: icon == null
                ? text
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        height: s.baseFontSize * 0.95 * 1.25,
                        child: Center(
                          child: SelectionContainer.disabled(
                            child: HugeIcon(icon, size: 17, color: s.accent),
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(child: text),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// status — rows with logo, amount, status chip, date and an action
// (Figma: "chuk_chat – Status-Block", phone 390 / desktop 720)

/// Below this width a row stacks (amount next to the name, chip and action
/// under the detail); above it the amount and the action get their own
/// right-hand column.
const double _kStatusWideMin = 560;

class _StatusColors {
  const _StatusColors(this.fg, this.fill);
  final Color fg;
  final Color fill;
}

_StatusColors _statusColors(StatusKind kind, _AnswerBlockStyle s) {
  final Color fg;
  switch (kind) {
    case StatusKind.failed:
      fg = s.bad;
    case StatusKind.overdue:
      fg = s.dark ? const Color(0xFFFFB870) : const Color(0xFF9A4A00);
    case StatusKind.due:
      fg = s.dark ? const Color(0xFFE8D27A) : const Color(0xFF6B5A00);
    case StatusKind.ok:
    case StatusKind.neutral:
      return _StatusColors(s.secondary, s.textColor.withValues(alpha: 0.08));
  }
  return _StatusColors(fg, fg.withValues(alpha: s.dark ? 0.15 : 0.12));
}

HugeIconData _statusIcon(StatusKind kind) {
  switch (kind) {
    case StatusKind.failed:
      return HugeIcons.alert02;
    case StatusKind.overdue:
      return HugeIcons.clock01;
    case StatusKind.due:
      return HugeIcons.hourglass;
    case StatusKind.ok:
      return HugeIcons.tick02;
    case StatusKind.neutral:
      return HugeIcons.informationCircle;
  }
}

String _plainInline(String text) =>
    text.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '');

class _StatusBlock extends StatefulWidget {
  const _StatusBlock({required this.spec, required this.s});

  final StatusSpec spec;
  final _AnswerBlockStyle s;

  @override
  State<_StatusBlock> createState() => _StatusBlockState();
}

class _StatusBlockState extends State<_StatusBlock> {
  bool _expanded = false;

  _AnswerBlockStyle get s => widget.s;

  TextStyle _style(
    double scale, {
    FontWeight weight = FontWeight.w400,
    Color? color,
  }) {
    return TextStyle(
      color: color ?? s.textColor,
      fontSize: s.baseFontSize * scale,
      fontWeight: weight,
      height: 1.3,
      fontFamily: s.fontFamily,
    );
  }

  /// The most urgent kind in the list sets the header icon.
  StatusKind get _worst {
    const List<StatusKind> order = <StatusKind>[
      StatusKind.failed,
      StatusKind.overdue,
      StatusKind.due,
      StatusKind.ok,
    ];
    for (final StatusKind k in order) {
      if (widget.spec.items.any((StatusItem i) => i.kind == k)) return k;
    }
    return StatusKind.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final StatusSpec spec = widget.spec;
    if (spec.items.isEmpty && spec.title.isEmpty && spec.moreLabel.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= _kStatusWideMin;
        final bool hasHead = spec.title.isNotEmpty || spec.summary.isNotEmpty;
        final List<Widget> children = <Widget>[
          if (hasHead) _header(),
        ];
        void addRow(StatusItem item) {
          if (children.isNotEmpty) children.add(_hairline());
          children.add(_row(context, item, wide));
        }

        for (final StatusItem item in spec.items) {
          addRow(item);
        }
        if (spec.moreLabel.isNotEmpty) {
          if (children.isNotEmpty) children.add(_hairline());
          children.add(_footer());
          if (_expanded) {
            for (final StatusItem item in spec.moreItems) {
              addRow(item);
            }
          }
        }
        return _ModuleCard(
          s: s,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      },
    );
  }

  Widget _hairline() => Container(height: 1, color: s.textColor.withValues(alpha: 0.10));

  Widget _iconTile(HugeIconData icon, Color fg, Color fill, double size) {
    return SelectionContainer.disabled(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: HugeIcon(icon, size: size * 0.56, color: fg),
      ),
    );
  }

  Widget _header() {
    final StatusKind worst = _worst;
    final _StatusColors col = _statusColors(worst, s);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          _iconTile(_statusIcon(worst), col.fg, col.fill, 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.spec.title.isNotEmpty)
                  Text(
                    _plainInline(widget.spec.title),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _style(1.1, weight: FontWeight.w700),
                  ),
                if (widget.spec.summary.isNotEmpty)
                  Text(
                    _plainInline(widget.spec.summary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _style(0.88, weight: FontWeight.w500, color: s.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _logo(StatusItem item) {
    if (item.domain.isEmpty) {
      return _iconTile(HugeIcons.store01, s.muted, s.tileFill, 28);
    }
    return SelectionContainer.disabled(
      child: FaviconImage(
        host: item.domain,
        size: 28,
        borderRadius: 8,
        fallbackColor: s.muted,
      ),
    );
  }

  Widget _chip(StatusItem item) {
    final _StatusColors col = _statusColors(item.kind, s);
    return SelectionContainer.disabled(
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
        decoration: BoxDecoration(
          color: col.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HugeIcon(_statusIcon(item.kind), size: 14, color: col.fg),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                item.statusLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(0.8, weight: FontWeight.w700, color: col.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext context, StatusItem item) {
    final bool iconOnly = item.actionLabel.isEmpty;
    return Semantics(
      button: true,
      label: iconOnly ? 'Open link' : null,
      child: Material(
        color: s.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openBlockUrl(context, item.actionUrl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34, minWidth: 34),
            child: Padding(
              padding: iconOnly
                  ? const EdgeInsets.all(9)
                  : const EdgeInsets.fromLTRB(12, 7, 10, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (!iconOnly) ...<Widget>[
                    Flexible(
                      child: Text(
                        _plainInline(item.actionLabel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _style(0.86, weight: FontWeight.w700, color: s.accent),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  HugeIcon(HugeIcons.arrowUpRight01, size: 15, color: s.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _name(StatusItem item) => Text(
    _plainInline(item.title),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: _style(1.0, weight: FontWeight.w700),
  );

  Widget _date(StatusItem item) => Text(
    item.date,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: _style(0.8, weight: FontWeight.w500, color: s.muted),
  );

  Widget _amount(StatusItem item, double scale) => Text(
    _plainInline(item.amount),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.right,
    style: _style(scale, weight: FontWeight.w700),
  );

  Widget? _detail(StatusItem item) => item.detail.isEmpty
      ? null
      : Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            _plainInline(item.detail),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _style(0.88, color: s.secondary.withValues(alpha: 0.78)),
          ),
        );

  Widget _row(BuildContext context, StatusItem item, bool wide) {
    final bool hasChip = item.statusLabel.isNotEmpty;
    final bool hasAction = item.actionUrl.isNotEmpty;
    final Widget? detail = _detail(item);
    if (wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            _logo(item),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _name(item),
                  ?detail,
                  if (hasChip || item.date.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Row(
                        children: <Widget>[
                          if (hasChip) Flexible(child: _chip(item)),
                          if (hasChip && item.date.isNotEmpty)
                            const SizedBox(width: 8),
                          if (item.date.isNotEmpty) _date(item),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (item.amount.isNotEmpty || hasAction) ...<Widget>[
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (item.amount.isNotEmpty) _amount(item, 1.3),
                    if (item.amount.isNotEmpty && hasAction)
                      const SizedBox(height: 8),
                    if (hasAction) _action(context, item),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _logo(item),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // At least the logo's height, so the name lines up with
                    // it; taller when a large text scale needs the room.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 28),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Row(
                              children: <Widget>[
                                Flexible(child: _name(item)),
                                if (item.date.isNotEmpty) ...<Widget>[
                                  const SizedBox(width: 6),
                                  _date(item),
                                ],
                              ],
                            ),
                          ),
                          if (item.amount.isNotEmpty) ...<Widget>[
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: c.maxWidth * 0.45,
                              ),
                              child: _amount(item, 1.1),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?detail,
                    if (hasChip || hasAction)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 6,
                          children: <Widget>[
                            if (hasChip) _chip(item),
                            if (hasAction) _action(context, item),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final bool canOpen = widget.spec.moreItems.isNotEmpty;
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: <Widget>[
          _iconTile(HugeIcons.archive02, s.muted, s.tileFill, 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _plainInline(widget.spec.moreLabel),
              maxLines: _expanded ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: _style(0.88, weight: FontWeight.w500, color: s.secondary),
            ),
          ),
          if (canOpen) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              '${widget.spec.moreItems.length}',
              style: _style(0.8, weight: FontWeight.w700, color: s.muted),
            ),
            const SizedBox(width: 6),
            SelectionContainer.disabled(
              child: AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: HugeIcon(HugeIcons.arrowDown01, size: 18, color: s.muted),
              ),
            ),
          ],
        ],
      ),
    );
    if (!canOpen) return content;
    return Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: content,
      ),
    );
  }
}
