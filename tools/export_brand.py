"""Export Nudge's open book and spark, with launcher-mask checks.

Uses the existing Pillow tooling. SVG and raster exports share one geometry.
Run: python tools/export_brand.py [--check]
"""
from pathlib import Path
import io
import math
import os
import sys
import tempfile
from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / 'assets/branding'
RES = ROOT / 'android/app/src/main/res'
LAVENDER = '#CBB6FA'
PURPLE = '#241B45'
# A symmetric, rounded book with a separate four-point spark. Both exports
# interpret these same SVG move/line/quadratic commands (32-unit canvas).
LEFT_PAGE = [
    ('M', 6, 14), ('Q', 10.5, 12, 15, 15), ('L', 15, 27),
    ('Q', 10.5, 24, 6, 25), ('Q', 5, 25, 5, 24),
    ('L', 5, 15), ('Q', 5, 14.4, 6, 14),
]
RIGHT_PAGE = [tuple([c[0]] + [32-v if i % 2 == 0 else v for i, v in enumerate(c[1:])]) for c in LEFT_PAGE]
SPARK = [
    ('M', 16, 5), ('Q', 16.6, 8.4, 19.5, 9),
    ('Q', 16.6, 9.6, 16, 13), ('Q', 15.4, 9.6, 12.5, 9),
    ('Q', 15.4, 8.4, 16, 5),
]
SHAPES = [LEFT_PAGE, RIGHT_PAGE, SPARK]


def svg():
    paths = []
    for shape in SHAPES:
        d = ' '.join(f'{c[0]} ' + ' '.join(str(v) for v in c[1:]) for c in shape)
        paths.append(f'<path fill="{LAVENDER}" d="{d} Z"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 32 32">\n'
            '<title>Nudge open book and spark</title>\n' + '\n'.join(paths) + '\n</svg>\n')


def raster(size, fraction, opaque=False):
    scale = 8
    factor = size * fraction / 22
    offset = size * (1-fraction) / 2
    mask = Image.new('L', (size*scale, size*scale))
    draw = ImageDraw.Draw(mask)
    for shape in SHAPES:
        polygon = []
        current = None
        for command in shape:
            end = command[-2:]
            if command[0] == 'Q':
                control = command[1:3]
                for step in range(1, 33):
                    t = step/32
                    polygon.append(tuple(((1-t)**2*current[j] + 2*(1-t)*t*control[j] + t*t*end[j] - 5)*factor*scale + offset*scale for j in (0, 1)))
            else:
                polygon.append(tuple(((v-5)*factor+offset)*scale for v in end))
            current = end
        draw.polygon(polygon, fill=255)
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    mark = Image.new('RGBA', (size, size), LAVENDER)
    mark.putalpha(mask)
    if opaque:
        background = Image.new('RGBA', (size, size), PURPLE)
        return Image.alpha_composite(background, mark).convert('RGB')
    return mark


def write(path, data):
    path.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent,delete=False) as f:
        f.write(data)
        temporary = Path(f.name)
    try:
        # Replace complete images atomically instead of truncating the current icon.
        os.replace(temporary,path)
    finally:
        temporary.unlink(missing_ok=True)


def png(path, image):
    output = io.BytesIO()
    image.save(output,format='PNG')
    write(path,output.getvalue())


def export():
    write(BRAND/'nudge-logo.svg',svg().encode())
    png(BRAND/'nudge-mark.png',raster(512,.75))
    png(BRAND/'nudge-icon.png',raster(1024,.60,True))
    for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
        png(RES/f'mipmap-{density}/ic_launcher.png',raster(size,.60,True))
    # A 46dp square fits fully inside the adaptive icon's central 66dp circle.
    png(RES/'drawable/nudge_foreground.png',raster(432,46/108))
    for path in (ROOT/'ios/Runner/Assets.xcassets/AppIcon.appiconset').glob('*.png'):
        with Image.open(path) as current:
            size = current.width
        png(path,raster(size,.60,True))


def check():
    paths = [BRAND/'nudge-mark.png',BRAND/'nudge-icon.png',RES/'drawable/nudge_foreground.png']
    paths += sorted(RES.glob('mipmap-*/ic_launcher.png'))
    paths += sorted((ROOT/'ios/Runner/Assets.xcassets/AppIcon.appiconset').glob('*.png'))
    for path in paths:
        with Image.open(path) as original:
            image = original.convert('RGBA')
        alpha = image.getchannel('A')
        if alpha.getextrema()[0] == 0:
            mask = alpha.point(lambda value: 255 if value >= 32 else 0)
        else:
            background = Image.new('RGB',image.size,PURPLE)
            mask = ImageChops.difference(image.convert('RGB'),background).convert('L').point(lambda value: 255 if value >= 24 else 0)
        bounds = mask.getbbox()
        assert bounds, f'Empty mark: {path}'
        cx, cy = (bounds[0]+bounds[2])/2, (bounds[1]+bounds[3])/2
        assert abs(cx-image.width/2) <= 1 and abs(cy-image.height/2) <= 1, f'Visible mark off-center: {path.name}, bounds={bounds}, canvas={image.size}'
        samples = [(x,y) for y in range(image.height) for x in range(image.width) if mask.getpixel((x,y))]
        for axis in (0,1):
            centroid = sum(p[axis] for p in samples)/len(samples)
            assert abs(centroid-(image.size[axis]-1)/2) <= (1 if axis == 0 else image.height*.12), f'Ink mass off-center: {path}'
        if path.name == 'nudge_foreground.png':
            safe_radius = image.width*33/108
            assert all(math.hypot(x+.5-image.width/2,y+.5-image.height/2) <= safe_radius for x,y in samples), 'Adaptive icon extends beyond safe circle'
        if path.name in ['nudge-icon.png','ic_launcher.png']:
            assert all(math.hypot(x+.5-image.width/2,y+.5-image.height/2) <= image.width*.46 for x,y in samples), 'Icon clipped by circular mask'
    print(f'PASS: {len(paths)} book/spark exports; centered bounds, horizontal balance and launcher masks safe.')


if __name__ == '__main__':
    if sys.argv[1:] not in ([], ['--check']):
        raise SystemExit('Usage: python tools/export_brand.py [--check]')
    if not sys.argv[1:]:
        export()
    check()
