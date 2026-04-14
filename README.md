# Keynote → PPTX Image Replacer

A local web app that replaces low-quality raster images in a PowerPoint file with the original high-quality assets from the Keynote source file it was exported from.

When Keynote exports to `.pptx`, vector graphics (PDF/SVG) and high-resolution images become downsampled rasters. This tool matches each PPTX media file back to its Keynote original using slide structure (XML) and perceptual image hashing, then patches the PPTX in place.

---

## How it works

1. Both files are unzipped and their media inventories are parsed.
2. Keynote's internal protobuf (`.iwa`) files are decoded to map each image to its slide number.
3. PPTX slide relationship XML is parsed to do the same on the PowerPoint side.
4. Images that can be matched exactly by slide structure skip fingerprinting entirely.
5. Remaining images are fingerprinted in parallel (ahash → phash → ColorMoment distance).
6. A review UI lets you confirm, override, or skip each match.
7. The confirmed replacements are embedded into a patched `.pptx` output.

Slide master and layout images are excluded — only content slide images are replaced.

---

## Requirements

### System dependencies

Install these before the Python packages.

**macOS (Homebrew):**

```bash
brew install librsvg pngquant poppler
```

| Tool | Purpose |
|---|---|
| `rsvg-convert` (librsvg) | SVG → PNG conversion |
| `pngquant` | Lossy PNG compression after conversion |
| `pdftocairo` (poppler) | PDF → SVG (vector_in_place mode) |

---

## Install

### With uv (recommended)

[uv](https://docs.astral.sh/uv/) installs the tool globally and makes `keynotepptx` available as a command:

```bash
uv tool install /path/to/keynotepptx
```

Or install directly from the project directory:

```bash
cd /path/to/keynotepptx
uv tool install .
```

Then run from anywhere:

```bash
keynotepptx --pptx presentation.pptx --keynote presentation.key
```

To update after pulling changes:

```bash
uv tool install --reinstall .
```

### With pip / venv

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install .
keynotepptx --pptx presentation.pptx --keynote presentation.key
```

---

## Running

### Basic usage

```bash
keynotepptx --pptx /path/to/presentation.pptx --keynote /path/to/presentation.key
```

A browser tab opens automatically at `http://127.0.0.1:5100`. Press **Ctrl-C** to stop.

If `--pptx` and `--keynote` are omitted, the web UI lets you upload both files on the start page.

### All options

| Flag | Default | Description |
|---|---|---|
| `--pptx` | — | Path to the PowerPoint file |
| `--keynote` | — | Path to the Keynote file |
| `--mapping-csv` | — | Pre-load a confirmed mapping CSV from a previous run |
| `--host` | `127.0.0.1` | Host to bind the server to |
| `--port` | `5100` | Port to bind the server to |
| `--no-browser` | off | Don't open a browser tab on start |

### Re-using a previous mapping

After patching, a `confirmed_mapping.csv` is saved alongside the output PPTX. Pass it back on the next run to pre-populate all review choices:

```bash
keynotepptx \
  --pptx /path/to/presentation.pptx \
  --keynote /path/to/presentation.key \
  --mapping-csv /path/to/confirmed_mapping.csv
```

---

## Patch modes

After reviewing image matches, choose how replacements are embedded:

| Mode | Description |
|---|---|
| **Embed vector images** | SVG files are embedded directly. PDF replacements are converted to SVG first. |
| **Embed as high quality PNG** | SVG/PDF replacements are rasterised to PNG at 2560 px wide using `rsvg-convert` / PyMuPDF, then compressed with `pngquant`. |
| **Embed as WEBP quality 75** | Same as PNG but converted to WebP at quality 75 for smaller file sizes. |

Raster replacements (PNG, JPEG, TIFF) are embedded as-is regardless of mode. Transparency is preserved in all modes.

---

## Output

The patched file is downloaded automatically from the browser when processing completes. A CSV report listing every replacement (or skip) is also available for download.
