
# PPTX ↔ Keynote Image Mapper

A local Flask application for matching rasterized PowerPoint media back to original Keynote source assets.

## Features

- Opens a browser automatically on launch.
- Shows a live progress bar while it:
  - unzips the packages
  - fingerprints Keynote assets
  - fingerprints PPTX media
  - compares perceptual hashes
- Renders a review table for each PPT image.
- Shows the best 3 candidate matches under each row.
- Prefers SVG, else PDF-to-SVG, else higher-quality raster.
- Supports an **Other** upload per row.
- Saves a confirmed mapping CSV.
- Patches the PPTX and updates XML relationship targets.

## Install

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

System dependency for PDF-to-SVG conversion:

```bash
pdftocairo
```

On macOS this is usually available via Poppler.

## Run

With a browser opening automatically:

```bash
python app.py --pptx /path/to/PhD_Seminar.pptx --keynote "/path/to/Presentation.key"
```

Or start without auto-opening:

```bash
python app.py --no-browser
```

Then go to the URL shown in the terminal.


## New features

- Optional `confirmed_mapping.csv` input to pre-load previous choices.
- Two patch modes:
  - `vector_in_place`: keep SVG replacements as SVG and convert PDF to SVG.
  - `embed_png_600`: convert selected SVG/PDF assets to 600 DPI PNG before embedding.

Autostart example:

```bash
python app.py --pptx /path/to/file.pptx --keynote /path/to/file.key --mapping-csv /path/to/confirmed_mapping.csv
```
