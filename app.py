from __future__ import annotations

import argparse
import csv
import json
import io
import os
import platform
import re
import shutil
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import uuid
import webbrowser
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

import cairosvg
try:
    import cv2
except ImportError:
    cv2 = None  # OpenCV optional for ColorMomentHash
import fitz
import numpy as np
from flask import Flask, flash, jsonify, redirect, render_template, request, send_file, send_from_directory, url_for
from PIL import Image, ImageFile, ImageOps
from scipy.fftpack import dct
from werkzeug.utils import secure_filename

ImageFile.LOAD_TRUNCATED_IMAGES = True
Image.MAX_IMAGE_PIXELS = None  # output resolution is explicitly controlled; suppress decompression bomb warning

APP_ROOT = Path(__file__).resolve().parent

_home = Path.home()
_sys = platform.system()
if _sys == 'Darwin':
    DATA_ROOT = _home / 'Library' / 'Caches' / 'keynotepptx' / 'jobs'
elif _sys == 'Windows':
    DATA_ROOT = Path(os.environ.get('LOCALAPPDATA', _home / 'AppData' / 'Local')) / 'keynotepptx' / 'jobs'
else:
    DATA_ROOT = Path(os.environ.get('XDG_CACHE_HOME', _home / '.cache')) / 'keynotepptx' / 'jobs'
DATA_ROOT.mkdir(parents=True, exist_ok=True)

IMAGE_EXTS = {'.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.webp', '.gif', '.svg', '.pdf'}
RASTER_EXTS = {'.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.webp', '.gif'}
PPT_RASTER_EXTS = {'.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp', '.webp'}
XML_TEXT_EXTS = {'.xml', '.rels', '.vml', '.txt'}
CONTENT_TYPE_BY_EXT = {
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.tif': 'image/tiff',
    '.tiff': 'image/tiff',
    '.gif': 'image/gif',
    '.bmp': 'image/bmp',
    '.webp': 'image/webp',
    '.pdf': 'application/pdf',
}

app = Flask(__name__)
app.secret_key = 'pptx-keynote-mapper-dev'
JOBS: dict[str, dict[str, Any]] = {}
JOBS_LOCK = threading.Lock()


def now_ts() -> float:
    return time.time()


def ext_priority(ext: str) -> int:
    ext = ext.lower()
    if ext == '.svg':
        return 0
    if ext == '.pdf':
        return 1
    if ext == '.png':
        return 2
    if ext in {'.jpg', '.jpeg'}:
        return 3
    if ext in {'.tif', '.tiff'}:
        return 4
    if ext == '.bmp':
        return 5
    if ext == '.webp':
        return 6
    if ext == '.gif':
        return 7
    return 8


def is_keynote_ignored_preview(name: str) -> bool:
    name_l = name.lower()
    if '-small-' in name_l:
        return True
    return bool(re.match(r'^st-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-\d+\.(png|jpe?g|tiff?|gif|bmp|webp)$', name_l))


def prepare_image_for_hashing(img: Image.Image) -> Image.Image:
    """Convert image to RGB, handling transparency and color mode."""
    # Handle transparency by compositing onto white background
    if img.mode in ('RGBA', 'LA') or (img.mode == 'P' and 'transparency' in img.info):
        if img.mode != 'RGBA':
            img = img.convert('RGBA')
        bg = Image.new('RGB', img.size, (255, 255, 255))
        bg.paste(img, mask=img.split()[-1])
        img = bg
    # Convert other modes to RGB (e.g., CMYK, L, P, etc.)
    elif img.mode not in ('RGB', 'L'):
        img = img.convert('RGB')
    return img

def normalize_image_dimensions(img: Image.Image, target_size: tuple[int, int] = (256, 256)) -> Image.Image:
    """Resize image to target dimensions, preserving aspect ratio, padding with white if needed."""
    # Resize to fit within target dimensions while preserving aspect ratio
    img_resized = ImageOps.contain(img, target_size, Image.Resampling.LANCZOS)

    # If image doesn't fill the target dimensions, create a white background and center the image
    if img_resized.size != target_size:
        bg = Image.new('RGB', target_size, (255, 255, 255))
        offset = ((target_size[0] - img_resized.size[0]) // 2,
                  (target_size[1] - img_resized.size[1]) // 2)
        # Ensure img_resized is RGB for pasting onto RGB background
        if img_resized.mode != 'RGB':
            img_resized = img_resized.convert('RGB')
        bg.paste(img_resized, offset)
        return bg

    # If image fills target dimensions but is not RGB, convert to RGB for consistency
    if img_resized.mode != 'RGB':
        img_resized = img_resized.convert('RGB')
    return img_resized

def ahash_from_image(img: Image.Image, hash_size: int = 8) -> str:
    """Average hash: resize, grayscale, compare to mean."""
    img = prepare_image_for_hashing(img)
    img = ImageOps.exif_transpose(img).convert('L').resize(
        (hash_size, hash_size), Image.Resampling.LANCZOS
    )
    pixels = np.asarray(img, dtype=np.float32)
    mean = np.mean(pixels)
    diff = pixels > mean
    bits = ''.join('1' if v else '0' for v in diff.flatten())
    return f'{int(bits, 2):016x}'


def phash_from_image(img: Image.Image, hash_size: int = 8, highfreq_factor: int = 4) -> str:
    """Perceptual hash using DCT."""
    img = prepare_image_for_hashing(img)
    img = ImageOps.exif_transpose(img).convert('L').resize(
        (hash_size * highfreq_factor, hash_size * highfreq_factor), Image.Resampling.LANCZOS
    )
    pixels = np.asarray(img, dtype=np.float32)
    dct_rows = dct(pixels, axis=0, norm='ortho')
    dct_full = dct(dct_rows, axis=1, norm='ortho')
    dct_low = dct_full[:hash_size, :hash_size]
    med = np.median(dct_low[1:, 1:]) if dct_low.size > 1 else dct_low[0, 0]
    diff = dct_low > med
    bits = ''.join('1' if v else '0' for v in diff.flatten())
    return f'{int(bits, 2):016x}'


def colormomenthash_from_image(img: Image.Image) -> list[float] | None:
    """Color moment hash using OpenCV's img_hash.ColorMomentHash."""
    try:
        # Prepare image for hashing (handles transparency, converts to RGB/L)
        img = prepare_image_for_hashing(img)
        # ColorMomentHash needs RGB, convert L to RGB
        if img.mode == 'L':
            img = img.convert('RGB')
        # Normalize dimensions to 256×256 for consistent hashing across formats
        img = normalize_image_dimensions(img, target_size=(256, 256))
        # PIL to numpy array (RGB)
        rgb_array = np.array(img)
        # Convert RGB to BGR for OpenCV
        bgr_array = cv2.cvtColor(rgb_array, cv2.COLOR_RGB2BGR)

        # Compute color moment hash
        hash_obj = cv2.img_hash.ColorMomentHash_create()
        hash_array = hash_obj.compute(bgr_array)
        return hash_array.flatten().tolist()
    except Exception:
        # OpenCV or img_hash not available
        return None


def hamming_hex(h1: str, h2: str) -> int:
    return (int(h1, 16) ^ int(h2, 16)).bit_count()


def colormoment_distance(h1: list[float], h2: list[float]) -> float:
    """Euclidean distance between two color moment hash arrays."""
    return float(np.linalg.norm(np.array(h1) - np.array(h2)))


def render_to_image(path: Path, max_size: int = 768, normalize_for_hashing: bool = False) -> Image.Image:
    """Render any supported image format to PIL Image.

    Args:
        path: Path to image file
        max_size: Maximum dimension (width or height) in pixels
        normalize_for_hashing: If True, output will be resized to max_size×max_size with white padding
    """
    ext = path.suffix.lower()

    if ext in RASTER_EXTS:
        img = Image.open(path)
        img.load()
    elif ext == '.svg':
        png_bytes = cairosvg.svg2png(
            url=str(path),
            output_width=max_size,
            background_color='white'
        )
        img = Image.open(io.BytesIO(png_bytes))
    elif ext == '.pdf':
        doc = fitz.open(str(path))
        page = doc.load_page(0)
        # Calculate matrix to render at max_size pixels for largest dimension
        rect = page.rect
        width_pt = rect.width
        height_pt = rect.height
        max_dim_pt = max(width_pt, height_pt)
        if max_dim_pt == 0:
            matrix = fitz.Matrix(2.5, 2.5)  # fallback
        else:
            scale = max_size / max_dim_pt
            matrix = fitz.Matrix(scale, scale)
        pix = page.get_pixmap(matrix=matrix, alpha=False)
        img = Image.open(io.BytesIO(pix.tobytes('png')))
    else:
        raise ValueError(f'Unsupported file type: {path}')

    # Normalize for hashing if requested
    if normalize_for_hashing:
        # Prepare image for hashing (handle transparency, convert to RGB/L)
        img = prepare_image_for_hashing(img)
        # Resize to fit within max_size×max_size while preserving aspect ratio
        img_resized = ImageOps.contain(img, (max_size, max_size), Image.Resampling.LANCZOS)
        # If image doesn't fill the target dimensions, create a white background and center
        if img_resized.size != (max_size, max_size):
            bg = Image.new('RGB', (max_size, max_size), (255, 255, 255))
            offset = ((max_size - img_resized.size[0]) // 2,
                      (max_size - img_resized.size[1]) // 2)
            # Ensure img_resized is RGB for pasting onto RGB background
            if img_resized.mode != 'RGB':
                img_resized = img_resized.convert('RGB')
            bg.paste(img_resized, offset)
            img = bg
        else:
            # Image fills target dimensions, ensure RGB for consistency
            if img_resized.mode != 'RGB':
                img_resized = img_resized.convert('RGB')
            img = img_resized
    else:
        # Original behavior: resize only if larger than max_size
        if max(img.size) > max_size:
            img = ImageOps.contain(img, (max_size, max_size), Image.Resampling.LANCZOS)

    return img


def save_preview(src: Path, dst: Path, max_size: tuple[int, int] = (260, 180)) -> tuple[int, int]:
    img = render_to_image(src)
    w, h = img.size
    # Handle transparency by compositing onto white background
    if img.mode in ('RGBA', 'LA') or (img.mode == 'P' and 'transparency' in img.info):
        if img.mode != 'RGBA':
            img = img.convert('RGBA')
        bg = Image.new('RGB', img.size, (255, 255, 255))
        bg.paste(img, mask=img.split()[-1])
        img = bg
    else:
        img = img.convert('RGB')
    preview = ImageOps.contain(img, max_size, Image.Resampling.LANCZOS)
    dst.parent.mkdir(parents=True, exist_ok=True)
    preview.save(dst, format='PNG')
    return w, h


def unzip(src: Path, dst: Path) -> None:
    with zipfile.ZipFile(src) as zf:
        zf.extractall(dst)


def rezip(src_dir: Path, out_file: Path) -> None:
    with zipfile.ZipFile(out_file, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(src_dir.rglob('*')):
            if path.is_file():
                zf.write(path, path.relative_to(src_dir).as_posix())


def replace_text_refs(root_dir: Path, old_name: str, new_name: str) -> list[str]:
    changed: list[str] = []
    for path in root_dir.rglob('*'):
        if not path.is_file() or path.suffix.lower() not in XML_TEXT_EXTS:
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            continue
        if old_name not in text:
            continue
        new_text = text.replace(old_name, new_name)
        if new_text != text:
            path.write_text(new_text, encoding='utf-8')
            changed.append(str(path.relative_to(root_dir)))
    return changed


def ensure_default_content_type(content_types_xml: Path, ext: str) -> None:
    ext = ext.lower().lstrip('.')
    wanted = CONTENT_TYPE_BY_EXT.get('.' + ext)
    if not wanted:
        return
    ns = {'ct': 'http://schemas.openxmlformats.org/package/2006/content-types'}
    ET.register_namespace('', ns['ct'])
    tree = ET.parse(content_types_xml)
    root = tree.getroot()
    for child in root.findall('ct:Default', ns):
        if child.attrib.get('Extension', '').lower() == ext:
            if child.attrib.get('ContentType') != wanted:
                child.attrib['ContentType'] = wanted
                tree.write(content_types_xml, encoding='utf-8', xml_declaration=True)
            return
    elem = ET.Element(f'{{{ns["ct"]}}}Default', {'Extension': ext, 'ContentType': wanted})
    inserted = False
    for idx, child in enumerate(list(root)):
        if child.tag.endswith('Override'):
            root.insert(idx, elem)
            inserted = True
            break
    if not inserted:
        root.append(elem)
    tree.write(content_types_xml, encoding='utf-8', xml_declaration=True)


def run_cmd(cmd: list[str], err_hint: str) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or err_hint)


def convert_pdf_to_svg(pdf_path: Path, svg_path: Path) -> None:
    svg_path.parent.mkdir(parents=True, exist_ok=True)
    run_cmd(['pdftocairo', '-svg', str(pdf_path), str(svg_path)], 'pdftocairo failed')
    if not svg_path.exists():
        raise RuntimeError(f'Expected SVG not created: {svg_path.name}')


def pngquant_inplace(png_path: Path) -> None:
    """Run pngquant lossy compression on a PNG in-place. Best-effort: silent on failure."""
    try:
        proc = subprocess.run(
            ['pngquant', '--force', '--quality=65-85', '--ext', '.png', '--', str(png_path)],
            capture_output=True
        )
        # pngquant exit code 98 means quality too low to quantize (original kept) — that's fine
    except FileNotFoundError:
        pass  # pngquant not installed


def convert_svg_to_png(svg_path: Path, png_path: Path, width_px: int = 2560) -> None:
    if not svg_path.exists():
        raise RuntimeError(f'Source SVG not found: {svg_path}')
    png_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ['rsvg-convert', '-w', str(width_px), '-o', str(png_path), str(svg_path)],
        capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or 'rsvg-convert failed')
    if not png_path.exists():
        raise RuntimeError(f'Expected PNG not created: {png_path.name}')
    pngquant_inplace(png_path)


def convert_pdf_to_png(pdf_path: Path, png_path: Path, width_px: int = 2560) -> None:
    png_path.parent.mkdir(parents=True, exist_ok=True)
    doc = fitz.open(str(pdf_path))
    page = doc.load_page(0)
    scale = width_px / page.rect.width
    pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=True)
    pix.save(str(png_path))
    doc.close()
    pngquant_inplace(png_path)



def convert_png_to_webp_quality_75(png_path: Path, webp_path: Path) -> None:
    with Image.open(png_path) as img:
        img.save(webp_path, format='WEBP', quality=75, method=6)

def choose_replacement_kind(ext: str) -> str:
    ext = ext.lower()
    if ext == '.svg':
        return 'svg'
    if ext == '.pdf':
        return 'pdf_to_svg'
    return 'raster'


def materialize_replacement(source_path: Path, source_ext: str, mode: str, dest_stub: Path) -> tuple[Path, str]:
    source_ext = source_ext.lower()
    mode = mode or 'vector_in_place'
    if mode == 'embed_png_600' and source_ext == '.svg':
        out = dest_stub.with_suffix('.png')
        convert_svg_to_png(source_path, out)
        return out, 'svg_to_png'
    if mode == 'embed_png_600' and source_ext == '.pdf':
        out = dest_stub.with_suffix('.png')
        convert_pdf_to_png(source_path, out)
        return out, 'pdf_to_png'
    if mode == 'embed_webp_75' and source_ext == '.svg':
        png_tmp = dest_stub.with_suffix('.png')
        out = dest_stub.with_suffix('.webp')
        convert_svg_to_png(source_path, png_tmp)
        convert_png_to_webp_quality_75(png_tmp, out)
        png_tmp.unlink(missing_ok=True)
        return out, 'svg_to_webp_75'
    if mode == 'embed_webp_75' and source_ext == '.pdf':
        png_tmp = dest_stub.with_suffix('.png')
        out = dest_stub.with_suffix('.webp')
        convert_pdf_to_png(source_path, png_tmp)
        convert_png_to_webp_quality_75(png_tmp, out)
        png_tmp.unlink(missing_ok=True)
        return out, 'pdf_to_webp_75'
    if mode == 'vector_in_place' and source_ext == '.pdf':
        out = dest_stub.with_suffix('.svg')
        convert_pdf_to_svg(source_path, out)
        return out, 'pdf_to_svg'
    out = dest_stub.with_suffix(source_ext)
    shutil.copy2(source_path, out)
    return out, choose_replacement_kind(source_ext)


def parse_keynote_slide_media(key_dir: Path) -> dict[str, list[int]]:
    """Parse Keynote IWA files to map Data/ image filenames to 1-based slide numbers.

    Requires the keynote-parser library. Returns empty dict if unavailable or on error.
    """
    try:
        from keynote_parser.codec import IWAFile
    except ImportError:
        return {}

    index_dir = key_dir / 'Index'
    data_dir = key_dir / 'Data'
    if not index_dir.exists() or not data_dir.exists():
        return {}

    def _parse_iwa(path: Path) -> dict[str, Any]:
        f = IWAFile.from_buffer(path.read_bytes())
        objs: dict[str, Any] = {}
        for chunk in f.chunks:
            for archive in chunk.archives:
                d = archive.to_dict()
                objs[d['header']['identifier']] = d
        return objs

    # Load all IWA files; track template object IDs separately to exclude from slide traversal
    all_objects: dict[str, Any] = {}
    template_obj_ids: set[str] = set()
    for iwa_path in index_dir.glob('*.iwa'):
        try:
            objs = _parse_iwa(iwa_path)
            all_objects.update(objs)
            if iwa_path.name.startswith('TemplateSlide'):
                template_obj_ids.update(objs.keys())
        except Exception:
            pass

    # Build Data/ image object-ID -> filename map (ID is the trailing number before extension)
    id_to_filename: dict[str, str] = {}
    for p in data_dir.iterdir():
        if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
            m = re.search(r'-(\d+)\.[^.]+$', p.name)
            if m:
                id_to_filename[m.group(1)] = p.name

    # Find slide order from KN.ShowArchive slideTree
    slide_order: list[str] = []
    for obj in all_objects.values():
        for o in obj.get('objects', []):
            st = o.get('slideTree', {})
            if st and 'slides' in st:
                slide_order = [s['identifier'] for s in st['slides']]
                break
        if slide_order:
            break

    if not slide_order:
        return {}

    def _collect_data_refs(obj_id: str, visited: set[str]) -> list[str]:
        if obj_id in visited or obj_id in template_obj_ids:
            return []
        visited.add(obj_id)
        obj = all_objects.get(obj_id)
        if not obj:
            return []
        refs: list[str] = []
        for msg_info in obj['header'].get('messageInfos', []):
            refs.extend(msg_info.get('dataReferences', []))
            for child_id in msg_info.get('objectReferences', []):
                refs.extend(_collect_data_refs(child_id, visited))
        return refs

    image_to_slides: dict[str, list[int]] = defaultdict(list)
    for slide_num, slide_id in enumerate(slide_order, start=1):
        for ref_id in _collect_data_refs(slide_id, set()):
            img_name = id_to_filename.get(ref_id)
            if img_name and not is_keynote_ignored_preview(img_name) and slide_num not in image_to_slides[img_name]:
                image_to_slides[img_name].append(slide_num)

    return dict(image_to_slides)


def parse_ppt_slide_media(ppt_dir: Path) -> tuple[dict[str, list[int]], set[str]]:
    """Return (slide_media, master_only_media).

    slide_media: media filename -> list of 1-based slide numbers that reference it
                 (only from ppt/slides/, not layouts/masters)
    master_only_media: media filenames referenced exclusively by slide masters or
                       slide layouts — these should be skipped entirely.
    """
    rel_ns = '{http://schemas.openxmlformats.org/package/2006/relationships}'

    def _media_names_from_rels_dir(rels_dir: Path, glob: str = '*.rels') -> set[str]:
        names: set[str] = set()
        for rels_path in sorted(rels_dir.glob(glob)):
            try:
                root = ET.parse(rels_path).getroot()
            except Exception:
                continue
            for rel in root.findall(f'{rel_ns}Relationship'):
                target = rel.attrib.get('Target', '')
                if '../media/' in target:
                    names.add(Path(target).name)
        return names

    # Media referenced by actual slide content
    slides_dir = ppt_dir / 'ppt' / 'slides'
    slide_media: dict[str, list[int]] = defaultdict(list)
    slides_rels_dir = slides_dir / '_rels'
    for slide_xml in sorted(slides_dir.glob('slide*.xml')):
        m = re.search(r'slide(\d+)\.xml$', slide_xml.name)
        slide_no = int(m.group(1)) if m else None
        rels_path = slides_rels_dir / f'{slide_xml.name}.rels'
        if not rels_path.exists():
            continue
        try:
            root = ET.parse(rels_path).getroot()
        except Exception:
            continue
        for rel in root.findall(f'{rel_ns}Relationship'):
            target = rel.attrib.get('Target', '')
            if '../media/' in target:
                slide_media[Path(target).name].append(slide_no)

    # Media referenced only by slide layouts or slide masters
    slide_content_media = set(slide_media.keys())
    master_media: set[str] = set()
    for subdir in ('slideMasters', 'slideLayouts'):
        rels_dir = ppt_dir / 'ppt' / subdir / '_rels'
        if rels_dir.exists():
            master_media.update(_media_names_from_rels_dir(rels_dir))
    master_only_media = master_media - slide_content_media

    return slide_media, master_only_media


_N_WORKERS = max(1, (os.cpu_count() or 2) - 1)


def fingerprint_paths(paths: list[Path], preview_dir: Path, kind: str, progress_cb=None, compute_hashes: bool = True) -> list[dict[str, Any]]:
    total = max(len(paths), 1)
    done = 0
    done_lock = threading.Lock()

    def _process(args: tuple[int, Path]) -> dict[str, Any]:
        nonlocal done
        idx, p = args
        row: dict[str, Any] = {'path': str(p), 'name': p.name, 'ext': p.suffix.lower(), 'bytes': p.stat().st_size, 'error': None}
        try:
            if compute_hashes:
                img = render_to_image(p, normalize_for_hashing=True)
                row['ahash'] = ahash_from_image(img)
                row['phash'] = phash_from_image(img)
                row['cmhash'] = colormomenthash_from_image(img)
                row['width'], row['height'] = img.size
            else:
                img = render_to_image(p)
                row['ahash'] = None
                row['phash'] = None
                row['cmhash'] = None
                row['width'], row['height'] = img.size
            preview_name = f'{kind}_{idx:04d}_{secure_filename(p.name)}.png'
            save_preview(p, preview_dir / preview_name)
            row['preview_name'] = preview_name
        except Exception as e:
            row.update({'ahash': None, 'phash': None, 'cmhash': None, 'width': None, 'height': None, 'preview_name': None, 'error': str(e)})
        if progress_cb:
            with done_lock:
                done += 1
                progress_cb(done / total)
        return row

    with ThreadPoolExecutor(max_workers=_N_WORKERS) as pool:
        rows = list(pool.map(_process, enumerate(paths, start=1)))
    return rows


def update_job(job_id: str, **kwargs: Any) -> None:
    with JOBS_LOCK:
        JOBS[job_id].update(kwargs)
        JOBS[job_id]['updated_at'] = now_ts()


def set_progress(job_id: str, stage: str, detail: str, percent: float) -> None:
    update_job(job_id, stage=stage, detail=detail, progress=max(0.0, min(100.0, percent)))


def load_existing_mapping(path: Path | None) -> dict[str, dict[str, Any]]:
    if not path or not path.exists():
        return {}
    out: dict[str, dict[str, Any]] = {}
    with path.open(newline='', encoding='utf-8') as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            ppt_name = (row.get('ppt_name') or '').strip()
            if ppt_name:
                out[ppt_name] = row
    return out


def add_saved_mapping_defaults(rows_for_ui: list[dict[str, Any]], prior_map: dict[str, dict[str, Any]], key_lookup: dict[str, Any], previews: Path) -> dict[str, dict[str, Any]]:
    saved_custom_lookup: dict[str, dict[str, Any]] = {}
    for row in rows_for_ui:
        prior = prior_map.get(row['ppt_name'])
        if not prior:
            continue
        selection = (prior.get('selection') or '').strip().lower()
        source_name = (prior.get('source_name') or '').strip()
        source_path_str = (prior.get('source_path') or '').strip()
        source_path = Path(source_path_str) if source_path_str else None
        source_ext = (prior.get('source_ext') or (source_path.suffix if source_path else '')).lower()
        if selection == 'skip':
            row['default_choice'] = '__skip__'
            continue
        if source_name and source_name in key_lookup:
            row['default_choice'] = source_name
            continue
        if source_path and source_path.exists():
            token = f"__saved_custom__::{row['ppt_name']}"
            preview_name = f"saved_{secure_filename(row['ppt_name'])}_{secure_filename(source_path.name)}.png"
            try:
                save_preview(source_path, previews / preview_name)
            except Exception:
                preview_name = row['ppt_preview']
            row['top_matches'] = [{
                'key_name': token,
                'display_name': source_path.name + ' (saved mapping)',
                'key_ext': source_ext,
                'distance': 'saved',
                'bytes': source_path.stat().st_size,
                'preview': preview_name,
                'replacement_kind': choose_replacement_kind(source_ext),
            }] + row['top_matches'][:2]
            row['default_choice'] = token
            saved_custom_lookup[row['ppt_name']] = {
                'source_path': str(source_path),
                'source_name': source_path.name,
                'source_ext': source_ext,
                'replacement_kind': choose_replacement_kind(source_ext),
            }
    return saved_custom_lookup


def build_mapping(job_id: str) -> None:
    job = JOBS[job_id]
    root = Path(job['root'])
    inputs = root / 'inputs'
    work = root / 'work'
    previews = root / 'previews'
    outputs = root / 'outputs'
    for d in [inputs, work, previews, outputs]:
        d.mkdir(parents=True, exist_ok=True)

    pptx_file = Path(job['pptx_file'])
    keynote_file = Path(job['keynote_file'])
    existing_mapping_file = Path(job['existing_mapping_file']) if job.get('existing_mapping_file') else None
    key_dir = work / 'key'
    ppt_dir = work / 'pptx'

    set_progress(job_id, 'unzipping', 'Unzipping Keynote package', 2)
    unzip(keynote_file, key_dir)
    set_progress(job_id, 'unzipping', 'Unzipping PowerPoint package', 6)
    unzip(pptx_file, ppt_dir)

    key_data_dir = key_dir / 'Data'
    ppt_media_dir = ppt_dir / 'ppt' / 'media'
    key_imgs = sorted([p for p in key_data_dir.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTS and not is_keynote_ignored_preview(p.name)])
    ppt_imgs = sorted([p for p in ppt_media_dir.iterdir() if p.is_file() and p.suffix.lower() in PPT_RASTER_EXTS])

    # Parse XML slide structure first (cheap) to determine which images need hash fingerprinting
    set_progress(job_id, 'parsing_xml', 'Parsing slide structure from XML', 8)
    slide_media, master_only_media = parse_ppt_slide_media(ppt_dir)
    # Drop images that belong exclusively to slide masters/layouts — we never replace those
    ppt_imgs = [p for p in ppt_imgs if p.name not in master_only_media]
    key_slide_media = parse_keynote_slide_media(key_dir)  # keynote img -> [slide_nos]

    # Build reverse: slide_no -> set of keynote image names
    key_slides_to_imgs: dict[int, set[str]] = defaultdict(set)
    for img_name, slides in key_slide_media.items():
        for s in slides:
            key_slides_to_imgs[s].add(img_name)

    key_img_names_available = {p.name for p in key_imgs}

    # Pre-classify each PPTX image: xml_exact (single keynote candidate) vs needs hash matching
    xml_exact_map: dict[str, str] = {}   # pptx_name -> keynote_name
    pptx_exact_list: list[Path] = []     # xml_exact PPTX images (preview only)
    pptx_hash_list: list[Path] = []      # images needing hash fingerprinting
    keynote_hash_needed: set[str] = set()

    for pptx_img in ppt_imgs:
        ppt_slides = slide_media.get(pptx_img.name, [])
        xml_cands: set[str] = set()
        for s in ppt_slides:
            xml_cands.update(key_slides_to_imgs.get(s, set()))
        xml_cands &= key_img_names_available

        if len(xml_cands) == 1:
            key_name = next(iter(xml_cands))
            xml_exact_map[pptx_img.name] = key_name
            pptx_exact_list.append(pptx_img)
        else:
            pptx_hash_list.append(pptx_img)
            if xml_cands:
                keynote_hash_needed.update(xml_cands)
            else:
                keynote_hash_needed.update(key_img_names_available)

    # Keynote images that are exclusively xml_exact (only needed for preview, not hashing)
    all_exact_key_names = set(xml_exact_map.values())
    key_hash_list = [p for p in key_imgs if p.name in keynote_hash_needed]
    key_preview_list = [p for p in key_imgs if p.name in all_exact_key_names and p.name not in keynote_hash_needed]

    n_key_hash = len(key_hash_list)
    n_key_prev = len(key_preview_list)
    n_ppt_hash = len(pptx_hash_list)
    n_ppt_exact = len(pptx_exact_list)

    set_progress(job_id, 'fingerprinting_keynote', f'Fingerprinting {n_key_hash} Keynote images ({n_key_prev} xml_exact, preview only)', 12)
    key_rows_hash = fingerprint_paths(key_hash_list, previews, 'key', compute_hashes=True,
                                      progress_cb=lambda x: set_progress(job_id, 'fingerprinting_keynote', f'Fingerprinting {n_key_hash} Keynote images', 12 + 22 * x))
    key_rows_prev = fingerprint_paths(key_preview_list, previews, 'key', compute_hashes=False)
    key_rows = key_rows_hash + key_rows_prev
    key_valid = [r for r in key_rows_hash if r['phash']]

    set_progress(job_id, 'fingerprinting_pptx', f'Fingerprinting {n_ppt_hash} PPTX images ({n_ppt_exact} xml_exact skipped)', 35)
    ppt_rows_hash = fingerprint_paths(pptx_hash_list, previews, 'ppt', compute_hashes=True,
                                      progress_cb=lambda x: set_progress(job_id, 'fingerprinting_pptx', f'Fingerprinting {n_ppt_hash} PPTX images', 35 + 20 * x))
    ppt_rows_prev = fingerprint_paths(pptx_exact_list, previews, 'ppt', compute_hashes=False)
    ppt_rows = ppt_rows_hash + ppt_rows_prev

    key_row_by_name = {r['name']: r for r in key_rows}
    ppt_row_by_name = {r['name']: r for r in ppt_rows}
    key_valid_by_name = {r['name']: r for r in key_valid}

    set_progress(job_id, 'comparing', 'Comparing images with multi-stage hashing', 58)

    rows_for_ui: list[dict[str, Any]] = []
    keynote_match_counts: dict[str, int] = defaultdict(int)

    # Thresholds for multi-stage filtering
    AHASH_THRESHOLD = 25
    PHASH_THRESHOLD = 7

    def _score_candidates(pool: list[dict], prow: dict) -> list[dict]:
        candidates = []
        for krow in pool:
            if prow['ahash'] is None or krow['ahash'] is None:
                candidates.append(krow)
            else:
                if hamming_hex(prow['ahash'], krow['ahash']) <= AHASH_THRESHOLD:
                    candidates.append(krow)
        if not candidates:
            candidates = pool

        filtered = []
        for krow in candidates:
            if prow['phash'] is None or krow['phash'] is None:
                filtered.append((krow, 999))
            else:
                p_dist = hamming_hex(prow['phash'], krow['phash'])
                if p_dist <= PHASH_THRESHOLD:
                    filtered.append((krow, p_dist))

        scored = []
        for krow, p_dist in filtered:
            a_dist = 999 if (prow['ahash'] is None or krow['ahash'] is None) else hamming_hex(prow['ahash'], krow['ahash'])
            cm_dist = float(p_dist) if (prow['cmhash'] is None or krow['cmhash'] is None) else colormoment_distance(prow['cmhash'], krow['cmhash'])
            scored.append({**krow, 'distance': cm_dist, 'ahash_distance': a_dist, 'phash_distance': p_dist,
                           'priority': ext_priority(krow['ext']), 'replacement_kind': choose_replacement_kind(krow['ext'])})

        if not scored:
            for krow in pool:
                p_dist = 999 if (prow['phash'] is None or krow['phash'] is None) else hamming_hex(prow['phash'], krow['phash'])
                a_dist = 999 if (prow['ahash'] is None or krow['ahash'] is None) else hamming_hex(prow['ahash'], krow['ahash'])
                scored.append({**krow, 'distance': float(p_dist), 'ahash_distance': a_dist, 'phash_distance': p_dist,
                               'priority': ext_priority(krow['ext']), 'replacement_kind': choose_replacement_kind(krow['ext'])})

        scored.sort(key=lambda r: (r['distance'], r['priority'], r['name']))
        return scored

    # Build rows in original ppt_imgs order so UI slide sequence is consistent
    total_hash = max(len(pptx_hash_list), 1)
    hash_idx = 0
    for pptx_img in ppt_imgs:
        ppt_slides = slide_media.get(pptx_img.name, [])

        if pptx_img.name in xml_exact_map:
            # XML-exact: single candidate identified from slide structure, no hashing needed
            key_name = xml_exact_map[pptx_img.name]
            krow = key_row_by_name.get(key_name, {})
            prow = ppt_row_by_name.get(pptx_img.name, {})
            keynote_match_counts[key_name] += 1
            key_ext = Path(key_name).suffix.lower()
            row = {
                'ppt_name': pptx_img.name,
                'ppt_path': str(pptx_img),
                'ppt_preview': prow.get('preview_name'),
                'ppt_width': prow.get('width'),
                'ppt_height': prow.get('height'),
                'slides': ppt_slides,
                'xml_match': True,
                'xml_exact': True,
                'top_matches': [{
                    'key_name': key_name,
                    'display_name': key_name,
                    'key_ext': key_ext,
                    'distance': 0.0,
                    'phash_distance': 0,
                    'ahash_distance': 0,
                    'bytes': int(krow.get('bytes', 0)),
                    'preview': krow.get('preview_name'),
                    'replacement_kind': choose_replacement_kind(key_ext),
                }] if krow else [],
                'default_choice': key_name if krow else '__skip__',
            }
            rows_for_ui.append(row)
            continue

        prow = ppt_row_by_name.get(pptx_img.name)
        if not prow or not prow.get('phash'):
            continue  # couldn't fingerprint

        hash_idx += 1
        xml_candidate_names: set[str] = set()
        for s in ppt_slides:
            xml_candidate_names.update(key_slides_to_imgs.get(s, set()))
        xml_pool = [key_valid_by_name[n] for n in xml_candidate_names if n in key_valid_by_name]

        xml_match = bool(xml_pool)
        scored = _score_candidates(xml_pool if xml_pool else key_valid, prow)
        top3 = scored[:3]
        if top3:
            keynote_match_counts[top3[0]['name']] += 1

        row = {
            'ppt_name': prow['name'],
            'ppt_path': prow['path'],
            'ppt_preview': prow['preview_name'],
            'ppt_width': prow['width'],
            'ppt_height': prow['height'],
            'slides': ppt_slides,
            'xml_match': xml_match,
            'xml_exact': False,
            'top_matches': [{
                'key_name': m['name'],
                'display_name': m['name'],
                'key_ext': m['ext'],
                'distance': float(m['distance']),
                'phash_distance': int(m['phash_distance']),
                'ahash_distance': int(m['ahash_distance']),
                'bytes': int(m['bytes']),
                'preview': m['preview_name'],
                'replacement_kind': m['replacement_kind'],
            } for m in top3],
            'default_choice': '__skip__' if not top3 or top3[0]['distance'] >= 10.0 else top3[0]['name'],
        }
        rows_for_ui.append(row)
        set_progress(job_id, 'comparing', f'Comparing images ({hash_idx}/{total_hash})', 58 + 35 * (hash_idx / total_hash))

    for row in rows_for_ui:
        if not row['top_matches']:
            row['quality'] = 'no_match'
            continue
        best = row['top_matches'][0]
        flags = []
        if keynote_match_counts[best['key_name']] > 1:
            flags.append('multi_map')
        if row.get('xml_exact'):
            base = 'xml_exact'
        elif row.get('xml_match'):
            base = 'xml_match'
        else:
            d = best.get('phash_distance', 999)
            if d == 0:
                base = 'exact'
            elif d <= 4:
                base = 'strong'
            elif d <= 9:
                base = 'review'
            else:
                base = 'poor'
        row['quality'] = base + (':' + ','.join(flags) if flags else '')
        row['best_match_count'] = keynote_match_counts[best['key_name']]

    key_lookup_map = {r['name']: r for r in key_rows}
    prior_map = load_existing_mapping(existing_mapping_file)
    saved_custom_lookup = add_saved_mapping_defaults(rows_for_ui, prior_map, key_lookup_map, previews) if prior_map else {}

    mapping_csv = outputs / 'initial_mapping.csv'
    with mapping_csv.open('w', newline='', encoding='utf-8') as fh:
        writer = csv.writer(fh)
        writer.writerow(['ppt_name', 'slides', 'quality', 'suggested_key_name', 'suggested_kind', 'suggested_distance', 'default_choice'])
        for row in rows_for_ui:
            top = row['top_matches'][0] if row['top_matches'] else None
            # Use phash_distance for compatibility with existing mapping files
            dist = top.get('phash_distance', top['distance'] if top else '') if top else ''
            writer.writerow([
                row['ppt_name'], ';'.join(map(str, row['slides'])), row['quality'],
                top['key_name'] if top else '', top['replacement_kind'] if top else '', dist, row['default_choice']
            ])

    update_job(job_id, status='ready', stage='ready', detail='Review mappings and confirm replacements.', progress=100.0,
               results=rows_for_ui, key_lookup=key_lookup_map, ppt_lookup={r['name']: r for r in ppt_rows},
               mapping_csv=str(mapping_csv), existing_mapping_csv=str(existing_mapping_file) if existing_mapping_file else '',
               saved_custom_lookup=saved_custom_lookup)


def start_background_build(job_id: str) -> None:
    def runner() -> None:
        try:
            build_mapping(job_id)
        except Exception as e:
            update_job(job_id, status='error', stage='error', detail=str(e), progress=100.0)
    threading.Thread(target=runner, daemon=True).start()


def create_job_from_files(pptx_file: Path, keynote_file: Path, existing_mapping_file: Path | None = None, root: Path | None = None) -> str:
    if root is None:
        job_id = uuid.uuid4().hex[:12]
        root = DATA_ROOT / job_id
    else:
        job_id = root.name
    root.mkdir(parents=True, exist_ok=True)
    with JOBS_LOCK:
        JOBS[job_id] = {
            'id': job_id, 'root': str(root), 'created_at': now_ts(), 'updated_at': now_ts(),
            'status': 'running', 'stage': 'queued', 'detail': 'Queued', 'progress': 0.0,
            'pptx_file': str(pptx_file), 'keynote_file': str(keynote_file),
            'existing_mapping_file': str(existing_mapping_file) if existing_mapping_file else '',
            'results': None, 'key_lookup': {}, 'ppt_lookup': {}, 'saved_custom_lookup': {}
        }
    start_background_build(job_id)
    return job_id


@app.route('/')
def index():
    return render_template('index.html')


@app.post('/start')
def start():
    pptx_upload = request.files.get('pptx_file')
    keynote_upload = request.files.get('keynote_file')
    mapping_upload = request.files.get('mapping_file')
    pptx_path_text = (request.form.get('pptx_path') or '').strip()
    keynote_path_text = (request.form.get('keynote_path') or '').strip()
    mapping_path_text = (request.form.get('mapping_path') or '').strip()

    if pptx_upload and keynote_upload and pptx_upload.filename and keynote_upload.filename:
        job_hex = uuid.uuid4().hex[:12]
        root = DATA_ROOT / job_hex
        inp = root / 'inputs'
        inp.mkdir(parents=True, exist_ok=True)
        pptx_path = inp / secure_filename(pptx_upload.filename)
        key_path = inp / secure_filename(keynote_upload.filename)
        pptx_upload.save(pptx_path)
        keynote_upload.save(key_path)
        mapping_path = None
        if mapping_upload and mapping_upload.filename:
            mapping_path = inp / secure_filename(mapping_upload.filename)
            mapping_upload.save(mapping_path)
        job_id = create_job_from_files(pptx_path, key_path, mapping_path, root=root)
        return redirect(url_for('review_job', job_id=job_id))

    if pptx_path_text and keynote_path_text:
        pptx_path = Path(pptx_path_text).expanduser().resolve()
        key_path = Path(keynote_path_text).expanduser().resolve()
        mapping_path = Path(mapping_path_text).expanduser().resolve() if mapping_path_text else None
        if not pptx_path.exists() or not key_path.exists() or (mapping_path and not mapping_path.exists()):
            flash('One or more input paths do not exist.')
            return redirect(url_for('index'))
        job_id = create_job_from_files(pptx_path, key_path, mapping_path)
        return redirect(url_for('review_job', job_id=job_id))

    flash('Provide either two uploads or two local file paths.')
    return redirect(url_for('index'))


@app.route('/job/<job_id>')
def review_job(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    return render_template('review.html', job_id=job_id)


@app.get('/job/<job_id>/status')
def job_status(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return jsonify({'error': 'Job not found'}), 404
    return jsonify({'id': job_id, 'status': job['status'], 'stage': job['stage'], 'detail': job['detail'], 'progress': job['progress'], 'has_results': bool(job.get('results'))})


@app.get('/job/<job_id>/results')
def job_results(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return jsonify({'error': 'Job not found'}), 404
    if job.get('status') != 'ready':
        return jsonify({'error': 'Not ready'}), 409
    return jsonify({'rows': job['results']})


@app.get('/job/<job_id>/preview/<name>')
def preview(job_id: str, name: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    return send_from_directory(Path(job['root']) / 'previews', name)



def apply_selections_to_pptx(
    pptx_file: Path,
    selections: list[dict[str, Any]],
    output_pptx: Path,
    report_csv: Path,
    patch_mode: str = 'vector_in_place',
    progress_cb=None,
) -> None:
    with tempfile.TemporaryDirectory(prefix='pptx_patch_') as td:
        td = Path(td)
        if progress_cb:
            progress_cb('preparing_patch', 'Unzipping PowerPoint package', 2.0)
        ppt_dir = td / 'pptx'
        unzip(pptx_file, ppt_dir)
        media_dir = ppt_dir / 'ppt' / 'media'
        ct_xml = ppt_dir / '[Content_Types].xml'
        actions: list[dict[str, Any]] = []
        total = max(len(selections), 1)
        label = 'Converting and embedding images' if patch_mode in {'embed_png_600', 'embed_webp_75'} else 'Embedding selected replacements'

        # Phase 1 (sequential): resolve dest_stubs so glob checks don't race.
        work: list[tuple[str, Path, Path, str, Path] | None] = []
        for row in selections:
            if row['selection'] == 'skip':
                work.append(None)
                continue
            ppt_name = row['ppt_name']
            old_media = media_dir / ppt_name
            source_path = Path(row['source_path'])
            source_ext = row['source_ext'].lower()
            dest_stub = media_dir / Path(ppt_name).stem
            # If another media file (different image, same stem, different ext) exists,
            # use a unique stub so we don't overwrite an unrelated file.
            if any(f.name != ppt_name for f in media_dir.glob(Path(ppt_name).stem + '.*')):
                dest_stub = media_dir / (Path(ppt_name).stem + '_repl')
            work.append((ppt_name, old_media, source_path, source_ext, dest_stub))

        # Phase 2 (parallel): convert + pngquant — each task writes to its own dest_stub.
        if progress_cb:
            progress_cb('embedding', f'{label} (0/{total})', 5.0)
        mat_done = 0
        mat_lock = threading.Lock()
        materialized: list[tuple[Path, str] | None] = [None] * len(work)

        def _materialize(args: tuple[int, tuple | None]) -> None:
            nonlocal mat_done
            i, item = args
            if item is None:
                return
            _, _, source_path, source_ext, dest_stub = item
            new_media, applied_kind = materialize_replacement(source_path, source_ext, patch_mode, dest_stub)
            materialized[i] = (new_media, applied_kind)
            if progress_cb:
                with mat_lock:
                    mat_done += 1
                    n = mat_done
                progress_cb('embedding', f'{label} ({n}/{total})', 5.0 + 80.0 * n / total)

        with ThreadPoolExecutor(max_workers=_N_WORKERS) as pool:
            list(pool.map(_materialize, enumerate(work)))

        # Phase 3 (sequential): XML updates — replace refs, fix aspect ratio, content types.
        for idx, (row, item, mat) in enumerate(zip(selections, work, materialized), start=1):
            ppt_name = row['ppt_name']
            if row['selection'] == 'skip':
                actions.append({'ppt_name': ppt_name, 'status': 'skipped', 'new_name': '', 'source_name': '', 'replacement_kind': '', 'patch_mode': patch_mode, 'updated_files': ''})
                continue
            _, old_media, source_path, source_ext, _ = item
            new_media, applied_kind = mat
            if old_media != new_media and old_media.exists():
                old_media.unlink()
            changed_files = replace_text_refs(ppt_dir, ppt_name, new_media.name)
            ensure_default_content_type(ct_xml, new_media.suffix.lower())
            actions.append({
                'ppt_name': ppt_name, 'status': 'ok', 'new_name': new_media.name,
                'source_name': row.get('source_name', source_path.name), 'replacement_kind': applied_kind,
                'patch_mode': patch_mode, 'updated_files': ';'.join(changed_files),
            })
        if progress_cb:
            progress_cb('writing_report', 'Writing patch report', 88.0)
        with report_csv.open('w', newline='', encoding='utf-8') as fh:
            writer = csv.DictWriter(fh, fieldnames=['ppt_name', 'status', 'new_name', 'source_name', 'replacement_kind', 'patch_mode', 'updated_files'])
            writer.writeheader()
            writer.writerows(actions)
        if progress_cb:
            progress_cb('zipping', 'Zipping patched PowerPoint', 94.0)
        rezip(ppt_dir, output_pptx)
        if progress_cb:
            progress_cb('done', 'Patched PowerPoint ready', 100.0)


def collect_selections_from_request(job: dict[str, Any]) -> list[dict[str, Any]]:
    results = job['results']
    selections: list[dict[str, Any]] = []
    custom_dir = Path(job['root']) / 'custom_uploads'
    custom_dir.mkdir(exist_ok=True)

    for row in results:
        ppt_name = row['ppt_name']
        choice = request.form.get(f'choice__{ppt_name}', '__skip__')
        if choice == '__skip__':
            selections.append({'ppt_name': ppt_name, 'selection': 'skip'})
            continue
        if choice.startswith('__saved_custom__::'):
            saved = (job.get('saved_custom_lookup') or {}).get(ppt_name)
            if saved:
                selections.append({'ppt_name': ppt_name, 'selection': 'custom_saved', **saved})
            else:
                selections.append({'ppt_name': ppt_name, 'selection': 'skip'})
            continue
        if choice == '__other__':
            upload = request.files.get(f'custom__{ppt_name}')
            if not upload or not upload.filename:
                selections.append({'ppt_name': ppt_name, 'selection': 'skip'})
                continue
            saved = custom_dir / f'{Path(ppt_name).stem}__{secure_filename(upload.filename)}'
            upload.save(saved)
            selections.append({
                'ppt_name': ppt_name, 'selection': 'custom', 'source_path': str(saved), 'source_name': saved.name,
                'source_ext': saved.suffix.lower(), 'replacement_kind': choose_replacement_kind(saved.suffix.lower())
            })
            continue
        key_meta = job['key_lookup'].get(choice)
        if not key_meta:
            selections.append({'ppt_name': ppt_name, 'selection': 'skip'})
            continue
        selections.append({
            'ppt_name': ppt_name, 'selection': 'keynote', 'source_path': key_meta['path'], 'source_name': key_meta['name'],
            'source_ext': key_meta['ext'], 'replacement_kind': choose_replacement_kind(key_meta['ext'])
        })
    return selections


def write_confirmed_mapping_csv(mapping_csv: Path, selections: list[dict[str, Any]], patch_mode: str) -> None:
    with mapping_csv.open('w', newline='', encoding='utf-8') as fh:
        writer = csv.DictWriter(fh, fieldnames=['ppt_name', 'selection', 'source_name', 'source_ext', 'replacement_kind', 'source_path', 'patch_mode'])
        writer.writeheader()
        for row in selections:
            row2 = dict(row)
            row2['patch_mode'] = patch_mode
            writer.writerow(row2)


@app.post('/job/<job_id>/prepare_apply')
def prepare_apply(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    if job.get('status') != 'ready':
        return 'Job not ready', 409
    selections = collect_selections_from_request(job)
    out_dir = Path(job['root']) / 'outputs'
    pending_json = out_dir / 'pending_selections.json'
    pending_json.write_text(json.dumps(selections, indent=2), encoding='utf-8')
    summary = {
        'total': len(selections),
        'skipped': sum(1 for s in selections if s.get('selection') == 'skip'),
        'vectors': sum(1 for s in selections if s.get('source_ext') in ('.svg', '.pdf')),
        'rasters': sum(1 for s in selections if s.get('source_ext') not in (None, '.svg', '.pdf', '')),
    }
    update_job(job_id, pending_selections=str(pending_json), pending_summary=summary)
    return redirect(url_for('patch_options', job_id=job_id))


@app.get('/job/<job_id>/patch-options')
def patch_options(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    if not job.get('pending_selections'):
        return redirect(url_for('review_job', job_id=job_id))
    return render_template('patch_options.html', job_id=job_id, job=job)


@app.post('/job/<job_id>/apply')
def apply_mapping(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    pending_path = job.get('pending_selections')
    if not pending_path:
        return redirect(url_for('review_job', job_id=job_id))
    patch_mode = (request.form.get('patch_mode') or 'vector_in_place').strip()
    out_dir = Path(job['root']) / 'outputs'
    selections = json.loads(Path(pending_path).read_text(encoding='utf-8'))

    mapping_csv = out_dir / 'confirmed_mapping.csv'
    write_confirmed_mapping_csv(mapping_csv, selections, patch_mode)

    patched_pptx = out_dir / 'patched_output.pptx'
    patch_report = out_dir / 'patch_report.csv'

    update_job(
        job_id,
        status='patching',
        stage='queued_patch',
        detail='Queued for patching.',
        progress=0.0,
        confirmed_mapping_csv=str(mapping_csv),
        patch_mode=patch_mode,
        patched_pptx='',
        patch_report='',
    )

    def runner() -> None:
        def cb(stage: str, detail: str, progress: float) -> None:
            update_job(job_id, stage=stage, detail=detail, progress=progress, status='patching')
        try:
            apply_selections_to_pptx(
                Path(job['pptx_file']),
                selections,
                patched_pptx,
                patch_report,
                patch_mode,
                progress_cb=cb,
            )
            update_job(job_id, status='patched', stage='done', detail='Patched PowerPoint ready.', progress=100.0,
                       patched_pptx=str(patched_pptx), patch_report=str(patch_report))
        except Exception as e:
            update_job(job_id, status='error', stage='error', detail=str(e), progress=100.0)

    threading.Thread(target=runner, daemon=True).start()
    return redirect(url_for('patch_progress', job_id=job_id))



@app.get('/job/<job_id>/patch-progress')
def patch_progress(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    return render_template('patch_progress.html', job_id=job_id, job=job)


@app.get('/job/<job_id>/downloads')

def downloads(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    return render_template('downloads.html', job_id=job_id, job=job)


@app.get('/job/<job_id>/download/<kind>')
def download_file(job_id: str, kind: str):
    job = JOBS.get(job_id)
    if not job:
        return 'Job not found', 404
    mapping = {'pptx': job.get('patched_pptx'), 'mapping_csv': job.get('confirmed_mapping_csv') or job.get('mapping_csv'), 'patch_report': job.get('patch_report')}
    target = mapping.get(kind)
    if not target:
        return 'File not found', 404
    return send_file(target, as_attachment=True)


def launch_browser(url: str) -> None:
    def _open() -> None:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    threading.Timer(1.0, _open).start()


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description='Flask UI for mapping PPTX media to Keynote source assets.')
    ap.add_argument('--pptx', default='')
    ap.add_argument('--keynote', default='')
    ap.add_argument('--mapping-csv', default='')
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--port', type=int, default=5000)
    ap.add_argument('--no-browser', action='store_true')
    return ap.parse_args()


def maybe_autostart_job(args: argparse.Namespace) -> str | None:
    if not args.pptx or not args.keynote:
        if not args.pptx:
            print('Autostart: --pptx argument is empty')
        if not args.keynote:
            print('Autostart: --keynote argument is empty')
        return None
    pptx = Path(args.pptx).expanduser().resolve()
    keynote = Path(args.keynote).expanduser().resolve()
    mapping = Path(args.mapping_csv).expanduser().resolve() if args.mapping_csv else None
    missing = []
    if not pptx.exists():
        missing.append(f'PPTX: {pptx}')
    if not keynote.exists():
        missing.append(f'Keynote: {keynote}')
    if mapping and not mapping.exists():
        missing.append(f'Mapping CSV: {mapping}')
    if missing:
        print('Autostart skipped: missing input path(s):')
        for m in missing:
            print(f'  {m}')
        return None
    return create_job_from_files(pptx, keynote, mapping)


if __name__ == '__main__':
    import signal
    import socket
    from wsgiref.simple_server import make_server, WSGIServer

    args = parse_args()
    job_id = maybe_autostart_job(args)
    browser_host = '127.0.0.1' if args.host == '0.0.0.0' else args.host
    url = f'http://{browser_host}:{args.port}/'
    if job_id:
        url = f'http://{browser_host}:{args.port}/job/{job_id}'
    if not args.no_browser:
        launch_browser(url)

    class ReusableServer(WSGIServer):
        allow_reuse_address = True
        def server_bind(self):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, 'SO_REUSEPORT'):
                try:
                    self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                except OSError:
                    pass
            super().server_bind()

    server = make_server(args.host, args.port, app, server_class=ReusableServer)
    signal.signal(signal.SIGTERM, lambda *_: server.shutdown())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
