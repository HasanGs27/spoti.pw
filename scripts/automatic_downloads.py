"""LAN companion for explicit Spotify download requests. No accounts or cookies."""
import argparse
import copy
import hashlib
import ipaddress
import json
import re
import secrets
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from mutagen.mp3 import MP3
from download_metadata import canonical, collection

LIMIT = 100 * 1024 * 1024
ACTIVE = {"queued", "resolving", "running"}


def lan_address(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Adresse du réseau local requise.")
    return str(address)


def audio_record(path, metadata):
    if path.is_symlink() or not 1024 <= path.stat().st_size <= LIMIT:
        raise ValueError("Fichier audio invalide.")
    audio = MP3(path)
    if audio.info.length < 1 or not audio.tags or not audio.tags.getall("APIC"):
        raise ValueError("Audio ou pochette manquant.")
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {"id": digest, "bytes": path.stat().st_size, "seconds": round(audio.info.length, 3),
        "title": str(audio.tags['TIT2']), "artist": str(audio.tags['TPE1']),
        "album": str(audio.tags.get('TALB', '')), "cover": True,
        "source": metadata.get('source', ''), "quality": metadata.get('quality', '')}


class Queue:
    def __init__(self, root, ffmpeg, prepare=None, resolve=collection):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.ffmpeg, self.resolve, self.prepare = ffmpeg, resolve, prepare or self.worker
        self.lock, self.jobs, self.files = threading.RLock(), {}, {}
        self.pool = ThreadPoolExecutor(max_workers=1)
        for path in self.root.glob('*/job.json'):
            if not re.fullmatch('[a-f0-9]{32}', path.parent.name) or path.is_symlink(): continue
            try:
                job = json.loads(path.read_text(encoding='utf-8'))
                if job['id'] != path.parent.name: continue
                if job['state'] in ACTIVE:
                    job.update(state='interrupted', message='PC redémarré : relance ce téléchargement.')
                for item in job.get('items', []):
                    if item['state'] == 'ready':
                        audio = path.parent / str(item['position']) / 'audio.mp3'
                        if audio.is_file() and audio_record(audio, item)['id'] == item['id']:
                            self.register(item['id'], audio)
                        else:
                            item.update(state='error', message='Fichier absent ou modifié sur le PC.')
                            job.update(state='partial', message='Certains fichiers ne sont plus disponibles sur le PC.')
                self.jobs[job['id']] = job
                self.save(job)
            except (ValueError, KeyError, OSError): continue

    def register(self, ident, path):
        path = path.resolve(strict=True)
        if not path.is_relative_to(self.root): raise ValueError('Chemin audio invalide.')
        stat = path.stat()
        self.files[ident] = (path, stat.st_size, stat.st_mtime_ns)

    def save(self, job):
        path = self.root / job['id']
        path.mkdir(exist_ok=True)
        tmp = path / 'job.tmp'
        tmp.write_text(json.dumps(job, ensure_ascii=False), encoding='utf-8')
        tmp.replace(path / 'job.json')

    def snapshot(self, ident):
        with self.lock:
            if ident not in self.jobs: raise KeyError(ident)
            return copy.deepcopy(self.jobs[ident])

    def submit(self, request):
        if not isinstance(request, dict): raise ValueError('Requête invalide.')
        url = canonical(request.get('url'))
        key = request.get('request_id', '')
        if not isinstance(key, str) or not re.fullmatch('[A-Za-z0-9-]{16,64}', key):
            raise ValueError('Identifiant de requête invalide.')
        tracks = request.get('track_urls')
        if tracks is not None:
            if not isinstance(tracks, list) or not 1 <= len(tracks) <= 500:
                raise ValueError('Au maximum 500 morceaux par demande.')
            tracks = [canonical(track) for track in tracks]
            if not all('/track/' in track for track in tracks): raise ValueError('Liste de morceaux attendue.')
        with self.lock:
            for job in self.jobs.values():
                if job['request_id'] == key:
                    if job['url'] != url or job.get('track_urls') != tracks:
                        raise ValueError('Cet identifiant correspond à une autre demande.')
                    return copy.deepcopy(job)
                if job['url'] == url and job['state'] in ACTIVE:
                    return copy.deepcopy(job)
            if sum(j['state'] in ACTIVE for j in self.jobs.values()) >= 10:
                raise ValueError('La file est pleine : attends un téléchargement en cours.')
            ident = secrets.token_hex(16)
            job = dict(version=2, id=ident, request_id=key, url=url, track_urls=tracks,
                name='Téléchargement', state='queued', items=[], message='En attente.', scope='', created=time.time())
            self.jobs[ident] = job
            self.save(job)
            self.pool.submit(self.run, ident)
            return copy.deepcopy(job)

    def worker(self, url, folder):
        with (folder / 'engine.log').open('w', encoding='utf-8') as log:
            subprocess.run([sys.executable, '-X', 'utf8', str(Path(__file__).with_name('download_worker.py')),
                url, str(folder), '--ffmpeg', self.ffmpeg], stdout=log, stderr=subprocess.STDOUT,
                timeout=240, check=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        metadata = json.loads((folder / 'audio-ready.json').read_text(encoding='utf-8'))
        if metadata['spotify'] != url: raise ValueError('Mauvaise identité audio.')
        return folder / 'audio.mp3', metadata

    def run(self, ident):
        try:
            with self.lock:
                job = self.jobs[ident]
                job.update(state='resolving', message='Lecture de la sélection Spotify.')
                self.save(job)
            name, scope, urls = self.resolve(job['url'], job.get('track_urls'))
            with self.lock:
                job.update(name=name, scope=scope, state='running', items=[
                    dict(position=i, spotify=url, title='Recherche du morceau…', artist='', state='waiting')
                    for i, url in enumerate(urls, 1)])
                self.save(job)
            for item in job['items']:
                folder = self.root / ident / str(item['position'])
                folder.mkdir(exist_ok=True)
                with self.lock:
                    item.update(state='running')
                    job['message'] = f"Recherche audio {item['position']}/{len(urls)}."
                    self.save(job)
                try:
                    path, metadata = self.prepare(item['spotify'], folder)
                    record = audio_record(path, metadata)
                    with self.lock:
                        self.register(record['id'], path)
                        item.update(record, state='ready')
                        self.save(job)
                except Exception as error:
                    metadata_file = folder / 'metadata.json'
                    labels = {}
                    if metadata_file.is_file():
                        try:
                            metadata = json.loads(metadata_file.read_text(encoding='utf-8'))
                            labels = {key:metadata[key] for key in ('title','artist') if isinstance(metadata.get(key), str)}
                        except (ValueError, OSError): pass
                    with self.lock:
                        item.update(labels, state='error', message='Source introuvable, non conforme ou inaccessible.')
                        self.save(job)
                    (folder / 'error.txt').write_text(str(error), encoding='utf-8')
            with self.lock:
                ready = sum(item['state'] == 'ready' for item in job['items'])
                job.update(state='complete' if ready == len(urls) else 'partial' if ready else 'error',
                    message=f'{ready}/{len(urls)} fichiers préparés sur le PC.')
                self.save(job)
        except Exception as error:
            with self.lock:
                self.jobs[ident].update(state='error', message='Sélection inaccessible ou non prise en charge.')
                self.save(self.jobs[ident])
            (self.root / ident / 'error.txt').write_text(str(error), encoding='utf-8')


def handler_for(queue, host, port, token):
    base, origin = '/' + token, f'http://{host}:{port}'
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
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            path = urlsplit(self.path)
            if (self.headers.get('Host') != f'{host}:{port}' or path.query or path.fragment or
                path.path != base + '/jobs' or self.headers.get('Origin') not in (None, origin) or
                self.headers.get('Content-Type', '').split(';')[0] != 'application/json'):
                return self.reply(403, {'error':'Requête refusée.'})
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 65536: return self.reply(413, {'error':'Requête trop volumineuse.'})
                self.connection.settimeout(15)
                payload = self.rfile.read(size)
                if len(payload) != size: raise ValueError('Requête incomplète.')
                return self.reply(202, queue.submit(json.loads(payload)))
            except (ValueError, OSError): return self.reply(400, {'error':'Demande invalide ou file pleine.'})
        def do_GET(self):
            parsed = urlsplit(self.path)
            if self.headers.get('Host') != f'{host}:{port}' or parsed.query or parsed.fragment:
                return self.reply(404, {})
            path = parsed.path
            if path in (base, base + '/'):
                return self.reply(200, ("<!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
                    "<title>Téléchargements automatiques</title><style>body{font:18px system-ui;padding:24px;background:#111;color:white;line-height:1.5}</style>"
                    "<h1>PC prêt</h1><p>Copie l’adresse de cette page dans <b>spoti.pw → Player → Téléchargements automatiques → Connecter le PC</b>.</p>"
                    "<p>Ensuite, utilise la flèche d’une playlist Spotify. Garde Spotify ouvert, le PC allumé et les deux appareils sur le même Wi-Fi.</p>"
                    "<p>Prototype : les sources audio sont externes. Un titre sans correspondance fiable sera signalé en échec.</p>").encode(), 'text/html; charset=utf-8')
            if path == base + '/hello': return self.reply(200, {'version':2,'service':'spoti-auto-downloads'})
            ident = path.removeprefix(base + '/jobs/')
            if re.fullmatch('[a-f0-9]{32}', ident):
                try: return self.reply(200, queue.snapshot(ident))
                except KeyError: return self.reply(404, {})
            ident = path.removeprefix(base + '/file/')
            with queue.lock: record = queue.files.get(ident)
            if not record or not re.fullmatch('[a-f0-9]{64}', ident): return self.reply(404, {})
            source, size, stamp = record
            try:
                stat = source.stat()
                if source.is_symlink() or source.resolve() != source or (stat.st_size,stat.st_mtime_ns) != (size,stamp):
                    return self.reply(409,{})
                with source.open('rb') as stream:
                    self.send_response(200)
                    self.send_header('Content-Type','audio/mpeg')
                    self.send_header('Content-Length',str(size))
                    self.end_headers()
                    while chunk := stream.read(131072): self.wfile.write(chunk)
            except OSError: self.close_connection = True
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', required=True, type=lan_address)
    parser.add_argument('--port', type=int, default=8768)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--session', type=Path, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535: raise ValueError('Port invalide.')
    token = secrets.token_urlsafe(24)
    if args.session.is_file() and not args.session.is_symlink():
        try:
            previous = urlsplit(json.loads(args.session.read_text(encoding='utf-8'))['url'])
            candidate = previous.path.strip('/')
            if previous.netloc == f'{args.bind}:{args.port}' and re.fullmatch('[A-Za-z0-9_-]{32}', candidate):
                token = candidate
        except (ValueError, KeyError, OSError): pass
    queue = Queue(args.data, args.ffmpeg)
    server = ThreadingHTTPServer((args.bind, args.port), handler_for(queue, args.bind, args.port, token))
    url = f'http://{args.bind}:{args.port}/{token}/'
    args.session.parent.mkdir(parents=True, exist_ok=True)
    args.session.write_text(json.dumps({'url':url}), encoding='utf-8')
    print(url, flush=True)
    timer = threading.Timer(6*3600, server.shutdown)
    timer.daemon = True
    timer.start()
    try: server.serve_forever()
    finally:
        timer.cancel()
        server.server_close()
        queue.pool.shutdown(wait=True)


if __name__ == '__main__': main()
