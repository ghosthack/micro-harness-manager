"""Renders scene.js and writes every icon file the build and the app use.

Run from this directory after `npm ci`:  python3 build.py
Needs Node with Playwright's Chromium, and Python with Pillow.
"""
import os
import subprocess
import tempfile
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.dirname(HERE)
APP_ICON = os.path.join(ICONS, '..', '..', 'app', 'src', 'main', 'resources',
                        'io', 'github', 'ghosthack', 'microhm', 'app', 'ui', 'app-icon.png')
RENDER_SIZE = 2400
VIEW = '{"YAW":40,"CAM_Y":8.6,"CAM_Z":7.6}'
MARGIN = 0.06


def frame(raw: Image.Image) -> Image.Image:
    """Crops a square centred on the rendered part, with an even margin, at 1024 px."""
    alpha = raw.getchannel('A').point(lambda a: 255 if a > 8 else 0)
    left, top, right, bottom = alpha.getbbox()
    side = max(right - left, bottom - top) / (1 - 2 * MARGIN)
    cx, cy = (left + right) / 2, (top + bottom) / 2
    box = [round(v) for v in (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)]
    square = Image.new('RGBA', (round(side), round(side)), (0, 0, 0, 0))
    inside = raw.crop((max(box[0], 0), max(box[1], 0), min(box[2], raw.width), min(box[3], raw.height)))
    square.alpha_composite(inside, (max(-box[0], 0), max(-box[1], 0)))
    return square.resize((1024, 1024), Image.LANCZOS)


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        raw_path = os.path.join(tmp, 'raw.png')
        subprocess.run(['node', os.path.join(HERE, 'render.js'), raw_path, str(RENDER_SIZE), VIEW], check=True)
        master = frame(Image.open(raw_path).convert('RGBA'))

    sized = lambda s: master if s == 1024 else master.resize((s, s), Image.LANCZOS)
    master.save(os.path.join(ICONS, 'micro-harness-manager.png'), optimize=True)
    sized(256).save(APP_ICON, optimize=True)
    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    sized(256).save(os.path.join(ICONS, 'micro-harness-manager.ico'), format='ICO',
                    sizes=[(s, s) for s in ico_sizes], append_images=[sized(s) for s in ico_sizes[:-1]])
    master.save(os.path.join(ICONS, 'micro-harness-manager.icns'), format='ICNS',
                append_images=[sized(s) for s in [16, 32, 64, 128, 256, 512]])


if __name__ == '__main__':
    main()
