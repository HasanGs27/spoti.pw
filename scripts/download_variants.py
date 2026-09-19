"""Explicit, durable audio copies. Never changes the original download selection."""
import copy
import hashlib
import math
import re
import secrets
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from mutagen import MutagenError

from download_metadata import canonical
from download_storage import atomic_document, safe_path

SPEEDS = (.75, 1.25, 1.5, 2.0)
ACTIVE = {'queued', 'running'}
STATES = ACTIVE | {'ready', 'error', 'interrupted'}


class VariantRequestError(ValueError):
    """Only fixed user-facing text; safe to return from the authenticated endpoint."""


def request_fields(request):
    if not isinstance(request, dict): raise VariantRequestError('Demande de copie audio invalide.')
    key, digest = request.get('request_id'), request.get('source_id')
    if not isinstance(key, str) or not re.fullmatch('[A-Za-z0-9-]{16,64}', key):
        raise VariantRequestError('Identifiant de demande invalide.')
    if not isinstance(digest, str) or not re.fullmatch('[a-f0-9]{64}', digest):
        raise VariantRequestError('Identifiant du fichier source invalide.')
    if ('spotify' in request) == ('source_local_id' in request):
        raise VariantRequestError('Choisis un morceau Spotify ou un import personnel, pas les deux.')
    identity = {}
    if 'source_local_id' in request:
        local_id = request['source_local_id']
        if not isinstance(local_id, str) or not re.fullmatch('[a-f0-9]{32}', local_id):
            raise VariantRequestError('Identifiant d’import personnel invalide.')
        identity['source_local_id'] = local_id
    else:
        try: spotify = canonical(request.get('spotify'))
        except ValueError: raise VariantRequestError('Un lien de morceau Spotify valide est requis.') from None
        if request.get('spotify') != spotify or '/track/' not in spotify:
            raise VariantRequestError('Un lien de morceau Spotify canonique est requis.')
        identity['spotify'] = spotify
    kind = request.get('kind')
    if kind not in ('speed', 'instrumental'): raise VariantRequestError('Type de copie audio invalide.')
    fields = dict(identity, request_id=key, source_id=digest, kind=kind)
    if kind == 'speed':
        speed = request.get('speed')
        if type(speed) not in (float, int) or speed not in SPEEDS:
            raise VariantRequestError('Choisis une vitesse proposée.')
        fields['speed'] = float(speed)
    elif 'speed' in request: raise VariantRequestError('La copie instrumentale ne prend pas de vitesse.')
    return fields


class VariantQueue:
    """One local transform at a time; injected workers use the audio_variants manifest.

    Public snapshots never contain filesystem paths. The existing queue lock also
    serializes source selection/register with its explicit storage cleanup.
    """
    def __init__(self, queue, ffmpeg, worker=None, instrumental_worker=None, local_imports=None):
        self.queue, self.ffmpeg = queue, ffmpeg
        self.root, self.lock = Path(queue.root), queue.lock
        if local_imports is not None and (local_imports.queue is not queue or local_imports.lock is not self.lock):
            raise ValueError('La file d’imports doit appartenir au même compagnon.')
        self.local_imports = local_imports
        self.directory = self.root / '.audio-variants'
        safe_path(self.directory, self.root, exists=False)
        self.directory.mkdir(exist_ok=True)
        self.job_directory = self.directory / 'jobs'
        safe_path(self.job_directory, self.root, exists=False)
        self.job_directory.mkdir(exist_ok=True)
        self.worker = worker or self._speed_worker
        self.instrumental_worker = instrumental_worker
        self.jobs, self.closed = {}, False
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='audio-variant')
        self._restore()

    @staticmethod
    def _speed_worker(root, source, fields, ffmpeg):
        from audio_variants import create_speed_variant
        return create_speed_variant(root, source, fields['speed'], ffmpeg)

    def capabilities(self):
        return {'speeds':list(SPEEDS), 'instrumental':self._instrumental_ready(),
                'localSources':self.local_imports is not None}

    def _instrumental_ready(self):
        if self.instrumental_worker is not None: return True
        try:
            from audio_variants import instrumental_available
            return bool(instrumental_available())
        except (ImportError, OSError, ValueError): return False

    @staticmethod
    def _instrumental(root, source, fields, ffmpeg):
        from audio_variants import create_instrumental_variant
        return create_instrumental_variant(root, source, ffmpeg)

    @staticmethod
    def _public(job):
        return copy.deepcopy({key:value for key, value in job.items() if not key.startswith('_')})

    def listing(self):
        with self.lock:
            return {'version':1, 'capabilities':self.capabilities(),
                    'jobs':[self._public(job) for job in sorted(self.jobs.values(),
                        key=lambda value:value['created'], reverse=True)[:200]]}

    def _recipe(self, fields):
        """Version the processing contract, including instrumental model parameters."""
        recipe = {'version':1, 'kind':fields['kind'], 'extension':'m4a'}
        if fields['kind'] == 'speed': return dict(recipe, speed=fields['speed'])
        if self.instrumental_worker is not None: return None
        try:
            from audio_variants import MODEL_SHA, studio_configuration
            _, models = studio_configuration()
            with (models / 'vocals_mel_band_roformer.yaml').open('rb') as stream: data = stream.read(32769)
            if not 1 <= len(data) <= 32768: return None
            return dict(recipe, modelSHA256=MODEL_SHA, configSHA256=hashlib.sha256(data).hexdigest(), separator='0.47.0')
        except (ImportError, OSError, ValueError, TypeError, KeyError): return None

    def get(self, ident):
        with self.lock:
            if not isinstance(ident, str) or ident not in self.jobs: raise KeyError(ident)
            return self._public(self.jobs[ident])

    def active(self):
        with self.lock: return any(job['state'] in ACTIVE for job in self.jobs.values())

    def _save(self, job):
        safe_path(self.job_directory, self.root)
        atomic_document(self.job_directory / (job['id'] + '.json'), job)

    def _output_path(self, relative):
        if (not isinstance(relative, str) or not relative or '\\' in relative or '\x00' in relative or
                Path(relative).is_absolute() or ':' in relative or
                any(part in ('', '.', '..') for part in relative.split('/'))):
            raise ValueError('Copie audio persistée invalide.')
        path = self.root / relative
        safe_path(path, self.root)
        if not path.is_relative_to(self.directory) or path.is_relative_to(self.job_directory):
            raise ValueError('Copie audio hors du dossier privé.')
        if path.suffix not in ('.mp3', '.m4a'): raise ValueError('Format de copie invalide.')
        return path

    @staticmethod
    def _row_identity(row, fields, ident):
        if not isinstance(row, dict) or row.get('state') != 'ready' or row.get('position') != 1:
            return False
        if 'spotify' in fields:
            return row.get('spotify') == fields['spotify'] and 'source_local_id' not in row
        return ('spotify' not in row and row.get('local_id') == ident and
                row.get('source_local_id') == fields['source_local_id'] and row.get('source_id') == fields['source_id'] and
                row.get('variant_kind') == fields['kind'] and
                (row.get('variant_speed') == fields['speed'] if fields['kind'] == 'speed' else 'variant_speed' not in row))

    @staticmethod
    def _ready_row(checked, fields, ident, provenance=None):
        if not 1 <= checked['seconds'] <= 2701: raise ValueError('Durée de copie invalide.')
        if 'spotify' in fields:
            return dict(checked, spotify=fields['spotify'], position=1, state='ready')
        from local_import_media import source_url
        url, kind = source_url(provenance['source_url'])
        if (url != provenance['source_url'] or provenance.get('sourceKind') != kind or
                provenance.get('sourceURL', url) != url): raise ValueError('Provenance de copie invalide.')
        row = {key:value for key, value in checked.items() if key not in ('source', 'spotify')}
        row.update(state='ready', position=1, local_id=ident, source_local_id=fields['source_local_id'],
                   source_id=fields['source_id'], source_url=url, sourceURL=url, sourceKind=kind,
                   variant_kind=fields['kind'])
        if fields['kind'] == 'speed': row['variant_speed'] = fields['speed']
        return row

    def _restore(self):
        from automatic_downloads import audio_record, worker_document
        with self.lock:
            for path in self.job_directory.glob('*.json'):
                try:
                    if not re.fullmatch('[a-f0-9]{32}', path.stem): continue
                    safe_path(path, self.root)
                    job = worker_document(path, 128 * 1024)
                    if (job.get('version') != 1 or job.get('id') != path.stem or
                            job.get('state') not in STATES): continue
                    fields = request_fields(job)
                    created = job.get('created')
                    if type(created) not in (int, float) or not math.isfinite(created): continue
                    clean = dict(fields, id=path.stem, version=1, created=created, state=job['state'],
                                 message='Copie audio conservée.')
                    recipe = job.get('_recipe')
                    if isinstance(recipe, dict) and recipe == self._recipe(fields): clean['_recipe'] = recipe
                    if job['state'] in ACTIVE:
                        clean.update(state='interrupted', message='Le PC a redémarré. Relance la création de cette copie.')
                    elif job['state'] == 'ready':
                        try:
                            row = job['row']
                            if not self._row_identity(row, fields, path.stem): raise ValueError('Copie incohérente.')
                            output = self._output_path(job['_audio'])
                            checked = audio_record(output, row)
                            if (checked['id'] != row['id'] or checked['bytes'] != row['bytes'] or
                                    checked['id'] == fields['source_id']): raise ValueError('Copie modifiée.')
                            clean.update(row=self._ready_row(checked, fields, path.stem, row),
                                         _audio=job['_audio'], message='Copie prête à importer.')
                            self.queue.register(checked['id'], output, checked['extension'])
                        except (OSError, ValueError, KeyError, TypeError, AttributeError, MutagenError):
                            clean.update(state='error', message='La copie audio est absente ou a changé sur le PC.')
                    else:
                        clean['message'] = 'Création interrompue. Tu peux demander une nouvelle copie.'
                    self._save(clean)
                    self.jobs[clean['id']] = clean
                except (OSError, ValueError, KeyError, TypeError, MutagenError): continue

    def _source(self, fields):
        from automatic_downloads import audio_record, file_stamp
        if 'source_local_id' in fields:
            # A registered SHA alone is insufficient: it must be the exact ready
            # personal import requested, with its own verified private file.
            local_id = fields['source_local_id']
            job = self.local_imports.jobs.get(local_id) if self.local_imports is not None else None
            row = job.get('row') if isinstance(job, dict) and job.get('state') == 'ready' else None
            if (not isinstance(row, dict) or row.get('local_id') != local_id or 'spotify' in row or
                    row.get('state') != 'ready' or row.get('id') != fields['source_id']):
                raise ValueError('Cet import personnel doit être disponible sur le PC.')
            source = self.local_imports._path(job['_audio'])
            checked = self.local_imports._verified(source, row, job, local_id)
            if not 1 <= checked['seconds'] <= 1800: raise ValueError('Choisis un morceau de 30 minutes maximum.')
            return source, checked
        digest, spotify = fields['source_id'], fields['spotify']
        rows = (row for job in self.queue.jobs.values() for row in job.get('items', []))
        row = next((row for row in rows if row.get('state') == 'ready' and
                    row.get('id') == digest and row.get('spotify') == spotify), None)
        registered = self.queue.files.get(digest)
        if row is None or registered is None:
            raise ValueError('Ce fichier original doit être téléchargé et disponible sur le PC.')
        source, stamp, extension = registered
        safe_path(source, self.root)
        if (source.suffix != '.' + extension or extension != row.get('extension', 'mp3') or
                file_stamp(source.stat()) != stamp): raise ValueError('Le fichier original a changé sur le PC.')
        checked = audio_record(source, row)
        if checked['id'] != digest or checked['bytes'] != row['bytes']:
            raise ValueError('Le fichier original a changé sur le PC.')
        if not 1 <= checked['seconds'] <= 1800:
            raise ValueError('Choisis un morceau de 30 minutes maximum.')
        return source, checked

    def submit(self, request):
        fields = request_fields(request)
        with self.lock:
            for job in self.jobs.values():
                if job['request_id'] == fields['request_id']:
                    if request_fields(job) != fields:
                        raise VariantRequestError('Cet identifiant correspond à une autre copie audio.')
                    return self._public(job)
            if self.closed: raise VariantRequestError('Le compagnon PC est en cours de fermeture.')
            if fields['kind'] == 'instrumental' and not self._instrumental_ready():
                raise VariantRequestError('La création instrumentale n’est pas disponible sur ce PC.')
            if sum(job['state'] in ACTIVE for job in self.jobs.values()) >= 10:
                raise VariantRequestError('La file de copies audio est pleine. Attends une création en cours.')
            try: self._source(fields)
            except (OSError, ValueError, KeyError, TypeError, MutagenError):
                raise VariantRequestError('Le fichier original est absent, modifié ou incompatible sur le PC. Télécharge-le de nouveau avant de créer une copie.') from None
            job = dict(fields, version=1, id=secrets.token_hex(16), created=time.time(),
                       state='queued', message='Copie audio en attente.')
            recipe = self._recipe(fields)
            if recipe is not None:
                job['_recipe'] = recipe
                reusable = self._reuse(fields, recipe, job['id'])
                if reusable is not None:
                    output, row = reusable
                    job.update(state='ready', row=row, _audio=output.relative_to(self.root).as_posix(),
                               message='Copie déjà prête à importer.')
                    self._save(job)
                    self.jobs[job['id']] = job
                    self.queue.register(row['id'], output, row['extension'])
                    return self._public(job)
            self._save(job)
            self.jobs[job['id']] = job
            self.queue.running_jobs.add('variant:' + job['id'])
            self.pool.submit(self._run, job['id'])
            return self._public(job)

    def _reuse(self, fields, recipe, ident):
        from automatic_downloads import audio_record
        for prior in sorted(self.jobs.values(), key=lambda value:value['created'], reverse=True):
            if (prior['state'] != 'ready' or prior.get('_recipe') != recipe or
                    any(prior.get(key) != fields.get(key) for key in ('source_id', 'spotify', 'source_local_id', 'kind', 'speed'))): continue
            try:
                output = self._output_path(prior['_audio'])
                old = prior['row']
                if not self._row_identity(old, fields, prior['id']): continue
                checked = audio_record(output, old)
                if checked['id'] != old['id'] or checked['bytes'] != old['bytes']: continue
                return output, self._ready_row(checked, fields, ident, old)
            except (OSError, ValueError, KeyError, TypeError, MutagenError): continue
        return None

    def _result(self, result, fields, source, original, ident):
        from automatic_downloads import audio_record
        if (not isinstance(result, dict) or result.get('kind') != fields['kind'] or
                result.get('source', {}).get('sha256') != fields['source_id']):
            raise ValueError('Origine de la copie audio incohérente.')
        if fields['kind'] == 'speed' and (type(result.get('speed')) not in (int, float) or
                result['speed'] != fields['speed']): raise ValueError('Vitesse de la copie incohérente.')
        audio = result['audio']
        directory = Path(result['directory'])
        safe_path(directory, self.root)
        if audio.get('file') not in ('audio.mp3', 'audio.m4a'): raise ValueError('Sortie audio invalide.')
        output = directory / audio['file']
        output = self._output_path(output.relative_to(self.root).as_posix())
        if output == source: raise ValueError('La copie doit rester distincte de l’original.')
        metadata = {'extension':audio['extension'], 'quality':'Copie locale · ' + str(result.get('label', ''))[:128]}
        checked = audio_record(output, metadata)
        if (checked['id'] != audio['sha256'] or checked['id'] == fields['source_id'] or
                checked['bytes'] != audio['bytes'] or checked['extension'] != output.suffix[1:] or
                any(checked[key] != audio[key] for key in ('title', 'artist', 'album')) or
                checked['artist'] != original['artist'] or checked['title'] == original['title'] or
                checked['album'] == original['album']):
            raise ValueError('La copie audio ne correspond pas au résultat validé.')
        expected = original['seconds'] / fields.get('speed', 1)
        if abs(checked['seconds'] - expected) > max(.3, expected * .008):
            raise ValueError('La durée de la copie audio est incohérente.')
        # Recheck the registered original after processing. No cache promotion follows.
        current, again = self._source(fields)
        if current != source or again['id'] != original['id']: raise ValueError('Le fichier original a changé.')
        return output, self._ready_row(checked, fields, ident, original)

    def _run(self, ident):
        try:
            with self.lock:
                job = self.jobs[ident]
                if job['state'] != 'queued': return
                fields = request_fields(job)
                source, original = self._source(fields)
                job.update(state='running', message='Création d’une copie audio séparée…')
                self._save(job)
            worker = (self.instrumental_worker or self._instrumental) if fields['kind'] == 'instrumental' else self.worker
            result = worker(self.root, source, fields, self.ffmpeg)
            with self.lock:
                if job.get('_recipe') is not None and job['_recipe'] != self._recipe(fields):
                    raise ValueError('La configuration de traitement a changé.')
                output, row = self._result(result, fields, source, original, ident)
                job.update(state='ready', row=row, _audio=output.relative_to(self.root).as_posix(),
                           message='Copie prête à importer.')
                self._save(job)
                self.queue.register(row['id'], output, row['extension'])
        except Exception:
            # No paths, subprocess arguments, model configuration or stderr in the API.
            with self.lock:
                job = self.jobs[ident]
                job.pop('row', None); job.pop('_audio', None)
                job.update(state='error', message='La copie audio n’a pas pu être créée. L’original est conservé.')
                self._save(job)
        finally:
            with self.lock: self.queue.running_jobs.discard('variant:' + ident)

    def shutdown(self, wait=True):
        with self.lock:
            self.closed = True
            for job in self.jobs.values():
                if job['state'] == 'queued':
                    job.update(state='interrupted', message='Le compagnon a été arrêté. Relance cette copie si nécessaire.')
                    self._save(job)
                    self.queue.running_jobs.discard('variant:' + job['id'])
        self.pool.shutdown(wait=wait, cancel_futures=True)
