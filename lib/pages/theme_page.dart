// lib/pages/theme_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class ThemePage extends StatefulWidget {
  final AppShellConfig config;

  const ThemePage({super.key, required this.config});

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  late Brightness _selectedThemeMode;
  late Color _selectedAccentColor;
  late Color _selectedIconFgColor;
  late Color _selectedBgColor;
  late bool _selectedDynamicColor;

  final TextEditingController _accentHexController = TextEditingController();
  final TextEditingController _iconFgHexController = TextEditingController();
  final TextEditingController _bgHexController = TextEditingController();

  // Curated swatch palettes. Order: brand default first, then a balanced
  // spread across hues plus neutrals (incl. black & white) so users can
  // dial in either vivid accents or pure-mono themes.
  final List<Color> _accentColorOptions = const [
    kDefaultAccentColor,
    Color(0xFF8AB4F8), // soft blue
    Color(0xFF7C4DFF), // deep purple A
    Color(0xFFB388FF), // soft violet
    Color(0xFFEA80FC), // pink violet
    Color(0xFFFF80AB), // pink
    Color(0xFFFF5252), // red
    Color(0xFFFF7043), // deep orange
    Color(0xFFFFB300), // amber
    Color(0xFFFFD54F), // yellow
    Color(0xFFAEEA00), // lime
    Color(0xFF00E676), // green
    Color(0xFF26A69A), // teal
    Color(0xFF26C6DA), // cyan
    Color(0xFF8D6E63), // brown
    Color(0xFFBDBDBD), // light grey
    Color(0xFF424242), // dark grey
    Color(0xFF000000), // black
    Color(0xFFFFFFFF), // white
  ];

  // Foreground/icon palette includes pure black + white so users can pick
  // a high-contrast text colour against any background.
  final List<Color> _iconFgColorOptions = const [
    kDefaultIconFgColor,
    Color(0xFFFFFFFF), // white
    Color(0xFF000000), // black
    Color(0xFFE0E0E0), // light grey
    Color(0xFF9E9E9E), // mid grey
    Color(0xFF424242), // dark grey
    Color(0xFFCFD8DC), // blue grey 100
    Color(0xFF90A4AE), // blue grey 300
    Color(0xFFFFE082), // amber 200
    Color(0xFFFFAB91), // orange 200
    Color(0xFFF48FB1), // pink 200
    Color(0xFFCE93D8), // purple 200
    Color(0xFF9FA8DA), // indigo 200
    Color(0xFF80DEEA), // cyan 200
    Color(0xFFA5D6A7), // green 200
    Color(0xFFC5E1A5), // light green 200
    Color(0xFFEEEBE3), // warm beige
  ];

  final List<Color> _bgColorOptions = [
    kDefaultBgColor,
    kDefaultBgColor.lighten(0.8),
    const Color(0xFF000000), // pure black
    const Color(0xFFFFFFFF), // pure white
    const Color(0xFF111318), // near-black
    const Color(0xFF1B1B1F), // charcoal
    const Color(0xFF202124), // graphite
    const Color(0xFF263238), // blue grey 900
    const Color(0xFF1A237E), // indigo 900
    const Color(0xFF311B92), // deep purple 900
    const Color(0xFF004D40), // teal 900
    const Color(0xFF3E2723), // brown 900
    const Color(0xFFF5F5F5), // off-white
    const Color(0xFFFAFAFA), // grey 50
    const Color(0xFFEEEBE3), // warm beige
    const Color(0xFFE3F2FD), // blue 50
    const Color(0xFFFFF3E0), // orange 50
  ];

  @override
  void initState() {
    super.initState();
    _selectedThemeMode = widget.config.currentThemeMode;
    _selectedAccentColor = widget.config.currentAccentColor;
    _selectedIconFgColor = widget.config.currentIconFgColor;
    _selectedBgColor = widget.config.currentBgColor;
    _selectedDynamicColor = widget.config.dynamicColorEnabled;

    _accentHexController.text = _selectedAccentColor.toHexString();
    _iconFgHexController.text = _selectedIconFgColor.toHexString();
    _bgHexController.text = _selectedBgColor.toHexString();
  }

  @override
  void dispose() {
    _accentHexController.dispose();
    _iconFgHexController.dispose();
    _bgHexController.dispose();
    super.dispose();
  }

  void _applyThemeChanges() {
    widget.config.setThemeMode(_selectedThemeMode);
    widget.config.setAccentColor(_selectedAccentColor);
    widget.config.setIconFgColor(_selectedIconFgColor);
    widget.config.setBgColor(_selectedBgColor);
  }

  void _updateThemeMode(bool useDarkMode) {
    setState(() {
      _selectedThemeMode = useDarkMode ? Brightness.dark : Brightness.light;
      _selectedBgColor = useDarkMode
          ? kDefaultBgColor
          : kDefaultBgColor.lighten(0.8);
      _bgHexController.text = _selectedBgColor.toHexString();
      _applyThemeChanges();
    });
  }

  void _updateDynamicColorEnabled(bool enabled) {
    setState(() {
      _selectedDynamicColor = enabled;
    });
    widget.config.setDynamicColorEnabled(enabled);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l = AppLocalizations.of(context)!;
    final bool isDarkMode = _selectedThemeMode == Brightness.dark;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(l.themeSettings),
        centerTitle: false,
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Mode section: dark toggle + dynamic colour grouped in one card.
          const _SectionHeader('Mode'),
          _GroupedCard(
            children: [
              _SwitchRow(
                icon: Icons.dark_mode_outlined,
                title: l.darkMode,
                subtitle: l.darkModeSubtitle,
                value: isDarkMode,
                onChanged: _updateThemeMode,
              ),
              _divider(context),
              _SwitchRow(
                icon: Icons.palette_outlined,
                title: l.dynamicColor,
                subtitle: l.dynamicColorSubtitle,
                value: _selectedDynamicColor,
                onChanged: _updateDynamicColorEnabled,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Material You drives the whole palette (accent, icon/foreground and
          // background). While it is on, every colour picker is replaced by a
          // note so the UI never implies a choice that the system overrides.
          _SectionHeader(l.accentColor),
          if (_selectedDynamicColor)
            _dynamicColorNote(l)
          else
            _ColorCard(
              description: l.accentColorSubtitle,
              hexLabel: l.customHexColor,
              currentColor: _selectedAccentColor,
              options: _accentColorOptions,
              hexController: _accentHexController,
              gridColumns: 8,
              onColorSelected: (c) {
                setState(() {
                  _selectedAccentColor = c;
                  _accentHexController.text = c.toHexString();
                  _applyThemeChanges();
                });
              },
              onHexChanged: (hex) {
                try {
                  final c = ColorExtension.fromHexString(hex);
                  setState(() {
                    _selectedAccentColor = c;
                    _applyThemeChanges();
                  });
                } catch (_) {}
              },
            ),
          const SizedBox(height: 24),

          _SectionHeader(l.iconFgColor),
          if (_selectedDynamicColor)
            _dynamicColorNote(l)
          else
            _ColorCard(
              description: l.iconFgColorSubtitle,
              hexLabel: l.customHexColor,
              currentColor: _selectedIconFgColor,
              options: _iconFgColorOptions,
              hexController: _iconFgHexController,
              gridColumns: 5,
              onColorSelected: (c) {
                setState(() {
                  _selectedIconFgColor = c;
                  _iconFgHexController.text = c.toHexString();
                  _applyThemeChanges();
                });
              },
              onHexChanged: (hex) {
                try {
                  final c = ColorExtension.fromHexString(hex);
                  setState(() {
                    _selectedIconFgColor = c;
                    _applyThemeChanges();
                  });
                } catch (_) {}
              },
            ),
          const SizedBox(height: 24),

          _SectionHeader(l.backgroundColor),
          if (_selectedDynamicColor)
            _dynamicColorNote(l)
          else
            _ColorCard(
              description: l.backgroundColorSubtitle,
              hexLabel: l.customHexColor,
              currentColor: _selectedBgColor,
              options: _bgColorOptions,
              hexController: _bgHexController,
              gridColumns: 8,
              onColorSelected: (c) {
                setState(() {
                  _selectedBgColor = c;
                  _bgHexController.text = c.toHexString();
                  _applyThemeChanges();
                });
              },
              onHexChanged: (hex) {
                try {
                  final c = ColorExtension.fromHexString(hex);
                  setState(() {
                    _selectedBgColor = c;
                    _applyThemeChanges();
                  });
                } catch (_) {}
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // Shown in place of a colour picker while Material You is active — the
  // system palette owns the colour, so there is nothing to choose here.
  Widget _dynamicColorNote(AppLocalizations l) {
    return _GroupedCard(
      children: [
        _NoteRow(
          icon: Icons.auto_awesome_outlined,
          text: l.colorDynamicNote,
        ),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Divider(height: 1, color: m3.outlineVariant, indent: 56);
  }
}

// Small caps section header used across both settings pages.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: cs.primary,
        ),
      ),
    );
  }
}

// Grouped rounded surfaceContainer card, rows separated by thin dividers.
class _GroupedCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupedCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return InkWell(
      borderRadius: kBorderRadiusRow,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 24, color: m3.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

// Informational row (icon + text) used to explain a disabled control,
// e.g. the accent picker when Material You / dynamic colour is active.
class _NoteRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _NoteRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 22, color: m3.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: m3.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// Color section: description, swatch grid, hex input field.
class _ColorCard extends StatelessWidget {
  final String description;
  final String hexLabel;
  final Color currentColor;
  final List<Color> options;
  final TextEditingController hexController;
  final int gridColumns;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<String> onHexChanged;

  const _ColorCard({
    required this.description,
    required this.hexLabel,
    required this.currentColor,
    required this.options,
    required this.hexController,
    required this.gridColumns,
    required this.onColorSelected,
    required this.onHexChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            style: TextStyle(fontSize: 13, color: m3.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final totalSpacing = spacing * (gridColumns - 1);
              final size = (constraints.maxWidth - totalSpacing) / gridColumns;
              final swatchSize = size.clamp(32.0, 40.0);
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: options
                    .map(
                      (c) => _Swatch(
                        color: c,
                        selected: c == currentColor,
                        size: swatchSize,
                        onTap: () => onColorSelected(c),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            hexLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: hexController,
            decoration: InputDecoration(
              prefixIcon: Icon(
                Icons.colorize_outlined,
                color: m3.onSurfaceVariant,
              ),
              suffixIcon: IconButton(
                icon: Icon(Icons.check_circle, color: cs.primary),
                onPressed: () => onHexChanged(hexController.text),
              ),
              hintText: '#RRGGBB',
            ),
            onFieldSubmitted: onHexChanged,
            keyboardType: TextInputType.text,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^[#0-9a-fA-F]+$')),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final picked = await showDialog<Color>(
                  context: context,
                  builder: (_) => _ColorPickerDialog(initial: currentColor),
                );
                if (picked != null) {
                  onColorSelected(picked);
                }
              },
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: Text(AppLocalizations.of(context)!.pickCustomColor),
            ),
          ),
        ],
      ),
    );
  }
}

// HSV-based custom color picker. Built in-tree to avoid a new dependency.
class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  const _ColorPickerDialog({required this.initial});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexController = TextEditingController(text: widget.initial.toHexString());
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor v) {
    setState(() {
      _hsv = v;
      _hexController.text = v.toColor().toHexString();
    });
  }

  void _onHexSubmit(String hex) {
    try {
      final c = ColorExtension.fromHexString(hex);
      setState(() {
        _hsv = HSVColor.fromColor(c);
        _hexController.text = c.toHexString();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    final color = _hsv.toColor();
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: m3.surfaceContainerHigh,
      title: Text(l.pickAColor),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Live preview swatch.
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: m3.outlineVariant),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              l.hue,
              style: TextStyle(fontSize: 12, color: m3.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            _GradientSlider(
              colors: const [
                Color(0xFFFF0000),
                Color(0xFFFFFF00),
                Color(0xFF00FF00),
                Color(0xFF00FFFF),
                Color(0xFF0000FF),
                Color(0xFFFF00FF),
                Color(0xFFFF0000),
              ],
              value: _hsv.hue / 360.0,
              onChanged: (v) =>
                  _setHsv(_hsv.withHue((v * 360.0).clamp(0.0, 360.0))),
            ),
            const SizedBox(height: 14),
            Text(
              l.saturation,
              style: TextStyle(fontSize: 12, color: m3.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            _GradientSlider(
              colors: [
                HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
                HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
              ],
              value: _hsv.saturation,
              onChanged: (v) => _setHsv(_hsv.withSaturation(v)),
            ),
            const SizedBox(height: 14),
            Text(
              l.brightness,
              style: TextStyle(fontSize: 12, color: m3.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            _GradientSlider(
              colors: [
                Colors.black,
                HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
              ],
              value: _hsv.value,
              onChanged: (v) => _setHsv(_hsv.withValue(v)),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _hexController,
              decoration: InputDecoration(
                prefixIcon: Icon(
                  Icons.tag,
                  color: m3.onSurfaceVariant,
                  size: 18,
                ),
                hintText: '#RRGGBB',
                isDense: true,
              ),
              onFieldSubmitted: _onHexSubmit,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^[#0-9a-fA-F]+$')),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.primary),
          onPressed: () => Navigator.pop(context, color),
          child: Text(l.useColor),
        ),
      ],
    );
  }
}

class _GradientSlider extends StatelessWidget {
  final List<Color> colors;
  final double value;
  final ValueChanged<double> onChanged;

  const _GradientSlider({
    required this.colors,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    const trackHeight = 18.0;
    const thumbDiameter = 22.0;
    return SizedBox(
      height: thumbDiameter + 4,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          void update(double dx) {
            final v = (dx / w).clamp(0.0, 1.0);
            onChanged(v);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.localPosition.dx),
            onPanStart: (d) => update(d.localPosition.dx),
            onPanUpdate: (d) => update(d.localPosition.dx),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: trackHeight,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: colors),
                    borderRadius: BorderRadius.circular(trackHeight / 2),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                Positioned(
                  left: ((w - thumbDiameter) * value).clamp(
                    0.0,
                    (w - thumbDiameter).clamp(0.0, double.infinity),
                  ),
                  child: Container(
                    width: thumbDiameter,
                    height: thumbDiameter,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.35),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Check mark uses a contrast-aware foreground so it stays legible
    // on both light and dark swatches.
    final checkColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: selected
              ? Border.all(color: cs.onSurface, width: 2)
              : Border.all(color: Colors.transparent, width: 2),
          boxShadow: selected
              ? [BoxShadow(color: cs.surface, spreadRadius: 3)]
              : null,
        ),
        child: selected
            ? Icon(Icons.check, size: size * 0.5, color: checkColor)
            : null,
      ),
    );
  }
}
