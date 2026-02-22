#!/usr/bin/env python3
"""
Icon Generator for chuk_chat
Rasterizes assets/logo.svg to all required platform icon sizes.
"""

import os
import io
import cairosvg
from PIL import Image


SVG_PATH = os.path.join(os.path.dirname(__file__), "..", "assets", "logo.svg")


def render_svg(size):
    """Render logo.svg to a PIL Image at the given pixel size."""
    png_data = cairosvg.svg2png(
        url=os.path.abspath(SVG_PATH),
        output_width=size,
        output_height=size,
    )
    return Image.open(io.BytesIO(png_data)).convert("RGBA")


def save_icon(img, path):
    """Save image, creating parent dirs as needed."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print(f"  {path}")


def with_white_bg(img):
    """Composite RGBA image onto white background (for iOS/platforms that need opaque)."""
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    bg.paste(img, (0, 0), img)
    return bg.convert("RGB")


def generate_android_icons():
    """Generate Android launcher icons (mipmap) and adaptive icon layers."""
    base = "android/app/src/main/res"

    # Standard launcher icons
    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in densities.items():
        icon = render_svg(size)
        save_icon(icon, f"{base}/mipmap-{density}/ic_launcher.png")

    # Adaptive icon layers (foreground has extra padding for safe zone)
    # Canvas is 108dp per density; safe zone is center 72dp (66.67%)
    adaptive_densities = {
        "mdpi": 108,
        "hdpi": 162,
        "xhdpi": 216,
        "xxhdpi": 324,
        "xxxhdpi": 432,
    }
    for density, canvas_size in adaptive_densities.items():
        # Foreground: render logo into center ~60% of canvas (extra margin beyond safe zone)
        logo_size = int(canvas_size * 0.60)
        logo = render_svg(logo_size)
        foreground = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        offset = (canvas_size - logo_size) // 2
        foreground.paste(logo, (offset, offset), logo)
        save_icon(foreground, f"{base}/mipmap-{density}/ic_launcher_foreground.png")

        # Monochrome: same as foreground (Android uses tinting)
        save_icon(foreground, f"{base}/mipmap-{density}/ic_launcher_monochrome.png")

        # Background: transparent (Material You theming)
        background = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        save_icon(background, f"{base}/mipmap-{density}/ic_launcher_background.png")


def generate_android_notification_icons():
    """Generate Android notification icons (white silhouette on transparent)."""
    base = "android/app/src/main/res"
    densities = {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}

    for density, size in densities.items():
        icon = render_svg(size)
        # Convert to white silhouette: make all non-transparent pixels white
        pixels = icon.load()
        for y in range(size):
            for x in range(size):
                r, g, b, a = pixels[x, y]
                if a > 0:
                    pixels[x, y] = (255, 255, 255, a)
        save_icon(icon, f"{base}/drawable-{density}/ic_notification.png")


def generate_ios_icons():
    """Generate iOS app icons (opaque, white background required)."""
    base = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }

    for filename, size in sizes.items():
        icon = render_svg(size)
        icon = with_white_bg(icon)
        save_icon(icon, f"{base}/{filename}")


def generate_macos_icons():
    """Generate macOS app icons."""
    base = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    sizes = {
        "app_icon_16.png": 16,
        "app_icon_32.png": 32,
        "app_icon_64.png": 64,
        "app_icon_128.png": 128,
        "app_icon_256.png": 256,
        "app_icon_512.png": 512,
        "app_icon_1024.png": 1024,
    }

    for filename, size in sizes.items():
        icon = render_svg(size)
        icon = with_white_bg(icon)
        save_icon(icon, f"{base}/{filename}")


def generate_web_icons():
    """Generate web app icons and favicon."""
    # Main icons
    for filename, size in {"Icon-192.png": 192, "Icon-512.png": 512}.items():
        icon = render_svg(size)
        save_icon(icon, f"web/icons/{filename}")

    # Maskable icons (with padding for safe zone)
    for filename, size in {
        "Icon-maskable-192.png": 192,
        "Icon-maskable-512.png": 512,
    }.items():
        logo_size = int(size * 0.80)
        logo = render_svg(logo_size)
        canvas = Image.new("RGBA", (size, size), (255, 255, 255, 255))
        offset = (size - logo_size) // 2
        canvas.paste(logo, (offset, offset), logo)
        save_icon(canvas, f"web/icons/{filename}")

    # Favicon
    favicon = render_svg(128)
    save_icon(favicon, "web/favicon.png")


def generate_windows_icon():
    """Generate Windows .ico with multiple embedded sizes."""
    icon = render_svg(256)
    path = "windows/runner/resources/app_icon.ico"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    icon.save(
        path,
        format="ICO",
        sizes=[
            (16, 16),
            (24, 24),
            (32, 32),
            (48, 48),
            (64, 64),
            (128, 128),
            (256, 256),
        ],
    )
    print(f"  {path}")


if __name__ == "__main__":
    print("Generating icons from assets/logo.svg ...\n")

    print("Android launcher + adaptive icons:")
    generate_android_icons()

    print("\nAndroid notification icons:")
    generate_android_notification_icons()

    print("\niOS icons:")
    generate_ios_icons()

    print("\nmacOS icons:")
    generate_macos_icons()

    print("\nWeb icons + favicon:")
    generate_web_icons()

    print("\nWindows icon:")
    generate_windows_icon()

    print("\nDone. All platform icons generated from logo.svg.")
