// lib/pages/theme_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/utils/color_extensions.dart'; // For ColorExtension

class ThemePage extends StatefulWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor; // Now also passed for editing
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor; // New callback

  const ThemePage({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor, // New
  }) : super(key: key);

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  late Brightness _selectedThemeMode;
  late Color _selectedAccentColor;
  late Color _selectedIconFgColor;
  late Color _selectedBgColor; // New

  final TextEditingController _accentHexController = TextEditingController();
  final TextEditingController _iconFgHexController = TextEditingController();
  final TextEditingController _bgHexController = TextEditingController(); // New

  // Predefined color options for easy selection
  final List<Color> _accentColorOptions = [
    kDefaultAccentColor, // Default
    Colors.deepPurple,
    Colors.teal,
    Colors.blue,
    Colors.orange,
  ];

  final List<Color> _iconFgColorOptions = [
    kDefaultIconFgColor, // Default
    Colors.lightGreen,
    Colors.cyan,
    Colors.pinkAccent,
    Colors.amber,
  ];

  final List<Color> _bgColorOptions = [
    kDefaultBgColor, // Default dark
    kDefaultBgColor.lighten(0.8), // A predefined light option
    Colors.black87,
    Colors.blueGrey.shade900,
    Colors.deepPurple.shade900,
    Colors.white,
    Colors.grey.shade100,
    Colors.blue.shade50,
  ];


  @override
  void initState() {
    super.initState();
    _selectedThemeMode = widget.currentThemeMode;
    _selectedAccentColor = widget.currentAccentColor;
    _selectedIconFgColor = widget.currentIconFgColor;
    _selectedBgColor = widget.currentBgColor; // Initialize with current background color

    _accentHexController.text = _selectedAccentColor.toHexString();
    _iconFgHexController.text = _selectedIconFgColor.toHexString();
    _bgHexController.text = _selectedBgColor.toHexString(); // Initialize hex controller
  }

  @override
  void dispose() {
    _accentHexController.dispose();
    _iconFgHexController.dispose();
    _bgHexController.dispose(); // Dispose new controller
    super.dispose();
  }

  // This method applies changes to the parent and saves them to SharedPreferences
  void _applyThemeChanges() {
    widget.setThemeMode(_selectedThemeMode);
    widget.setAccentColor(_selectedAccentColor);
    widget.setIconFgColor(_selectedIconFgColor);
    widget.setBgColor(_selectedBgColor); // Apply background color change
  }

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically for UI elements on this page
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final TextStyle? titleTextStyle = Theme.of(context).appBarTheme.titleTextStyle;

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
          // Theme Mode Toggle
          Card(
            color: scaffoldBg.lighten(0.05),
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: iconFg.withOpacity(0.3), width: 1),
            ),
            child: SwitchListTile(
              title: Text(
                'Dark Mode',
                style: TextStyle(color: iconFg, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Toggle between dark and light themes',
                style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
              ),
              value: _selectedThemeMode == Brightness.dark,
              onChanged: (bool value) {
                setState(() {
                  _selectedThemeMode = value ? Brightness.dark : Brightness.light;
                  // When theme mode changes, also set a default background color
                  // that aligns with the chosen brightness, but allow override by explicit
                  // background color selection.
                  _selectedBgColor = _selectedThemeMode == Brightness.dark
                      ? kDefaultBgColor
                      : kDefaultBgColor.lighten(0.8);
                  _bgHexController.text = _selectedBgColor.toHexString();
                  _applyThemeChanges(); // Apply theme changes immediately
                });
              },
              activeColor: accent,
              inactiveTrackColor: iconFg.withOpacity(0.3),
              tileColor: scaffoldBg.lighten(0.05),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
          const SizedBox(height: 24),

          // Accent Color Selection
          _buildColorSelectionSection(
            title: 'Accent Color',
            description: 'Choose your primary accent color',
            currentColor: _selectedAccentColor,
            options: _accentColorOptions,
            onColorSelected: (color) {
              setState(() {
                _selectedAccentColor = color;
                _accentHexController.text = color.toHexString();
                _applyThemeChanges();
              });
            },
            hexController: _accentHexController,
            onHexChanged: (hex) {
              try {
                final color = ColorExtension.fromHexString(hex);
                setState(() {
                  _selectedAccentColor = color;
                  _applyThemeChanges();
                });
              } catch (e) {
                print('Invalid accent hex: $hex');
              }
            },
            contextBgColor: scaffoldBg,
            contextAccentColor: accent,
            contextIconFgColor: iconFg,
          ),
          const SizedBox(height: 24),

          // Icon/Foreground Color Selection
          _buildColorSelectionSection(
            title: 'Icon/Foreground Color',
            description: 'Choose the color for icons and key text',
            currentColor: _selectedIconFgColor,
            options: _iconFgColorOptions,
            onColorSelected: (color) {
              setState(() {
                _selectedIconFgColor = color;
                _iconFgHexController.text = color.toHexString();
                _applyThemeChanges();
              });
            },
            hexController: _iconFgHexController,
            onHexChanged: (hex) {
              try {
                final color = ColorExtension.fromHexString(hex);
                setState(() {
                  _selectedIconFgColor = color;
                  _applyThemeChanges();
                });
              } catch (e) {
                print('Invalid iconFg hex: $hex');
              }
            },
            contextBgColor: scaffoldBg,
            contextAccentColor: accent,
            contextIconFgColor: iconFg,
          ),
          const SizedBox(height: 24),

          // Background Color Selection (NEW SECTION)
          _buildColorSelectionSection(
            title: 'Background Color',
            description: 'Choose the main background color for the app',
            currentColor: _selectedBgColor,
            options: _bgColorOptions,
            onColorSelected: (color) {
              setState(() {
                _selectedBgColor = color;
                _bgHexController.text = color.toHexString();
                _applyThemeChanges();
              });
            },
            hexController: _bgHexController,
            onHexChanged: (hex) {
              try {
                final color = ColorExtension.fromHexString(hex);
                setState(() {
                  _selectedBgColor = color;
                  _applyThemeChanges();
                });
              } catch (e) {
                print('Invalid background hex: $hex');
              }
            },
            contextBgColor: scaffoldBg,
            contextAccentColor: accent,
            contextIconFgColor: iconFg,
          ),
        ],
      ),
    );
  }

  Widget _buildColorSelectionSection({
    required String title,
    required String description,
    required Color currentColor,
    required List<Color> options,
    required ValueChanged<Color> onColorSelected,
    required TextEditingController hexController,
    required ValueChanged<String> onHexChanged,
    required Color contextBgColor,
    required Color contextAccentColor,
    required Color contextIconFgColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
              color: contextIconFgColor,
              fontSize: 18,
              fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(color: contextIconFgColor.lighten(0.3), fontSize: 14),
        ),
        const SizedBox(height: 16),
        // Hex input field
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: TextField(
            controller: hexController,
            decoration: InputDecoration(
              labelText: 'Custom Hex Color (#RRGGBB)',
              prefixIcon: Icon(Icons.colorize, color: contextIconFgColor.withOpacity(0.7)),
              labelStyle: TextStyle(color: contextIconFgColor.withOpacity(0.8)),
              suffixIcon: IconButton(
                icon: Icon(Icons.check_circle, color: contextAccentColor),
                onPressed: () => onHexChanged(hexController.text),
              ),
            ),
            onSubmitted: onHexChanged,
            keyboardType: TextInputType.text,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^[#0-9a-fA-F]+$')),
            ],
            style: TextStyle(color: contextIconFgColor),
          ),
        ),

        // Predefined color options
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
                    color: isSelected ? contextAccentColor : contextIconFgColor.withOpacity(0.4),
                    width: isSelected ? 3.0 : 1.0,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: color.withOpacity(0.5),
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: isSelected
                    ? Icon(Icons.check, color: Colors.white, size: 28)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}