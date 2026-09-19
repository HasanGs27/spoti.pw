"""Synthetic audio and loopback-only tests. Never downloads music or contacts a source."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from mutagen.id3 import TALB, TIT2, TPE1, WOAS
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4

from automatic_downloads import Queue, audio_record, handler_for
from download_storage import atomic_document
from download_worker import Budget
from local_import_media import (PublicHTTPSConnection, fetch_https, neutral_cover, prepare, public_address,
                                source_url, tag_local)
from local_imports import LocalImportQueue, LocalImportRequestError, request_fields

YOUTUBE = 'https://www.youtube.com/watch?v=abcdefghijk'
DIRECT = 'https://audio.example.test/recording.mp3?token=private-test'


class SourceBoundaryTests(unittest.TestCase):
    def test_explicit_video_identity_and_public_https_only(self):
        for value in (YOUTUBE, YOUTUBE + '&list=ignored', 'https://youtu.be/abcdefghijk?si=tracking',
                      'https://m.youtube.com/watch?v=abcdefghijk', 'https://music.youtube.com/watch?v=abcdefghijk',
                      'https://www.youtube.com/shorts/abcdefghijk'):
            self.assertEqual(source_url(value), (YOUTUBE, 'youtube'))
        for value in ('file:///tmp/music.mp3', 'http://audio.example.test/a', 'https://user:secret@example.test/a',
                      'https://localhost/a', 'https://10.1.2.3/a', 'https://127.0.0.1/a', 'https://169.254.169.254/a',
                      'https://224.0.0.1/a', 'https://[::1]/a', 'https://www.youtube.com/playlist?list=x',
                      YOUTUBE + '&v=bbbbbbbbbbb', 'https://audio.example.test:4430/a', 'https://bad\n.example/a'):
            with self.subTest(value=value), self.assertRaises(ValueError): source_url(value)
        self.assertEqual(source_url(DIRECT), (DIRECT, 'direct'))

    def test_dns_private_answers_and_rebinding_are_blocked(self):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('93.184.216.34', 443))]
        with patch('local_import_media.socket.getaddrinfo', return_value=answers):
            self.assertEqual(public_address('audio.example.test'), '93.184.216.34')
        answers.append((socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.168.1.2', 443)))
        with patch('local_import_media.socket.getaddrinfo', return_value=answers), self.assertRaises(ValueError):
            public_address('audio.example.test')
        raw, tls = Mock(), Mock()
        connection = PublicHTTPSConnection('audio.example.test', timeout=3)
        connection._context = Mock(); connection._context.wrap_socket.return_value = tls
        with patch('local_import_media.public_address', return_value='93.184.216.34'), \
             patch('local_import_media.socket.create_connection', return_value=raw) as connect:
            connection.connect()
        connect.assert_called_once_with(('93.184.216.34', 443), 3)
        connection._context.wrap_socket.assert_called_once_with(raw, server_hostname='audio.example.test')
        self.assertIs(connection.sock, tls)

    def test_direct_fetch_is_bounded_and_redirects_revalidated(self):
        response = Mock(status=200)
        response.getheader.side_effect = lambda key, default=None: {'Content-Length':'5', 'Content-Type':'audio/mpeg'}.get(key, default)
        response.read.side_effect = [b'abc', b'de', b'']
        client = Mock(); client.getresponse.return_value = response
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'audio.bin'
            fetch_https(DIRECT, target, 5, Budget(5), connection=Mock(return_value=client))
            self.assertEqual(target.read_bytes(), b'abcde')
            request = client.request.call_args
            self.assertEqual(request.args[:2], ('GET', '/recording.mp3?token=private-test'))
            self.assertNotIn('Authorization', request.kwargs['headers'])
            target.unlink()
            response.status = 302
            response.getheader.side_effect = lambda key, default=None: 'https://127.0.0.1/private' if key == 'Location' else default
            with self.assertRaises(ValueError): fetch_https(DIRECT, target, 5, Budget(5), connection=Mock(return_value=client))
            response.status = 200
            response.getheader.side_effect = lambda key, default=None: '6' if key == 'Content-Length' else default
            with self.assertRaises(ValueError): fetch_https(DIRECT, target, 5, Budget(5), connection=Mock(return_value=client))
            response.getheader.side_effect = lambda key, default=None: default
            response.read.side_effect = [b'abcdef']
            with self.assertRaises(ValueError): fetch_https(DIRECT, target, 5, Budget(5), connection=Mock(return_value=client))


class LocalImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix='sg-import-audio-')
        cls.ffmpeg = os.environ.get('SG_TEST_FFMPEG') or shutil.which('ffmpeg')
        if not cls.ffmpeg: raise RuntimeError('Set SG_TEST_FFMPEG for synthetic audio tests.')
        cls.audio = {}
        for extension, codec in (('mp3', 'libmp3lame'), ('m4a', 'aac')):
            file = Path(cls.fixtures.name) / ('original.' + extension)
            subprocess.run([cls.ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
                '-c:a', codec, str(file)], check=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            tag_local(file, {'title':'Original', 'artist':'Synthetic', 'album':'Album', 'source_url':'https://example.test/a'}, neutral_cover())
            if extension == 'mp3':
                tagged = MP3(file); tagged.tags.add(WOAS(url='https://open.spotify.com/track/0123456789012345678901')); tagged.save()
            else:
                tagged = MP4(file); tagged['----:com.apple.iTunes:SPOTIFY_URL'] = [b'https://open.spotify.com/track/0123456789012345678901']; tagged.save()
            cls.audio[extension] = file

    @classmethod
    def tearDownClass(cls): cls.fixtures.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sg-local-import-')
        self.queue = Queue(self.temp.name, self.ffmpeg, start=False)
        self.imports, self.calls = [], []

    def tearDown(self):
        for imports in self.imports: imports.shutdown()
        self.queue.pool.shutdown(wait=True); self.temp.cleanup()

    def request(self, **changes):
        return dict({'request_id':'local-synthetic-request-01', 'source_url':YOUTUBE, 'title':'Confirmed title'}, **changes)

    def worker(self, folder, fields, cancelled, progress):
        self.calls.append(dict(fields))
        path = folder / 'audio.m4a'; shutil.copyfile(self.audio['m4a'], path)
        tag_local(path, fields, neutral_cover())
        record = audio_record(path, {'extension':'m4a', 'quality':'Synthetic verified source'})
        return path, dict(record, source_url=fields['source_url'])

    def imports_queue(self, **kwargs):
        imports = LocalImportQueue(self.queue, self.ffmpeg, worker=kwargs.pop('worker', self.worker), **kwargs)
        self.imports.append(imports); return imports

    def settled(self, imports, request=None):
        job = imports.submit(request or self.request())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            job = imports.get(job['id'])
            if job['state'] not in ('queued', 'running'): return job
            time.sleep(.01)
        self.fail('Import did not settle.')

    def test_confirmed_labels_defaults_and_no_fake_spotify(self):
        fields = request_fields(self.request())
        self.assertEqual(fields['artist'], 'Import personnel'); self.assertEqual(fields['album'], 'Imports personnels')
        for changes in ({'title':''}, {'title':'x' * 201}, {'artist':'a\nb'}, {'request_id':'bad'}, {'spotify':'anything'}):
            with self.assertRaises(LocalImportRequestError): request_fields(self.request(**changes))
        job = self.settled(self.imports_queue())
        self.assertEqual(job['state'], 'ready', job)
        self.assertEqual(job['row']['title'], 'Confirmed title'); self.assertEqual(job['row']['local_id'], job['id'])
        self.assertNotIn('spotify', job); self.assertNotIn('spotify', job['row'])
        self.assertNotIn(str(self.queue.root), json.dumps(job))
        self.assertFalse(self.queue.jobs); self.assertFalse(self.queue.reusable); self.assertFalse(self.queue.preferred)

    def test_same_request_and_exact_source_labels_reuse_verified_audio(self):
        imports = self.imports_queue()
        one = self.settled(imports)
        self.assertEqual(imports.submit(self.request())['id'], one['id'])
        with self.assertRaises(LocalImportRequestError): imports.submit(self.request(title='Other title'))
        two = self.settled(imports, self.request(request_id='second-explicit-request'))
        self.assertNotEqual(one['id'], two['id']); self.assertEqual(one['row']['id'], two['row']['id'])
        self.assertEqual(two['row']['local_id'], two['id']); self.assertEqual(len(self.calls), 1)
        path = self.queue.files[one['row']['id']][0]
        data = bytearray(path.read_bytes()); data[-45] ^= 1; path.write_bytes(data)
        three = self.settled(imports, self.request(request_id='retry-corrupt-file-01'))
        self.assertEqual(three['state'], 'ready'); self.assertEqual(len(self.calls), 2)
        changed = self.settled(imports, self.request(request_id='changed-title-request', title='Other title'))
        self.assertEqual(changed['state'], 'ready'); self.assertEqual(len(self.calls), 3)

    def test_ready_restore_and_active_interruption_do_not_replay(self):
        imports = self.imports_queue(); ready = self.settled(imports); imports.shutdown()
        self.queue.files.clear()
        for index, state in enumerate(('queued', 'running', 'cancelled')):
            ident = str(index + 1) * 32
            job = dict(request_fields(self.request(request_id='restore-request-' + str(index))),
                       version=1, id=ident, state=state, created=time.time())
            atomic_document(imports.job_directory / (ident + '.json'), job)
        restored = self.imports_queue()
        self.assertEqual(restored.get(ready['id'])['state'], 'ready')
        self.assertIn(ready['row']['id'], self.queue.files)
        self.assertEqual(restored.get('1' * 32)['state'], 'interrupted')
        self.assertEqual(restored.get('2' * 32)['state'], 'interrupted')
        self.assertEqual(restored.get('3' * 32)['state'], 'cancelled')
        self.assertEqual(len(self.calls), 1)

    def test_cancel_prevents_late_registration_and_preserves_other_files(self):
        entered, release = threading.Event(), threading.Event()
        def blocked(*args):
            entered.set(); release.wait(5)
            return self.worker(*args)
        imports = self.imports_queue(worker=blocked)
        marker = self.queue.root / 'untouched.txt'; marker.write_text('keep')
        try:
            job = imports.submit(self.request()); self.assertTrue(entered.wait(3))
            self.assertEqual(self.queue.storage_status()['active_jobs'], 1)
            with self.assertRaises(ValueError): self.queue.cleanup_storage({})
            self.assertEqual(imports.cancel({'job_id':job['id']})['state'], 'cancelled')
            self.assertTrue(self.queue.running_jobs)
        finally: release.set()
        imports.pool.shutdown(wait=True)
        self.assertFalse(self.queue.files); self.assertFalse(self.queue.running_jobs)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertFalse((imports.directory / job['id'] / 'audio.m4a').exists())

    def test_ten_active_limit_and_bounded_listing(self):
        entered, release = threading.Event(), threading.Event()
        def blocked(*args):
            entered.set(); release.wait(5)
            return self.worker(*args)
        imports = self.imports_queue(worker=blocked)
        try:
            imports.submit(self.request()); self.assertTrue(entered.wait(3))
            for index in range(1, 10): imports.submit(self.request(request_id='queued-import-' + str(index).zfill(3)))
            with self.assertRaises(LocalImportRequestError): imports.submit(self.request(request_id='extra-import-rejected'))
            self.assertEqual(sum(job['state'] == 'running' for job in imports.jobs.values()), 1)
            imports.shutdown(wait=False)
        finally: release.set()
        imports.pool.shutdown(wait=True)
        self.assertFalse(self.queue.running_jobs); self.assertFalse(self.queue.files)
        fields = request_fields(self.request())
        for index in range(205):
            ident = format(index, '032x')
            imports.jobs[ident] = dict(fields, id=ident, created=index, version=1, state='error', message='Indisponible.')
        self.assertEqual(len(imports.listing()['jobs']), 200)
        self.assertEqual(imports.get('0' * 32)['id'], '0' * 32)

    def test_malformed_persisted_row_is_rejected_without_crashing_startup(self):
        imports = self.imports_queue(); ready = self.settled(imports); imports.shutdown()
        saved = copy.deepcopy(imports.jobs[ready['id']]); saved['row'] = []
        atomic_document(imports.job_directory / (ready['id'] + '.json'), saved)
        restored = self.imports_queue()
        self.assertEqual(restored.get(ready['id'])['state'], 'error')
        self.assertEqual(len(self.calls), 1)

    def test_output_tag_mismatch_cannot_be_registered(self):
        def wrong_tags(folder, fields, cancelled, progress):
            path, record = self.worker(folder, fields, cancelled, progress)
            record['source_url'] = DIRECT
            return path, record
        imports = self.imports_queue(worker=wrong_tags)
        job = self.settled(imports)
        self.assertEqual(job['state'], 'error'); self.assertFalse(self.queue.files)
        self.assertFalse((imports.directory / job['id'] / 'audio.m4a').exists())

    def test_subprocess_timeout_kills_owned_child(self):
        imports = self.imports_queue(worker=None, timeout=1)
        folder = imports.directory / ('a' * 32); folder.mkdir()
        real = subprocess.Popen; started = []
        def launch(arguments, **kwargs):
            process = real([sys.executable, '-c', 'import time;time.sleep(30)'], **kwargs)
            started.append(process); return process
        with patch('local_imports.subprocess.Popen', side_effect=launch), self.assertRaises(TimeoutError):
            imports._worker(folder, request_fields(self.request()), lambda:False, lambda phase:None)
        self.assertEqual(len(started), 1); self.assertIsNotNone(started[0].poll())

    def test_preparation_preserves_mp3_aac_and_removes_catalogue_tags(self):
        for extension in ('mp3', 'm4a'):
            folder = self.queue.root / extension; folder.mkdir()
            before = self.audio[extension].read_bytes()
            def fetch(url, target, maximum, budget): shutil.copyfile(self.audio[extension], target)
            fields = request_fields(self.request(source_url=DIRECT, artist='User confirmed artist'))
            output, record = prepare(fields, folder, self.ffmpeg, fetcher=fetch)
            self.assertEqual(output.suffix, '.' + extension); self.assertEqual(record['title'], fields['title'])
            self.assertEqual(self.audio[extension].read_bytes(), before)
            tagged = MP4(output) if extension == 'm4a' else MP3(output)
            self.assertNotIn('----:com.apple.iTunes:SPOTIFY_URL', tagged.tags)
            self.assertFalse(tagged.tags.get('WOAS'))
            self.assertNotIn('spotify', record)

    def test_explicit_youtube_preparation_never_searches_or_changes_selected_id(self):
        folder = self.queue.root / 'youtube'; folder.mkdir()
        calls = []
        def exact_source(url, root, budget):
            calls.append(url)
            attempt = root / 'source-0123456789abcdef'; attempt.mkdir()
            path = attempt / 'raw.m4a'; shutil.copyfile(self.audio['m4a'], path)
            return path, {'seconds':MP4(path).info.length}
        fields = request_fields(self.request())
        with patch('download_worker.choose_sources', side_effect=AssertionError('No catalogue matching permitted')):
            output, record = prepare(fields, folder, self.ffmpeg, fetcher=exact_source)
        self.assertEqual(calls, ['https://music.youtube.com/watch?v=abcdefghijk'])
        self.assertEqual(record['source_url'], YOUTUBE)
        self.assertEqual(output.suffix, '.m4a')

    @contextmanager
    def http(self, imports):
        server = ThreadingHTTPServer(('127.0.0.1', 0), lambda *args:None)
        port = server.server_port
        server.RequestHandlerClass = handler_for(self.queue, '127.0.0.1', port, 'private-test-token', local_imports=imports)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try: yield 'http://127.0.0.1:' + str(port) + '/private-test-token'
        finally: server.shutdown(); server.server_close(); thread.join()

    def test_authenticated_http_import_poll_range_cancel_and_rejected_origin(self):
        imports = self.imports_queue()
        with self.http(imports) as base:
            def post(path, payload, **headers):
                return urlopen(Request(path, data=json.dumps(payload).encode(), headers={'Content-Type':'application/json', **headers}))
            with post(base + '/local-imports', self.request()) as response: job = json.load(response)
            ready = self.settled(imports)
            with urlopen(base + '/local-imports/' + job['id']) as response: self.assertEqual(json.load(response)['state'], 'ready')
            with urlopen(base + '/local-imports') as response: self.assertEqual(len(json.load(response)['jobs']), 1)
            digest = ready['row']['id']; file = self.queue.files[digest][0]
            with urlopen(Request(base + '/file/' + digest, headers={'Range':'bytes=0-31'})) as response:
                self.assertEqual(response.status, 206); self.assertEqual(response.read(), file.read_bytes()[:32])
            with post(base + '/local-imports/cancel', {'job_id':job['id']}) as response:
                self.assertEqual(json.load(response)['state'], 'ready') # Completed file is never deleted.
            for path, headers in ((base.replace('private-test-token', 'wrong') + '/local-imports', {}),
                                  (base + '/local-imports?bad=1', {}),
                                  (base + '/local-imports', {'Origin':'https://unrelated.example'})):
                with self.assertRaises(HTTPError) as error: post(path, self.request(request_id='unauthorized-attempt'), **headers)
                self.assertEqual(error.exception.code, 403)
            self.assertEqual(len(self.calls), 1)


if __name__ == '__main__': unittest.main(verbosity=2)
