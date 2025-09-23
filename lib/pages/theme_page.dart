// lib/pages/theme_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

class ThemePage extends StatefulWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;
  final bool grainEnabled;                // NEW
  final Function(bool) setGrainEnabled;   // NEW

  const ThemePage({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.grainEnabled,
    required this.setGrainEnabled,
  }) : super(key: key);

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  late Brightness _selectedThemeMode;
  late Color _selectedAccentColor;
  late Color _selectedIconFgColor;
  late Color _selectedBgColor;
  late bool _selectedGrain; // NEW

  final TextEditingController _accentHexController = TextEditingController();
  final TextEditingController _iconFgHexController = TextEditingController();
  final TextEditingController _bgHexController = TextEditingController();

  // Presets (same as your earlier file)
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
    _selectedThemeMode = widget.currentThemeMode;
    _selectedAccentColor = widget.currentAccentColor;
    _selectedIconFgColor = widget.currentIconFgColor;
    _selectedBgColor = widget.currentBgColor;
    _selectedGrain = widget.grainEnabled;

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
    widget.setThemeMode(_selectedThemeMode);
    widget.setAccentColor(_selectedAccentColor);
    widget.setIconFgColor(_selectedIconFgColor);
    widget.setBgColor(_selectedBgColor);
    widget.setGrainEnabled(_selectedGrain); // NEW
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.iconTheme.color!;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Theme Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Dark Mode
          _card(
            context,
            child: SwitchListTile(
              title: Text('Dark Mode', style: TextStyle(color: iconFg, fontWeight: FontWeight.w600)),
              subtitle: Text('Toggle between dark and light themes', style: TextStyle(color: iconFg.withValues(alpha: 0.6))),
              value: _selectedThemeMode == Brightness.dark,
              onChanged: (value) {
                setState(() {
                  _selectedThemeMode = value ? Brightness.dark : Brightness.light;
                  _selectedBgColor = _selectedThemeMode == Brightness.dark
                      ? kDefaultBgColor
                      : kDefaultBgColor.lighten(0.8);
                  _bgHexController.text = _selectedBgColor.toHexString();
                  _applyThemeChanges();
                });
              },
              activeColor: accent,
            ),
          ),
          const SizedBox(height: 24),

          // Accent Color
          _colorSection(
            title: 'Accent Color',
            description: 'Choose your primary accent color',
            currentColor: _selectedAccentColor,
            options: _accentColorOptions,
            hexController: _accentHexController,
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
                setState(() { _selectedAccentColor = c; _applyThemeChanges(); });
              } catch (_) {}
            },
            iconFg: iconFg,
            accent: accent,
            scaffoldBg: scaffoldBg,
          ),
          const SizedBox(height: 24),

          // Icon / Foreground Color
          _colorSection(
            title: 'Icon/Foreground Color',
            description: 'Choose the color for icons and key text',
            currentColor: _selectedIconFgColor,
            options: _iconFgColorOptions,
            hexController: _iconFgHexController,
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
                setState(() { _selectedIconFgColor = c; _applyThemeChanges(); });
              } catch (_) {}
            },
            iconFg: iconFg,
            accent: accent,
            scaffoldBg: scaffoldBg,
          ),
          const SizedBox(height: 24),

          // Background Color
          _colorSection(
            title: 'Background Color',
            description: 'Choose the main background color for the app',
            currentColor: _selectedBgColor,
            options: _bgColorOptions,
            hexController: _bgHexController,
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
                setState(() { _selectedBgColor = c; _applyThemeChanges(); });
              } catch (_) {}
            },
            iconFg: iconFg,
            accent: accent,
            scaffoldBg: scaffoldBg,
          ),
          const SizedBox(height: 24),

          // Film Grain
          _card(
            context,
            child: SwitchListTile(
              title: Text('Film Grain Effect', style: TextStyle(color: iconFg, fontWeight: FontWeight.w600)),
              subtitle: Text('Add a subtle shot-on-film texture', style: TextStyle(color: iconFg.withValues(alpha: 0.6))),
              value: _selectedGrain,
              onChanged: (value) {
                setState(() {
                  _selectedGrain = value;
                  _applyThemeChanges();
                });
              },
              activeColor: accent,
            ),
          ),
        ],
      ),
    );
  }

  // ----- UI helpers -----

  Widget _card(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.iconTheme.color!;
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: child,
    );
  }

  Widget _colorSection({
    required String title,
    required String description,
    required Color currentColor,
    required List<Color> options,
    required TextEditingController hexController,
    required ValueChanged<Color> onColorSelected,
    required ValueChanged<String> onHexChanged,
    required Color iconFg,
    required Color accent,
    required Color scaffoldBg,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: iconFg, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(description, style: TextStyle(color: iconFg.withValues(alpha: 0.6), fontSize: 14)),
        const SizedBox(height: 16),

        // Hex input
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: TextField(
            controller: hexController,
            decoration: InputDecoration(
              labelText: 'Custom Hex Color (#RRGGBB)',
              prefixIcon: Icon(Icons.colorize, color: iconFg.withValues(alpha: 0.7)),
              suffixIcon: IconButton(
                icon: Icon(Icons.check_circle, color: accent),
                onPressed: () => onHexChanged(hexController.text),
              ),
            ),
            onSubmitted: onHexChanged,
            keyboardType: TextInputType.text,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^[#0-9a-fA-F]+$')),
            ],
            style: TextStyle(color: iconFg),
          ),
        ),

        // Presets
        Wrap(
          spacing: 12.0,
          runSpacing: 12.0,
          children: options.map((color) {
            final bool isSelected = color.value == currentColor.value;
            return GestureDetector(
              onTap: () => onColorSelected(color),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? accent : iconFg.withValues(alpha: 0.4),
                    width: isSelected ? 3.0 : 1.0,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.5),
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 28) : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
