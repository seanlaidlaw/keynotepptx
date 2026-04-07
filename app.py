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
import uuid
import webbrowser
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

import cairosvg
import fitz
import numpy as np
from flask import Flask, flash, jsonify, redirect, render_template, request, send_file, send_from_directory, url_for
from PIL import Image, ImageFile, ImageOps
from scipy.fftpack import dct
from werkzeug.utils import secure_filename

ImageFile.LOAD_TRUNCATED_IMAGES = True

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


def phash_from_image(img: Image.Image, hash_size: int = 8, highfreq_factor: int = 4) -> str:
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


def hamming_hex(h1: str, h2: str) -> int:
    return (int(h1, 16) ^ int(h2, 16)).bit_count()


def render_to_image(path: Path, max_size: int = 768) -> Image.Image:
    ext = path.suffix.lower()
    if ext in RASTER_EXTS:
        img = Image.open(path)
        img.load()
        return img
    if ext == '.svg':
        png_bytes = cairosvg.svg2png(url=str(path), output_width=max_size, output_height=max_size)
        return Image.open(io.BytesIO(png_bytes))
    if ext == '.pdf':
        doc = fitz.open(str(path))
        page = doc.load_page(0)
        pix = page.get_pixmap(matrix=fitz.Matrix(2.5, 2.5), alpha=False)
        return Image.open(io.BytesIO(pix.tobytes('png')))
    raise ValueError(f'Unsupported file type: {path}')


def save_preview(src: Path, dst: Path, max_size: tuple[int, int] = (260, 180)) -> tuple[int, int]:
    img = render_to_image(src)
    w, h = img.size
    preview = ImageOps.contain(img.convert('RGB'), max_size, Image.Resampling.LANCZOS)
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


def convert_svg_to_png_600(svg_path: Path, png_path: Path) -> None:
    if not svg_path.exists():
        raise RuntimeError(f'Source SVG not found: {svg_path}')
    png_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([
        'inkscape', str(svg_path), '--export-type=png', '--export-area-drawing', '--export-area-snap',
        '--export-width=6144', '--export-dpi=600', f'--export-filename={png_path}'
    ], capture_output=True, text=True)
    if proc.returncode != 0 or "cannot be opened" in proc.stderr or "failed to create document" in proc.stderr:
        raise RuntimeError(proc.stderr.strip() or 'inkscape failed')
    if not png_path.exists():
        raise RuntimeError(f'Expected PNG not created: {png_path.name}')


def convert_pdf_to_png_600(pdf_path: Path, png_path: Path) -> None:
    png_path.parent.mkdir(parents=True, exist_ok=True)
    prefix = png_path.with_suffix('')
    run_cmd([
        'pdftoppm', str(pdf_path), str(prefix), '-png', '-cropbox', '-r', '600',
        '-scale-to-x', '6144', '-scale-to-y', '-1'
    ], 'pdftoppm failed')
    candidates = [prefix.with_name(prefix.name + '-1.png'), prefix.with_suffix('.png')]
    made = next((p for p in candidates if p.exists()), None)
    if not made:
        matches = sorted(png_path.parent.glob(prefix.name + '*.png'))
        made = matches[0] if matches else None
    if not made:
        raise RuntimeError(f'Expected PNG not created from PDF: {pdf_path.name}')
    if made != png_path:
        if png_path.exists():
            png_path.unlink()
        made.rename(png_path)



def convert_png_to_webp_quality_75(png_path: Path, webp_path: Path) -> None:
    cmd = ['magick', str(png_path), '-quality', '75', str(webp_path)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or 'magick webp conversion failed')
    if not webp_path.exists():
        raise RuntimeError(f'Expected WEBP not created: {webp_path}')

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
        convert_svg_to_png_600(source_path, out)
        return out, 'svg_to_png_600'
    if mode == 'embed_png_600' and source_ext == '.pdf':
        out = dest_stub.with_suffix('.png')
        convert_pdf_to_png_600(source_path, out)
        return out, 'pdf_to_png_600'
    if mode == 'embed_webp_75' and source_ext == '.svg':
        png_tmp = dest_stub.with_suffix('.png')
        out = dest_stub.with_suffix('.webp')
        convert_svg_to_png_600(source_path, png_tmp)
        convert_png_to_webp_quality_75(png_tmp, out)
        png_tmp.unlink(missing_ok=True)
        return out, 'svg_to_webp_75_via_png_600'
    if mode == 'embed_webp_75' and source_ext == '.pdf':
        png_tmp = dest_stub.with_suffix('.png')
        out = dest_stub.with_suffix('.webp')
        convert_pdf_to_png_600(source_path, png_tmp)
        convert_png_to_webp_quality_75(png_tmp, out)
        png_tmp.unlink(missing_ok=True)
        return out, 'pdf_to_webp_75_via_png_600'
    if mode == 'vector_in_place' and source_ext == '.pdf':
        out = dest_stub.with_suffix('.svg')
        convert_pdf_to_svg(source_path, out)
        return out, 'pdf_to_svg'
    out = dest_stub.with_suffix(source_ext)
    shutil.copy2(source_path, out)
    return out, choose_replacement_kind(source_ext)


def parse_ppt_slide_media(ppt_dir: Path) -> dict[str, list[int]]:
    slide_media: dict[str, list[int]] = defaultdict(list)
    slides_dir = ppt_dir / 'ppt' / 'slides'
    rels_dir = slides_dir / '_rels'
    for slide_xml in sorted(slides_dir.glob('slide*.xml')):
        m = re.search(r'slide(\d+)\.xml$', slide_xml.name)
        slide_no = int(m.group(1)) if m else None
        rels_path = rels_dir / f'{slide_xml.name}.rels'
        if not rels_path.exists():
            continue
        tree = ET.parse(rels_path)
        root = tree.getroot()
        for rel in root.findall('{http://schemas.openxmlformats.org/package/2006/relationships}Relationship'):
            target = rel.attrib.get('Target', '')
            if '../media/' in target:
                slide_media[Path(target).name].append(slide_no)
    return slide_media


def fingerprint_paths(paths: list[Path], preview_dir: Path, kind: str, progress_cb=None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    total = max(len(paths), 1)
    for idx, p in enumerate(paths, start=1):
        row = {'path': str(p), 'name': p.name, 'ext': p.suffix.lower(), 'bytes': p.stat().st_size, 'error': None}
        try:
            img = render_to_image(p)
            row['phash'] = phash_from_image(img)
            row['width'], row['height'] = img.size
            preview_name = f'{kind}_{idx:04d}_{secure_filename(p.name)}.png'
            save_preview(p, preview_dir / preview_name)
            row['preview_name'] = preview_name
        except Exception as e:
            row.update({'phash': None, 'width': None, 'height': None, 'preview_name': None, 'error': str(e)})
        rows.append(row)
        if progress_cb:
            progress_cb(idx / total)
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

    set_progress(job_id, 'phashing_keynote', f'Fingerprinting {len(key_imgs)} Keynote images', 8)
    key_rows = fingerprint_paths(key_imgs, previews, 'key', progress_cb=lambda x: set_progress(job_id, 'phashing_keynote', f'Fingerprinting {len(key_imgs)} Keynote images', 8 + 26 * x))
    key_valid = [r for r in key_rows if r['phash']]

    set_progress(job_id, 'phashing_pptx', f'Fingerprinting {len(ppt_imgs)} PPTX images', 35)
    ppt_rows = fingerprint_paths(ppt_imgs, previews, 'ppt', progress_cb=lambda x: set_progress(job_id, 'phashing_pptx', f'Fingerprinting {len(ppt_imgs)} PPTX images', 35 + 20 * x))
    ppt_valid = [r for r in ppt_rows if r['phash']]

    slide_media = parse_ppt_slide_media(ppt_dir)
    set_progress(job_id, 'comparing', 'Comparing perceptual hashes', 58)

    rows_for_ui: list[dict[str, Any]] = []
    keynote_match_counts: dict[str, int] = defaultdict(int)
    total = max(len(ppt_valid), 1)
    for idx, prow in enumerate(ppt_valid, start=1):
        scored = []
        for krow in key_valid:
            dist = hamming_hex(prow['phash'], krow['phash'])
            scored.append({**krow, 'distance': dist, 'priority': ext_priority(krow['ext']), 'replacement_kind': choose_replacement_kind(krow['ext'])})
        scored.sort(key=lambda r: (r['distance'], r['priority'], r['name']))
        top3 = scored[:3]
        if top3:
            keynote_match_counts[top3[0]['name']] += 1
        row = {
            'ppt_name': prow['name'],
            'ppt_path': prow['path'],
            'ppt_preview': prow['preview_name'],
            'ppt_width': prow['width'],
            'ppt_height': prow['height'],
            'slides': slide_media.get(prow['name'], []),
            'top_matches': [{
                'key_name': m['name'],
                'display_name': m['name'],
                'key_ext': m['ext'],
                'distance': int(m['distance']),
                'bytes': int(m['bytes']),
                'preview': m['preview_name'],
                'replacement_kind': m['replacement_kind'],
            } for m in top3],
            'default_choice': top3[0]['name'] if top3 else '__skip__',
        }
        rows_for_ui.append(row)
        set_progress(job_id, 'comparing', f'Comparing perceptual hashes ({idx}/{len(ppt_valid)})', 58 + 35 * (idx / total))

    for row in rows_for_ui:
        if not row['top_matches']:
            row['quality'] = 'no_match'
            continue
        best = row['top_matches'][0]
        d = best['distance'] if isinstance(best['distance'], int) else 999
        flags = []
        if keynote_match_counts[best['key_name']] > 1:
            flags.append('multi_map')
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
            writer.writerow([
                row['ppt_name'], ';'.join(map(str, row['slides'])), row['quality'],
                top['key_name'] if top else '', top['replacement_kind'] if top else '', top['distance'] if top else '', row['default_choice']
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


def create_job_from_files(pptx_file: Path, keynote_file: Path, existing_mapping_file: Path | None = None) -> str:
    job_id = uuid.uuid4().hex[:12]
    root = DATA_ROOT / job_id
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
        job_root = DATA_ROOT / uuid.uuid4().hex[:12]
        inp = job_root / 'inputs'
        inp.mkdir(parents=True, exist_ok=True)
        pptx_path = inp / secure_filename(pptx_upload.filename)
        key_path = inp / secure_filename(keynote_upload.filename)
        pptx_upload.save(pptx_path)
        keynote_upload.save(key_path)
        mapping_path = None
        if mapping_upload and mapping_upload.filename:
            mapping_path = inp / secure_filename(mapping_upload.filename)
            mapping_upload.save(mapping_path)
        job_id = create_job_from_files(pptx_path, key_path, mapping_path)
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
        for idx, row in enumerate(selections, start=1):
            ppt_name = row['ppt_name']
            if progress_cb:
                label = 'Converting and embedding images' if patch_mode in {'embed_png_600', 'embed_webp_75'} else 'Embedding selected replacements'
                progress_cb('embedding', f'{label}: {ppt_name} ({idx}/{total})', 5.0 + 80.0 * (idx - 1) / total)
            if row['selection'] == 'skip':
                actions.append({'ppt_name': ppt_name, 'status': 'skipped', 'new_name': '', 'source_name': '', 'replacement_kind': '', 'patch_mode': patch_mode, 'updated_files': ''})
                continue
            old_media = media_dir / ppt_name
            source_path = Path(row['source_path'])
            source_ext = row['source_ext'].lower()
            dest_stub = media_dir / Path(ppt_name).stem
            for existing in media_dir.glob(Path(ppt_name).stem + '.*'):
                if existing.name != ppt_name:
                    existing.unlink(missing_ok=True)
            new_media, applied_kind = materialize_replacement(source_path, source_ext, patch_mode, dest_stub)
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
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=5000)
    ap.add_argument('--no-browser', action='store_true')
    return ap.parse_args()


def maybe_autostart_job(args: argparse.Namespace) -> str | None:
    if not args.pptx or not args.keynote:
        return None
    pptx = Path(args.pptx).expanduser().resolve()
    keynote = Path(args.keynote).expanduser().resolve()
    mapping = Path(args.mapping_csv).expanduser().resolve() if args.mapping_csv else None
    if not pptx.exists() or not keynote.exists() or (mapping and not mapping.exists()):
        print('Autostart skipped: missing input path(s).')
        return None
    return create_job_from_files(pptx, keynote, mapping)


if __name__ == '__main__':
    args = parse_args()
    job_id = maybe_autostart_job(args)
    url = f'http://{args.host}:{args.port}/'
    if job_id:
        url = f'http://{args.host}:{args.port}/job/{job_id}'
    if not args.no_browser:
        launch_browser(url)
    app.run(host=args.host, port=args.port, debug=False)
