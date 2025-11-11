#!/usr/bin/env python3
"""
Material You Icon Generator for chuk_chat
Creates transparent icons with prominent lines (no background)
"""

from PIL import Image, ImageDraw
import os

def draw_chat_brain_icon(size, line_width_ratio=0.08, padding_ratio=0.05):
    """
    Draw a chat bubble with brain icon (Material You style)
    - Transparent background
    - Clean, prominent lines
    - Larger, more visible design
    - No filled shapes, just outlines
    """
    # Create transparent image
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Calculate dimensions (thicker lines, less padding for bigger icon)
    line_width = max(4, int(size * line_width_ratio))
    padding = int(size * padding_ratio)

    # Chat bubble dimensions (larger than before)
    bubble_left = padding
    bubble_top = padding
    bubble_right = size - padding
    bubble_bottom = int(size * 0.75)

    # Draw chat bubble (rounded rectangle)
    corner_radius = int(size * 0.15)
    draw.rounded_rectangle(
        [bubble_left, bubble_top, bubble_right, bubble_bottom],
        radius=corner_radius,
        outline='#000000',
        width=line_width
    )

    # Draw chat tail (lines forming a small triangle at bottom left)
    tail_size = int(size * 0.10)
    tail_x = bubble_left + int(tail_size * 0.5)
    tail_y = size - padding - int(tail_size * 0.3)

    # Left line of tail
    draw.line(
        [(bubble_left, bubble_bottom - 2), (tail_x, tail_y)],
        fill='#000000',
        width=line_width
    )
    # Right line of tail
    draw.line(
        [(tail_x, tail_y), (bubble_left + tail_size, bubble_bottom - 2)],
        fill='#000000',
        width=line_width
    )

    # Brain/AI symbol design inside bubble (simplified circuit/neural network style)
    brain_padding = int(size * 0.22)
    brain_left = brain_padding
    brain_right = size - brain_padding
    brain_top = bubble_top + int(size * 0.14)
    brain_bottom = bubble_bottom - int(size * 0.14)
    brain_center_x = (brain_left + brain_right) // 2
    brain_center_y = (brain_top + brain_bottom) // 2

    brain_width = brain_right - brain_left
    brain_height = brain_bottom - brain_top

    # Neural network / circuit board style design
    # Central vertical line
    draw.line(
        [brain_center_x, brain_top, brain_center_x, brain_bottom],
        fill='#000000',
        width=line_width
    )

    # Left nodes and connections
    node_radius = int(size * 0.035)

    # Top left node
    top_left_x = brain_left + int(brain_width * 0.15)
    top_left_y = brain_top + int(brain_height * 0.2)
    draw.ellipse(
        [top_left_x - node_radius, top_left_y - node_radius,
         top_left_x + node_radius, top_left_y + node_radius],
        outline='#000000',
        width=line_width
    )
    draw.line([top_left_x + node_radius, top_left_y, brain_center_x, brain_center_y],
              fill='#000000', width=line_width)

    # Bottom left node
    bottom_left_x = brain_left + int(brain_width * 0.15)
    bottom_left_y = brain_bottom - int(brain_height * 0.2)
    draw.ellipse(
        [bottom_left_x - node_radius, bottom_left_y - node_radius,
         bottom_left_x + node_radius, bottom_left_y + node_radius],
        outline='#000000',
        width=line_width
    )
    draw.line([bottom_left_x + node_radius, bottom_left_y, brain_center_x, brain_center_y],
              fill='#000000', width=line_width)

    # Right nodes and connections
    # Top right node
    top_right_x = brain_right - int(brain_width * 0.15)
    top_right_y = brain_top + int(brain_height * 0.2)
    draw.ellipse(
        [top_right_x - node_radius, top_right_y - node_radius,
         top_right_x + node_radius, top_right_y + node_radius],
        outline='#000000',
        width=line_width
    )
    draw.line([brain_center_x, brain_center_y, top_right_x - node_radius, top_right_y],
              fill='#000000', width=line_width)

    # Bottom right node
    bottom_right_x = brain_right - int(brain_width * 0.15)
    bottom_right_y = brain_bottom - int(brain_height * 0.2)
    draw.ellipse(
        [bottom_right_x - node_radius, bottom_right_y - node_radius,
         bottom_right_x + node_radius, bottom_right_y + node_radius],
        outline='#000000',
        width=line_width
    )
    draw.line([brain_center_x, brain_center_y, bottom_right_x - node_radius, bottom_right_y],
              fill='#000000', width=line_width)

    # Center node (larger)
    center_node_radius = int(node_radius * 1.3)
    draw.ellipse(
        [brain_center_x - center_node_radius, brain_center_y - center_node_radius,
         brain_center_x + center_node_radius, brain_center_y + center_node_radius],
        outline='#000000',
        width=line_width
    )

    return img

def generate_android_icons():
    """Generate Android launcher icons (mipmap)"""
    sizes = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192
    }

    base_path = 'android/app/src/main/res'

    for density, size in sizes.items():
        icon = draw_chat_brain_icon(size)
        output_path = f'{base_path}/mipmap-{density}/ic_launcher.png'
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        icon.save(output_path)
        print(f'✓ Generated {output_path}')

def generate_ios_icons():
    """Generate iOS app icons"""
    sizes = {
        'Icon-App-20x20@1x.png': 20,
        'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58,
        'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40,
        'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }

    base_path = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'

    for filename, size in sizes.items():
        icon = draw_chat_brain_icon(size)
        # iOS requires opaque background for app icons
        if size == 1024:
            # App Store icon needs white background
            bg = Image.new('RGBA', (size, size), (255, 255, 255, 255))
            bg.paste(icon, (0, 0), icon)
            icon = bg
        output_path = f'{base_path}/{filename}'
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        icon.save(output_path)
        print(f'✓ Generated {output_path}')

def generate_web_icons():
    """Generate web app icons"""
    sizes = {
        'Icon-192.png': 192,
        'Icon-512.png': 512,
        'Icon-maskable-192.png': 192,
        'Icon-maskable-512.png': 512,
    }

    base_path = 'web/icons'

    for filename, size in sizes.items():
        icon = draw_chat_brain_icon(size)
        output_path = f'{base_path}/{filename}'
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        icon.save(output_path)
        print(f'✓ Generated {output_path}')

def generate_adaptive_icon():
    """Generate Android Adaptive Icon (foreground + background)"""
    # Foreground: 108dp x 108dp (safe area is center 72dp)
    # We generate at 432px (108dp * 4 for xxxhdpi)
    size = 432

    # Foreground (transparent, just the icon - less padding for bigger appearance)
    foreground = draw_chat_brain_icon(size, padding_ratio=0.12)
    fg_path = 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png'
    os.makedirs(os.path.dirname(fg_path), exist_ok=True)
    foreground.save(fg_path)
    print(f'✓ Generated {fg_path}')

    # Background (transparent for true Material You theming)
    background = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    bg_path = 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_background.png'
    background.save(bg_path)
    print(f'✓ Generated {bg_path}')

    # Generate for other densities
    densities = {
        'mdpi': 108,
        'hdpi': 162,
        'xhdpi': 216,
        'xxhdpi': 324,
    }

    for density, sz in densities.items():
        fg = draw_chat_brain_icon(sz, padding_ratio=0.12)
        fg.save(f'android/app/src/main/res/mipmap-{density}/ic_launcher_foreground.png')

        bg = Image.new('RGBA', (sz, sz), (0, 0, 0, 0))
        bg.save(f'android/app/src/main/res/mipmap-{density}/ic_launcher_background.png')
        print(f'✓ Generated adaptive icons for {density}')

if __name__ == '__main__':
    print('🎨 Generating Material You icons for chuk_chat...\n')

    print('📱 Android icons (mipmap)...')
    generate_android_icons()

    print('\n📱 Android adaptive icons...')
    generate_adaptive_icon()

    print('\n🍎 iOS icons...')
    generate_ios_icons()

    print('\n🌐 Web icons...')
    generate_web_icons()

    print('\n✅ All icons generated successfully!')
    print('   Icons have:')
    print('   - Transparent background')
    print('   - Prominent black lines')
    print('   - Material You adaptive icon support')
    print('   - Larger, more visible design')
