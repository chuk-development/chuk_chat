# App Icons - Material You Design

## Übersicht

Die App verwendet jetzt **Material You-kompatible Icons**:

- ✅ Transparenter Hintergrund (keine weiße Fläche)
- ✅ Saubere, prominente schwarze Linien
- ✅ Größeres, besser sichtbares Design
- ✅ Android Adaptive Icon Support
- ✅ Neural Network Symbol in Chat-Bubble (zeigt AI-Funktionalität)

## Icon-Design

Das Icon zeigt:
- **Chat-Bubble** (Sprechblase mit abgerundeten Ecken und Tail)
- **Neural Network Symbol** (zentrale Node mit 4 verbundenen Nodes)
- Repräsentiert perfekt: AI + Chat = chuk.chat

## Generierte Icons

Das `generate_icons.py` Script erstellt automatisch:

### Android
- **Launcher Icons**: mdpi, hdpi, xhdpi, xxhdpi, xxxhdpi (48-192px)
- **Adaptive Icons**: Foreground + Background für Material You Support
- **Adaptive Icon XML**: `mipmap-anydpi-v26/ic_launcher.xml`

### iOS
- Alle benötigten Größen von 20x20@1x bis 1024x1024@1x
- Automatisch platziert in `ios/Runner/Assets.xcassets/AppIcon.appiconset/`

### Web
- Icon-192.png
- Icon-512.png
- Icon-maskable-192.png
- Icon-maskable-512.png

## Icons neu generieren

Falls du das Icon-Design ändern möchtest:

```bash
# Icons neu generieren
python3 generate_icons.py
```

Das Script verwendet:
- **PIL (Pillow)** für Icon-Generierung
- Parametrierbare Linienstärke und Padding
- Alle Größen werden automatisch skaliert

## Android Adaptive Icon

Die App verwendet Android Adaptive Icons (API 26+):

**Struktur:**
```
android/app/src/main/res/
├── mipmap-anydpi-v26/
│   └── ic_launcher.xml          # Adaptive Icon Definition
├── mipmap-mdpi/
│   ├── ic_launcher.png          # Legacy Icon
│   ├── ic_launcher_foreground.png
│   └── ic_launcher_background.png
├── mipmap-hdpi/
│   └── ...
└── ...
```

**Vorteile:**
- Passt sich verschiedenen Launcher-Stilen an (rund, quadratisch, etc.)
- Material You Theming Support (Android 12+)
- Monochrome Icon Support für themed icons
- Bessere Sichtbarkeit auf verschiedenen Wallpaper-Farben

## Material You Features

Das Icon unterstützt:

1. **Adaptive Shapes**: System formt das Icon automatisch (rund/quadratisch/squircle)
2. **Themed Icons**: Android 13+ kann Monochrome-Version nutzen
3. **Dynamic Color**: Hintergrund passt sich dem System-Theme an
4. **Legacy Fallback**: Ältere Android-Versionen nutzen Standard-PNG

## Icon-Customization

Du kannst das Icon-Design im `generate_icons.py` anpassen:

```python
# Linienstärke ändern
line_width_ratio=0.06  # Dünner: 0.04, Dicker: 0.08

# Padding ändern
padding_ratio=0.10     # Mehr Padding: 0.15, Weniger: 0.05

# Node-Größe ändern (im Code)
node_radius = int(size * 0.035)  # Größer: 0.045, Kleiner: 0.025
```

Dann neu generieren:
```bash
python3 generate_icons.py
```

## Build Integration

Die Icons werden automatisch beim Build verwendet:

```bash
./build.sh apk      # Android APK mit neuen Icons
./build.sh linux    # Linux mit neuen Icons (Desktop-Integration)
```

## Verifikation

Die Icons wurden erfolgreich generiert und getestet:
- ✅ Android: Adaptive Icon funktioniert
- ✅ iOS: Alle Größen vorhanden
- ✅ Web: PWA Icons vorhanden
- ✅ Transparenter Hintergrund: ✓
- ✅ Material You kompatibel: ✓
