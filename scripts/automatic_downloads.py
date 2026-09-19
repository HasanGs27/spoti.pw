"""LAN companion for explicit Spotify download requests. No accounts or cookies."""
import argparse
import copy
import hashlib
import io
import ipaddress
import json
import math
import os
import re
import secrets
import stat
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import requests
from mutagen import MutagenError
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4
from PIL import Image
from download_metadata import canonical, collection
from download_worker import source_url
from download_storage import AudioStore, atomic_document, safe_path

LIMIT = 100 * 1024 * 1024
ACTIVE = {"queued", "resolving", "running"}
PHASES = {'metadata', 'search', 'download', 'cover', 'verify'}
FAILURES = {'network', 'unavailable', 'no_match', 'invalid_audio', 'cover', 'error'}
TERMINAL = {'complete', 'partial', 'error', 'interrupted', 'paused', 'cancelled'}
CAPABILITIES = {'version':1, 'resumeJobs':True, 'storage':True, 'alternativeVersions':True, 'refreshPlaylists':True}


def request_fields(request):
    if not isinstance(request, dict): raise ValueError('Requête invalide.')
    url = canonical(request.get('url'))
    key = request.get('request_id', '')
    if not isinstance(key, str) or not re.fullmatch('[A-Za-z0-9-]{16,64}', key): raise ValueError('Identifiant de requête invalide.')
    kind = request.get('kind', 'download')
    if kind not in ('download', 'alternative'): raise ValueError('Type de demande invalide.')
    refresh = request.get('refresh', False)
    if type(refresh) is not bool: raise ValueError('Actualisation invalide.')
    tracks = request.get('track_urls')
    if tracks is not None:
        if not isinstance(tracks, list) or not 1 <= len(tracks) <= 500: raise ValueError('Au maximum 500 morceaux par demande.')
        tracks = [canonical(track) for track in tracks]
        if not all('/track/' in track for track in tracks): raise ValueError('Liste de morceaux attendue.')
    if refresh and (tracks is not None or kind != 'download'): raise ValueError('Une actualisation relit la playlist.')
    avoid = request.get('avoid_sources', [])
    if not isinstance(avoid, list) or len(avoid) > 8: raise ValueError('Au maximum 8 sources exclues.')
    normalized = []
    for value in avoid:
        source = source_url(value) if isinstance(value, str) else None
        if not source: raise ValueError('Lien audio exclu invalide.')
        if source not in normalized: normalized.append(source)
    if kind == 'alternative':
        if '/track/' not in url or tracks is not None: raise ValueError('Une autre version concerne un seul titre.')
    elif avoid: raise ValueError('Sources exclues réservées aux autres versions.')
    return {'url':url, 'request_id':key, 'kind':kind, 'refresh':refresh, 'track_urls':tracks, 'avoid_sources':normalized}


def transient(error):
    if isinstance(error, (TimeoutError, ConnectionError, subprocess.TimeoutExpired, requests.Timeout,
                          requests.ConnectionError, requests.exceptions.ChunkedEncodingError)): return True
    return isinstance(error, requests.HTTPError) and error.response is not None and error.response.status_code in (408, 500, 502, 503, 504)


def audio_extension(metadata):
    # Protocol 2 originally had only MP3 and omitted this field.
    value = metadata.get('extension', 'mp3')
    if value not in ('mp3', 'm4a'): raise ValueError('Format audio invalide.')
    return value


def source_details(metadata):
    result = {}
    if isinstance(metadata.get('sourceCodec'), str): result['sourceCodec'] = metadata['sourceCodec'][:64]
    value = metadata.get('sourceBitrate')
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 < value <= 8000000:
        result['sourceBitrate'] = value
    return result


def file_stamp(info):
    # Python 3.12 on Windows can report creation time for stat().st_ctime
    # but change time for fstat().st_ctime on the SAME file. Compare its stable
    # identity/size/mtime there; the complete SHA still detects timestamp tampering.
    return (info.st_size, info.st_mtime_ns, info.st_ctime_ns if os.name != 'nt' else 0, info.st_dev, info.st_ino)


def bounded_digest(stream, size):
    digest, remaining = hashlib.sha256(), size
    while remaining:
        chunk = stream.read(min(131072, remaining))
        if not chunk: raise ValueError('Fichier audio incomplet.')
        digest.update(chunk); remaining -= len(chunk)
    if stream.read(1): raise ValueError('Le fichier audio a changé.')
    return digest.hexdigest()


def valid_cover(data):
    if not isinstance(data, bytes) or not 24 <= len(data) <= 20 * 1024 * 1024: return False
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format not in ('JPEG', 'PNG') or not all(1 <= n <= 10000 for n in image.size) or image.width * image.height > 40000000:
                return False
            image.verify()
        return True
    except (ValueError, OSError, Image.DecompressionBombError): return False


def byte_range(header, size):
    """One bounded inclusive range; unknown units may be ignored per HTTP semantics."""
    if header is None: return None
    if len(header) > 512: raise ValueError('Plage invalide.')
    if not header.startswith('bytes='): return None
    match = re.fullmatch(r'bytes=([0-9]{0,20})-([0-9]{0,20})', header)
    if not match or not any(match.groups()): raise ValueError('Plage invalide.')
    first, last = match.groups()
    if not first:
        count = int(last)
        if not count: raise ValueError('Plage vide.')
        return max(0, size-count), size-1
    start = int(first)
    end = min(int(last), size-1) if last else size-1
    if start >= size or start > end: raise ValueError('Plage hors fichier.')
    return start, end


def worker_document(path, limit=16384):
    """Best-effort bounded reads: workers can still be writing metadata on failure."""
    try:
        if path.is_symlink() or path.stat().st_size > limit: return {}
        with path.open('rb') as stream: data = stream.read(limit+1)
        if len(data) > limit: return {}
        result = json.loads(data)
        return result if isinstance(result, dict) else {}
    except (ValueError, OSError): return {}


def worker_labels(folder):
    metadata = worker_document(folder / 'metadata.json')
    return {key:metadata[key][:512] for key in ('title', 'artist')
            if isinstance(metadata.get(key), str) and metadata[key].strip()}


def lan_address(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Adresse du réseau local requise.")
    return str(address)


def audio_record(path, metadata):
    extension = audio_extension(metadata)
    before = path.stat()
    if path.is_symlink() or not stat.S_ISREG(before.st_mode) or not 1024 <= before.st_size <= LIMIT:
        raise ValueError("Fichier audio invalide.")
    with path.open('rb') as stream:
        if file_stamp(os.fstat(stream.fileno())) != file_stamp(before): raise ValueError('Le fichier audio a changé.')
        audio = MP4(stream) if extension == 'm4a' else MP3(stream)
        info = audio.info
        if (not math.isfinite(info.length) or not 1 <= info.length <= 86400 or
            not 8000 <= info.sample_rate <= 192000 or not 1 <= info.channels <= 8 or
            not 0 < info.bitrate <= 8000000 or not audio.tags):
            raise ValueError('Audio invalide ou métadonnées absentes.')
        if extension == 'm4a':
            if not info.codec.startswith('mp4a.'): raise ValueError('Codec M4A non pris en charge.')
            title, artist, album = ((audio.tags.get(key) or [''])[0] for key in ('\xa9nam', '\xa9ART', '\xa9alb'))
            covers = audio.tags.get('covr', [])
        else:
            if info.layer != 3: raise ValueError('Codec MP3 invalide.')
            title, artist, album = (str(audio.tags.get(key, '')) for key in ('TIT2', 'TPE1', 'TALB'))
            covers = [cover.data for cover in audio.tags.getall('APIC')]
        if (not all(isinstance(value, str) and len(value) <= 4096 for value in (title, artist, album)) or
            not title.strip() or not artist.strip() or not any(valid_cover(data) for data in covers)):
            raise ValueError('Titre, artiste ou pochette manquant.')
        stream.seek(0)
        digest = bounded_digest(stream, before.st_size)
        if file_stamp(os.fstat(stream.fileno())) != file_stamp(before) or file_stamp(path.stat()) != file_stamp(before):
            raise ValueError('Le fichier audio a changé.')
    record = {"id": digest, "bytes": before.st_size, "seconds": round(info.length, 3),
        "title": title, "artist": artist, "album": album, "cover": True, "extension": extension,
        "source": metadata.get('source', ''), "quality": metadata.get('quality', '')}
    record.update(source_details(metadata))
    return record


class Queue:
    def __init__(self, root, ffmpeg, prepare=None, resolve=collection, retry_delays=(2.0,), start=True):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.ffmpeg, self.resolve, self.prepare = ffmpeg, resolve, prepare or self.worker
        self.custom_prepare = prepare is not None
        self.retry_delays = tuple(retry_delays)[:2]
        self.lock, self.jobs, self.files = threading.RLock(), {}, {}
        self.running_jobs = set()
        self.reusable, self.repairable = {}, {}
        self.store, self.preferred = AudioStore(self.root, audio_record), {}
        self.pool = ThreadPoolExecutor(max_workers=1)
        resumed = []
        for path in self.root.glob('*/job.json'):
            try:
                if (not re.fullmatch('[a-f0-9]{32}', path.parent.name) or path.is_symlink() or
                    path.resolve() != path or path.stat().st_size > 8 * 1024 * 1024): continue
                job = json.loads(path.read_text(encoding='utf-8'))
                if not isinstance(job, dict) or job.get('version') != 2 or job.get('id') != path.parent.name: continue
                fields = request_fields(job)
                if 'effective_avoid_sources' in job:
                    job['effective_avoid_sources'] = request_fields(dict(fields, avoid_sources=job['effective_avoid_sources']))['avoid_sources']
                if job.get('state') not in ACTIVE | TERMINAL: continue
                rows = job.get('items')
                if not isinstance(rows, list) or len(rows) > 500: continue
                created = job.get('created', 0)
                if type(created) not in (float, int) or not math.isfinite(created): continue
                for index, item in enumerate(rows, 1):
                    if (not isinstance(item, dict) or type(item.get('position')) is not int or item['position'] != index or
                        '/track/' not in canonical(item.get('spotify')) or item.get('state') not in {'waiting', 'running', 'ready', 'error'}):
                        raise ValueError('Lignes de téléchargement invalides.')
                    item['spotify'] = canonical(item['spotify'])
                    attempts = item.get('attempts', 0)
                    if type(attempts) is not int or not 0 <= attempts <= 3: raise ValueError('Compteur invalide.')
                if fields['kind'] == 'alternative' and (len(rows) > 1 or any(item['spotify'] != fields['url'] for item in rows)):
                    raise ValueError('Identité de version incohérente.')
                if fields['kind'] == 'alternative' and (type(job.get('variant_number')) is not int or not 2 <= job['variant_number'] <= 999999):
                    raise ValueError('Numéro de version invalide.')
                if fields['track_urls'] is not None and rows and [item['spotify'] for item in rows] != fields['track_urls']:
                    raise ValueError('Sélection persistée incohérente.')
                if type(job.get('resolveAttempts', 0)) is not int or not 0 <= job.get('resolveAttempts', 0) <= 3:
                    raise ValueError('Compteur invalide.')
                job.update(fields)
                if 'completeMetadata' not in job:
                    tracks = job.get('track_urls')
                    job['completeMetadata'] = ('/track/' in canonical(job['url']) or
                        isinstance(tracks, list) and 1 <= len(tracks) <= 500 and
                        all('/track/' in canonical(track) for track in tracks))
                was_active = job['state'] in ACTIVE
                if job.get('cancelled') is True: job['state'] = 'cancelled'; was_active = False
                elif job.get('paused') is True or job.get('userPaused') is True: job['state'] = 'paused'; was_active = False
                for item in job.get('items', []):
                    position = item.get('position')
                    if isinstance(position, bool) or not isinstance(position, int) or not 1 <= position <= 500:
                        raise ValueError('Position audio invalide.')
                    folder = path.parent / str(position)
                    if item['state'] == 'ready':
                        record = None
                        try:
                            audio = self.row_path(item, folder)
                            if audio.is_file() and audio.resolve(strict=True) == audio:
                                record = audio_record(audio, item)
                        except (OSError, ValueError, KeyError, MutagenError): pass
                        if record and record['id'] == item['id']:
                            self.register(item['id'], audio, record['extension'])
                            if job['kind'] != 'alternative': self.remember_audio(item['spotify'], audio, record)
                            item.update(record)
                        else:
                            item.update(state='error', message='Fichier absent ou modifié sur le PC.')
                            if not was_active and not self.stopped(job): job.update(state='partial', message='Certains fichiers ne sont plus disponibles sur le PC.')
                    if item['state'] != 'ready':
                        if job['kind'] != 'alternative': self.remember_repair(item['spotify'], folder)
                        if was_active and item['state'] == 'running': item['state'] = 'waiting'
                if was_active:
                    job.update(state='queued', message='Reprise automatique après redémarrage du PC.')
                    resumed.append(job)
                self.jobs[job['id']] = job
                self.save(job)
            except (ValueError, KeyError, TypeError, OSError, MutagenError): continue
        self.restore_preferences()
        self.pending_resume = sorted(resumed, key=lambda value: value.get('created', 0))
        if start: self.resume_pending()

    def resume_pending(self):
        # main() binds and publishes the service before any persisted job issues traffic.
        with self.lock:
            pending, self.pending_resume = self.pending_resume, []
            for job in pending:
                try:
                    if job['kind'] == 'alternative' and 'effective_avoid_sources' not in job:
                        job['effective_avoid_sources'] = self.effective_avoid(job)
                        self.save(job)
                    self.pool.submit(self.run, job['id'])
                except (ValueError, OSError):
                    job.update(state='error', message='Cette demande ne peut pas être reprise. Relance-la depuis l’iPhone.')
                    self.save(job)

    def row_path(self, row, folder):
        return self.store.path(row) if row.get('storage') == 'blob' else folder / ('audio.' + audio_extension(row))

    def stopped(self, job):
        return job.get('state') in {'paused', 'cancelled'} or any(job.get(key) is True for key in ('paused', 'userPaused', 'cancelled'))

    def effective_avoid(self, fields):
        values = list(fields.get('avoid_sources', []))
        cached = self.reusable.get(fields['url'])
        current = self.preferred.get(fields['url']) or (cached[1] if cached else {})
        source = source_url(current.get('source'))
        if source and source not in values: values.append(source)
        if len(values) > 8: raise ValueError('Au maximum 8 sources, version actuelle comprise.')
        return values

    def restore_preferences(self):
        document = worker_document(self.root / 'preferred-audio.json', 8 * 1024 * 1024)
        if document.get('version') != 1 or not isinstance(document.get('tracks'), dict): return
        for url, row in document['tracks'].items():
            try:
                if '/track/' not in canonical(url) or not isinstance(row, dict): continue
                path = self.store.path(row)
                checked = self.store.verified(path, row)
                self.preferred[url] = dict(row, **checked)
                self.register(checked['id'], path, checked['extension'])
                self.remember_audio(url, path, checked)
            except (ValueError, KeyError, TypeError, OSError, MutagenError): continue

    def accept_version(self, request):
        if not isinstance(request, dict): raise ValueError('Demande invalide.')
        ident, digest = request.get('job_id'), request.get('sha256')
        if not isinstance(ident, str) or not re.fullmatch('[a-f0-9]{32}', ident) or not isinstance(digest, str) or not re.fullmatch('[a-f0-9]{64}', digest):
            raise ValueError('Version invalide.')
        with self.lock:
            job = self.jobs.get(ident)
            if not job or job.get('kind') != 'alternative' or job['state'] != 'complete' or len(job['items']) != 1:
                raise ValueError('Cette autre version n’est pas prête.')
            row = job['items'][0]
            if row.get('state') != 'ready' or row.get('id') != digest or row['spotify'] != job['url']:
                raise ValueError('Identité de version incohérente.')
            path = self.row_path(row, self.root / ident / '1')
            path, checked = self.store.install(path, row)
            preferred = dict(self.preferred)
            preferred[job['url']] = dict(checked, storage='blob')
            atomic_document(self.root / 'preferred-audio.json', {'version':1, 'tracks':preferred})
            self.preferred = preferred
            self.remember_audio(job['url'], path, checked)
            self.register(digest, path, checked['extension'])
            return {'accepted':True, 'spotify':job['url'], 'sha256':digest, 'extension':checked['extension']}

    def storage_inventory(self):
        # Hold self.lock. Any unrecognized job prevents cleanup rather than
        # guessing which canonical files its missing metadata might reference.
        protected, legacy, uncertain = set(), {}, False
        for path in self.root.glob('*/job.json'):
            if path.parent.name not in self.jobs or path.is_symlink() or path.resolve() != path: uncertain = True
            elif worker_document(path, 8 * 1024 * 1024) != self.jobs[path.parent.name]: uncertain = True
        for job in self.jobs.values():
            for row in job['items']:
                if row['state'] != 'ready': continue
                try:
                    path = self.row_path(row, self.root / job['id'] / str(row['position']))
                    protected.add(path)
                    protected.add(self.store.path(row))
                    if row.get('storage') != 'blob':
                        safe_path(path, self.root)
                        info = path.stat()
                        if stat.S_ISREG(info.st_mode): legacy[path] = info
                except (OSError, ValueError): pass
        for row in self.preferred.values(): protected.add(self.store.path(row))
        entries = self.store.inventory()
        audio = [(path, info) for path, info in entries if path.suffix in ('.mp3', '.m4a')]
        audio.extend(legacy.items())
        # Recent orphans may come from a crash just before committing a job.
        cutoff = time.time() - 24 * 3600
        reclaim = [(path, info) for path, info in entries if path not in protected and info.st_mtime <= cutoff]
        for job in self.jobs.values():
            if job['state'] in ACTIVE or self.stopped(job) and job['state'] != 'cancelled': continue
            for row in job['items']:
                folder = self.root / job['id'] / str(row['position'])
                for extension in ('mp3', 'm4a'):
                    path = folder / ('audio.'+extension)
                    if path in protected: continue
                    try:
                        safe_path(path, self.root)
                        info = path.stat()
                        if stat.S_ISREG(info.st_mode) and 0 <= info.st_size <= LIMIT and info.st_mtime <= cutoff:
                            reclaim.append((path, info))
                    except (OSError, ValueError): pass
        return audio, reclaim, uncertain

    def storage_status(self):
        with self.lock, self.store.lock:
            audio, reclaim, uncertain = self.storage_inventory()
            active = len({job['id'] for job in self.jobs.values() if job['state'] in ACTIVE} | self.running_jobs)
            identities = {}
            for job in self.jobs.values():
                for row in job['items']:
                    if row['state'] == 'ready':
                        path = self.row_path(row, self.root/job['id']/str(row['position']))
                        identities[path] = row['id']+'.'+audio_extension(row)
            groups = {}
            for path, info in audio:
                identity = identities.get(path, path.name if path.parent == self.store.directory else str(path))
                groups.setdefault(identity, []).append(info.st_size)
            duplicates = sum(len(sizes)-1 for sizes in groups.values())
            duplicate_bytes = sum(sum(sizes)-max(sizes) for sizes in groups.values())
            return {'version':1, 'audio_bytes':sum(info.st_size for _, info in audio), 'audio_files':len(audio),
                'reclaimable_bytes':sum(info.st_size for _, info in reclaim)+duplicate_bytes if not uncertain else 0,
                'reclaimable_files':len(reclaim)+duplicates if not uncertain else 0,
                'active_jobs':active, 'cleanup_available':not active and not uncertain}

    def cleanup_storage(self, request):
        if not isinstance(request, dict) or request: raise ValueError('Nettoyage invalide.')
        with self.lock, self.store.lock:
            status = self.storage_status()
            if not status['cleanup_available']: raise ValueError('Attends la fin des préparations avant le nettoyage.')
            audio, reclaim, uncertain = self.storage_inventory()
            if uncertain: raise ValueError('Historique incomplet : aucun fichier supprimé.')
            before = {path:info.st_size for path, info in audio+reclaim}
            consolidated = 0
            for job in self.jobs.values():
                for row in job['items']:
                    if row['state'] != 'ready' or row.get('storage') == 'blob': continue
                    original = self.row_path(row, self.root/job['id']/str(row['position']))
                    old_row = dict(row)
                    try:
                        snapshot = original.stat()
                        target, checked = self.store.install(original, row)
                        row.update(checked, storage='blob')
                        try: self.save(job)
                        except (OSError, ValueError):
                            row.clear(); row.update(old_row)
                            raise
                        self.register(row['id'], target, row['extension'])
                        if job.get('kind') != 'alternative': self.remember_audio(row['spotify'], target, checked)
                        if self.store.remove_snapshot(original, snapshot): consolidated += 1
                    except (OSError, ValueError, MutagenError): continue
            _, reclaim, _ = self.storage_inventory()
            removed_files = removed_bytes = 0
            for path, snapshot in reclaim:
                try:
                    if self.store.remove_snapshot(path, snapshot):
                        removed_files += 1; removed_bytes += snapshot.st_size
                except (OSError, ValueError): continue
            # Unfinished repair references may have pointed at removed staging files.
            self.repairable = {url:record for url, record in self.repairable.items() if record[0].is_file()}
            after_audio, after_reclaim, _ = self.storage_inventory()
            after = {path:info.st_size for path, info in after_audio+after_reclaim}
            return {'removed_bytes':max(0, sum(before.values())-sum(after.values())),
                'removed_files':max(0, len(before)-len(after)), 'consolidated_files':consolidated, 'storage':self.storage_status()}

    def register(self, ident, path, extension='mp3'):
        if (path.is_symlink() or path.resolve(strict=True) != path or not path.is_relative_to(self.root) or
            not re.fullmatch('[a-f0-9]{64}', ident) or extension not in ('mp3', 'm4a')):
            raise ValueError('Chemin audio invalide.')
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or not 1024 <= info.st_size <= LIMIT: raise ValueError('Fichier audio invalide.')
        self.files[ident] = (path, file_stamp(info), extension)

    def remember_audio(self, url, path, record):
        url = canonical(url)
        if '/track/' not in url: return
        path = path.resolve(strict=True)
        if not path.is_relative_to(self.root): raise ValueError('Chemin audio invalide.')
        if url in self.preferred and self.preferred[url]['id'] != record['id']: return
        self.reusable[url] = (path, dict(record))

    def reuse_audio(self, url, folder):
        """Reuse a verified canonical file, without creating a copy per playlist."""
        url = canonical(url)
        with self.lock: cached = self.reusable.get(url)
        if not cached: return None
        source, metadata = cached
        try:
            if (source.is_symlink() or source.resolve(strict=True) != source or
                not source.is_relative_to(self.root) or source.stat().st_size != metadata['bytes'] or
                folder.is_symlink() or folder.resolve(strict=True) != folder or not folder.is_relative_to(self.root)):
                raise ValueError('Copie locale indisponible.')
            target, record = self.store.install(source, metadata)
            record['storage'] = 'blob'
            return target, record
        except (OSError, ValueError, KeyError, MutagenError):
            with self.lock:
                if self.reusable.get(url) is cached: self.reusable.pop(url, None)
            return None

    def repair_record(self, url, folder):
        """Matched unfinished audio is never an entry in self.files/self.reusable."""
        try:
            url = canonical(url)
            if '/track/' not in url or folder.is_symlink() or folder.resolve(strict=True) != folder or not folder.is_relative_to(self.root):
                return None
            marker = worker_document(folder / 'prepared-audio.json')
            version = marker.get('version')
            if (type(version) is not int or version not in (1, 2) or
                canonical(marker.get('spotify')) != url or
                not isinstance(marker.get('source'), str) or not source_url(marker['source']) or
                not isinstance(marker.get('sha256'), str) or not re.fullmatch('[a-f0-9]{64}', marker['sha256'])):
                return None
            # Version 1 never represented M4A. Version 2 must declare its format.
            if version == 1:
                if marker.get('extension', 'mp3') != 'mp3': return None
                extension = 'mp3'
            else:
                if 'extension' not in marker: return None
                extension = audio_extension(marker)
            path = folder / ('audio.' + extension)
            if path.is_symlink() or path.resolve(strict=True) != path or not 1024 <= path.stat().st_size <= LIMIT:
                return None
            digest, size = hashlib.sha256(), 0
            with path.open('rb') as incoming:
                while chunk := incoming.read(131072):
                    size += len(chunk)
                    if size > LIMIT: return None
                    digest.update(chunk)
            if size < 1024 or digest.hexdigest() != marker['sha256']: return None
            normalized = {'version':version, 'spotify':url, 'source':source_url(marker['source']), 'sha256':marker['sha256']}
            if version == 2: normalized['extension'] = extension
            normalized.update(source_details(marker))
            return path, normalized, size
        except (OSError, ValueError, TypeError):
            return None

    def remember_repair(self, url, folder):
        record = self.repair_record(url, folder)
        if record:
            with self.lock: self.repairable[canonical(url)] = record

    def seed_repair(self, url, folder):
        """Copy verified unfinished bytes; the worker must still validate and finish them."""
        url = canonical(url)
        with self.lock: cached = self.repairable.get(url)
        if not cached: return False
        temporary, marker_tmp, installed = None, None, False
        try:
            source, marker, expected_size = cached
            if self.repair_record(url, source.parent) != cached:
                raise ValueError('Audio conservé modifié ou absent.')
            if folder.is_symlink() or folder.resolve(strict=True) != folder or not folder.is_relative_to(self.root):
                raise ValueError('Dossier de réparation invalide.')
            target, marker_path = folder / ('audio.' + audio_extension(marker)), folder / 'prepared-audio.json'
            if target.exists() or target.is_symlink() or marker_path.exists() or marker_path.is_symlink(): return False
            temporary = folder / ('repair-' + secrets.token_hex(8) + '.tmp')
            digest, size = hashlib.sha256(), 0
            with source.open('rb') as incoming, temporary.open('xb') as outgoing:
                while chunk := incoming.read(131072):
                    size += len(chunk)
                    if size > LIMIT: raise ValueError('Fichier audio trop volumineux.')
                    outgoing.write(chunk); digest.update(chunk)
            if size != expected_size or digest.hexdigest() != marker['sha256']:
                raise ValueError('Audio conservé modifié.')
            temporary.replace(target); installed = True
            marker_tmp = folder / ('marker-' + secrets.token_hex(8) + '.tmp')
            with marker_tmp.open('x', encoding='utf-8') as output: json.dump(marker, output)
            marker_tmp.replace(marker_path)
            return True
        except (OSError, ValueError, TypeError):
            with self.lock:
                if self.repairable.get(url) is cached: self.repairable.pop(url, None)
            if installed:
                try: target.unlink(missing_ok=True)
                except OSError: pass
            return False
        finally:
            for path in (temporary, marker_tmp):
                if path is not None:
                    try: path.unlink(missing_ok=True)
                    except OSError: pass

    def save(self, job):
        path = self.root / job['id']
        path.mkdir(exist_ok=True)
        safe_path(path, self.root)
        atomic_document(path / 'job.json', job)

    def snapshot(self, ident):
        with self.lock:
            if ident not in self.jobs: raise KeyError(ident)
            return copy.deepcopy(self.jobs[ident])

    def submit(self, request):
        fields = request_fields(request)
        url, key, tracks = fields['url'], fields['request_id'], fields['track_urls']
        with self.lock:
            for job in self.jobs.values():
                if job['request_id'] == key:
                    if request_fields(job) != fields:
                        raise ValueError('Cet identifiant correspond à une autre demande.')
                    return copy.deepcopy(job)
                if (job['state'] in ACTIVE and all(job.get(name) == fields[name] for name in
                    ('url', 'track_urls', 'kind', 'avoid_sources', 'refresh'))):
                    return copy.deepcopy(job)
            if sum(j['state'] in ACTIVE for j in self.jobs.values()) >= 10:
                raise ValueError('La file est pleine : attends un téléchargement en cours.')
            ident = secrets.token_hex(16)
            job = dict(fields, version=2, id=ident,
                completeMetadata=tracks is not None or '/track/' in url,
                name='Téléchargement', state='queued', items=[], message='En attente.', scope='', created=time.time())
            if fields['kind'] == 'alternative':
                job['effective_avoid_sources'] = self.effective_avoid(fields)
                job['variant_number'] = max((existing.get('variant_number', 1) for existing in self.jobs.values()
                    if existing.get('kind') == 'alternative' and existing['url'] == url), default=1) + 1
                if job['variant_number'] > 999999: raise ValueError('Nombre de versions trop élevé.')
            self.save(job)
            self.jobs[ident] = job
            self.pool.submit(self.run, ident)
            return copy.deepcopy(job)

    def worker(self, url, folder, avoid_sources=(), variant_number=None):
        with (folder / 'engine.log').open('w', encoding='utf-8') as log:
            subprocess.run([sys.executable, '-X', 'utf8', str(Path(__file__).with_name('download_worker.py')),
                url, str(folder), '--ffmpeg', self.ffmpeg], stdout=log, stderr=subprocess.STDOUT,
                timeout=240, check=True, env={**os.environ, 'SG_METADATA_CACHE_DIR':str(self.root / '.metadata-cache'),
                    'SG_ARTWORK_CACHE_DIR':str(self.root / '.artwork-cache'), 'SG_AVOID_SOURCES':json.dumps(list(avoid_sources)),
                    'SG_VARIANT_LABEL':f'Version {variant_number}' if variant_number is not None else ''},
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        metadata = worker_document(folder / 'audio-ready.json')
        if metadata.get('spotify') != url: raise ValueError('Mauvaise identité audio.')
        return folder / ('audio.' + audio_extension(metadata)), metadata

    def save_progress(self, job):
        # Caller holds self.lock: publish complete row changes and their counts together.
        ready = sum(item['state'] == 'ready' for item in job['items'])
        running = sum(item['state'] == 'running' for item in job['items'])
        job['message'] = f"{ready}/{len(job['items'])} fichiers préparés sur le PC. {running} en cours."
        self.save(job)

    def publish_worker_progress(self, job):
        with self.lock:
            running = [(item['position'], item['spotify']) for item in job['items'] if item['state'] == 'running']
        changes = []
        for position, url in running:
            folder = self.root / job['id'] / str(position)
            labels = worker_labels(folder)
            progress = worker_document(folder / 'progress.json')
            message = progress.get('message')
            message = message[:240] if progress.get('phase') in PHASES and isinstance(message, str) else None
            if labels or message: changes.append((position, url, labels, message))
        with self.lock:
            changed = False
            for position, url, labels, message in changes:
                # A completed row wins over late progress from its subprocess.
                if job['items'][position - 1]['state'] != 'running': continue
                for item in job['items']:
                    if item['spotify'] != url or item['state'] not in ('waiting', 'running'): continue
                    fields = dict(labels)
                    if item['position'] == position and message: fields['message'] = message
                    if any(item.get(key) != value for key, value in fields.items()):
                        item.update(fields); changed = True
            if changed: self.save_progress(job)

    def prepare_with_retry(self, job, item, folder):
        maximum = 1 + len(self.retry_delays)
        while item.get('attempts', 0) < maximum:
            if self.stopped(job): raise InterruptedError('Préparation arrêtée.')
            attempt = item.get('attempts', 0)
            if attempt:
                with self.lock:
                    item['message'] = 'Connexion interrompue. Nouvel essai automatique.'
                    self.save_progress(job)
                time.sleep(self.retry_delays[attempt-1])
                if self.stopped(job): raise InterruptedError('Préparation arrêtée.')
            with self.lock:
                item['attempts'] = attempt + 1
                self.save(job) # Persist the budget before issuing any network request.
            for name in ('failure.json', 'progress.json'):
                path = folder / name
                if path.is_symlink(): raise ValueError('Dossier de préparation invalide.')
                path.unlink(missing_ok=True)
            try:
                if self.custom_prepare: return self.prepare(item['spotify'], folder)
                return self.worker(item['spotify'], folder, job.get('effective_avoid_sources', []),
                    job.get('variant_number') if job['kind'] == 'alternative' else None)
            except Exception as error:
                detail = worker_document(folder / 'failure.json')
                if not (transient(error) or detail.get('code') == 'network') or attempt + 1 >= maximum: raise
        raise ValueError('Essais automatiques épuisés. Réessaie depuis l’iPhone.')

    def prepare_group(self, job, items):
        """One preparation per identity; positions refer to verified canonical files."""
        failure, labels, detail = None, {}, {}
        failure_message = 'Source introuvable, non conforme ou inaccessible.'
        for index, item in enumerate(items):
            folder = self.root / job['id'] / str(item['position'])
            if self.stopped(job): return
            if item['state'] in ('ready', 'error'): continue
            try:
                folder.mkdir(exist_ok=True)
                safe_path(folder, self.root)
                if failure is not None: raise failure
                with self.lock:
                    item.update(state='running')
                    self.save_progress(job)
                alternative = job.get('kind') == 'alternative'
                reused = None if alternative else self.reuse_audio(item['spotify'], folder)
                prepared_source = None
                if reused:
                    path, record = reused
                elif index == 0:
                    if not alternative: self.seed_repair(item['spotify'], folder)
                    path, metadata = self.prepare_with_retry(job, item, folder)
                    record = audio_record(path, metadata)
                    if alternative:
                        provenance = source_url(record.get('source'))
                        if not provenance or provenance in job.get('effective_avoid_sources', job['avoid_sources']):
                            raise ValueError('La source alternative est absente ou déjà exclue.')
                        label = f"Version {job['variant_number']}"
                        if record['album'] != label and not record['album'].endswith(' · ' + label):
                            raise ValueError('La version ne contient pas son album distinct.')
                    prepared_source = path
                    path, record = self.store.install(path, record)
                    record['storage'] = 'blob'
                else:
                    # A duplicate must not launch another search if its verified copy
                    # was removed or changed between positions.
                    raise ValueError('Copie locale indisponible ou modifiée.')
                with self.lock:
                    self.register(record['id'], path, record['extension'])
                    if not alternative: self.remember_audio(item['spotify'], path, record)
                    item.update(record, state='ready')
                    item.pop('message', None)
                    self.save_progress(job)
                # Consume only this worker's successful staging file after saving
                # the canonical reference. Legacy completed files are untouched.
                if prepared_source is not None and prepared_source.parent == folder and prepared_source != path:
                    try:
                        safe_path(prepared_source, self.root)
                        prepared_source.unlink()
                    except (OSError, ValueError): pass
            except Exception as error:
                if index == 0:
                    failure = error
                    if job.get('kind') != 'alternative': self.remember_repair(item['spotify'], folder)
                    labels = worker_labels(folder)
                    detail = worker_document(folder / 'failure.json')
                    if detail.get('code') in FAILURES and isinstance(detail.get('message'), str) and detail['message'].strip():
                        failure_message = detail['message'][:240]
                with self.lock:
                    if self.stopped(job): return
                    item.update(labels, state='error', message=failure_message)
                    if detail.get('detail') == 'no_alternative': item['detail'] = 'no_alternative'
                    self.save_progress(job)
                try: (folder / 'error.txt').write_text(str(error), encoding='utf-8')
                except OSError: pass # Diagnostics must not prevent the remaining tracks from running.

    def run(self, ident):
        with self.lock: self.running_jobs.add(ident)
        try:
            with self.lock:
                job = self.jobs[ident]
                if self.stopped(job): return
            if not job['items']:
                maximum = 1 + len(self.retry_delays)
                while True:
                    attempt = job.get('resolveAttempts', 0)
                    if attempt >= maximum: raise ValueError('Essais de lecture épuisés.')
                    if attempt: time.sleep(self.retry_delays[attempt-1])
                    with self.lock:
                        if self.stopped(job): return
                        job.update(state='resolving', message='Lecture de la sélection Spotify.', resolveAttempts=attempt+1)
                        self.save(job)
                    try:
                        name, scope, urls = self.resolve(job['url'], job.get('track_urls'))
                        urls = [canonical(url) for url in urls]
                        if not 1 <= len(urls) <= 500 or not all('/track/' in url for url in urls): raise ValueError('Liste de morceaux attendue.')
                        if job['kind'] == 'alternative' and urls != [job['url']]: raise ValueError('Identité de version incohérente.')
                        break
                    except Exception as error:
                        if not transient(error) or attempt + 1 >= maximum: raise
                with self.lock:
                    if self.stopped(job): return
                    job.update(name=name, scope=scope, items=[dict(position=i, spotify=url,
                        title='Recherche du morceau…', artist='', state='waiting') for i, url in enumerate(urls, 1)])
            with self.lock:
                if self.stopped(job): return
                job['state'] = 'running'
                self.save(job)
            groups = {}
            for item in job['items']: groups.setdefault(item['spotify'], []).append(item)
            # The outer pool still serializes playlists. This pool is joined before
            # the next playlist starts, including when queue.pool.shutdown waits.
            with ThreadPoolExecutor(max_workers=2) as tracks:
                futures = [tracks.submit(self.prepare_group, job, items) for items in groups.values()]
                pending = set(futures)
                while pending:
                    _, pending = wait(pending, timeout=0.5)
                    self.publish_worker_progress(job)
                for future in futures: future.result()
            with self.lock:
                if self.stopped(job): return
                ready = sum(item['state'] == 'ready' for item in job['items'])
                job.update(state='complete' if ready == len(job['items']) else 'partial' if ready else 'error',
                    message=f"{ready}/{len(job['items'])} fichiers préparés sur le PC.")
                self.save(job)
        except Exception as error:
            with self.lock:
                if self.stopped(self.jobs[ident]): return
                self.jobs[ident].update(state='error', message='Sélection inaccessible ou non prise en charge.')
                self.save(self.jobs[ident])
            (self.root / ident / 'error.txt').write_text(str(error), encoding='utf-8')
        finally:
            with self.lock: self.running_jobs.discard(ident)


def handler_for(queue, host, port, token, variants=None):
    base, origin = '/' + token, f'http://{host}:{port}'
    nonce = secrets.token_urlsafe(18)
    page = r'''<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>spoti.pw · Téléchargements PC</title>
<style nonce="__NONCE__">
:root{color-scheme:dark;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#101413;color:#f2f6f3}
*{box-sizing:border-box}body{margin:0;line-height:1.55}main{max-width:920px;margin:auto;padding:48px 24px 72px}
.brand{letter-spacing:.14em;font-size:.75rem;color:#aab9af;font-weight:700;text-transform:uppercase}
h1{font-size:clamp(2rem,5vw,3.2rem);letter-spacing:-.04em;line-height:1.1;margin:20px 0 14px}h2{font-size:1.15rem;margin:0 0 16px}
p{margin:8px 0;color:#b6c2ba}.connection{display:inline-flex;gap:8px;align-items:center;background:#173426;color:#a6efbc;border-radius:30px;padding:6px 12px;font-size:.85rem;margin-top:22px}
.connection:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}.connection.offline{background:#332825;color:#ffc4b4}
.setup{margin:30px 0;padding:24px;border:1px solid #2c3831;border-radius:20px;background:#17201b}ol{margin:0;padding-left:22px}li+li{margin-top:10px}strong{color:#eef5f0}
.stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:28px 0 34px}.stat{padding:18px;background:#19221d;border-radius:16px}.stat b{display:block;font-size:2rem;line-height:1.2}.stat span{color:#b6c2ba;font-size:.85rem}
.section-head{display:flex;justify-content:space-between;gap:16px;align-items:baseline}.section-head p{font-size:.8rem}
.job{border:1px solid #2c3831;border-radius:16px;padding:18px 20px;margin:12px 0}.job-head{display:flex;justify-content:space-between;align-items:start;gap:16px}.job h3{margin:0;font-size:1rem;overflow-wrap:anywhere}.badge{flex-shrink:0;font-size:.75rem;padding:4px 9px;border-radius:20px;background:#27352d;color:#c8d8ce}.badge.complete{background:#173f2a;color:#9ee7b7}.badge.error{background:#482925;color:#ffbaaa}.badge.partial{background:#43351b;color:#f2d28b}
.job p{font-size:.85rem}.job .scope{color:#edcf8b}progress{display:block;appearance:none;width:100%;height:6px;border:0;border-radius:8px;overflow:hidden;background:#2b3830;margin:16px 0 10px}progress::-webkit-progress-bar{background:#2b3830}progress::-webkit-progress-value{background:#59cd87}progress::-moz-progress-bar{background:#59cd87}
.empty{padding:28px;border:1px dashed #36463b;border-radius:16px;text-align:center}.note{font-size:.8rem;margin-top:24px;color:#8e9f93}.alert{color:#ffbcaa}footer{margin-top:32px;border-top:1px solid #29382f;padding-top:18px}
@media(max-width:540px){main{padding:28px 18px 48px}.setup{padding:20px}.stats{gap:8px}.stat{padding:14px 10px}.stat b{font-size:1.7rem}.job-head{display:block}.badge{display:inline-block;margin-top:8px}.section-head{display:block}}
</style></head><body><main>
<div class="brand">spoti.pw / compagnon PC</div><div id="connection" class="connection" role="status">PC connecté</div>
<h1>Ta musique, prête à emporter.</h1><p>Lance une demande depuis l’iPhone. Le PC prépare les fichiers et tu suis l’avancement ici.</p>
<section class="setup" aria-labelledby="setup-title"><h2 id="setup-title">Trois étapes, depuis ton téléphone</h2><ol>
<li>Dans <strong>spoti.pw → Téléchargements automatiques → Connecter le PC</strong>, colle l’adresse de cette page.</li>
<li>Ouvre ta playlist puis appuie sur sa <strong>flèche de téléchargement</strong>.</li>
<li>Garde Spotify ouvert, le PC allumé et les deux appareils sur le même réseau Wi-Fi jusqu’à la fin du transfert.</li>
</ol></section>
<div class="stats" aria-label="Bilan des dix dernières demandes"><div class="stat"><b id="ready">—</b><span>fichiers prêts sur le PC</span></div><div class="stat"><b id="active">—</b><span>demandes en cours</span></div><div class="stat"><b id="failed">—</b><span>titres en échec</span></div></div>
<section aria-labelledby="jobs-title"><div class="section-head"><h2 id="jobs-title">Dernières demandes</h2><p>Les 10 plus récentes</p></div>
<p id="notice" role="status">Lecture de l’avancement…</p><div id="jobs"></div></section>
<footer><p class="note">« Prêt sur le PC » ne confirme pas encore l’enregistrement sur l’iPhone. Vérifie la flèche verte dans l’app avant de passer hors ligne. Un titre sans source fiable reste signalé en échec.</p><p class="note">Cette page se met à jour uniquement lorsqu’elle est visible. Tu peux la fermer : le PC continue les demandes en cours.</p></footer>
</main><script nonce="__NONCE__">
(() => {
  const byId = id => document.getElementById(id);
  const endpoint = location.pathname.replace(/\/?$/, '/') + 'status';
  let timer = null, request = null, generation = 0;
  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function render(data) {
    byId('ready').textContent = data.totals.ready;
    byId('active').textContent = data.totals.active;
    byId('failed').textContent = data.totals.failed;
    const fragment = document.createDocumentFragment();
    for (const job of data.jobs) {
      const card = element('article', undefined, 'job');
      const heading = element('div', undefined, 'job-head');
      heading.append(element('h3', job.name), element('span', job.label, 'badge ' + job.tone));
      card.append(heading);
      if (job.total > 0) {
        const progress = element('progress');
        progress.max = job.total; progress.value = job.ready;
        progress.setAttribute('aria-label', 'Fichiers prêts sur le PC');
        card.append(progress, element('p', job.ready + ' / ' + job.total + ' prêts sur le PC · ' + job.running + ' en préparation · ' + job.failed + ' en échec'));
        if (job.waiting > 0) card.append(element('p', job.waiting + ' en attente'));
      }
      if (!job.completeMetadata && job.total > 0) card.append(element('p', 'La sélection reçue peut être incomplète.', 'scope'));
      if (job.state === 'error' || job.state === 'partial' || job.state === 'interrupted') {
        card.append(element('p', 'Ouvre les téléchargements dans l’app pour consulter le détail et relancer les titres manquants.'));
      }
      fragment.append(card);
    }
    if (!data.jobs.length) fragment.append(element('p', 'Aucune demande pour le moment. Appuie sur la flèche d’une playlist dans spoti.pw pour commencer.', 'empty'));
    byId('jobs').replaceChildren(fragment);
    byId('notice').textContent = 'À jour · ' + new Date().toLocaleTimeString('fr-FR', {hour:'2-digit', minute:'2-digit'});
    byId('notice').className = '';
    byId('connection').textContent = 'PC connecté'; byId('connection').className = 'connection';
  }
  function stop() {
    clearTimeout(timer); generation += 1;
    if (request) request.abort();
    request = null;
  }
  async function refresh() {
    if (document.hidden || request) return;
    const current = generation, controller = new AbortController(); request = controller;
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(endpoint, {cache:'no-store', credentials:'omit', redirect:'error', signal:controller.signal});
      if (!response.ok) throw new Error('Indisponible');
      const data = await response.json();
      if (current === generation && !document.hidden) render(data);
    } catch (_) {
      if (current === generation && !document.hidden) {
        byId('connection').textContent = 'PC injoignable'; byId('connection').className = 'connection offline';
        byId('notice').textContent = 'Actualisation impossible. Les derniers chiffres restent affichés ; vérifie que le compagnon PC est toujours ouvert.';
        byId('notice').className = 'alert';
      }
    } finally {
      clearTimeout(timeout);
      if (current === generation) { request = null; if (!document.hidden) timer = setTimeout(refresh, 3000); }
    }
  }
  document.addEventListener('visibilitychange', () => { stop(); if (!document.hidden) refresh(); });
  window.addEventListener('pagehide', stop);
  window.addEventListener('pageshow', () => { if (!document.hidden) refresh(); });
  refresh();
})();
</script></body></html>'''.replace('__NONCE__', nonce).encode('utf-8')

    def status_summary():
        labels = {'queued':'En attente', 'resolving':'Lecture de la sélection', 'running':'Préparation en cours',
                  'complete':'Prêt sur le PC', 'partial':'Des titres restent à vérifier',
                  'error':'Demande échouée', 'interrupted':'À relancer après redémarrage'}
        jobs = []
        with queue.lock:
            recent = sorted(queue.jobs.values(), key=lambda job: job.get('created', 0), reverse=True)[:10]
            for job in recent:
                items = job.get('items', [])
                state = job.get('state', 'interrupted')
                if state not in labels: state = 'interrupted'
                ready = sum(item.get('state') == 'ready' for item in items)
                failed = sum(item.get('state') == 'error' for item in items)
                running = sum(item.get('state') == 'running' for item in items) if state in ACTIVE else 0
                complete = bool(job.get('completeMetadata', False))
                name = job.get('name')
                jobs.append({'name':name[:160] if isinstance(name, str) and name.strip() else 'Téléchargement',
                    'state':state, 'label':'Titres accessibles prêts' if state == 'complete' and not complete else labels[state],
                    'tone':'partial' if state == 'complete' and not complete else state,
                    'total':len(items), 'ready':ready, 'running':running, 'failed':failed,
                    'waiting':len(items) - ready - running - failed,
                    'completeMetadata':complete})
        return {'jobs':jobs, 'limit':10, 'totals':{'ready':sum(job['ready'] for job in jobs),
                'active':sum(job['state'] in ACTIVE for job in jobs), 'failed':sum(job['failed'] for job in jobs)}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def reply(self, code, data, kind='application/json; charset=utf-8'):
            if not isinstance(data, bytes): data = json.dumps(data, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('X-Frame-Options', 'DENY')
            if kind.startswith('text/html'):
                self.send_header('Content-Security-Policy', "default-src 'none'; connect-src 'self'; "
                    f"script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; "
                    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            path = urlsplit(self.path)
            if (self.headers.get('Host') != f'{host}:{port}' or path.query or path.fragment or
                path.path not in (base+'/jobs', base+'/accept-version', base+'/storage/cleanup', base+'/audio-variants') or self.headers.get('Origin') not in (None, origin) or
                self.headers.get('Content-Type', '').split(';')[0] != 'application/json'):
                return self.reply(403, {'error':'Requête refusée.'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 65536: return self.reply(413, {'error':'Requête trop volumineuse.'})
                self.connection.settimeout(15)
                payload = self.rfile.read(size)
                if len(payload) != size: raise ValueError('Requête incomplète.')
                request = json.loads(payload)
                if path.path == base+'/audio-variants':
                    if variants is None: return self.reply(503, {'error':'Les versions audio ne sont pas disponibles sur ce compagnon.'})
                    from download_variants import VariantRequestError
                    try: return self.reply(202, variants.submit(request))
                    except VariantRequestError as error: return self.reply(400, {'error':str(error)[:300]})
                if path.path == base+'/accept-version': return self.reply(200, queue.accept_version(request))
                if path.path == base+'/storage/cleanup': return self.reply(200, queue.cleanup_storage(request))
                return self.reply(202, queue.submit(request))
            except (ValueError, OSError): return self.reply(400, {'error':'Demande invalide ou file pleine.'})
        def do_GET(self):
            parsed = urlsplit(self.path)
            if (self.headers.get('Host') != f'{host}:{port}' or parsed.fragment or
                self.headers.get('Origin') not in (None, origin)):
                return self.reply(404, {})
            if parsed.path == '/discover':
                from companion_discovery import discovery_reply
                result = discovery_reply(self.path, host, port, token)
                return self.reply(200, result) if result is not None else self.reply(404, {})
            if parsed.query: return self.reply(404, {})
            path = parsed.path
            if path in (base, base + '/'):
                return self.reply(200, page, 'text/html; charset=utf-8')
            if path == base + '/hello': return self.reply(200, {'version':2,'service':'spoti-auto-downloads'})
            if path == base + '/capabilities': return self.reply(200, dict(CAPABILITIES, audioVariants=variants is not None))
            if path == base + '/audio-variants':
                return self.reply(200, variants.listing()) if variants is not None else self.reply(404, {})
            variant_id = path.removeprefix(base + '/audio-variants/')
            if re.fullmatch('[a-f0-9]{32}', variant_id):
                if variants is None: return self.reply(404, {})
                try: return self.reply(200, variants.get(variant_id))
                except KeyError: return self.reply(404, {})
            if path == base + '/storage': return self.reply(200, queue.storage_status())
            if path == base + '/status': return self.reply(200, status_summary())
            ident = path.removeprefix(base + '/jobs/')
            if re.fullmatch('[a-f0-9]{32}', ident):
                try: return self.reply(200, queue.snapshot(ident))
                except KeyError: return self.reply(404, {})
            ident = path.removeprefix(base + '/file/')
            with queue.lock: record = queue.files.get(ident)
            if not record or not re.fullmatch('[a-f0-9]{64}', ident): return self.reply(404, {})
            source, stamp, extension = record
            size, etag = stamp[0], '"' + ident + '"'
            headers_sent = False
            try:
                if (source.is_symlink() or source.resolve(strict=True) != source or not source.is_relative_to(queue.root) or
                    file_stamp(source.stat()) != stamp): return self.reply(409, {})
                with source.open('rb') as stream:
                    # Check the opened file as well as its path. Hashing is bounded to
                    # the registered size and also catches same-size/mtime tampering.
                    # The client verifies this same digest after joining a resumed file.
                    if (file_stamp(os.fstat(stream.fileno())) != stamp or bounded_digest(stream, size) != ident or
                        file_stamp(os.fstat(stream.fileno())) != stamp or file_stamp(source.stat()) != stamp):
                        return self.reply(409, {})
                    requested = self.headers.get_all('Range', [])
                    try:
                        if len(requested) > 1: raise ValueError('Plusieurs plages.')
                        interval = byte_range(requested[0] if requested else None, size) if self.headers.get('If-Range') in (None, etag) else None
                    except ValueError:
                        self.send_response(416)
                        self.send_header('Content-Range', f'bytes */{size}')
                        self.send_header('Accept-Ranges', 'bytes')
                        self.send_header('ETag', etag)
                        self.send_header('Content-Length', '0')
                        self.send_header('Cache-Control', 'no-store')
                        self.end_headers()
                        return
                    start, end = interval if interval is not None else (0, size-1)
                    remaining = end-start+1
                    stream.seek(start)
                    self.connection.settimeout(20)
                    self.send_response(206 if interval is not None else 200)
                    self.send_header('Content-Type', 'audio/mp4' if extension == 'm4a' else 'audio/mpeg')
                    self.send_header('Content-Length', str(remaining))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.send_header('ETag', etag)
                    self.send_header('Cache-Control', 'no-store')
                    self.send_header('X-Content-Type-Options', 'nosniff')
                    self.send_header('Referrer-Policy', 'no-referrer')
                    if interval is not None: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
                    headers_sent = True
                    self.end_headers()
                    while remaining:
                        chunk = stream.read(min(131072, remaining))
                        if (not chunk or file_stamp(os.fstat(stream.fileno())) != stamp or
                            source.is_symlink() or source.resolve(strict=True) != source or file_stamp(source.stat()) != stamp):
                            raise ValueError('Fichier audio modifié pendant le transfert.')
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (OSError, ValueError):
                if not headers_sent:
                    try: self.reply(409, {})
                    except OSError: pass
                self.close_connection = True
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', required=True, type=lan_address)
    parser.add_argument('--port', type=int, default=8768)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--session', type=Path, required=True)
    parser.add_argument('--lifetime-seconds', type=int, default=21600)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535: raise ValueError('Port invalide.')
    if not 0 <= args.lifetime_seconds <= 86400: raise ValueError('Durée de service invalide.')
    token = secrets.token_urlsafe(24)
    session_fields = {}
    if args.session.is_file() and not args.session.is_symlink():
        try:
            session_fields = worker_document(args.session)
            previous = urlsplit(session_fields['url'])
            candidate = previous.path.strip('/')
            if (previous.scheme == 'http' and not previous.username and not previous.password and
                not previous.query and not previous.fragment and previous.port == args.port and
                lan_address(previous.hostname) and re.fullmatch('[A-Za-z0-9_-]{32}', candidate)):
                token = candidate
        except (ValueError, KeyError, TypeError, OSError): pass
    queue = Queue(args.data, args.ffmpeg, start=False)
    server = timer = variants = None
    try:
        from download_variants import VariantQueue
        variants = VariantQueue(queue, args.ffmpeg)
        server = ThreadingHTTPServer((args.bind, args.port), handler_for(queue, args.bind, args.port, token, variants))
        url = f'http://{args.bind}:{args.port}/{token}/'
        args.session.parent.mkdir(parents=True, exist_ok=True)
        atomic_document(args.session, dict(session_fields, url=url))
        print(url, flush=True)
        from companion_discovery import advertise
        with advertise(args.bind, args.port, token):
            queue.resume_pending()
            timer = threading.Timer(args.lifetime_seconds, server.shutdown) if args.lifetime_seconds else None
            if timer:
                timer.daemon = True
                timer.start()
            server.serve_forever()
    finally:
        if timer: timer.cancel()
        if server: server.server_close()
        if variants: variants.shutdown(wait=True)
        queue.pool.shutdown(wait=True, cancel_futures=True)


if __name__ == '__main__': main()
