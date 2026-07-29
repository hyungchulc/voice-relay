#!/usr/bin/env python3
from __future__ import annotations

import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
VOICE_RELAY_ROOT = ROOT.parents[1]
ICON_PATH = VOICE_RELAY_ROOT / "Resources" / "VoiceRelayIcon-1024.png"
ASSET_DIR = ROOT / "assets"
MOTION_DIR = ROOT / "motion"

SF_FONT = Path("/System/Library/Fonts/SFNS.ttf")
KOREAN_FONT = Path("/System/Library/Fonts/AppleSDGothicNeo.ttc")


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def background(width: int, height: int, accent: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (width, height), "#030406")
    pixels = image.load()
    assert pixels is not None
    centers = (
        (width * 0.52, height * 0.10, (38, 78, 165), 0.58),
        (width * 0.24, height * 0.74, (96, 38, 170), 0.38),
        (width * 0.78, height * 0.72, accent, 0.30),
        (width * 0.50, height * 0.58, (215, 130, 24), 0.12),
    )
    scale = max(width, height)
    for y in range(height):
        for x in range(width):
            r = 3.0
            g = 4.0
            b = 6.0
            for cx, cy, color, strength in centers:
                distance = math.hypot(x - cx, y - cy) / scale
                weight = math.exp(-((distance / 0.31) ** 2)) * strength
                r += color[0] * weight
                g += color[1] * weight
                b += color[2] * weight
            pixels[x, y] = (
                min(255, int(r)),
                min(255, int(g)),
                min(255, int(b)),
            )
    noise = Image.effect_noise((width, height), 10).convert("L")
    noise = noise.point(lambda value: int(value * 0.08))
    texture = Image.merge("RGB", (noise, noise, noise))
    return Image.blend(image, texture, 0.12)


def rounded_panel(
    image: Image.Image,
    bounds: tuple[int, int, int, int],
    radius: int,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int],
) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(bounds, radius=radius, fill=fill, outline=outline, width=2)
    image.alpha_composite(layer)


def place_icon(
    canvas: Image.Image,
    size: int,
    center: tuple[int, int],
    glow_radius: int = 54,
) -> None:
    icon_source = Image.open(ICON_PATH).convert("RGB")
    icon = icon_source.crop((70, 70, 954, 954)).resize(
        (size, size),
        Image.Resampling.LANCZOS,
    )
    icon_rgba = icon.convert("RGBA")
    alpha = Image.new("L", (size, size), 0)
    alpha_draw = ImageDraw.Draw(alpha)
    alpha_draw.ellipse((size * 0.08, size * 0.08, size * 0.92, size * 0.92), fill=255)
    alpha = alpha.filter(ImageFilter.GaussianBlur(max(3, size // 80)))
    icon_rgba.putalpha(alpha)
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    glow_patch = Image.new("RGBA", (size, size), (44, 111, 255, 0))
    glow_patch.putalpha(alpha.filter(ImageFilter.GaussianBlur(glow_radius)))
    left = center[0] - size // 2
    top = center[1] - size // 2
    glow.alpha_composite(glow_patch, (left, top))
    canvas.alpha_composite(glow)
    canvas.alpha_composite(icon_rgba, (left, top))


def text_center(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    value: str,
    text_font: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
    spacing: int = 8,
) -> None:
    draw.multiline_text(
        xy,
        value,
        font=text_font,
        fill=fill,
        anchor="mm",
        align="center",
        spacing=spacing,
    )


def save(image: Image.Image, name: str) -> Path:
    path = ASSET_DIR / name
    image.convert("RGB").save(path, format="PNG", optimize=True)
    return path


def square_hero() -> Path:
    width = height = 1080
    canvas = background(width, height, (19, 159, 184)).convert("RGBA")
    rounded_panel(
        canvas,
        (48, 48, width - 48, height - 48),
        48,
        (3, 6, 12, 132),
        (255, 255, 255, 24),
    )
    place_icon(canvas, 570, (width // 2, 390))
    draw = ImageDraw.Draw(canvas)
    text_center(draw, (width // 2, 735), "Voice Relay", font(SF_FONT, 88), (255, 255, 255, 255))
    text_center(
        draw,
        (width // 2, 830),
        "Voice + Codex in one persistent task",
        font(SF_FONT, 38),
        (215, 222, 235, 230),
    )
    text_center(
        draw,
        (width // 2, 958),
        "PUBLIC DEVELOPER ALPHA  ·  macOS  ·  GPLv3",
        font(SF_FONT, 24),
        (157, 171, 194, 235),
    )
    return save(canvas, "voice-relay-square-1080.png")


def threads_portrait() -> Path:
    width, height = 1080, 1350
    canvas = background(width, height, (15, 143, 118)).convert("RGBA")
    place_icon(canvas, 550, (width // 2, 380))
    rounded_panel(
        canvas,
        (64, 690, width - 64, height - 64),
        50,
        (2, 5, 10, 168),
        (255, 255, 255, 30),
    )
    draw = ImageDraw.Draw(canvas)
    text_center(
        draw,
        (width // 2, 850),
        "말로 시작하고,\n같은 Codex task에서 계속.",
        font(KOREAN_FONT, 62),
        (255, 255, 255, 255),
        spacing=18,
    )
    text_center(draw, (width // 2, 1080), "Voice Relay", font(SF_FONT, 72), (255, 255, 255, 255))
    text_center(
        draw,
        (width // 2, 1185),
        "공개 개발자 알파  ·  macOS  ·  GPLv3",
        font(KOREAN_FONT, 28),
        (176, 190, 211, 240),
    )
    return save(canvas, "voice-relay-threads-1080x1350.png")


def x_landscape() -> Path:
    width, height = 1600, 900
    canvas = background(width, height, (20, 168, 182)).convert("RGBA")
    rounded_panel(
        canvas,
        (52, 52, width - 52, height - 52),
        46,
        (2, 5, 10, 126),
        (255, 255, 255, 24),
    )
    place_icon(canvas, 700, (470, height // 2))
    draw = ImageDraw.Draw(canvas)
    draw.text((865, 270), "Voice Relay", font=font(SF_FONT, 90), fill=(255, 255, 255, 255))
    draw.multiline_text(
        (870, 405),
        "Realtime voice.\nThe same Codex task.",
        font=font(SF_FONT, 48),
        fill=(211, 220, 235, 242),
        spacing=12,
    )
    draw.text(
        (870, 664),
        "PUBLIC DEVELOPER ALPHA  ·  macOS  ·  GPLv3",
        font=font(SF_FONT, 24),
        fill=(155, 170, 194, 238),
    )
    return save(canvas, "voice-relay-x-1600x900.png")


def vertical_endcard() -> Path:
    width, height = 1080, 1920
    canvas = background(width, height, (26, 116, 194)).convert("RGBA")
    place_icon(canvas, 720, (width // 2, 720))
    draw = ImageDraw.Draw(canvas)
    text_center(draw, (width // 2, 1215), "Voice Relay", font(SF_FONT, 104), (255, 255, 255, 255))
    text_center(
        draw,
        (width // 2, 1345),
        "Public developer alpha",
        font(SF_FONT, 40),
        (216, 225, 240, 242),
    )
    rounded_panel(
        canvas,
        (120, 1530, width - 120, 1688),
        38,
        (2, 5, 10, 178),
        (255, 255, 255, 28),
    )
    text_center(
        ImageDraw.Draw(canvas),
        (width // 2, 1610),
        "github.com/hyungchulc/voice-relay",
        font(SF_FONT, 30),
        (255, 255, 255, 250),
    )
    text_center(
        ImageDraw.Draw(canvas),
        (width // 2, 1800),
        "macOS  ·  GPLv3",
        font(SF_FONT, 28),
        (155, 170, 194, 238),
    )
    return save(canvas, "voice-relay-vertical-1080x1920.png")


def motion_bumper(source: Path) -> Path:
    output = MOTION_DIR / "voice-relay-bumper-16x9-6s.mp4"
    subprocess.run(
        [
            "/opt/homebrew/bin/ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-loop",
            "1",
            "-i",
            str(source),
            "-vf",
            (
                "scale=1920:1080,"
                "zoompan=z='min(zoom+0.00022,1.035)':"
                "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':"
                "d=180:s=1920x1080:fps=30,"
                "fade=t=in:st=0:d=0.6,"
                "fade=t=out:st=5.3:d=0.7,"
                "format=yuv420p"
            ),
            "-t",
            "6",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "18",
            "-movflags",
            "+faststart",
            str(output),
        ],
        check=True,
    )
    return output


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    MOTION_DIR.mkdir(parents=True, exist_ok=True)
    outputs = [
        square_hero(),
        threads_portrait(),
        x_landscape(),
        vertical_endcard(),
    ]
    outputs.append(motion_bumper(outputs[2]))
    for output in outputs:
        print(output)


if __name__ == "__main__":
    main()
