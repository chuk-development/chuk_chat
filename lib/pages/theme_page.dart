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
  late bool _selectedGrain;

  final TextEditingController _accentHexController = TextEditingController();
  final TextEditingController _iconFgHexController = TextEditingController();
  final TextEditingController _bgHexController = TextEditingController();

  // Preset swatches preserved byte-for-byte from the prior version.
  final List<Color> _accentColorOptions = [
    kDefaultAccentColor,
    Colors.deepPurple,
    Colors.teal,
    Colors.blue,
    Colors.orange,
  ];

  final List<Color> _iconFgColorOptions = [
    kDefaultIconFgColor,
    Colors.lightGreen,
    Colors.cyan,
    Colors.pinkAccent,
    Colors.amber,
  ];

  final List<Color> _bgColorOptions = [
    kDefaultBgColor,
    kDefaultBgColor.lighten(0.8),
    Colors.black87,
    Colors.blueGrey,
    Colors.deepPurple,
    Colors.white,
    Colors.grey,
    Colors.blue.shade50,
  ];

  @override
  void initState() {
    super.initState();
    _selectedThemeMode = widget.config.currentThemeMode;
    _selectedAccentColor = widget.config.currentAccentColor;
    _selectedIconFgColor = widget.config.currentIconFgColor;
    _selectedBgColor = widget.config.currentBgColor;
    _selectedGrain = widget.config.grainEnabled;

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
    widget.config.setGrainEnabled(_selectedGrain);
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

  void _updateGrainEnabled(bool enabled) {
    setState(() {
      _selectedGrain = enabled;
      _applyThemeChanges();
    });
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
          // Mode section: dark toggle + film grain grouped in one card.
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
                icon: Icons.blur_on_outlined,
                title: l.filmGrainEffect,
                subtitle: l.filmGrainSubtitle,
                value: _selectedGrain,
                onChanged: _updateGrainEnabled,
              ),
            ],
          ),
          const SizedBox(height: 24),

          _SectionHeader(l.accentColor),
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
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
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
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
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
              final size =
                  (constraints.maxWidth - totalSpacing) / gridColumns;
              final swatchSize = size.clamp(32.0, 40.0);
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: options
                    .map((c) => _Swatch(
                          color: c,
                          selected: c == currentColor,
                          size: swatchSize,
                          onTap: () => onColorSelected(c),
                        ))
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
              prefixIcon:
                  Icon(Icons.colorize_outlined, color: m3.onSurfaceVariant),
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
        ],
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
    final checkColor = ThemeData.estimateBrightnessForColor(color) ==
            Brightness.dark
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
              ? [
                  BoxShadow(
                    color: cs.surface,
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
        child: selected
            ? Icon(Icons.check, size: size * 0.5, color: checkColor)
            : null,
      ),
    );
  }
}
