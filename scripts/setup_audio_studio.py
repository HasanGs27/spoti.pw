"""Explicit, isolated installation of the optional local instrumental studio."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import venv
import wave

from audio_studio_worker import MODEL_SHA, CONFIG_SHA, MODEL_NAME

DOWNLOADS = [
    (MODEL_NAME, 'https://huggingface.co/KimberleyJSN/melbandroformer/resolve/main/MelBandRoformer.ckpt', 913106900, MODEL_SHA),
    ('vocals_mel_band_roformer.yaml', 'https://raw.githubusercontent.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model/main/configs/config_vocals_mel_band_roformer.yaml', 733, CONFIG_SHA),
    ('MODEL_CARD.md', 'https://huggingface.co/KimberleyJSN/melbandroformer/raw/main/README.md', 20, '5c1b3fd193f37b9dcdd947a12e566189f1c9d2664f4e5e95548e6a4b9fc7adab'),
]


def fetch_reviewed(directory, name, url, size, expected):
    target = directory / name
    if target.is_symlink(): raise ValueError('Symbolic model path refused')
    if target.exists():
        with target.open('rb') as stream: actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if target.stat().st_size != size or actual != expected: raise ValueError('Existing model differs; refusing overwrite')
        return
    temporary = target.with_suffix(target.suffix + '.partial')
    created = False
    try:
        total, digest = 0, hashlib.sha256()
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open('xb') as stream:
            created = True
            for chunk in iter(lambda: response.read(1048576), b''):
                total += len(chunk)
                if total > size: raise ValueError('Oversized download')
                digest.update(chunk); stream.write(chunk)
            stream.flush(); os.fsync(stream.fileno())
        if total != size or digest.hexdigest() != expected: raise ValueError('Model integrity check failed')
        temporary.rename(target)
    finally:
        if created: temporary.unlink(missing_ok=True)


def validate(studio, python, ffmpeg):
    """Exercise CUDA/model/decoder on a generated signal, never on a user's music."""
    sample_dir = studio / ('validation-' + str(time.time_ns()))
    sample_dir.mkdir()
    source = sample_dir / 'input.wav'
    with wave.open(str(source), 'wb') as stream:
        stream.setnchannels(2); stream.setsampwidth(2); stream.setframerate(44100)
        frames = bytearray()
        for i in range(12 * 44100):
            value = int(5000 * math.sin(2 * math.pi * 440 * i / 44100) + 1200 * math.sin(2 * math.pi * 880 * i / 44100))
            frames.extend(struct.pack('<hh', value, value))
        stream.writeframes(frames)
    report = sample_dir / 'report.log'
    # Supervision is supplied by the companion's already tested Windows job helper.
    from download_worker import windows_child_job
    job = windows_child_job() if os.name == 'nt' else None
    process = None
    try:
        with report.open('wb') as output:
            process = subprocess.Popen([str(python), '-X', 'utf8', str(Path(__file__).with_name('audio_studio_worker.py')),
                '--models', str(studio / 'models'), '--source', str(source), '--output', str(sample_dir / 'instrumental.wav'),
                '--ffmpeg', str(ffmpeg)], stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if job and not job[0].AssignProcessToJobObject(job[1], int(process._handle)):
                raise OSError('Cannot supervise studio validation')
            if process.wait(timeout=600): raise RuntimeError('Synthetic studio validation failed; inspect its private report')
    finally:
        if job: job[0].CloseHandle(job[1])
        if process:
            if process.poll() is None: process.kill()
            process.wait()
    lines = report.read_text(encoding='utf-8', errors='replace').splitlines()
    result = next(json.loads(line) for line in reversed(lines) if line.startswith('{') and 'cudaValidated' in line)
    if result.get('ready') is not True or result.get('cudaValidated') is not True or abs(result.get('audioSeconds', 0) - 12) > .1:
        raise ValueError('Synthetic validation did not succeed')
    config = {**result, 'version':1, 'python':str(python), 'models':str(studio / 'models'),
              'modelBytes':913106900, 'syntheticValidated':True, 'validationReport':str(report)}
    temporary = studio / ('config-' + str(time.time_ns()) + '.json')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(config, stream, ensure_ascii=False, indent=2); stream.flush(); os.fsync(stream.fileno())
    temporary.replace(studio / 'config.json')
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path(__file__).resolve().parents[2] / 'audio-studio')
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--validate-only', action='store_true', help='No installation or network; verify existing local runtime.')
    args = parser.parse_args()
    studio, ffmpeg = args.directory.absolute(), args.ffmpeg.absolute()
    if studio.is_symlink() or studio.resolve() != studio or not ffmpeg.is_file(): raise ValueError('Invalid isolated studio path')
    if not args.validate_only and shutil.disk_usage(studio.parent).free < 15 * 1024**3: raise ValueError('At least 15 GiB free is required')
    python = studio / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
    if not args.validate_only:
        if sys.version_info[:2] != (3,12): raise ValueError('This reviewed installation requires Python 3.12')
        venv.EnvBuilder(with_pip=True).create(studio)
        subprocess.run([str(python), '-m', 'pip', 'install', '--require-hashes', '-r', str(Path(__file__).with_name('audio-studio-requirements.txt')),
                        '--report', str(studio / 'install-report.json')], check=True, timeout=1800)
        with (studio / 'installed-versions.txt').open('wb') as stream:
            subprocess.run([str(python), '-m', 'pip', 'freeze'], stdout=stream, check=True, timeout=30)
        models = studio / 'models'; models.mkdir(exist_ok=True)
        if models.is_symlink() or models.resolve() != models: raise ValueError('Invalid model folder')
        for name, url, size, expected in DOWNLOADS: fetch_reviewed(models, name, url, size, expected)
        (models / 'provenance.json').write_text(json.dumps({'license':'MIT', 'author':'KimberleyJensen / KimberleyJSN',
            'files':[dict(file=n, url=u, bytes=s, sha256=h) for n,u,s,h in DOWNLOADS]}, indent=2), encoding='utf-8')
    result = validate(studio, python, ffmpeg)
    print(json.dumps({'ready':result['ready'], 'cudaValidated':result['cudaValidated'], 'gpu':result['gpu'],
                      'syntheticSeconds':result['seconds'], 'config':str(studio / 'config.json')}, ensure_ascii=False))


if __name__ == '__main__': main()
