"""Create independent, verified speed or instrumental copies of local audio."""
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time

from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover
from mutagen.id3 import TIT2, TPE1, TALB, APIC
from PIL import Image


SPEEDS = (.75, 1.0, 1.25, 1.5, 2.0)
MAX_AUDIO = 100 * 1024 * 1024
MAX_COVER = 8 * 1024 * 1024
MODEL_SHA = '87201f4d31afb5bc79993230fc49446918425574db48c01c405e44f365c7559e'


def studio_configuration(studio_python=None, model_dir=None):
    config_path = Path(os.environ.get('SG_AUDIO_STUDIO_CONFIG') or
                       Path(__file__).resolve().parents[2] / 'audio-studio' / 'config.json').absolute()
    if config_path.is_symlink() or config_path.resolve(strict=True) != config_path or config_path.stat().st_size > 16384:
        raise ValueError('Configuration du studio invalide.')
    config = json.loads(config_path.read_text(encoding='utf-8'))
    if not isinstance(config, dict): raise ValueError('Configuration du studio invalide.')
    studio = config_path.parent
    python = safe_path(studio_python or config.get('python', ''), studio)
    models = safe_path(model_dir or config.get('models', ''), studio)
    checkpoint = safe_path(models / 'vocals_mel_band_roformer.ckpt', studio)
    parameters = safe_path(models / 'vocals_mel_band_roformer.yaml', studio)
    if not 1 <= parameters.stat().st_size <= 32768: raise ValueError('Paramètres du modèle invalides.')
    if (type(config.get('version')) is not int or config.get('version') != 1 or
            config.get('ready') is not True or config.get('cudaValidated') is not True or
            config.get('modelSHA256') != MODEL_SHA or config.get('separatorVersion') != '0.47.0' or
            not python.is_file() or not models.is_dir() or checkpoint.stat().st_size != config.get('modelBytes') or
            hashlib.sha256(parameters.read_bytes()).hexdigest() != config.get('configSHA256')):
        raise ValueError('Le studio instrumental doit être validé sur ce PC.')
    return python, models


def instrumental_available(studio_python=None, model_dir=None):
    """Read-only, bounded check; never imports GPU libraries in the companion process."""
    try:
        studio_configuration(studio_python, model_dir)
        return True
    except (OSError, ValueError, TypeError, KeyError):
        return False


def safe_path(path, root, exists=True):
    path, root = Path(path).absolute(), Path(root).absolute()
    if root.resolve(strict=True) != root or not root.is_dir() or root.is_symlink():
        raise ValueError('Racine privée invalide.')
    if path.is_symlink() or path.resolve(strict=exists) != path or not path.is_relative_to(root):
        raise ValueError('Le fichier doit rester dans le dossier privé, sans lien symbolique.')
    return path


def digest(path):
    before = path.stat()
    if not stat.S_ISREG(before.st_mode) or not 1024 <= before.st_size <= MAX_AUDIO:
        raise ValueError('Taille ou type audio invalide.')
    value, total = hashlib.sha256(), 0
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(131072), b''):
            total += len(chunk)
            if total > MAX_AUDIO: raise ValueError('Audio trop volumineux.')
            value.update(chunk)
    after = path.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or total != before.st_size:
        raise ValueError('Le fichier audio a changé pendant sa lecture.')
    return value.hexdigest(), total


def cover_info(data):
    if not data or len(data) > MAX_COVER: raise ValueError('Pochette invalide.')
    with Image.open(io.BytesIO(data)) as image:
        if image.format not in ('JPEG', 'PNG') or not 1 <= image.width <= 4096 or not 1 <= image.height <= 4096:
            raise ValueError('Pochette invalide.')
        mime = Image.MIME[image.format]
        image.verify()
    return mime


def read_audio(path):
    extension = path.suffix[1:].lower()
    if extension not in ('mp3', 'm4a'): raise ValueError('Source MP3 ou M4A requise.')
    audio = MP3(path) if extension == 'mp3' else MP4(path)
    info = audio.info
    if not math.isfinite(info.length) or not .1 <= info.length <= 2401:
        raise ValueError('Durée audio invalide.')
    if not 8000 <= info.sample_rate <= 192000 or not 1 <= info.channels <= 8:
        raise ValueError('Format audio invalide.')
    tags = audio.tags or {}
    if extension == 'mp3':
        if info.layer != 3: raise ValueError('La source ne contient pas de MP3.')
        values = [str(tags.get(key, '')) for key in ('TIT2', 'TPE1', 'TALB')]
        covers = [item.data for item in audio.tags.getall('APIC')] if audio.tags else []
        codec = 'MP3'
    else:
        if info.codec != 'mp4a.40.2': raise ValueError('AAC-LC requis pour le M4A.')
        values = [(tags.get(key) or [''])[0] for key in ('\xa9nam', '\xa9ART', '\xa9alb')]
        covers = tags.get('covr') or []
        codec = 'AAC-LC'
    if not all(isinstance(value, str) and len(value) <= 4096 for value in values):
        raise ValueError('Métadonnées audio invalides.')
    cover, mime = None, None
    for data in covers:
        try:
            mime, cover = cover_info(bytes(data)), bytes(data)
            break
        except (ValueError, OSError):
            continue
    return {'extension': extension, 'seconds': info.length, 'sampleRate': info.sample_rate,
            'channels': info.channels, 'codec': codec, 'title': values[0], 'artist': values[1],
            'album': values[2], 'cover': cover, 'coverMime': mime}


def write_tags(path, source, label):
    album = (source['album'] + ' · ' if source['album'] else '') + label
    if path.suffix == '.m4a':
        audio = MP4(path)
        if audio.tags is None: audio.add_tags()
        audio['\xa9nam'], audio['\xa9ART'], audio['\xa9alb'] = [source['title']], [source['artist']], [album]
        if source['cover']:
            kind = MP4Cover.FORMAT_JPEG if source['coverMime'] == 'image/jpeg' else MP4Cover.FORMAT_PNG
            audio['covr'] = [MP4Cover(source['cover'], imageformat=kind)]
        audio.save()
    else:
        audio = MP3(path)
        if audio.tags is None: audio.add_tags()
        for frame, value in ((TIT2, source['title']), (TPE1, source['artist']), (TALB, album)):
            audio.tags.add(frame(encoding=1, text=[value]))
        if source['cover']:
            audio.tags.add(APIC(encoding=1, mime=source['coverMime'], type=3, data=source['cover']))
        audio.save(v2_version=3)
    return album


def run_ffmpeg(ffmpeg, arguments, log, remaining):
    if remaining <= 0: raise TimeoutError('Délai de création dépassé.')
    # FFmpeg has no child executables here. subprocess.run kills and waits on timeout.
    with log.open('wb') as output:
        subprocess.run([str(ffmpeg), '-hide_banner', '-nostdin', *arguments],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=output,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), timeout=remaining, check=True)


def validate_decode(ffmpeg, path, log, remaining):
    measures = 'Number_of_NaNs+Number_of_Infs+Number_of_samples+Peak_level'
    run_ffmpeg(ffmpeg, ['-v', 'info', '-xerror', '-protocol_whitelist', 'file,pipe', '-i', str(path),
        '-map', '0:a:0', '-af', 'astats=measure_perchannel=none:measure_overall=' + measures,
        '-f', 'null', '-'], log, remaining)
    if log.stat().st_size > 1024 * 1024: raise ValueError('Diagnostic audio trop volumineux.')
    text = log.read_text(encoding='utf-8', errors='replace')
    values = {}
    for key in ('Number of NaNs', 'Number of Infs', 'Number of samples', 'Peak level dB'):
        found = re.findall(r'\[Parsed_astats_[^\]]+\]\s*' + re.escape(key) + r':\s*([^\s]+)', text)
        if not found: raise ValueError('Validation du décodage audio indisponible.')
        values[key] = float(found[-1])
    if (values['Number of NaNs'] != 0 or values['Number of Infs'] != 0 or
            not math.isfinite(values['Number of samples']) or values['Number of samples'] < 8000):
        raise ValueError('Échantillons audio invalides.')
    return {'finiteSamples': True, 'decodedSamples': int(values['Number of samples'])}


def create_speed_variant(root, source, speed, ffmpeg, output_format='m4a', timeout=180):
    if type(speed) not in (int, float) or speed not in SPEEDS: raise ValueError('Vitesse non prise en charge.')
    return _create_variant(root, source, ffmpeg, output_format, timeout, speed=speed)


def create_instrumental_variant(root, source, ffmpeg, studio_python=None, model_dir=None,
                                output_format='m4a', timeout=600):
    python, models = studio_configuration(studio_python, model_dir)
    return _create_variant(root, source, ffmpeg, output_format, timeout, studio=(python, models))


def run_instrumental(studio, source, output, ffmpeg, log, remaining):
    if remaining <= 0: raise TimeoutError('Délai de création dépassé.')
    from download_worker import windows_child_job
    python, models = studio
    command = [str(python), '-X', 'utf8', str(Path(__file__).with_name('audio_studio_worker.py')),
               '--models', str(models), '--source', str(source), '--output', str(output), '--ffmpeg', str(ffmpeg)]
    job = windows_child_job() if os.name == 'nt' else None
    process = None
    try:
        with log.open('wb') as diagnostic:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=diagnostic, stderr=diagnostic,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if job and not job[0].AssignProcessToJobObject(job[1], int(process._handle)):
                raise OSError('Le processus instrumental ne peut pas être supervisé.')
            if process.wait(timeout=max(.1, remaining)) != 0:
                raise ValueError('Le studio n’a pas pu créer cette version instrumentale.')
    finally:
        if job: job[0].CloseHandle(job[1])
        if process:
            if process.poll() is None: process.kill()
            process.wait()


def _create_variant(root, source, ffmpeg, output_format, timeout, speed=None, studio=None):
    """New independent copy under root/.audio-variants; no source mutation or cache promotion."""
    if output_format not in ('m4a', 'mp3'): raise ValueError('Format de sortie non pris en charge.')
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 1 <= timeout <= 600:
        raise ValueError('Délai de traitement invalide.')
    root = Path(root).absolute()
    source = safe_path(source, root)
    if source.suffix.lower() not in ('.mp3', '.m4a'): raise ValueError('Source MP3 ou M4A requise.')
    ffmpeg = Path(ffmpeg).absolute()
    if not ffmpeg.is_file(): raise ValueError('FFmpeg est absent.')
    source_digest, source_bytes = digest(source)
    store = safe_path(root / '.audio-variants', root, exists=False)
    store.mkdir(exist_ok=True)
    safe_path(store, root)
    kind = 'instrumental' if studio else 'speed'
    folder = Path(tempfile.mkdtemp(prefix=kind + '-', dir=store))
    staged = folder / ('input' + source.suffix.lower())
    output = folder / ('audio.' + output_format)
    log = folder / 'validation.log'
    manifest_path = folder / 'variant.json'
    separated = folder / 'instrumental.wav'
    decoded = folder / 'input.wav'
    deadline, success = time.monotonic() + timeout, False
    try:
        with source.open('rb') as incoming, staged.open('xb') as outgoing:
            remaining = source_bytes
            while remaining:
                data = incoming.read(min(131072, remaining))
                if not data: raise ValueError('Audio source incomplet.')
                outgoing.write(data); remaining -= len(data)
            if incoming.read(1): raise ValueError('La source audio a changé.')
        if digest(staged) != (source_digest, source_bytes): raise ValueError('La source audio a changé.')
        original = read_audio(staged)
        if not 1 <= original['seconds'] <= 1800: raise ValueError('La source doit durer entre 1 seconde et 30 minutes.')
        # Missing tags remain explicit; integration can supply Spotify metadata later.
        if not original['title']: original['title'] = source.stem[:4096]
        suffix = 'Instrumental' if studio else '×' + format(speed, 'g').replace('.', ',')
        label = 'Instrumental' if studio else 'Vitesse ' + suffix
        tagged = {**original, 'title': original['title'] + ' · ' + suffix}
        processing = {'sampleRate': 44100, 'channels': 2}
        if studio:
            run_ffmpeg(ffmpeg, ['-v', 'error', '-xerror', '-protocol_whitelist', 'file,pipe', '-i', str(staged),
                '-map', '0:a:0', '-vn', '-sn', '-dn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_f32le', '-n', str(decoded)],
                log, deadline - time.monotonic())
            run_instrumental(studio, decoded, separated, ffmpeg, log, deadline - time.monotonic())
            input_audio, filters, expected = separated, [], original['seconds']
            processing.update({'model': 'MelBandRoformer', 'modelSHA256': MODEL_SHA,
                               'separatorVersion': '0.47.0', 'overlap': 2, 'precision': 'float32'})
        else:
            input_audio, filters, expected = staged, ['-af', 'atempo=' + format(speed, 'g')], original['seconds'] / speed
            processing.update({'filter': filters[-1], 'pitchPreserved': True})
        encoding = (['-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', '256k', '-movflags', '+faststart']
                    if output_format == 'm4a' else ['-c:a', 'libmp3lame', '-q:a', '0'])
        run_ffmpeg(ffmpeg, ['-v', 'error', '-xerror', '-protocol_whitelist', 'file,pipe', '-i', str(input_audio),
            '-map', '0:a:0', '-vn', '-sn', '-dn', '-map_metadata', '-1', '-map_chapters', '-1',
            *filters, '-ac', '2', '-ar', '44100', *encoding, '-n', str(output)],
            log, deadline - time.monotonic())
        album = write_tags(output, tagged, label)
        result = read_audio(output)
        if abs(result['seconds'] - expected) > max(.12, expected * .007): raise ValueError('Durée transformée incohérente.')
        if result['channels'] != 2 or result['sampleRate'] != 44100: raise ValueError('Format transformé incohérent.')
        if (result['title'], result['artist'], result['album'], result['cover']) != (
                tagged['title'], original['artist'], album, original['cover']):
            raise ValueError('Métadonnées ou pochette perdues.')
        validation = validate_decode(ffmpeg, output, log, deadline - time.monotonic())
        output_digest, output_bytes = digest(output)
        if digest(safe_path(source, root)) != (source_digest, source_bytes): raise ValueError('La source audio a changé.')
        record = {'version': 1, 'kind': kind, 'label': label,
            'source': {'path': source.relative_to(root).as_posix(), 'sha256': source_digest,
                       'bytes': source_bytes, 'seconds': original['seconds'], 'extension': original['extension']},
            'audio': {'file': output.name, 'sha256': output_digest, 'bytes': output_bytes, 'seconds': result['seconds'],
                      'extension': output_format, 'codec': result['codec'], 'title': result['title'],
                      'artist': result['artist'], 'album': result['album'], 'cover': bool(result['cover'])},
            'processing': processing, 'validation': validation}
        if speed is not None: record['speed'] = float(speed)
        with manifest_path.open('x', encoding='utf-8') as stream:
            json.dump(record, stream, ensure_ascii=False, allow_nan=False, indent=2)
            stream.flush(); os.fsync(stream.fileno())
        success = True
        return {'directory': str(folder), **record}
    finally:
        # Only generated files in our unique private directory; never recurse.
        try:
            safe_path(folder, root)
            transient = (staged, log, decoded, separated)
            for path in (transient if success else (*transient, output, manifest_path)):
                path.unlink(missing_ok=True)
            if not success: folder.rmdir()
        except (OSError, ValueError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path, help='Racine privée contenant la source et les sorties.')
    parser.add_argument('--source', required=True, type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--speed', type=float, choices=SPEEDS)
    action.add_argument('--instrumental', action='store_true')
    parser.add_argument('--ffmpeg', required=True, type=Path)
    parser.add_argument('--format', choices=('m4a', 'mp3'), default='m4a')
    args = parser.parse_args()
    try:
        result = (create_instrumental_variant(args.root, args.source, args.ffmpeg, output_format=args.format)
                  if args.instrumental else create_speed_variant(args.root, args.source, args.speed, args.ffmpeg, args.format))
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        # Do not copy FFmpeg stderr (which may include arbitrary embedded tags) to caller logs.
        print(json.dumps({'ready': False, 'error': type(error).__name__, 'message': 'La copie audio n’a pas pu être créée.'}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
