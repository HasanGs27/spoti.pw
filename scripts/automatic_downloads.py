"""LAN companion for explicit Spotify download requests. No accounts or cookies."""
import argparse
import copy
import hashlib
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from mutagen import MutagenError
from mutagen.mp3 import MP3
from download_metadata import canonical, collection
from download_worker import source_url

LIMIT = 100 * 1024 * 1024
ACTIVE = {"queued", "resolving", "running"}
PHASES = {'metadata', 'search', 'download', 'cover', 'verify'}
FAILURES = {'network', 'unavailable', 'no_match', 'invalid_audio', 'cover', 'error'}


def worker_document(path):
    """Best-effort bounded reads: workers can still be writing metadata on failure."""
    try:
        if path.is_symlink() or path.stat().st_size > 16384: return {}
        with path.open('rb') as stream: data = stream.read(16385)
        if len(data) > 16384: return {}
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
        self.reusable, self.repairable = {}, {}
        self.pool = ThreadPoolExecutor(max_workers=1)
        for path in self.root.glob('*/job.json'):
            if not re.fullmatch('[a-f0-9]{32}', path.parent.name) or path.is_symlink(): continue
            try:
                job = json.loads(path.read_text(encoding='utf-8'))
                if job['id'] != path.parent.name: continue
                if 'completeMetadata' not in job:
                    tracks = job.get('track_urls')
                    job['completeMetadata'] = ('/track/' in canonical(job['url']) or
                        isinstance(tracks, list) and 1 <= len(tracks) <= 500 and
                        all('/track/' in canonical(track) for track in tracks))
                if job['state'] in ACTIVE:
                    job.update(state='interrupted', message='PC redémarré : relance ce téléchargement.')
                for item in job.get('items', []):
                    if item['state'] == 'ready':
                        audio = path.parent / str(item['position']) / 'audio.mp3'
                        record = audio_record(audio, item) if audio.is_file() else None
                        if record and record['id'] == item['id']:
                            self.register(item['id'], audio)
                            self.remember_audio(item['spotify'], audio, record)
                        else:
                            item.update(state='error', message='Fichier absent ou modifié sur le PC.')
                            job.update(state='partial', message='Certains fichiers ne sont plus disponibles sur le PC.')
                    if item['state'] != 'ready':
                        self.remember_repair(item['spotify'], path.parent / str(item['position']))
                self.jobs[job['id']] = job
                self.save(job)
            except (ValueError, KeyError, OSError, MutagenError): continue

    def register(self, ident, path):
        path = path.resolve(strict=True)
        if not path.is_relative_to(self.root): raise ValueError('Chemin audio invalide.')
        stat = path.stat()
        self.files[ident] = (path, stat.st_size, stat.st_mtime_ns)

    def remember_audio(self, url, path, record):
        url = canonical(url)
        if '/track/' not in url: return
        path = path.resolve(strict=True)
        if not path.is_relative_to(self.root): raise ValueError('Chemin audio invalide.')
        self.reusable[url] = (path, dict(record))

    def reuse_audio(self, url, folder):
        """Reuse only the exact previously verified file for this Spotify identity."""
        url = canonical(url)
        with self.lock: cached = self.reusable.get(url)
        if not cached: return None
        source, metadata = cached
        temporary = None
        try:
            if (source.is_symlink() or source.resolve(strict=True) != source or
                not source.is_relative_to(self.root) or source.stat().st_size != metadata['bytes'] or
                folder.is_symlink() or folder.resolve(strict=True) != folder or not folder.is_relative_to(self.root)):
                raise ValueError('Copie locale indisponible.')
            temporary = folder / ('reuse-' + secrets.token_hex(8) + '.tmp')
            # A separate copy keeps playlist files independent. Bound the copy even if
            # the source is changed while reading, then verify the destination itself.
            with source.open('rb') as incoming, temporary.open('xb') as outgoing:
                copied = 0
                while chunk := incoming.read(131072):
                    copied += len(chunk)
                    if copied > LIMIT: raise ValueError('Fichier audio trop volumineux.')
                    outgoing.write(chunk)
            record = audio_record(temporary, metadata)
            if record['id'] != metadata['id']:
                raise ValueError('Le fichier audio a changé.')
            target = folder / 'audio.mp3'
            temporary.replace(target)
            return target, record
        except (OSError, ValueError, KeyError, MutagenError):
            with self.lock:
                if self.reusable.get(url) is cached: self.reusable.pop(url, None)
            return None
        finally:
            if temporary is not None: temporary.unlink(missing_ok=True)

    def repair_record(self, url, folder):
        """A matched but unfinished MP3 is never an entry in self.files/self.reusable."""
        try:
            url = canonical(url)
            if '/track/' not in url or folder.is_symlink() or folder.resolve(strict=True) != folder or not folder.is_relative_to(self.root):
                return None
            marker = worker_document(folder / 'prepared-audio.json')
            if (marker.get('version') != 1 or isinstance(marker.get('version'), bool) or
                canonical(marker.get('spotify')) != url or
                not isinstance(marker.get('source'), str) or not source_url(marker['source']) or
                not isinstance(marker.get('sha256'), str) or not re.fullmatch('[a-f0-9]{64}', marker['sha256'])):
                return None
            path = folder / 'audio.mp3'
            if path.is_symlink() or path.resolve(strict=True) != path or not 1024 <= path.stat().st_size <= LIMIT:
                return None
            digest, size = hashlib.sha256(), 0
            with path.open('rb') as incoming:
                while chunk := incoming.read(131072):
                    size += len(chunk)
                    if size > LIMIT: return None
                    digest.update(chunk)
            if size < 1024 or digest.hexdigest() != marker['sha256']: return None
            return path, {'version':1, 'spotify':url, 'source':source_url(marker['source']), 'sha256':marker['sha256']}, size
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
            target, marker_path = folder / 'audio.mp3', folder / 'prepared-audio.json'
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
                completeMetadata=tracks is not None or '/track/' in url,
                name='Téléchargement', state='queued', items=[], message='En attente.', scope='', created=time.time())
            self.jobs[ident] = job
            self.save(job)
            self.pool.submit(self.run, ident)
            return copy.deepcopy(job)

    def worker(self, url, folder):
        with (folder / 'engine.log').open('w', encoding='utf-8') as log:
            subprocess.run([sys.executable, '-X', 'utf8', str(Path(__file__).with_name('download_worker.py')),
                url, str(folder), '--ffmpeg', self.ffmpeg], stdout=log, stderr=subprocess.STDOUT,
                timeout=240, check=True, env={**os.environ, 'SG_METADATA_CACHE_DIR':str(self.root / '.metadata-cache')},
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        metadata = json.loads((folder / 'audio-ready.json').read_text(encoding='utf-8'))
        if metadata['spotify'] != url: raise ValueError('Mauvaise identité audio.')
        return folder / 'audio.mp3', metadata

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

    def prepare_group(self, job, items):
        """One preparation per Spotify identity; duplicate positions keep separate files."""
        failure, labels = None, {}
        failure_message = 'Source introuvable, non conforme ou inaccessible.'
        for index, item in enumerate(items):
            folder = self.root / job['id'] / str(item['position'])
            try:
                folder.mkdir(exist_ok=True)
                if failure is not None: raise failure
                with self.lock:
                    item.update(state='running')
                    self.save_progress(job)
                reused = self.reuse_audio(item['spotify'], folder)
                if reused:
                    path, record = reused
                elif index == 0:
                    self.seed_repair(item['spotify'], folder)
                    path, metadata = self.prepare(item['spotify'], folder)
                    record = audio_record(path, metadata)
                else:
                    # A duplicate must not launch another search if its verified copy
                    # was removed or changed between positions.
                    raise ValueError('Copie locale indisponible ou modifiée.')
                with self.lock:
                    self.register(record['id'], path)
                    self.remember_audio(item['spotify'], path, record)
                    item.update(record, state='ready')
                    item.pop('message', None)
                    self.save_progress(job)
            except Exception as error:
                if index == 0:
                    failure = error
                    self.remember_repair(item['spotify'], folder)
                    labels = worker_labels(folder)
                    detail = worker_document(folder / 'failure.json')
                    if detail.get('code') in FAILURES and isinstance(detail.get('message'), str) and detail['message'].strip():
                        failure_message = detail['message'][:240]
                with self.lock:
                    item.update(labels, state='error', message=failure_message)
                    self.save_progress(job)
                try: (folder / 'error.txt').write_text(str(error), encoding='utf-8')
                except OSError: pass # Diagnostics must not prevent the remaining tracks from running.

    def run(self, ident):
        try:
            with self.lock:
                job = self.jobs[ident]
                job.update(state='resolving', message='Lecture de la sélection Spotify.')
                self.save(job)
            name, scope, urls = self.resolve(job['url'], job.get('track_urls'))
            urls = [canonical(url) for url in urls]
            if not urls or not all('/track/' in url for url in urls):
                raise ValueError('Liste de morceaux attendue.')
            with self.lock:
                job.update(name=name, scope=scope, state='running', items=[
                    dict(position=i, spotify=url, title='Recherche du morceau…', artist='', state='waiting')
                    for i, url in enumerate(urls, 1)])
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
            if (self.headers.get('Host') != f'{host}:{port}' or parsed.query or parsed.fragment or
                self.headers.get('Origin') not in (None, origin)):
                return self.reply(404, {})
            path = parsed.path
            if path in (base, base + '/'):
                return self.reply(200, page, 'text/html; charset=utf-8')
            if path == base + '/hello': return self.reply(200, {'version':2,'service':'spoti-auto-downloads'})
            if path == base + '/status': return self.reply(200, status_summary())
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
