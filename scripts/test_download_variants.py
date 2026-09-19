"""Offline queue, persistence, integrity and loopback HTTP tests for audio copies."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover
from mutagen.id3 import APIC, TALB, TIT2, TPE1
from PIL import Image

from automatic_downloads import Queue, audio_record, handler_for
from download_storage import atomic_document
from download_variants import VariantQueue, VariantRequestError, request_fields

TRACK = 'https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT'
OTHER = 'https://open.spotify.com/track/7sL89oFc1AcgjG5Q6tCkID'


class VariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix='sg-variant-fixtures-')
        cls.ffmpeg = os.environ.get('SG_TEST_FFMPEG') or shutil.which('ffmpeg')
        if not cls.ffmpeg: raise RuntimeError('Set SG_TEST_FFMPEG for these synthetic audio tests.')
        image = io.BytesIO(); Image.new('RGB', (32, 32), 'blue').save(image, format='JPEG')
        cls.cover = image.getvalue()
        cls.original = Path(cls.fixtures.name) / 'original.mp3'
        cls.convert(cls.original, 4)
        audio = MP3(cls.original)
        for frame, value in ((TIT2, 'Synthetic track'), (TPE1, 'Test artist'), (TALB, 'Test album')):
            audio.tags.add(frame(encoding=1, text=[value]))
        audio.tags.add(APIC(encoding=1, mime='image/jpeg', type=3, data=cls.cover)); audio.save(v2_version=3)
        cls.outputs = {}
        for speed in (.75, 1.25, 1.5, 2.0, 1.0):
            target = Path(cls.fixtures.name) / (str(speed) + '.m4a')
            cls.convert(target, 4 / speed)
            audio = MP4(target)
            label = 'Instrumental' if speed == 1 else 'Vitesse ×' + str(speed)
            audio['\xa9nam'], audio['\xa9ART'], audio['\xa9alb'] = ['Synthetic track · ' + label], ['Test artist'], ['Test album · ' + label]
            audio['covr'] = [MP4Cover(cls.cover, imageformat=MP4Cover.FORMAT_JPEG)]; audio.save()
            cls.outputs[speed] = target

    @classmethod
    def convert(cls, target, seconds):
        subprocess.run([cls.ffmpeg, '-hide_banner', '-v', 'error', '-nostdin', '-f', 'lavfi',
            '-i', 'sine=frequency=440:duration=' + str(seconds), '-c:a',
            'aac' if target.suffix == '.m4a' else 'libmp3lame', str(target)], check=True,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))

    @classmethod
    def tearDownClass(cls): cls.fixtures.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sg-variant-queue-')
        self.queue = Queue(self.temp.name, self.ffmpeg, start=False)
        self.source = self.queue.root / 'original.mp3'
        shutil.copyfile(self.original, self.source)
        self.record = audio_record(self.source, {})
        self.row = dict(self.record, spotify=TRACK, position=1, state='ready')
        self.queue.jobs['a' * 32] = {'id':'a' * 32, 'items':[self.row], 'state':'complete'}
        self.queue.register(self.row['id'], self.source)
        self.queue.remember_audio(TRACK, self.source, self.record)
        self.variants, self.calls = [], []

    def tearDown(self):
        for variants in self.variants: variants.shutdown()
        self.queue.pool.shutdown(wait=True)
        self.temp.cleanup()

    def worker(self, root, source, fields, ffmpeg):
        self.calls.append(dict(fields))
        folder = Path(tempfile.mkdtemp(prefix='synthetic-', dir=root / '.audio-variants'))
        output = folder / 'audio.m4a'
        shutil.copyfile(self.outputs[fields.get('speed', 1)], output)
        result = audio_record(output, {'extension':'m4a'})
        return {'directory':str(folder), 'kind':fields['kind'], 'label':'Test copy', 'speed':fields.get('speed'),
            'source':{'sha256':fields['source_id']},
            'audio':dict(result, file='audio.m4a', sha256=result['id'])}

    def variants_queue(self, **kwargs):
        variants = VariantQueue(self.queue, self.ffmpeg, worker=kwargs.pop('worker', self.worker), **kwargs)
        self.variants.append(variants)
        return variants

    def request(self, **changes):
        return dict({'request_id':'synthetic-request-01', 'spotify':TRACK, 'source_id':self.row['id'],
            'kind':'speed', 'speed':1.25}, **changes)

    def settled(self, variants, request=None):
        job = variants.submit(request or self.request())
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            job = variants.get(job['id'])
            if job['state'] not in ('queued', 'running'): return job
            time.sleep(.01)
        self.fail('Synthetic variant worker did not finish.')

    def test_request_strictness_and_no_client_file_path(self):
        for change in ({'request_id':'short'}, {'source_id':'A' * 64}, {'spotify':OTHER + '?si=x'},
                       {'spotify':TRACK.replace('/track/', '/playlist/')}, {'speed':True},
                       {'speed':float('nan')}, {'speed':1}, {'kind':'other'}):
            with self.subTest(change=change), self.assertRaises(ValueError): request_fields(self.request(**change))
        fields = request_fields(self.request(path='../../user.mp3'))
        self.assertNotIn('path', fields)

    def test_ready_copy_is_verified_and_original_cache_is_unchanged(self):
        variants = self.variants_queue()
        before = copy.deepcopy(self.queue.reusable)
        original = self.source.read_bytes()
        job = self.settled(variants)
        self.assertEqual(job['state'], 'ready', job)
        self.assertEqual(job['row']['extension'], 'm4a')
        self.assertEqual(job['row']['spotify'], TRACK)
        self.assertNotEqual(job['row']['id'], self.row['id'])
        self.assertNotEqual(job['row']['title'], self.row['title'])
        self.assertNotEqual(job['row']['album'], self.row['album'])
        self.assertEqual(self.queue.reusable, before)
        self.assertFalse(self.queue.preferred)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(list(self.queue.jobs), ['a' * 32])
        self.assertNotIn('_audio', job)
        self.assertNotIn(str(self.queue.root), json.dumps(variants.listing()))
        path, _, extension = self.queue.files[job['row']['id']]
        self.assertEqual(extension, 'm4a')
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), job['row']['id'])
        self.assertFalse(variants.active()); self.assertFalse(self.queue.running_jobs)

    def test_request_id_retry_is_idempotent_even_after_restart(self):
        first = self.variants_queue()
        job = self.settled(first)
        self.assertEqual(first.submit(self.request())['id'], job['id'])
        with self.assertRaises(ValueError): first.submit(self.request(speed=1.5))
        first.shutdown()
        self.queue.files.pop(job['row']['id'])
        restored = self.variants_queue()
        self.assertEqual(restored.submit(self.request())['id'], job['id'])
        self.assertEqual(restored.get(job['id'])['state'], 'ready')
        self.assertIn(job['row']['id'], self.queue.files)
        self.assertEqual(len(self.calls), 1)

    def test_equivalent_new_request_reuses_verified_copy_but_changed_bytes_do_not(self):
        variants = self.variants_queue()
        first = self.settled(variants)
        second = self.settled(variants, self.request(request_id='equivalent-new-request'))
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(first['row']['id'], second['row']['id'])
        self.assertEqual(len(self.calls), 1)
        output = self.queue.files[first['row']['id']][0]
        data = bytearray(output.read_bytes()); data[-70] ^= 1; output.write_bytes(data)
        third = self.settled(variants, self.request(request_id='equivalent-after-damage'))
        self.assertEqual(third['state'], 'ready')
        self.assertEqual(len(self.calls), 2)
        self.assertNotEqual(self.queue.files[third['row']['id']][0], output)
        fourth = self.settled(variants, self.request(request_id='different-speed-request', speed=1.5))
        self.assertEqual(fourth['state'], 'ready'); self.assertEqual(len(self.calls), 3)

    def test_listing_is_bounded_but_older_jobs_remain_addressable(self):
        variants = self.variants_queue()
        for index in range(205):
            ident = format(index, '032x')
            variants.jobs[ident] = dict(self.request(request_id='historic-request-' + str(index)),
                version=1, id=ident, state='interrupted', message='Interrompu.', created=index)
        self.assertEqual(len(variants.listing()['jobs']), 200)
        self.assertEqual(variants.get('0' * 32)['id'], '0' * 32)

    def test_source_identity_missing_and_modified_sources_are_refused(self):
        variants = self.variants_queue()
        for changes in ({'spotify':OTHER}, {'source_id':'b' * 64}):
            with self.assertRaises(ValueError): variants.submit(self.request(**changes))
        old = self.source.stat()
        data = bytearray(self.source.read_bytes()); data[-50] ^= 1; self.source.write_bytes(data)
        os.utime(self.source, ns=(old.st_atime_ns, old.st_mtime_ns))
        with self.assertRaises(ValueError): variants.submit(self.request())
        self.assertFalse(self.calls); self.assertFalse(variants.jobs)

    def test_legacy_mp3_without_extension_is_a_valid_source(self):
        self.row.pop('extension')
        self.assertEqual(self.settled(self.variants_queue())['state'], 'ready')

    def test_default_worker_creates_real_speed_copy_and_preserves_original(self):
        variants = VariantQueue(self.queue, self.ffmpeg)
        self.variants.append(variants)
        before = self.source.read_bytes()
        job = self.settled(variants)
        self.assertEqual(job['state'], 'ready', job)
        self.assertLess(abs(job['row']['seconds'] - self.row['seconds'] / 1.25), .12)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(job['row']['artist'], self.row['artist'])
        self.assertIn('×1,25', job['row']['title'])

    def test_expected_errors_are_safe_without_client_paths(self):
        variants = self.variants_queue()
        for changes in ({'source_id':'d' * 64}, {'spotify':'file:///private-secret'}, {'request_id':'/private-secret'}):
            with self.assertRaises(VariantRequestError) as raised: variants.submit(self.request(**changes))
            self.assertNotIn('private-secret', str(raised.exception))
            self.assertNotIn(str(self.queue.root), str(raised.exception))

    def test_instrumental_capability_is_not_a_false_success(self):
        variants = self.variants_queue()
        request = self.request(kind='instrumental'); request.pop('speed')
        with patch.object(variants, '_instrumental_ready', return_value=False):
            self.assertFalse(variants.capabilities()['instrumental'])
            with self.assertRaises(ValueError): variants.submit(request)
        ready = self.variants_queue(instrumental_worker=self.worker)
        self.assertTrue(ready.capabilities()['instrumental'])
        self.assertEqual(self.settled(ready, request)['state'], 'ready')

    def test_restart_interrupts_active_jobs_and_revalidates_ready_bytes(self):
        variants = self.variants_queue()
        ready = self.settled(variants); variants.shutdown()
        output = self.queue.files[ready['row']['id']][0]
        data = bytearray(output.read_bytes()); data[-60] ^= 1; output.write_bytes(data)
        for index, state in enumerate(('queued', 'running')):
            ident = str(index + 1) * 32
            saved = dict(self.request(request_id='persisted-request-' + str(index)),
                         version=1, id=ident, created=time.time(), state=state)
            atomic_document(variants.job_directory / (ident + '.json'), saved)
        restored = self.variants_queue()
        self.assertEqual(restored.get(ready['id'])['state'], 'error')
        for ident in ('1' * 32, '2' * 32): self.assertEqual(restored.get(ident)['state'], 'interrupted')
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.queue.running_jobs)

    def test_capacity_single_worker_cleanup_guard_and_explicit_shutdown(self):
        entered, release = threading.Event(), threading.Event()
        def blocked(*args):
            entered.set()
            if not release.wait(10): raise RuntimeError('fixture timed out')
            return self.worker(*args)
        variants = self.variants_queue(worker=blocked)
        try:
            first = variants.submit(self.request())
            self.assertTrue(entered.wait(3))
            for index in range(1, 10): variants.submit(self.request(request_id='queued-request-' + str(index).zfill(3)))
            self.assertEqual(len(self.queue.running_jobs), 10)
            self.assertEqual(sum(job['state'] == 'running' for job in variants.jobs.values()), 1)
            with self.assertRaises(ValueError): variants.submit(self.request(request_id='too-many-request-01'))
            self.assertEqual(self.queue.storage_status()['active_jobs'], 10)
            with self.assertRaises(ValueError): self.queue.cleanup_storage({})
            variants.shutdown(wait=False)
            self.assertEqual(len(self.queue.running_jobs), 1)
        finally: release.set()
        variants.pool.shutdown(wait=True)
        self.assertEqual(variants.get(first['id'])['state'], 'ready')
        self.assertFalse(self.queue.running_jobs)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(sum(job['state'] == 'interrupted' for job in variants.jobs.values()), 9)

    def test_worker_wrong_hash_or_original_path_cannot_register_a_copy(self):
        for wrong in ('hash', 'source', 'speed'):
            def invalid(*args):
                result = self.worker(*args)
                if wrong == 'hash': result['audio']['sha256'] = 'c' * 64
                elif wrong == 'source': result['source']['sha256'] = 'c' * 64
                else: result['speed'] = 1.5
                return result
            variants = self.variants_queue(worker=invalid)
            job = self.settled(variants, self.request(request_id='invalid-result-' + wrong))
            self.assertEqual(job['state'], 'error'); self.assertNotIn('row', job)
        self.assertEqual(set(self.queue.files), {self.row['id']})

    @contextmanager
    def http_service(self, variants):
        server = ThreadingHTTPServer(('127.0.0.1', 0), lambda *args: None)
        port = server.server_address[1]
        server.RequestHandlerClass = handler_for(self.queue, '127.0.0.1', port, 'test-private-key', variants)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try: yield 'http://127.0.0.1:' + str(port) + '/test-private-key'
        finally: server.shutdown(); server.server_close(); thread.join()

    def test_http_create_poll_and_authenticated_range_transfer(self):
        variants = self.variants_queue()
        with self.http_service(variants) as base:
            request = Request(base + '/audio-variants', data=json.dumps(self.request()).encode(),
                              headers={'Content-Type':'application/json'})
            with urlopen(request) as response:
                self.assertEqual(response.status, 202); job = json.load(response)
            finished = self.settled(variants)
            with urlopen(base + '/audio-variants/' + job['id']) as response:
                public = json.load(response)
            self.assertEqual(public['row'], finished['row'])
            digest = finished['row']['id']
            with urlopen(Request(base + '/file/' + digest, headers={'Range':'bytes=23-127'})) as response:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.headers['ETag'], '"' + digest + '"')
                self.assertEqual(response.read(), self.queue.files[digest][0].read_bytes()[23:128])
            with urlopen(base + '/audio-variants') as response:
                self.assertEqual(len(json.load(response)['jobs']), 1)

    def test_http_wrong_key_origin_and_query_never_launch_worker(self):
        variants = self.variants_queue()
        with self.http_service(variants) as base:
            for url, headers in ((base.replace('test-private-key', 'wrong-key') + '/audio-variants', {}),
                                 (base + '/audio-variants', {'Origin':'https://unrelated.invalid'}),
                                 (base + '/audio-variants?x=1', {})):
                request = Request(url, data=json.dumps(self.request()).encode(),
                                  headers={'Content-Type':'application/json', **headers})
                with self.assertRaises(HTTPError) as raised: urlopen(request)
                self.assertEqual(raised.exception.code, 403)
            for url in (base.replace('test-private-key', 'wrong-key') + '/audio-variants', base + '/audio-variants?x=1'):
                with self.assertRaises(HTTPError) as raised: urlopen(url)
                self.assertEqual(raised.exception.code, 404)
        self.assertFalse(self.calls); self.assertFalse(variants.jobs)


if __name__ == '__main__': unittest.main(verbosity=2)
