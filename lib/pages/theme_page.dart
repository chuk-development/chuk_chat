// lib/pages/theme_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

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
  late double _selectedContrast;
  late String _selectedUiFont;
  late String _selectedChatFont;

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
    // Read the LIVE service, not [widget.config]. The config is an immutable
    // snapshot captured when an ancestor settings route was pushed, so it goes
    // stale after the theme changes — re-entering this page from that route
    // would otherwise show the old preset and old picker colours. The setters
    // still go through [widget.config]; they point at the same singleton.
    final service = AppThemeService.instance;
    _selectedThemeMode = service.themeMode;
    _selectedAccentColor = service.accentColor;
    _selectedIconFgColor = service.iconFgColor;
    _selectedBgColor = service.bgColor;
    _selectedDynamicColor = service.dynamicColorEnabled;
    _selectedContrast = service.contrast.clamp(kMinContrast, kMaxContrast);
    _selectedUiFont = sanitizeUiFontFamily(service.uiFontFamily);
    _selectedChatFont = sanitizeChatFontFamily(service.chatFontFamily);

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
    final brightness = useDarkMode ? Brightness.dark : Brightness.light;
    // If a pack is currently applied, flipping the toggle switches to that same
    // pack's sibling look (its light or dark variant) instead of dropping back
    // to the plain default background.
    final active = _matchedPreset;
    if (active != null) {
      _selectPresetVariant(active, brightness);
      return;
    }
    setState(() {
      _selectedThemeMode = brightness;
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

  /// Applies a pack's variant for [brightness] to both local state and the
  /// live theme. Selecting a pack keeps the current brightness; the dark-mode
  /// toggle switches which variant is used.
  void _selectPresetVariant(ThemePreset preset, Brightness brightness) {
    final v = preset.variantFor(brightness);
    setState(() {
      _selectedDynamicColor = false;
      _selectedThemeMode = brightness;
      _selectedAccentColor = v.accent;
      _selectedIconFgColor = v.iconFg;
      _selectedBgColor = v.bg;
      _selectedContrast = v.contrast;
      _selectedUiFont = v.uiFont;
      _accentHexController.text = v.accent.toHexString();
      _iconFgHexController.text = v.iconFg.toHexString();
      _bgHexController.text = v.bg.toHexString();
    });
    preset.applyTo(widget.config, brightness);
  }

  void _applyPreset(ThemePreset preset) =>
      _selectPresetVariant(preset, _selectedThemeMode);

  /// The pack whose variant for the current brightness matches every selected
  /// value, or null when the user has customised away from every pack.
  ThemePreset? get _matchedPreset {
    if (_selectedDynamicColor) return null;
    for (final preset in kThemePresets) {
      if (preset.matches(
        brightness: _selectedThemeMode,
        accent: _selectedAccentColor,
        iconFg: _selectedIconFgColor,
        bg: _selectedBgColor,
        contrast: _selectedContrast,
        uiFont: _selectedUiFont,
      )) {
        return preset;
      }
    }
    return null;
  }

  void _updateContrast(double value, {bool commit = false}) {
    setState(() {
      _selectedContrast = value;
    });
    if (commit) {
      unawaited(widget.config.setContrast(value));
    }
  }

  void _updateUiFont(String id) {
    setState(() {
      _selectedUiFont = id;
    });
    unawaited(widget.config.setUiFontFamily(id));
  }

  void _updateChatFont(String id) {
    setState(() {
      _selectedChatFont = id;
    });
    widget.config.setChatFontFamily(id);
  }

  String _fontLabel(String id, AppLocalizations l) {
    switch (id) {
      case kChatFontFamilySystem:
        return l.fontFamilySystem;
      case kChatFontFamilyMerriweather:
        return l.fontFamilyMerriweather;
      case kChatFontFamilyJetBrainsMono:
        return l.fontFamilyJetBrainsMono;
      case kChatFontFamilyArimo:
      default:
        return l.fontFamilyArimo;
    }
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
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Presets, up top so a whole look can be applied before tuning the
          // individual controls below. Every change is applied live, so there
          // is no preview card.
          ExpressiveSectionHeader(l.themePresets),
          ExpressiveGroup(
            children: [
              _PresetPicker(
                presets: kThemePresets,
                selected: _matchedPreset,
                brightness: _selectedThemeMode,
                onSelected: _applyPreset,
                title: l.themePresetPack,
                subtitle: l.themePresetPackSubtitle,
                customLabel: l.themePresetCustom,
              ),
            ],
          ),

          // Mode: the dark toggle and Material You, one group.
          const ExpressiveSectionHeader('Mode'),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
                icon: Icons.dark_mode_outlined,
                title: l.darkMode,
                subtitle: l.darkModeSubtitle,
                value: isDarkMode,
                onChanged: _updateThemeMode,
              ),
              ExpressiveSwitchRow(
                icon: Icons.palette_outlined,
                title: l.dynamicColor,
                subtitle: l.dynamicColorSubtitle,
                value: _selectedDynamicColor,
                onChanged: _updateDynamicColorEnabled,
              ),
            ],
          ),

          // Material You drives the whole palette (accent, icon/foreground and
          // background). While it is on, every colour picker is replaced by a
          // note so the UI never implies a choice that the system overrides.
          ExpressiveSectionHeader(l.accentColor),
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

          ExpressiveSectionHeader(l.iconFgColor),
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

          ExpressiveSectionHeader(l.backgroundColor),
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

          // Contrast: scales how strongly surfaces and outlines separate from
          // the background.
          ExpressiveSectionHeader(l.themeContrast),
          ExpressiveGroup(
            children: [
              ExpressiveCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.themeContrastStrength,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l.themeContrastSubtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.m3.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.contrast_outlined,
                          size: 20,
                          color: theme.m3.onSurfaceVariant,
                        ),
                        Expanded(
                          child: Slider(
                            value: _selectedContrast,
                            min: kMinContrast,
                            max: kMaxContrast,
                            divisions: 10,
                            label: '${(_selectedContrast * 100).round()}%',
                            onChanged: (v) => _updateContrast(v),
                            onChangeEnd: (v) =>
                                _updateContrast(v, commit: true),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: Text(
                            '${(_selectedContrast * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Fonts: the app-chrome font (new) and the chat body font (also
          // reachable from Customisation), kept together so the two are not
          // confused.
          ExpressiveSectionHeader(l.themeFonts),
          ExpressiveGroup(
            children: [
              _FontCard(
                title: l.interfaceFont,
                subtitle: l.interfaceFontSubtitle,
                sample: l.fontSizePreview,
                value: _selectedUiFont,
                options: kSupportedUiFontFamilies,
                labelFor: (id) => _fontLabel(id, l),
                onChanged: _updateUiFont,
              ),
              _FontCard(
                title: l.chatFontFamily,
                subtitle: l.chatFontFamilySubtitle,
                sample: l.fontSizePreview,
                value: _selectedChatFont,
                options: kSupportedChatFontFamilies,
                labelFor: (id) => _fontLabel(id, l),
                onChanged: _updateChatFont,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Shown in place of a colour picker while Material You is active — the
  // system palette owns the colour, so there is nothing to choose here.
  Widget _dynamicColorNote(AppLocalizations l) {
    return ExpressiveInfoCard(
      icon: Icons.auto_awesome_outlined,
      text: l.colorDynamicNote,
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
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Description on the left, a live preview of the current colour on
          // the right so the choice is visible without hunting the grid.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: currentColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: m3.outlineVariant),
                ),
              ),
            ],
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
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          // Wrapped in an ExpressiveField so the input carries the same
          // rounded, filled shape as the fields on the other settings pages.
          ExpressiveField(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextFormField(
              controller: hexController,
              decoration: InputDecoration(
                border: InputBorder.none,
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
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
              // The spacer ring must match the card the swatch sits in, not
              // the scaffold surface, or the selected swatch shows a halo.
              : Border.all(color: Colors.transparent, width: 2),
          boxShadow: selected
              ? [BoxShadow(color: theme.m3.surfaceContainer, spreadRadius: 3)]
              : null,
        ),
        child: selected
            ? Icon(Icons.check, size: size * 0.5, color: checkColor)
            : null,
      ),
    );
  }
}

// Preset dropdown: pick a whole named pack. Shows a small three-dot swatch of
// each preset's background, accent and foreground next to its name.
class _PresetPicker extends StatelessWidget {
  final List<ThemePreset> presets;
  final ThemePreset? selected;
  final Brightness brightness;
  final ValueChanged<ThemePreset> onSelected;
  final String title;
  final String subtitle;
  final String customLabel;

  const _PresetPicker({
    required this.presets,
    required this.selected,
    required this.brightness,
    required this.onSelected,
    required this.title,
    required this.subtitle,
    required this.customLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          ExpressiveField(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ThemePreset>(
                value: selected,
                isExpanded: true,
                dropdownColor: m3.surfaceContainerHigh,
                borderRadius: kBorderRadiusMenu,
                focusColor: Colors.transparent,
                hint: Text(
                  customLabel,
                  style: TextStyle(color: m3.onSurfaceVariant),
                ),
                items: presets
                    .map(
                      (p) => DropdownMenuItem<ThemePreset>(
                        value: p,
                        child: Row(
                          children: [
                            _PresetDots(preset: p, brightness: brightness),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: cs.onSurface),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (p) {
                  if (p != null) onSelected(p);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// The three-colour dot cluster that previews a preset in the dropdown.
class _PresetDots extends StatelessWidget {
  final ThemePreset preset;
  final Brightness brightness;
  const _PresetDots({required this.preset, required this.brightness});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).m3.outlineVariant;
    final v = preset.variantFor(brightness);
    Widget dot(Color c) => Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: outline),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot(v.bg),
        const SizedBox(width: 4),
        dot(v.accent),
        const SizedBox(width: 4),
        dot(v.iconFg),
      ],
    );
  }
}

// A font dropdown with a small in-font preview line underneath.
class _FontCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String sample;
  final String value;
  final List<String> options;
  final String Function(String) labelFor;
  final ValueChanged<String> onChanged;

  const _FontCard({
    required this.title,
    required this.subtitle,
    required this.sample,
    required this.value,
    required this.options,
    required this.labelFor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          ExpressiveField(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                dropdownColor: m3.surfaceContainerHigh,
                borderRadius: kBorderRadiusMenu,
                focusColor: Colors.transparent,
                items: options
                    .map(
                      (id) => DropdownMenuItem<String>(
                        value: id,
                        child: Text(
                          labelFor(id),
                          style: TextStyle(
                            color: cs.onSurface,
                            fontFamily: resolveChatFontFamily(id),
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null && v != value) onChanged(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          ExpressiveField(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                sample,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 14,
                  height: 1.35,
                  fontFamily: resolveChatFontFamily(value),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

