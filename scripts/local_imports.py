"""Independent imports of user-confirmed sources; no Spotify catalogue identities."""
import copy
import math
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

from mutagen import MutagenError

from download_storage import atomic_document, safe_path
from local_import_media import source_url

ACTIVE = {'queued', 'running'}
STATES = ACTIVE | {'ready', 'error', 'cancelled', 'interrupted'}


class LocalImportRequestError(ValueError):
    """Only fixed, safe text may be returned through the authenticated API."""


def request_fields(request):
    if not isinstance(request, dict): raise LocalImportRequestError('Demande d’import invalide.')
    key = request.get('request_id')
    if not isinstance(key, str) or not re.fullmatch('[A-Za-z0-9-]{16,64}', key):
        raise LocalImportRequestError('Identifiant de demande invalide.')
    try: url, kind = source_url(request.get('source_url'))
    except (ValueError, TypeError, UnicodeError):
        raise LocalImportRequestError('Choisis un lien YouTube ou un lien HTTPS public vers un MP3/M4A.') from None
    result = {'request_id':key, 'source_url':url, 'source_kind':kind}
    for field, fallback in (('title', ''), ('artist', 'Import personnel'), ('album', 'Imports personnels')):
        value = request.get(field, fallback)
        if not isinstance(value, str): raise LocalImportRequestError('Titre, artiste ou album invalide.')
        value = value.strip() or fallback
        if not value or len(value) > 200 or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise LocalImportRequestError('Confirme un titre et des libellés de 200 caractères maximum.')
        result[field] = value
    if 'spotify' in request: raise LocalImportRequestError('Cet import personnel ne crée pas d’association Spotify.')
    return result


class LocalImportQueue:
    def __init__(self, queue, ffmpeg, worker=None, timeout=240):
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 1 <= timeout <= 240:
            raise ValueError('Délai d’import invalide.')
        self.queue, self.root, self.lock = queue, Path(queue.root), queue.lock
        self.ffmpeg, self.timeout, self.worker = ffmpeg, timeout, worker or self._worker
        self.directory = self.root / '.local-imports'
        safe_path(self.directory, self.root, exists=False); self.directory.mkdir(exist_ok=True)
        self.job_directory = self.directory / 'jobs'
        safe_path(self.job_directory, self.root, exists=False); self.job_directory.mkdir(exist_ok=True)
        self.jobs, self.closed = {}, False
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='local-import')
        self._restore()

    @staticmethod
    def capabilities(): return {'youtube':True, 'directHTTPS':True}

    @staticmethod
    def _public(job): return copy.deepcopy({key:value for key,value in job.items() if not key.startswith('_')})

    def listing(self):
        with self.lock:
            return {'version':1, 'capabilities':self.capabilities(), 'jobs':[self._public(job) for job in
                sorted(self.jobs.values(), key=lambda value:value['created'], reverse=True)[:200]]}

    def get(self, ident):
        with self.lock:
            if not isinstance(ident, str) or ident not in self.jobs: raise KeyError(ident)
            return self._public(self.jobs[ident])

    def _save(self, job):
        safe_path(self.job_directory, self.root)
        atomic_document(self.job_directory / (job['id'] + '.json'), job)

    def _path(self, relative):
        if (not isinstance(relative, str) or '\\' in relative or '\x00' in relative or ':' in relative or
                Path(relative).is_absolute() or any(part in ('', '.', '..') for part in relative.split('/'))):
            raise ValueError('Fichier d’import invalide.')
        path = self.root / relative
        safe_path(path, self.root)
        if not path.is_relative_to(self.directory) or path.is_relative_to(self.job_directory):
            raise ValueError('Fichier d’import hors du dossier privé.')
        if path.suffix not in ('.mp3', '.m4a'): raise ValueError('Format d’import invalide.')
        return path

    def _verified(self, path, row, fields, ident):
        from automatic_downloads import audio_record
        if not isinstance(row, dict): raise ValueError('Résultat d’import invalide.')
        checked = audio_record(path, row)
        if (checked['id'] != row['id'] or checked['bytes'] != row['bytes'] or
                checked['extension'] != path.suffix[1:] or not 1 <= checked['seconds'] <= 1801 or
                any(checked[key] != fields[key] for key in ('title', 'artist', 'album'))):
            raise ValueError('Import modifié ou incohérent.')
        for key in ('source', 'spotify'): checked.pop(key, None)
        return dict(checked, state='ready', position=1, local_id=ident, source_url=fields['source_url'],
                    sourceURL=fields['source_url'], sourceKind=fields['source_kind'])

    def _restore(self):
        from automatic_downloads import worker_document
        with self.lock:
            for path in self.job_directory.glob('*.json'):
                try:
                    if not re.fullmatch('[a-f0-9]{32}', path.stem): continue
                    safe_path(path, self.root)
                    saved = worker_document(path, 128 * 1024)
                    fields = request_fields(saved)
                    if saved.get('version') != 1 or saved.get('id') != path.stem or saved.get('state') not in STATES: continue
                    created = saved.get('created')
                    if type(created) not in (int, float) or not math.isfinite(created): continue
                    job = dict(fields, version=1, id=path.stem, created=created, state=saved['state'], message='Import conservé.')
                    if saved['state'] in ACTIVE:
                        job.update(state='interrupted', message='Le PC a redémarré. Relance cet import si nécessaire.')
                    elif saved['state'] == 'ready':
                        try:
                            output = self._path(saved['_audio'])
                            row = self._verified(output, saved['row'], fields, path.stem)
                            self.queue.register(row['id'], output, row['extension'])
                            job.update(row=row, _audio=saved['_audio'], message='Import prêt à enregistrer.')
                        except (OSError, ValueError, KeyError, TypeError, MutagenError):
                            job.update(state='error', message='Le fichier importé est absent ou a changé sur le PC.')
                    elif saved['state'] == 'cancelled': job['message'] = 'Import annulé.'
                    else: job['message'] = 'Import interrompu. Tu peux réessayer avec une nouvelle demande.'
                    self._save(job); self.jobs[job['id']] = job
                except (OSError, ValueError, KeyError, TypeError, MutagenError): continue

    def submit(self, request):
        fields = request_fields(request)
        with self.lock:
            for previous in self.jobs.values():
                if previous['request_id'] == fields['request_id']:
                    if request_fields(previous) != fields: raise LocalImportRequestError('Cet identifiant correspond à un autre import.')
                    return self._public(previous)
            if self.closed: raise LocalImportRequestError('Le compagnon PC est en cours de fermeture.')
            if sum(job['state'] in ACTIVE for job in self.jobs.values()) >= 10:
                raise LocalImportRequestError('La file d’imports est pleine. Attends une préparation en cours.')
            job = dict(fields, version=1, id=secrets.token_hex(16), created=time.time(), state='queued', message='Import en attente.')
            for previous in self.jobs.values():
                if previous['state'] != 'ready' or any(previous[key] != fields[key] for key in ('source_url', 'title', 'artist', 'album')): continue
                try:
                    output = self._path(previous['_audio'])
                    row = self._verified(output, previous['row'], fields, job['id'])
                    job.update(state='ready', row=row, _audio=previous['_audio'], message='Import déjà prêt à enregistrer.')
                    self.queue.register(row['id'], output, row['extension'])
                    break
                except (OSError, ValueError, KeyError, TypeError, MutagenError): continue
            self._save(job); self.jobs[job['id']] = job
            if job['state'] == 'queued':
                self.queue.running_jobs.add('local-import:' + job['id'])
                self.pool.submit(self._run, job['id'])
            return self._public(job)

    def cancel(self, request):
        if not isinstance(request, dict) or set(request) != {'job_id'} or not isinstance(request['job_id'], str):
            raise LocalImportRequestError('Demande d’annulation invalide.')
        with self.lock:
            job = self.jobs.get(request['job_id'])
            if not job: raise LocalImportRequestError('Cet import est introuvable.')
            if job['state'] in ACTIVE:
                job.update(state='cancelled', message='Import annulé. Les autres fichiers sont conservés.')
                self._save(job)
                # Keep the marker until the worker actually stops using its files.
            return self._public(job)

    def _worker(self, folder, fields, cancelled, progress):
        from automatic_downloads import worker_document
        from download_worker import windows_child_job
        atomic_document(folder / 'request.json', fields)
        process, owner = None, windows_child_job() if os.name == 'nt' else None
        try:
            process = subprocess.Popen([sys.executable, '-X', 'utf8', str(Path(__file__).with_name('local_import_media.py')),
                str(folder), '--ffmpeg', str(self.ffmpeg)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
                start_new_session=os.name != 'nt')
            if owner and not owner[0].AssignProcessToJobObject(owner[1], int(process._handle)):
                raise OSError('Impossible de surveiller le traitement audio.')
            deadline = time.monotonic() + self.timeout
            while process.poll() is None:
                if cancelled(): raise InterruptedError('Import annulé.')
                if time.monotonic() >= deadline: raise TimeoutError('Délai d’import dépassé.')
                status = worker_document(folder / 'progress.json')
                if status.get('phase') in ('download', 'cover', 'verify'): progress(status['phase'])
                time.sleep(.15)
            if process.returncode: raise ValueError('Source audio indisponible ou invalide.')
            record = worker_document(folder / 'local-ready.json')
            if record.get('file') not in ('audio.mp3', 'audio.m4a'): raise ValueError('Résultat d’import invalide.')
            return folder / record['file'], record
        finally:
            if owner: owner[0].CloseHandle(owner[1])
            elif process and process.poll() is None:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            if process and process.poll() is None: process.kill()
            if process: process.wait()

    def _run(self, ident):
        try:
            with self.lock:
                job = self.jobs[ident]
                if job['state'] != 'queued': return
                fields = request_fields(job)
                folder = self.directory / ident
                safe_path(folder, self.root, exists=False); folder.mkdir(exist_ok=True)
                job.update(state='running', phase='download', message='Téléchargement de la source choisie…'); self._save(job)
            def cancelled():
                with self.lock: return self.jobs[ident]['state'] != 'running'
            def progress(phase):
                with self.lock:
                    if not cancelled() and job.get('phase') != phase:
                        messages = {'download':'Téléchargement de la source choisie…', 'cover':'Ajout de la pochette…', 'verify':'Vérification de l’audio…'}
                        job.update(phase=phase, message=messages[phase]); self._save(job)
            output, metadata = self.worker(folder, fields, cancelled, progress)
            with self.lock:
                if cancelled(): return
                output = self._path(Path(output).relative_to(self.root).as_posix())
                if not output.is_relative_to(folder): raise ValueError('Résultat hors du dossier de cet import.')
                if metadata.get('source_url') != fields['source_url'] or 'spotify' in metadata:
                    raise ValueError('Provenance d’import incohérente.')
                row = self._verified(output, metadata, fields, ident)
                job.update(state='ready', row=row, _audio=output.relative_to(self.root).as_posix(), message='Import prêt à enregistrer.')
                job.pop('phase', None); self._save(job)
                self.queue.register(row['id'], output, row['extension'])
        except Exception:
            with self.lock:
                job = self.jobs[ident]
                if job['state'] not in ('cancelled', 'interrupted'):
                    job.pop('row', None); job.pop('_audio', None)
                    job.update(state='error', message='Cette source n’a pas fourni un audio public valide. Vérifie le lien ou choisis un fichier MP3/M4A.')
                    self._save(job)
        finally:
            with self.lock:
                if self.jobs[ident]['state'] != 'ready': self._discard_partial(ident)
                self.queue.running_jobs.discard('local-import:' + ident)

    def _discard_partial(self, ident):
        """Remove only generated files in this exact private failed-job directory."""
        folder = self.directory / ident
        if not re.fullmatch('[a-f0-9]{32}', ident) or not folder.exists(): return
        try:
            safe_path(folder, self.root)
            visited = 0
            for parent, directories, filenames in os.walk(folder, topdown=False, followlinks=False):
                parent = Path(parent)
                safe_path(parent, folder)
                for name in filenames:
                    visited += 1
                    if visited > 2000: return
                    file = parent / name
                    if parent == folder and name in ('request.json', 'progress.json', 'failure.json'): continue
                    try: safe_path(file, folder); file.unlink()
                    except (OSError, ValueError): pass
                for name in directories:
                    try:
                        child = parent / name; safe_path(child, folder); child.rmdir()
                    except (OSError, ValueError): pass
        except (OSError, ValueError): pass

    def shutdown(self, wait=True):
        with self.lock:
            self.closed = True
            for job in self.jobs.values():
                if job['state'] in ACTIVE:
                    waiting = job['state'] == 'queued'
                    job.update(state='interrupted', message='Le compagnon a été arrêté. Relance cet import si nécessaire.')
                    self._save(job)
                    if waiting: self.queue.running_jobs.discard('local-import:' + job['id'])
        self.pool.shutdown(wait=wait, cancel_futures=True)
