# Generó el ícono 1024 original (claro, oscuro y tintado) de la app nativa de iOS, ya borrada; las rutas son las de ios/Icon/.
"""Ícono de PRBar para iPhone a partir del glifo del ícono de Mac: claro, oscuro y tintado (1024×1024, sin máscara).

Uso: python3 ios/Icon/make_icon.py  (necesita numpy y Pillow). Escribe en ios/Icon/out/; copiar los tres PNG a
ios/PRBarMobile/Resources/Assets.xcassets/AppIcon.appiconset/.
"""
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent / "out"
HERE.mkdir(exist_ok=True)
MAC_PNG = Path(tempfile.mkdtemp()) / "mac-icon.png"
subprocess.run(["sips", "-s", "format", "png", str(ROOT / "Resources" / "AppIcon.icns"), "--out", str(MAC_PNG)], check=True, capture_output=True)
S = 1024

src = np.asarray(Image.open(MAC_PNG).convert("RGBA")).astype(float)
tile = src[100:924, 100:924]
r, b = tile[..., 0], tile[..., 2]
alpha = np.clip((r - 125) / (250 - 125), 0, 1)
# Fuera del glifo: el borde claro de la baldosa de macOS no es parte del dibujo.
edge = np.zeros_like(alpha, dtype=bool)
edge[:60, :] = edge[-60:, :] = True
edge[:, :60] = edge[:, -60:] = True
alpha[edge] = 0
lavender = (b - r) > 6
glyph = np.zeros(tile.shape)
glyph[..., :3] = np.where(lavender[..., None], [241, 233, 255.0], [255, 255, 255.0])
glyph[..., 3] = alpha * 255
# El glifo ocupa un poco menos que en macOS: en iOS el ícono es a sangre y la máscara recorta las esquinas.
g_full = Image.fromarray(glyph.astype(np.uint8), "RGBA").resize((920, 920), Image.LANCZOS)
g = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g.paste(g_full, ((S - 920) // 2, (S - 920) // 2 + 6), g_full)
g.save(HERE / "glyph.png")


def grad(top, mid, bot):
    y = np.linspace(0, 1, S)[:, None]
    x = np.linspace(0, 1, S)[None, :]
    t = np.clip(0.8 * y + 0.2 * x, 0, 1)
    top, mid, bot = (np.array(c, float) for c in (top, mid, bot))
    lo = top + (mid - top) * (t / 0.5)[..., None]
    hi = mid + (bot - mid) * ((t - 0.5) / 0.5)[..., None]
    out = np.where((t < 0.5)[..., None], lo, hi)
    return Image.fromarray(out.astype(np.uint8), "RGB").convert("RGBA")


def shadow(layer, opacity=0.35, blur=16, dy=10, color=(8, 18, 90)):
    a = layer.split()[3].point(lambda v: int(v * opacity))
    sh = Image.new("RGBA", layer.size, color + (0,))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.paste(sh, (0, dy), sh)
    return out


# Claro (el de siempre)
light = grad((124, 146, 255), (45, 78, 255), (33, 56, 210))
light.alpha_composite(shadow(g))
light.alpha_composite(g)
light.convert("RGB").save(HERE / "AppIcon-1024.png")

# Oscuro: fondo casi negro, glifo azul en degradé y estrella lavanda
dark = grad((30, 32, 46), (15, 16, 26), (7, 8, 13))
arr = np.asarray(g).astype(float)
y = np.linspace(0, 1, S)[:, None]
tint = np.zeros_like(arr)
c1, c2 = np.array([160, 178, 255.0]), np.array([84, 112, 255.0])
tint[..., :3] = c1 + (c2 - c1) * y[..., None]
is_star = (arr[..., 1] < 245) & (arr[..., 3] > 0)
tint[..., :3] = np.where(is_star[..., None], [226, 214, 255.0], tint[..., :3])
tint[..., 3] = arr[..., 3]
dark.alpha_composite(Image.fromarray(tint.astype(np.uint8), "RGBA"))
dark.convert("RGB").save(HERE / "AppIcon-1024-dark.png")

# Tintado: glifo en grises sobre negro (iOS lo colorea con el tinte elegido)
tn = Image.new("RGBA", (S, S), (0, 0, 0, 255))
gw = np.zeros_like(arr)
gw[..., :3] = 255
gw[..., 3] = arr[..., 3]
tn.alpha_composite(Image.fromarray(gw.astype(np.uint8), "RGBA"))
tn.convert("L").save(HERE / "AppIcon-1024-tinted.png")


def masked(img, size):
    im = img.convert("RGBA").resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), int(size * 4 * 0.2237), fill=255)
    im.putalpha(m.resize((size, size), Image.LANCZOS))
    return im


def tinted_preview(size):
    t = Image.open(HERE / "AppIcon-1024-tinted.png").convert("L")
    col = Image.new("RGB", (S, S), (255, 196, 120))
    base = Image.new("RGB", (S, S), (34, 26, 14))
    return masked(Image.composite(col, base, t), size)


P = Image.new("RGB", (1640, 460), (236, 237, 243))
P.paste((18, 18, 24), (820, 0, 1640, 460))
for f, x in (("AppIcon-1024.png", 50), ("AppIcon-1024-dark.png", 870)):
    big = masked(Image.open(HERE / f), 300)
    P.paste(big, (x, 80), big)
    for s, dx in ((180, 340), (120, 545), (60, 690)):
        sm = masked(Image.open(HERE / f), s)
        P.paste(sm, (x + dx, 80 + (300 - s) // 2), sm)
tp = tinted_preview(120)
P.paste(tp, (870 + 545, 80 + 300 + 0 - 120 - 0), tp) if False else None
P.save(HERE / "preview.png")

T = Image.new("RGB", (420, 260), (18, 18, 24))
tp = tinted_preview(180)
T.paste(tp, (120, 40), tp)
T.save(HERE / "preview-tinted.png")
print("ok")
