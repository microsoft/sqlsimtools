from pathlib import Path
import math
import sys

from PIL import Image


DURATIONS = [
    1500, 1500, 1700, 1900, 1300, 1600, 1400, 1400, 1900,
    2300, 1600, 2600, 450, 900, 2700, 1900, 2700,
]
OUTPUT_SIZE = (1440, 900)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: assemble-demo-gif.py <frame-directory> <output.gif>")

    frame_directory = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    frame_paths = sorted(frame_directory.glob("*.png"))
    if len(frame_paths) != len(DURATIONS):
        raise SystemExit(f"Expected {len(DURATIONS)} frames, found {len(frame_paths)}")

    resampling = Image.Resampling.LANCZOS
    images = []
    for frame in frame_paths:
        image = Image.open(frame).convert("RGB")
        images.append(image if image.size == OUTPUT_SIZE else image.resize(OUTPUT_SIZE, resampling))

    sample_size = (360, 225)
    sample_columns = 4
    sample_rows = math.ceil(len(images) / sample_columns)
    palette_source = Image.new("RGB", (sample_size[0] * sample_columns, sample_size[1] * sample_rows))
    for index, image in enumerate(images):
        sample = image.resize(sample_size, resampling)
        left = index % sample_columns * sample_size[0]
        top = index // sample_columns * sample_size[1]
        palette_source.paste(sample, (left, top))
    shared_palette = palette_source.quantize(colors=256, method=Image.Quantize.MEDIANCUT)

    frames = [
        image.quantize(
            palette=shared_palette,
            dither=Image.Dither.NONE,
        )
        for image in images
    ]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        output_path,
        save_all=True,
        append_images=frames[1:],
        duration=DURATIONS,
        loop=0,
        disposal=2,
        optimize=False,
    )
    print(output_path)


if __name__ == "__main__":
    main()