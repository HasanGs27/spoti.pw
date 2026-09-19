"""Offline regression tests. Set SG_TEST_FFMPEG to the ffmpeg executable."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from collections import Counter
from contextlib import contextmanager
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
from PIL import Image
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover
from mutagen.id3 import TIT2, TPE1, TALB, APIC
from automatic_downloads import Queue, handler_for, lan_address, audio_record, byte_range, file_stamp, request_fields, main
from download_metadata import canonical, collection
from download_worker import acceptable, remember_audio, reusable_audio, finish_audio

TRACK = 'https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT'
OTHER = 'https://open.spotify.com/track/7sL89oFc1AcgjG5Q6tCkID'
PLAYLIST = 'https://open.spotify.com/playlist/1Imj2Uc2NVvyHgrAouKQo3'
THIRD = TRACK[:-1]+'U'
FOURTH = TRACK[:-1]+'V'
SOURCE_A = 'https://music.youtube.com/watch?v=aaaaaaaaaaa'
SOURCE_B = 'https://music.youtube.com/watch?v=bbbbbbbbbbb'

class MetadataTests(unittest.TestCase):
    def test_urls_and_playlist_validation(self):
        self.assertEqual(canonical('spotify:track:3DaGnKmAAmyZGIbC0KjmxT'), TRACK)
        self.assertEqual(canonical(TRACK+'?si=ignored'), TRACK)
        for value in ('file:///etc/passwd', TRACK.replace('open.spotify.com','open.spotify.com.evil'),
                      TRACK.replace('https://','https://user@'), TRACK.replace('/track/','/episode/'), None):
            with self.assertRaises(ValueError): canonical(value)
        self.assertEqual(collection(TRACK, [OTHER, TRACK])[2], [OTHER, TRACK])
        with self.assertRaises(ValueError): collection(TRACK, [])
        with self.assertRaises(ValueError): lan_address('8.8.8.8')

    def test_wrong_versions_rejected(self):
        song = SimpleNamespace(name='Bandolero', artists=['Moha La Squale'], duration=186)
        base = dict(name='Bandolero', artists=['Moha La Squale'], duration=186, verified=True)
        self.assertTrue(acceptable(SimpleNamespace(**base), song))
        for change in ({'duration':181}, {'duration':196}, {'duration':float('nan')},
                       {'name':'Bandolero slowed'}, {'artists':['Someone Else']},
                       {'verified':False}, {'name':'A different song'}):
            self.assertFalse(acceptable(SimpleNamespace(**(base|change)), song), change)

class QueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.fixture = Path(cls.temp.name)/'fixture.mp3'
        ffmpeg = os.environ.get('SG_TEST_FFMPEG') or shutil.which('ffmpeg')
        if not ffmpeg: raise RuntimeError('Set SG_TEST_FFMPEG before these audio integration tests.')
        cls.ffmpeg = ffmpeg
        subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','sine=frequency=440:duration=3',
                        '-c:a','libmp3lame',str(cls.fixture)],check=True)
        cover = io.BytesIO(); Image.new('RGB',(32,32),'blue').save(cover,format='JPEG')
        audio = MP3(cls.fixture)
        audio.tags.add(TIT2(encoding=1,text=['Test track']))
        audio.tags.add(TPE1(encoding=1,text=['Test artist']))
        audio.tags.add(TALB(encoding=1,text=['']))
        audio.tags.add(APIC(encoding=1,mime='image/jpeg',type=3,data=cover.getvalue()))
        audio.save(v2_version=3)
        cls.m4a_fixture = Path(cls.temp.name)/'fixture.m4a'
        subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','sine=frequency=550:duration=3',
                        '-c:a','aac',str(cls.m4a_fixture)], check=True)
        audio = MP4(cls.m4a_fixture)
        audio['\xa9nam'], audio['\xa9ART'], audio['\xa9alb'] = ['AAC track'], ['AAC artist'], ['AAC album']
        audio['covr'] = [MP4Cover(cover.getvalue(), imageformat=MP4Cover.FORMAT_JPEG)]
        audio.save()
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.queues = []
    def tearDown(self):
        for queue in self.queues: queue.pool.shutdown(wait=True)
        self.folder.cleanup()
    def queue(self, **kwargs):
        def prepare(url, folder):
            if url == OTHER: raise ValueError('Deliberate missing source')
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target, {'source':'local test fixture'}
        queue = Queue(self.folder.name,'unused',prepare=kwargs.pop('prepare', prepare),
                      resolve=kwargs.pop('resolve', lambda url, tracks:('Selection','test',[TRACK,OTHER])), **kwargs)
        self.queues.append(queue)
        return queue
    def submit(self, queue):
        return queue.submit({'url':TRACK,'request_id':'test-idempotency-key'})
    def cached_queue(self, calls):
        def prepare(url, folder):
            calls.append(url)
            target = folder/'audio.mp3'; shutil.copyfile(self.fixture, target)
            return target, {'source':'verified synthetic fixture', 'quality':'test fixture'}
        return self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',tracks or [TRACK]))
    def settled(self, queue, request):
        job = queue.submit(request)
        queue.pool.submit(lambda: None).result(timeout=10)
        return queue.snapshot(job['id'])
    def m4a_queue(self, calls):
        def prepare(url, folder):
            calls.append(url)
            target = folder/'audio.m4a'; shutil.copyfile(self.m4a_fixture, target)
            return target, {'extension':'m4a', 'source':'synthetic AAC', 'quality':'AAC original',
                            'sourceCodec':'mp4a.40.2', 'sourceBitrate':128}
        return self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',tracks or [TRACK]))
    @contextmanager
    def http_service(self, queue):
        server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(queue, '127.0.0.1', 0, 'x'*32))
        server.RequestHandlerClass = handler_for(queue, '127.0.0.1', server.server_port, 'x'*32)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try: yield f'http://127.0.0.1:{server.server_port}/' + 'x'*32
        finally:
            server.shutdown(); server.server_close(); thread.join()
    def test_m4a_validation_and_reuse_restart_preserve_format_and_encoded_bytes(self):
        calls = []; queue = self.m4a_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'aac-first-playlist', 'track_urls':[TRACK, TRACK]})
        self.assertEqual(first['state'], 'complete')
        self.assertEqual(calls, [TRACK])
        expected = self.m4a_fixture.read_bytes()
        for row in first['items']:
            self.assertEqual((row['extension'], row['title'], row['artist'], row['album']), ('m4a', 'AAC track', 'AAC artist', 'AAC album'))
            self.assertEqual((row['sourceCodec'], row['sourceBitrate']), ('mp4a.40.2', 128))
            folder = Path(self.folder.name)/first['id']/str(row['position'])
            self.assertEqual(queue.row_path(row, folder).read_bytes(), expected)
            self.assertFalse((folder/'audio.mp3').exists())
        queue.pool.shutdown(wait=True)
        restored = self.m4a_queue(calls)
        second = self.settled(restored, {'url':TRACK, 'request_id':'aac-after-restart'})
        self.assertEqual(calls, [TRACK])
        row = second['items'][0]
        self.assertEqual(row['id'], hashlib.sha256(expected).hexdigest())
        self.assertEqual(row['extension'], 'm4a')
        with self.http_service(restored) as origin:
            with urlopen(origin+'/file/'+row['id']) as response:
                self.assertEqual(response.headers['Content-Type'], 'audio/mp4')
                self.assertEqual(response.read(), expected)
    def test_audio_validation_rejects_wrong_extension_tags_cover_and_codec(self):
        for fixture, extension in ((self.fixture, 'mp3'), (self.m4a_fixture, 'm4a')):
            self.assertEqual(audio_record(fixture, {'extension':extension})['extension'], extension)
            target = Path(self.folder.name)/('invalid.'+extension)
            for corruption in ('title', 'artist', 'cover'):
                shutil.copyfile(fixture, target)
                if extension == 'mp3':
                    audio = MP3(target)
                    if corruption == 'cover':
                        audio.tags.delall('APIC'); audio.tags.add(APIC(encoding=1,mime='image/jpeg',type=3,data=b'corrupt'*50))
                    else: audio.tags.delall('TIT2' if corruption == 'title' else 'TPE1')
                    audio.save()
                else:
                    audio = MP4(target)
                    if corruption == 'cover': audio['covr'] = [MP4Cover(b'corrupt'*50, imageformat=MP4Cover.FORMAT_JPEG)]
                    else: del audio['\xa9nam' if corruption == 'title' else '\xa9ART']
                    audio.save()
                with self.subTest(extension=extension, corruption=corruption), self.assertRaises(ValueError):
                    audio_record(target, {'extension':extension})
        for metadata in ({'extension':'../m4a'}, {'extension':'wav'}, {'extension':None}):
            with self.assertRaises(ValueError): audio_record(self.fixture, metadata)
        # An M4A declaration does not make MP3 bytes AAC, and vice versa.
        from mutagen import MutagenError
        for fixture, extension in ((self.fixture, 'm4a'), (self.m4a_fixture, 'mp3')):
            with self.assertRaises((MutagenError, ValueError)):
                audio_record(fixture, {'extension':extension})
        incompatible = Path(self.folder.name)/'alac.m4a'
        subprocess.run([self.ffmpeg, '-v', 'error', '-i', str(self.m4a_fixture), '-map', '0:a:0',
                        '-c:a', 'alac', str(incompatible)], check=True)
        # A valid M4A container alone does not qualify an unrequested codec.
        with self.assertRaisesRegex(ValueError, 'Codec M4A'):
            audio_record(incompatible, {'extension':'m4a'})
    def test_worker_declared_filename_and_shared_cache_contract(self):
        queue = self.cached_queue([])
        folder = Path(self.folder.name).resolve()/'worker-contract'; folder.mkdir()
        for extension in ('mp3', 'm4a'):
            metadata = {'spotify':TRACK, 'extension':extension}
            (folder/'audio-ready.json').write_text(json.dumps(metadata))
            with patch('automatic_downloads.subprocess.run') as run:
                target, returned = queue.worker(TRACK, folder)
            self.assertEqual(target, folder/('audio.'+extension))
            self.assertEqual(returned, metadata)
            self.assertEqual(run.call_args.kwargs['timeout'], 240)
            self.assertTrue(run.call_args.kwargs['check'])
            self.assertEqual(run.call_args.kwargs['env']['SG_ARTWORK_CACHE_DIR'], str(queue.root/'.artwork-cache'))
            self.assertEqual(run.call_args.kwargs['env']['SG_METADATA_CACHE_DIR'], str(queue.root/'.metadata-cache'))
        for metadata in ({'spotify':OTHER, 'extension':'m4a'}, {'spotify':TRACK, 'extension':'../bad'}, {'spotify':TRACK, 'extension':'wav'}):
            (folder/'audio-ready.json').write_text(json.dumps(metadata))
            with patch('automatic_downloads.subprocess.run'), self.assertRaises(ValueError): queue.worker(TRACK, folder)
    def test_legacy_mp3_without_extension_restores_and_serves_protocol_two(self):
        queue = self.cached_queue([])
        first = self.settled(queue, {'url':TRACK, 'request_id':'legacy-extension-first'})
        first['items'][0].pop('extension')
        queue.save(first); queue.pool.shutdown(wait=True)
        restored = self.cached_queue([])
        row = restored.snapshot(first['id'])['items'][0]
        self.assertEqual((row['state'], row['extension']), ('ready', 'mp3'))
        with self.http_service(restored) as origin:
            with urlopen(origin+'/hello') as response: self.assertEqual(json.load(response)['version'], 2)
            with urlopen(origin+'/file/'+row['id']) as response:
                self.assertEqual(response.headers['Content-Type'], 'audio/mpeg')
                self.assertEqual(response.read(), self.fixture.read_bytes())
    def test_prepared_v2_m4a_repair_is_private_and_preserves_format(self):
        queue = self.cached_queue([])
        folder = Path(self.folder.name).resolve()/'repair-source'; folder.mkdir()
        source = folder/'audio.m4a'; shutil.copyfile(self.m4a_fixture, source)
        audio = MP4(source); del audio['covr']; audio.save()
        marker = {'version':2, 'extension':'m4a', 'spotify':TRACK,
                  'source':'https://music.youtube.com/watch?v=abcdefghijk', 'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                  'sourceCodec':'mp4a.40.2', 'sourceBitrate':128}
        (folder/'prepared-audio.json').write_text(json.dumps(marker))
        queue.remember_repair(TRACK, folder)
        self.assertIn(TRACK, queue.repairable)
        self.assertFalse(queue.files); self.assertFalse(queue.reusable)
        target = folder.parent/'repair-target'; target.mkdir()
        self.assertTrue(queue.seed_repair(TRACK, target))
        self.assertEqual((target/'audio.m4a').read_bytes(), source.read_bytes())
        self.assertFalse((target/'audio.mp3').exists())
        self.assertEqual(json.loads((target/'prepared-audio.json').read_text()), marker)
        self.assertFalse(MP4(target/'audio.m4a').get('covr'))
        for change in ({'extension':'mp3'}, {'extension':'../m4a'}, {'extension':None}, {'version':1}, {'version':True}):
            (folder/'prepared-audio.json').write_text(json.dumps(marker|change))
            self.assertIsNone(queue.repair_record(TRACK, folder), change)
        marker.pop('extension')
        (folder/'prepared-audio.json').write_text(json.dumps(marker))
        self.assertIsNone(queue.repair_record(TRACK, folder))
    def test_prepared_legacy_v1_mp3_remains_repairable(self):
        queue = self.cached_queue([])
        folder = Path(self.folder.name).resolve()/'legacy-repair'; folder.mkdir()
        shutil.copyfile(self.fixture, folder/'audio.mp3')
        marker = {'version':1, 'spotify':TRACK, 'source':'https://music.youtube.com/watch?v=abcdefghijk',
                  'sha256':hashlib.sha256(self.fixture.read_bytes()).hexdigest()}
        (folder/'prepared-audio.json').write_text(json.dumps(marker))
        queue.remember_repair(TRACK, folder)
        target = folder.parent/'legacy-target'; target.mkdir()
        self.assertTrue(queue.seed_repair(TRACK, target))
        self.assertEqual((target/'audio.mp3').read_bytes(), self.fixture.read_bytes())
        self.assertEqual(json.loads((target/'prepared-audio.json').read_text()), marker)
    def test_bad_m4a_restore_is_isolated_from_other_ready_tracks(self):
        queue = self.m4a_queue([])
        first = self.settled(queue, {'url':TRACK, 'request_id':'aac-invalid-restore', 'track_urls':[TRACK, OTHER]})
        queue.pool.shutdown(wait=True)
        # A corrupt declaration must not invalidate another reference to the same bytes.
        first['items'][0]['extension'] = 'mp3'
        queue.save(first)
        restored = self.m4a_queue([])
        self.assertEqual([row['state'] for row in restored.snapshot(first['id'])['items']], ['error', 'ready'])
        self.assertNotIn(TRACK, restored.reusable)
        self.assertIn(OTHER, restored.reusable)
    def test_byte_range_parser_bounds_suffixes_and_unsupported_units(self):
        for header, expected in ((None, None), ('items=0-1', None), ('bytes=0-0', (0,0)),
                                 ('bytes=3-', (3,9)), ('bytes=3-99', (3,9)), ('bytes=-2', (8,9)), ('bytes=-99', (0,9))):
            self.assertEqual(byte_range(header, 10), expected)
        for header in ('bytes=', 'bytes=-', 'bytes=-0', 'bytes=10-', 'bytes=5-2', 'bytes=0-1,3-4',
                       'bytes=+1-2', 'bytes= 0-1', 'bytes='+'9'*600+'-'):
            with self.subTest(header=header), self.assertRaises(ValueError): byte_range(header, 10)
    def test_http_ranges_reconstruct_audio_with_etag_and_if_range_fallback(self):
        queue = self.m4a_queue([])
        done = self.settled(queue, {'url':TRACK, 'request_id':'ranged-m4a-request'})
        row = done['items'][0]; data = self.m4a_fixture.read_bytes(); size = len(data)
        etag = '"'+row['id']+'"'
        with self.http_service(queue) as origin:
            url = origin+'/file/'+row['id']
            def fetch(headers):
                with urlopen(Request(url, headers=headers)) as response:
                    return response.status, response.headers, response.read()
            status, headers, prefix = fetch({'Range':'bytes=0-1023'})
            self.assertEqual((status, len(prefix), headers['Content-Range']), (206, 1024, f'bytes 0-1023/{size}'))
            self.assertEqual((headers['ETag'], headers['Accept-Ranges']), (etag, 'bytes'))
            status, headers, suffix = fetch({'Range':'bytes=1024-', 'If-Range':etag})
            self.assertEqual(status, 206)
            self.assertEqual(headers['Content-Length'], str(size-1024))
            self.assertEqual(hashlib.sha256(prefix+suffix).hexdigest(), row['id'])
            # A client that lost an ordinary 200 response can retain its prefix too.
            with urlopen(url) as response:
                interrupted_prefix = response.read(777)
                interrupted_etag = response.headers['ETag']
            status, _, resumed = fetch({'Range':'bytes=777-', 'If-Range':interrupted_etag})
            self.assertEqual((status, interrupted_prefix+resumed), (206, data))
            for range_value, expected in (('bytes=-31', data[-31:]), ('bytes=0-999999999', data),
                                           (f'bytes={size-1}-', data[-1:])):
                status, headers, actual = fetch({'Range':range_value})
                self.assertEqual(status, 206); self.assertEqual(actual, expected)
            for condition in ('"stale"', 'W/'+etag, 'Wed, 21 Oct 2015 07:28:00 GMT'):
                status, headers, full = fetch({'Range':'bytes=1024-', 'If-Range':condition})
                self.assertEqual((status, full), (200, data))
                self.assertNotIn('Content-Range', headers)
            for range_value in (f'bytes={size}-', 'bytes=0-1,4-7', 'bytes=-0', 'bytes=8-2'):
                with self.assertRaises(HTTPError) as error: fetch({'Range':range_value})
                self.assertEqual(error.exception.code, 416)
                self.assertEqual(error.exception.headers['Content-Range'], f'bytes */{size}')
                self.assertEqual(error.exception.headers['ETag'], etag)
                self.assertEqual(error.exception.read(), b'')
            for bad in (Request(url, headers={'Range':'bytes=0-1', 'Origin':'https://evil.example'}),
                        Request(url, headers={'Range':'bytes=0-1', 'Host':'evil.example'}),
                        Request(url.replace('x'*32, 'wrong'), headers={'Range':'bytes=0-1'})):
                with self.assertRaises(HTTPError) as error: urlopen(bad)
                self.assertEqual(error.exception.code, 404)
            path = queue.files[row['id']][0]; original_stat = path.stat()
            path.write_bytes(data[:-1]+bytes([data[-1]^1]))
            os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
            with self.assertRaises(HTTPError) as error: fetch({'Range':'bytes=1024-', 'If-Range':etag})
            self.assertEqual(error.exception.code, 409)
    def test_http_cannot_serve_outside_root_or_missing_registered_files(self):
        queue = self.m4a_queue([])
        done = self.settled(queue, {'url':TRACK, 'request_id':'ranged-path-boundary'})
        row = done['items'][0]; ident = row['id']; original = queue.files[ident]
        with self.assertRaises(ValueError): queue.register(ident, self.m4a_fixture.resolve(), 'm4a')
        with self.http_service(queue) as origin:
            request = Request(origin+'/file/'+ident, headers={'Range':'bytes=0-127'})
            # Even an invalid in-memory cache entry may not expose an outside file.
            queue.files[ident] = (self.m4a_fixture.resolve(), file_stamp(self.m4a_fixture.stat()), 'm4a')
            with self.assertRaises(HTTPError) as error: urlopen(request)
            self.assertEqual(error.exception.code, 409)
            queue.files[ident] = original
            original[0].unlink()
            with self.assertRaises(HTTPError) as error: urlopen(request)
            self.assertEqual(error.exception.code, 409)
            try: original[0].symlink_to(self.m4a_fixture.resolve())
            except OSError: pass # Windows may lack the optional symlink privilege.
            else:
                with self.assertRaises(HTTPError) as error: urlopen(request)
                self.assertEqual(error.exception.code, 409)
                original[0].unlink()
    def repair_worker(self, calls, downloads):
        cover = MP3(self.fixture).tags.getall('APIC')[0].data
        def prepare(url, folder):
            calls.append(url)
            song = SimpleNamespace(url=url, name='Repaired title', artists=['Test artist'], duration=3,
                                   cover_url='https://i.scdn.co/image/test')
            source = reusable_audio(folder, song)
            if source is None:
                downloads.append(url)
                source = 'https://music.youtube.com/watch?v=abcdefghijk'
                shutil.copyfile(self.fixture, folder/'audio.mp3')
                audio = MP3(folder/'audio.mp3'); audio.tags.delall('APIC'); audio.save(v2_version=3)
                remember_audio(folder, song, source)
            if len(calls) == 1:
                (folder/'failure.json').write_text(json.dumps({'code':'cover','message':'Pochette indisponible.'}), encoding='utf-8')
                raise ValueError('Synthetic cover request failed')
            finish_audio(folder/'audio.mp3', song, source, cover_loader=lambda url:(cover,'image/jpeg'))
            return folder/'audio.mp3', {'source':source}
        return prepare
    def test_cover_retry_reuses_unfinished_audio_only_after_worker_validation(self):
        calls, downloads = [], []
        queue = self.queue(prepare=self.repair_worker(calls, downloads), resolve=lambda url, tracks:('Selection','test',[TRACK]))
        first = self.settled(queue, {'url':TRACK,'request_id':'cover-first-attempt'})
        self.assertEqual(first['state'], 'error')
        self.assertFalse(queue.files)
        self.assertFalse(queue.reusable)
        self.assertIn(TRACK, queue.repairable)
        source = Path(self.folder.name)/first['id']/'1'/'audio.mp3'
        original = source.read_bytes()
        second = self.settled(queue, {'url':TRACK,'request_id':'cover-second-attempt'})
        self.assertEqual(calls, [TRACK,TRACK]) # The repair never bypasses the worker.
        self.assertEqual(downloads, [TRACK])
        self.assertEqual(second['state'], 'complete')
        self.assertEqual(second['items'][0]['title'], 'Repaired title')
        self.assertEqual(source.read_bytes(), original) # Retagging the new copy preserves the old file.
        self.assertFalse(MP3(source).tags.getall('APIC'))
        target = queue.row_path(second['items'][0], Path(self.folder.name)/second['id']/'1')
        self.assertTrue(MP3(target).tags.getall('APIC'))
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), second['items'][0]['id'])
    def test_cover_retry_restores_unfinished_audio_after_restart(self):
        calls, downloads = [], []
        prepare = self.repair_worker(calls, downloads)
        queue = self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',[TRACK]))
        first = self.settled(queue, {'url':TRACK,'request_id':'cover-before-restart'})
        queue.pool.shutdown(wait=True)
        restored = self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',[TRACK]))
        self.assertEqual(restored.snapshot(first['id'])['state'], 'error')
        self.assertFalse(restored.files)
        self.assertIn(TRACK, restored.repairable)
        second = self.settled(restored, {'url':TRACK,'request_id':'cover-after-restart'})
        self.assertEqual(second['state'], 'complete')
        self.assertEqual(calls, [TRACK,TRACK])
        self.assertEqual(downloads, [TRACK])
    def test_cover_retry_rejects_modified_audio_and_wrong_identity_marker(self):
        for corruption, restart in (('audio',False),('audio',True),('identity',False),('identity',True),('source',True)):
            with self.subTest(corruption=corruption, restart=restart), tempfile.TemporaryDirectory() as temp:
                calls, downloads = [], []
                prepare = self.repair_worker(calls, downloads)
                queue = Queue(temp, 'unused', prepare=prepare, resolve=lambda url, tracks:('Selection','test',[TRACK]))
                try:
                    first = self.settled(queue, {'url':TRACK,'request_id':'bad-cover-first-attempt'})
                    folder = Path(temp).resolve()/first['id']/'1'
                    if corruption == 'audio':
                        original = (folder/'audio.mp3').read_bytes()
                        (folder/'audio.mp3').write_bytes(original[:-1]+bytes([original[-1]^1]))
                    else:
                        marker = json.loads((folder/'prepared-audio.json').read_text())
                        marker['spotify' if corruption == 'identity' else 'source'] = OTHER if corruption == 'identity' else 'https://example.com/wrong'
                        (folder/'prepared-audio.json').write_text(json.dumps(marker))
                    if restart:
                        queue.pool.shutdown(wait=True)
                        queue = Queue(temp, 'unused', prepare=prepare, resolve=lambda url, tracks:('Selection','test',[TRACK]))
                        self.assertNotIn(TRACK, queue.repairable)
                    second = self.settled(queue, {'url':TRACK,'request_id':'bad-cover-second-attempt'})
                    self.assertEqual(second['state'], 'complete')
                    self.assertEqual(downloads, [TRACK,TRACK])
                finally:
                    queue.pool.shutdown(wait=True)
    def test_cover_repair_refuses_outside_cache_folder_and_oversized_marker(self):
        queue = self.cached_queue([])
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp).resolve()
            shutil.copyfile(self.fixture, folder/'audio.mp3')
            marker = {'version':1,'spotify':TRACK,'source':'https://music.youtube.com/watch?v=abcdefghijk',
                      'sha256':hashlib.sha256(self.fixture.read_bytes()).hexdigest()}
            (folder/'prepared-audio.json').write_text(json.dumps(marker))
            queue.remember_repair(TRACK, folder)
            self.assertNotIn(TRACK, queue.repairable)
            queue.repairable[TRACK] = (folder/'audio.mp3',marker,self.fixture.stat().st_size)
            target = Path(self.folder.name).resolve()/'new-position'; target.mkdir()
            self.assertFalse(queue.seed_repair(TRACK,target))
            self.assertFalse((target/'audio.mp3').exists())
        inside = Path(self.folder.name).resolve()/'candidate'; inside.mkdir()
        shutil.copyfile(self.fixture, inside/'audio.mp3')
        marker['padding'] = 'x'*20000
        (inside/'prepared-audio.json').write_text(json.dumps(marker))
        queue.remember_repair(TRACK, inside)
        self.assertNotIn(TRACK, queue.repairable)
    def test_two_parallel_tracks_publish_progress_and_keep_playlists_sequential(self):
        condition = threading.Condition()
        release = {url:threading.Event() for url in (TRACK, OTHER, THIRD, FOURTH)}
        started, active, maximum, folders = [], 0, 0, []
        def prepare(url, folder):
            nonlocal active, maximum
            with condition:
                started.append(url); folders.append(folder)
                active += 1; maximum = max(maximum, active)
                condition.notify_all()
            try:
                if not release[url].wait(10): raise TimeoutError('Test worker was not released.')
                target = folder/'audio.mp3'; shutil.copyfile(self.fixture, target)
                return target, {'source':url}
            finally:
                with condition:
                    active -= 1
                    condition.notify_all()
        queue = self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',tracks))
        first = queue.submit({'url':PLAYLIST, 'request_id':'parallel-first-playlist',
                              'track_urls':[TRACK, OTHER, TRACK, THIRD]})
        try:
            with condition:
                self.assertTrue(condition.wait_for(lambda: len(started) == 2, timeout=5))
                self.assertCountEqual(started, [TRACK, OTHER])
                self.assertEqual(active, 2)
            second = queue.submit({'url':OTHER, 'request_id':'parallel-second-playlist', 'track_urls':[FOURTH]})
            self.assertEqual(queue.snapshot(second['id'])['state'], 'queued')
            release[OTHER].set()
            with condition:
                self.assertTrue(condition.wait_for(lambda: THIRD in started, timeout=5))
                self.assertNotIn(FOURTH, started)
                self.assertEqual(active, 2)
            progress = queue.snapshot(first['id'])
            self.assertEqual([row['spotify'] for row in progress['items']], [TRACK, OTHER, TRACK, THIRD])
            self.assertEqual([row['state'] for row in progress['items']], ['running','ready','waiting','running'])
            self.assertIn('1/4', progress['message'])
            ready = progress['items'][1]
            served_file = queue.files[ready['id']][0]
            self.assertEqual(hashlib.sha256(served_file.read_bytes()).hexdigest(), ready['id'])
            persisted = json.loads((Path(self.folder.name)/first['id']/'job.json').read_text(encoding='utf-8'))
            self.assertEqual(persisted['items'][1]['state'], 'ready')
        finally:
            for event in release.values(): event.set()
            queue.pool.shutdown(wait=True)
        self.assertEqual(maximum, 2)
        self.assertEqual(Counter(started), Counter([TRACK, OTHER, THIRD, FOURTH]))
        self.assertEqual(len(set(folders)), 4)
        self.assertEqual(queue.snapshot(first['id'])['state'], 'complete')
        self.assertEqual(queue.snapshot(second['id'])['state'], 'complete')
        self.assertEqual([row['position'] for row in queue.snapshot(first['id'])['items']], [1,2,3,4])
        for row in queue.snapshot(first['id'])['items']:
            self.assertTrue(queue.row_path(row, Path(self.folder.name)/first['id']/str(row['position'])).is_file())
    def test_failed_duplicate_is_prepared_once_and_does_not_block_other_tracks(self):
        calls = []; barrier = threading.Barrier(2)
        def prepare(url, folder):
            calls.append(url)
            if url in (TRACK, OTHER): barrier.wait(timeout=5)
            if url == OTHER:
                (folder/'metadata.json').write_text(json.dumps({'title':'Missing song','artist':'Test artist'}), encoding='utf-8')
                (folder/'failure.json').write_text(json.dumps({'code':'no_match','message':'Aucune correspondance fiable.'}), encoding='utf-8')
                raise ValueError('Missing test source')
            target = folder/'audio.mp3'; shutil.copyfile(self.fixture, target)
            return target, {}
        queue = self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',tracks))
        done = self.settled(queue, {'url':PLAYLIST, 'request_id':'parallel-failed-duplicate',
                                   'track_urls':[TRACK, OTHER, OTHER, THIRD]})
        self.assertEqual(Counter(calls), Counter([TRACK, OTHER, THIRD]))
        self.assertEqual(done['state'], 'partial')
        self.assertEqual([row['state'] for row in done['items']], ['ready','error','error','ready'])
        self.assertEqual([row['title'] for row in done['items'][1:3]], ['Missing song','Missing song'])
        self.assertEqual([row['message'] for row in done['items'][1:3]], ['Aucune correspondance fiable.']*2)
        queue.pool.shutdown(wait=True)
        restored = self.cached_queue(calls)
        self.assertEqual([row['state'] for row in restored.snapshot(done['id'])['items']], ['ready','error','error','ready'])
        retry = self.settled(restored, {'url':PLAYLIST, 'request_id':'parallel-failed-retry',
                                       'track_urls':[TRACK, OTHER, OTHER, THIRD]})
        self.assertEqual(Counter(calls), Counter([TRACK, OTHER, OTHER, THIRD]))
        self.assertEqual(retry['state'], 'complete')
    def test_live_worker_labels_and_phase_are_coalesced_without_stale_ready_message(self):
        release, published = threading.Event(), threading.Event()
        saved = []
        def prepare(url, folder):
            (folder/'metadata.json').write_text(json.dumps({'title':'Early title','artist':'Early artist'}), encoding='utf-8')
            (folder/'progress.json').write_text(json.dumps({'phase':'download','message':'Audio en cours.'}), encoding='utf-8')
            if not release.wait(10): raise TimeoutError('Test worker was not released.')
            target = folder/'audio.mp3'; shutil.copyfile(self.fixture, target)
            return target, {}
        queue = self.queue(prepare=prepare, resolve=lambda url, tracks:('Selection','test',tracks))
        save = queue.save
        def observe(job):
            save(job); saved.append(job['state'])
            if job['items'] and job['items'][0].get('message') == 'Audio en cours.': published.set()
        queue.save = observe
        first = queue.submit({'url':PLAYLIST,'request_id':'live-progress-request','track_urls':[TRACK,TRACK]})
        try:
            self.assertTrue(published.wait(5))
            progress = queue.snapshot(first['id'])
            self.assertEqual([row['title'] for row in progress['items']], ['Early title']*2)
            self.assertEqual([row['state'] for row in progress['items']], ['running','waiting'])
            self.assertNotIn('id', progress['items'][0]) # A phase is not verified audio availability.
            self.assertEqual(progress['items'][0]['message'], 'Audio en cours.')
            before = len(saved)
            queue.publish_worker_progress(queue.jobs[first['id']])
            self.assertEqual(len(saved), before) # Unchanged progress must not rewrite the job.
            (Path(self.folder.name)/first['id']/'1'/'progress.json').write_text('{partial', encoding='utf-8')
            queue.publish_worker_progress(queue.jobs[first['id']])
            self.assertEqual(len(saved), before) # Incomplete worker output is harmless.
        finally:
            release.set()
            queue.pool.shutdown(wait=True)
        complete = queue.snapshot(first['id'])
        self.assertEqual(complete['state'], 'complete')
        self.assertEqual([row['title'] for row in complete['items']], ['Test track']*2)
        self.assertTrue(all('message' not in row for row in complete['items']))
        before = len(saved)
        queue.publish_worker_progress(queue.jobs[first['id']])
        self.assertEqual(len(saved), before)
    def test_complete_metadata_requires_app_list_or_single_track(self):
        queue = self.cached_queue([])
        for key, url, tracks, expected in (
            ('metadata-public-playlist', PLAYLIST, None, False),
            ('metadata-app-playlist', PLAYLIST, [TRACK, OTHER], True),
            ('metadata-single-track', TRACK, None, True),
        ):
            with self.subTest(key=key):
                job = self.settled(queue, {'url':url, 'request_id':key, 'track_urls':tracks})
                self.assertIs(job['completeMetadata'], expected)
                self.assertEqual(job['state'], 'complete') # Audio success alone does not prove a full playlist.
                persisted = json.loads((Path(self.folder.name)/job['id']/'job.json').read_text(encoding='utf-8'))
                self.assertIs(persisted['completeMetadata'], expected)
    def test_legacy_metadata_completeness_is_migrated_conservatively(self):
        queue = self.cached_queue([])
        expected = {}
        for key, url, tracks, complete in (
            ('legacy-public-playlist', PLAYLIST, None, False),
            ('legacy-app-playlist', PLAYLIST, [TRACK], True),
            ('legacy-single-track', TRACK, None, True),
            ('explicit-partial-playlist', PLAYLIST, [TRACK], False),
        ):
            job = self.settled(queue, {'url':url, 'request_id':key, 'track_urls':tracks})
            if key.startswith('legacy-'): job.pop('completeMetadata')
            else: job['completeMetadata'] = False
            queue.save(job)
            expected[job['id']] = complete
        queue.pool.shutdown(wait=True)
        def no_network(url, tracks):
            raise AssertionError('Restoring completeness must not fetch metadata.')
        restored = self.queue(resolve=no_network)
        for ident, complete in expected.items():
            self.assertIs(restored.snapshot(ident)['completeMetadata'], complete)
            persisted = json.loads((Path(self.folder.name)/ident/'job.json').read_text(encoding='utf-8'))
            self.assertIs(persisted['completeMetadata'], complete)
    def test_reuses_duplicates_and_other_playlists_without_crossing_identity(self):
        calls = []; queue = self.cached_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'reuse-first-request', 'track_urls':[TRACK,TRACK]})
        self.assertEqual(calls, [TRACK])
        self.assertEqual(first['state'], 'complete')
        self.assertEqual([row['position'] for row in first['items']], [1,2])
        self.assertEqual(first['items'][0]['id'], first['items'][1]['id'])
        second = self.settled(queue, {'url':OTHER, 'request_id':'reuse-second-request', 'track_urls':[TRACK,OTHER]})
        # The other Spotify identity still needs preparation even when its test audio happens to be identical.
        self.assertEqual(calls, [TRACK, OTHER])
        self.assertEqual(second['state'], 'complete')
        self.assertEqual(second['items'][0]['source'], 'verified synthetic fixture')
        one = queue.row_path(first['items'][0], Path(self.folder.name)/first['id']/'1')
        duplicate = queue.row_path(first['items'][1], Path(self.folder.name)/first['id']/'2')
        original = duplicate.read_bytes()
        self.assertEqual(one, duplicate) # Immutable verified bytes have one canonical copy.
        self.assertEqual(len(list(queue.store.directory.glob('*.mp3'))), 1)
        self.assertEqual(hashlib.sha256(original).hexdigest(), first['items'][1]['id'])
    def test_reuses_verified_audio_after_restart(self):
        calls = []; queue = self.cached_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'before-restart-request'})
        queue.pool.shutdown(wait=True)
        restored = self.cached_queue(calls)
        second = self.settled(restored, {'url':TRACK, 'request_id':'after-restart-request'})
        self.assertEqual(calls, [TRACK])
        self.assertEqual(first['items'][0]['id'], second['items'][0]['id'])
        self.assertEqual(second['state'], 'complete')
    def test_modified_cached_audio_is_not_reused(self):
        calls = []; queue = self.cached_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'before-modified-request'})
        source = queue.row_path(first['items'][0], Path(self.folder.name)/first['id']/'1')
        original = source.read_bytes(); changed = original[:-1]+bytes([original[-1]^1])
        source.write_bytes(changed) # Same size: checking only a file size would accept the wrong bytes.
        second = self.settled(queue, {'url':TRACK, 'request_id':'after-modified-request'})
        self.assertEqual(calls, [TRACK, TRACK])
        self.assertEqual(source.read_bytes(), original) # Reprepared verified bytes repair the corrupt blob.
        self.assertEqual(second['items'][0]['id'], hashlib.sha256(original).hexdigest())
        self.assertFalse(list((Path(self.folder.name)/second['id']/'1').glob('reuse-*.tmp')))
    def test_modified_audio_is_not_restored_as_reusable(self):
        calls = []; queue = self.cached_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'cache-restart-first'})
        queue.pool.shutdown(wait=True)
        source = queue.row_path(first['items'][0], Path(self.folder.name)/first['id']/'1')
        original = source.read_bytes(); source.write_bytes(original[:-1]+bytes([original[-1]^1]))
        restored = self.cached_queue(calls)
        self.assertEqual(restored.snapshot(first['id'])['items'][0]['state'], 'error')
        second = self.settled(restored, {'url':TRACK, 'request_id':'cache-restart-second'})
        self.assertEqual(calls, [TRACK, TRACK])
        self.assertEqual(second['state'], 'complete')
    def test_reuse_refuses_an_outside_cache_path(self):
        calls = []; queue = self.cached_queue(calls)
        queue.reusable[TRACK] = (self.fixture.resolve(), audio_record(self.fixture, {}))
        done = self.settled(queue, {'url':TRACK, 'request_id':'outside-cache-request'})
        self.assertEqual(calls, [TRACK])
        self.assertEqual(done['state'], 'complete')
    def test_partial_idempotency_and_restart(self):
        queue=self.queue(); job=self.submit(queue); queue.pool.shutdown(wait=True)
        done=queue.snapshot(job['id'])
        self.assertEqual(done['state'],'partial')
        self.assertEqual([r['state'] for r in done['items']],['ready','error'])
        self.assertEqual(self.submit(queue)['id'],job['id'])
        with self.assertRaises(ValueError): queue.submit({'url':OTHER,'request_id':'test-idempotency-key'})
        restored=self.queue()
        self.assertEqual(restored.snapshot(job['id'])['items'][0]['id'],done['items'][0]['id'])
        self.assertIn(done['items'][0]['id'],restored.files)
        done['state']='running'; queue.save(done)
        restarted=self.queue()
        restarted.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual(restarted.snapshot(job['id'])['state'],'partial')
    def stored_job(self, queue, key, state='queued', rows=None, **extra):
        fields = request_fields({'url':TRACK, 'request_id':key})
        job = dict(fields, id=hashlib.md5(key.encode(), usedforsecurity=False).hexdigest(), version=2,
                   name='Restart fixture', state=state, created=time.time(), scope='test', message='', items=rows or [])
        job.update(extra)
        queue.save(job)
        return job
    def test_restart_resumes_queued_and_running_without_repreparing_ready(self):
        calls = []; queue = self.cached_queue(calls)
        complete = self.settled(queue, {'url':TRACK, 'request_id':'resume-existing-ready'})
        queue.pool.shutdown(wait=True)
        ready = dict(complete['items'][0])
        ready['position'] = 1
        waiting = {'spotify':OTHER, 'position':2, 'state':'running', 'attempts':1}
        active = self.stored_job(queue, 'resume-running-request', 'running', [ready, waiting])
        queued = self.stored_job(queue, 'resume-queued-request')
        resolutions = []
        def resolve(url, tracks):
            resolutions.append(url)
            return 'Selection','test',[TRACK]
        def prepare(url, folder):
            calls.append(url)
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target, {}
        restored = self.queue(prepare=prepare, resolve=resolve, retry_delays=(0,))
        restored.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual(calls, [TRACK, OTHER])
        self.assertEqual(resolutions, [TRACK]) # Persisted running rows do not refetch metadata.
        self.assertEqual(restored.snapshot(active['id'])['state'], 'complete')
        self.assertEqual(restored.snapshot(queued['id'])['state'], 'complete')
        self.assertEqual(restored.snapshot(active['id'])['items'][0]['id'], ready['id'])
        self.assertEqual(restored.snapshot(active['id'])['items'][1]['attempts'], 2)
        self.assertEqual(restored.submit({'url':TRACK,'request_id':'resume-running-request'})['id'], active['id'])
    def test_restart_does_not_resurrect_cancel_pause_historical_interruption_or_invalid_input(self):
        queue = self.cached_queue([]); queue.pool.shutdown(wait=True)
        expected = {}
        for index, fields in enumerate(({'state':'interrupted'}, {'state':'cancelled'}, {'state':'paused'},
                                       {'state':'running','cancelled':True}, {'state':'queued','userPaused':True})):
            job = self.stored_job(queue, f'resume-stopped-{index:04}', **fields)
            expected[job['id']] = 'cancelled' if fields.get('cancelled') else 'paused' if fields.get('userPaused') else fields['state']
        bad = self.stored_job(queue, 'resume-invalid-request', rows=[{'position':1,'spotify':'file:///secret','state':'waiting'}])
        def forbidden(*args): raise AssertionError('Must not resume this snapshot')
        restored = self.queue(prepare=forbidden, resolve=forbidden)
        restored.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual({key:restored.snapshot(key)['state'] for key in expected}, expected)
        self.assertNotIn(bad['id'], restored.jobs)
        self.assertFalse(restored.storage_status()['cleanup_available']) # Unknown history protects its files.
    def test_transient_worker_retry_is_bounded_and_permanent_failure_is_not_retried(self):
        attempts = Counter()
        def prepare(url, folder):
            attempts[url] += 1
            if url == TRACK and attempts[url] == 1: raise TimeoutError('Synthetic connection loss')
            if url == OTHER:
                (folder/'failure.json').write_text(json.dumps({'code':'no_match','message':'Aucune correspondance fiable.'}))
                raise ValueError('Permanent match failure')
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target, {}
        queue = self.queue(prepare=prepare, resolve=lambda u,t:('Selection','test',[TRACK,OTHER]), retry_delays=(0,))
        done = self.settled(queue, {'url':PLAYLIST,'request_id':'retry-transient-worker'})
        self.assertEqual(done['state'], 'partial')
        self.assertEqual(attempts, Counter({TRACK:2, OTHER:1}))
        self.assertEqual([row['attempts'] for row in done['items']], [2,1])
        queue.pool.shutdown(wait=True)
        exhausted = self.stored_job(queue, 'resume-exhausted-budget', 'running',
            [{'spotify':THIRD,'position':1,'state':'running','attempts':2}])
        restored = self.queue(prepare=prepare, retry_delays=(0,))
        restored.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual(restored.snapshot(exhausted['id'])['state'], 'error')
        self.assertNotIn(THIRD, attempts) # Crashes cannot reset the durable attempt budget.
    def test_transient_resolver_retry_and_persisted_network_worker_error(self):
        import requests
        resolved, prepared = [], []
        def resolve(url, tracks):
            resolved.append(url)
            if len(resolved) == 1: raise requests.ConnectionError('Synthetic network loss')
            return 'Selection','test',[TRACK]
        def prepare(url, folder):
            prepared.append(url)
            if len(prepared) == 1:
                (folder/'failure.json').write_text(json.dumps({'code':'network','message':'Connexion indisponible.'}))
                raise subprocess.CalledProcessError(1, ['synthetic-worker'])
            self.assertFalse((folder/'failure.json').exists()) # Do not inherit a stale retry classification.
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target, {}
        queue=self.queue(prepare=prepare, resolve=resolve, retry_delays=(0,))
        done=self.settled(queue, {'url':TRACK,'request_id':'retry-resolver-network'})
        self.assertEqual((done['state'], done['resolveAttempts'], done['items'][0]['attempts']), ('complete',2,2))
        self.assertEqual((len(resolved), len(prepared)), (2,2))
    def test_alternative_isolated_until_explicit_idempotent_acceptance_and_persists(self):
        calls=[]
        def prepare(url, folder):
            calls.append(url)
            fixture, extension, source = (self.fixture,'mp3',SOURCE_A) if len(calls)==1 else (self.m4a_fixture,'m4a',SOURCE_B)
            target=folder/('audio.'+extension); shutil.copyfile(fixture,target)
            if extension == 'm4a':
                tagged=MP4(target); tagged['\xa9alb']=[f'AAC album · Version {len(calls)}']; tagged.save()
            return target, {'extension':extension,'source':source}
        queue=self.queue(prepare=prepare, resolve=lambda u,t:('Selection','test',[u]))
        first=self.settled(queue, {'url':TRACK,'request_id':'alternative-default-first'})
        candidate=self.settled(queue, {'url':TRACK,'request_id':'alternative-candidate-one','kind':'alternative'})
        self.assertEqual(candidate['state'], 'complete')
        self.assertEqual(candidate['variant_number'], 2)
        self.assertEqual(candidate['effective_avoid_sources'], [SOURCE_A]) # Old iPhone rows lacked provenance.
        ordinary=self.settled(queue, {'url':TRACK,'request_id':'alternative-before-accept'})
        self.assertEqual(ordinary['items'][0]['id'], first['items'][0]['id'])
        digest=candidate['items'][0]['id']
        with self.assertRaises(ValueError): queue.accept_version({'job_id':candidate['id'],'sha256':'0'*64})
        with self.assertRaises(ValueError): queue.accept_version({'job_id':first['id'],'sha256':first['items'][0]['id']})
        accepted=queue.accept_version({'job_id':candidate['id'],'sha256':digest})
        self.assertEqual(accepted, queue.accept_version({'job_id':candidate['id'],'sha256':digest}))
        self.assertEqual(accepted, {'accepted':True,'spotify':TRACK,'sha256':digest,'extension':'m4a'})
        ordinary=self.settled(queue, {'url':TRACK,'request_id':'alternative-after-accept'})
        self.assertEqual(ordinary['items'][0]['id'], digest)
        self.assertEqual(len(calls), 2)
        self.assertTrue(queue.row_path(first['items'][0], queue.root/first['id']/'1').is_file())
        queue.pool.shutdown(wait=True)
        restored=self.queue(prepare=prepare, resolve=lambda u,t:('Selection','test',[u]))
        ordinary=self.settled(restored, {'url':TRACK,'request_id':'alternative-after-restart'})
        self.assertEqual((ordinary['items'][0]['id'], len(calls)), (digest,2))
        next_candidate=self.settled(restored, {'url':TRACK,'request_id':'alternative-candidate-two','kind':'alternative'})
        self.assertEqual(next_candidate['variant_number'], 3)
        self.assertEqual(next_candidate['effective_avoid_sources'], [SOURCE_B])
        self.assertEqual(next_candidate['state'], 'error') # Same known source must not masquerade as another version.
        self.assertEqual(restored.reusable[TRACK][1]['id'], digest)
    def test_alternative_http_capabilities_storage_and_worker_env_contract(self):
        queue=self.cached_queue([])
        folder=queue.root/'environment-test'; folder.mkdir()
        (folder/'audio-ready.json').write_text(json.dumps({'spotify':TRACK,'extension':'mp3'}))
        with patch.dict(os.environ, {'SG_AVOID_SOURCES':'stale','SG_VARIANT_LABEL':'stale'}), patch('automatic_downloads.subprocess.run') as run:
            queue.worker(TRACK,folder)
            self.assertEqual(run.call_args.kwargs['env']['SG_AVOID_SOURCES'], '[]')
            self.assertEqual(run.call_args.kwargs['env']['SG_VARIANT_LABEL'], '')
            queue.worker(TRACK,folder,[SOURCE_A],3)
            self.assertEqual(json.loads(run.call_args.kwargs['env']['SG_AVOID_SOURCES']), [SOURCE_A])
            self.assertEqual(run.call_args.kwargs['env']['SG_VARIANT_LABEL'], 'Version 3')
        with self.http_service(queue) as origin:
            with urlopen(origin+'/hello') as response:
                self.assertEqual(json.load(response), {'version':2,'service':'spoti-auto-downloads'})
            with urlopen(origin+'/capabilities') as response:
                self.assertTrue(json.load(response)['alternativeVersions'])
            with urlopen(origin+'/storage') as response: self.assertEqual(json.load(response)['audio_files'], 0)
            request=Request(origin+'/storage/cleanup',data=b'{}',headers={'Content-Type':'application/json'})
            with urlopen(request) as response: self.assertEqual(json.load(response)['removed_files'], 0)
            for suffix in ('/capabilities','/storage'):
                with self.assertRaises(HTTPError): urlopen(origin.replace('x'*32,'wrong')+suffix)
            for payload in ({'url':PLAYLIST,'kind':'alternative','request_id':'invalid-alternative-playlist'},
                            {'url':TRACK,'kind':'alternative','request_id':'invalid-alternative-source','avoid_sources':['file:///private']},
                            {'url':TRACK,'refresh':True,'track_urls':[TRACK],'request_id':'invalid-refresh-explicit'}):
                with self.assertRaises(ValueError): queue.submit(payload)
    def test_legacy_audio_consolidation_is_explicit_and_preserves_all_completed_references(self):
        queue=self.cached_queue([]); queue.pool.shutdown(wait=True)
        original_paths=[]
        for index in range(2):
            job=self.stored_job(queue, f'legacy-storage-{index:04}', 'complete')
            folder=queue.root/job['id']/'1'; folder.mkdir()
            path=folder/'audio.mp3'; shutil.copyfile(self.fixture,path); original_paths.append(path)
            job['items']=[dict(audio_record(path,{}), spotify=TRACK,position=1,state='ready')]
            job['items'][0].pop('extension') # Genuine old protocol-2 snapshot.
            queue.save(job)
        restored=self.cached_queue([])
        self.assertTrue(all(path.exists() for path in original_paths)) # No automatic migration deletion.
        status=restored.storage_status()
        self.assertEqual((status['audio_files'],status['reclaimable_files']), (2,1))
        report=restored.cleanup_storage({})
        self.assertEqual((report['removed_files'],report['removed_bytes'],report['consolidated_files']), (1,self.fixture.stat().st_size,2))
        self.assertFalse(any(path.exists() for path in original_paths))
        self.assertEqual(report['storage']['audio_files'],1)
        for job in restored.jobs.values():
            self.assertEqual(job['items'][0]['storage'],'blob')
            self.assertEqual(job['items'][0]['id'],hashlib.sha256(self.fixture.read_bytes()).hexdigest())
        restored.pool.shutdown(wait=True)
        again=self.cached_queue([])
        self.assertTrue(all(job['items'][0]['state']=='ready' for job in again.jobs.values()))
        self.assertEqual(again.storage_status()['audio_files'],1)
    def test_cleanup_preserves_legacy_file_when_reference_commit_fails(self):
        queue=self.cached_queue([]); queue.pool.shutdown(wait=True)
        job=self.stored_job(queue,'legacy-storage-failure','complete')
        folder=queue.root/job['id']/'1'; folder.mkdir()
        original=folder/'audio.mp3'; shutil.copyfile(self.fixture,original)
        job['items']=[dict(audio_record(original,{}),spotify=TRACK,position=1,state='ready')]
        queue.save(job)
        restored=self.cached_queue([])
        with patch.object(restored,'save',side_effect=OSError('Synthetic disk failure')):
            report=restored.cleanup_storage({})
        self.assertEqual(report['consolidated_files'],0)
        self.assertEqual(original.read_bytes(), self.fixture.read_bytes())
        persisted=json.loads((folder.parent/'job.json').read_text(encoding='utf-8'))
        self.assertNotIn('storage',persisted['items'][0])
        self.assertNotIn('storage',restored.jobs[job['id']]['items'][0])
    def test_cleanup_only_removes_aged_unreferenced_owned_audio_and_rejects_active_jobs(self):
        queue=self.cached_queue([])
        done=self.settled(queue,{'url':TRACK,'request_id':'storage-protected-reference'})
        kept=queue.row_path(done['items'][0],queue.root/done['id']/'1')
        orphan=queue.store.directory/('1'*64+'.mp3'); orphan.write_bytes(b'old owned artifact')
        recent=queue.store.directory/('2'*64+'.mp3'); recent.write_bytes(b'recent owned artifact')
        unknown=queue.store.directory/'personal-note.txt'; unknown.write_text('Untouched')
        old=time.time()-25*3600; os.utime(orphan,(old,old)); os.utime(kept,(old,old))
        queue.running_jobs.add('synthetic-active')
        with self.assertRaises(ValueError): queue.cleanup_storage({})
        queue.running_jobs.clear()
        report=queue.cleanup_storage({})
        self.assertEqual(report['removed_files'],1)
        self.assertFalse(orphan.exists())
        self.assertTrue(recent.exists()); self.assertTrue(unknown.exists())
        self.assertEqual(kept.read_bytes(),self.fixture.read_bytes())
        self.assertEqual(queue.snapshot(done['id'])['state'],'complete')
    def test_deferred_start_preserves_pending_intent_without_issuing_traffic(self):
        queue=self.cached_queue([]); queue.pool.shutdown(wait=True)
        job=self.stored_job(queue,'deferred-server-start')
        calls=[]
        def prepare(url,folder):
            calls.append(url)
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target,{}
        restored=self.queue(prepare=prepare,resolve=lambda u,t:('Selection','test',[u]),start=False)
        restored.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual(calls,[])
        self.assertEqual(restored.snapshot(job['id'])['state'],'queued')
        restored.resume_pending(); restored.resume_pending()
        restored.pool.submit(lambda: None).result(timeout=10)
        self.assertEqual(calls,[TRACK])
        self.assertEqual(restored.snapshot(job['id'])['state'],'complete')
    def test_main_preserves_pairing_extra_fields_and_closes_queue_on_bind_failure(self):
        session=Path(self.folder.name)/'session.json'
        original={'url':'http://192.168.1.10:8768/'+'x'*32+'/', 'autostart':True, 'privateField':'unchanged'}
        session.write_text(json.dumps(original))
        arguments=['automatic_downloads.py','--bind','192.168.1.20','--port','8768','--data',self.folder.name,
                   '--ffmpeg','unused','--session',str(session),'--lifetime-seconds','0']
        with patch('sys.argv',arguments), patch('automatic_downloads.Queue') as queue_factory, \
             patch('download_variants.VariantQueue') as variants_factory, \
             patch('local_imports.LocalImportQueue') as local_factory, \
             patch('automatic_downloads.ThreadingHTTPServer',side_effect=OSError('Port occupied')):
            with self.assertRaises(OSError): main()
            queue_factory.assert_called_once_with(Path(self.folder.name),'unused',start=False)
            variants_factory.assert_called_once_with(queue_factory.return_value,'unused',local_imports=local_factory.return_value)
            queue_factory.return_value.resume_pending.assert_not_called()
            queue_factory.return_value.pool.shutdown.assert_called_once_with(wait=True,cancel_futures=True)
            variants_factory.return_value.shutdown.assert_called_once_with(wait=True)
            local_factory.return_value.shutdown.assert_called_once_with(wait=True)
        self.assertEqual(json.loads(session.read_text()),original)
        with patch('sys.argv',arguments), patch('automatic_downloads.Queue') as queue_factory, \
             patch('download_variants.VariantQueue'), \
             patch('local_imports.LocalImportQueue'), \
             patch('automatic_downloads.ThreadingHTTPServer') as server_factory, \
             patch('companion_discovery.advertise',return_value=nullcontext()), redirect_stdout(io.StringIO()):
            main()
            queue_factory.return_value.resume_pending.assert_called_once_with()
            server_factory.return_value.serve_forever.assert_called_once_with()
            server_factory.return_value.server_close.assert_called_once_with()
        stored=json.loads(session.read_text())
        self.assertEqual(stored,dict(original,url='http://192.168.1.20:8768/'+'x'*32+'/'))
    def test_rate_limit_is_not_retried_without_server_backoff(self):
        import requests
        calls=[]
        def limited(url,tracks):
            calls.append(url)
            response=requests.Response(); response.status_code=429
            raise requests.HTTPError('Rate limited',response=response)
        queue=self.queue(resolve=limited,retry_delays=(0,))
        result=self.settled(queue,{'url':TRACK,'request_id':'respect-rate-limit-test'})
        self.assertEqual(result['state'],'error')
        self.assertEqual(calls,[TRACK])
    def test_alternative_without_distinct_actual_album_never_becomes_ready(self):
        def untagged(url,folder):
            target=folder/'audio.mp3'; shutil.copyfile(self.fixture,target)
            return target,{'source':SOURCE_B}
        queue=self.queue(prepare=untagged,resolve=lambda u,t:('Selection','test',[u]))
        result=self.settled(queue,{'url':TRACK,'kind':'alternative','request_id':'alternative-missing-label'})
        self.assertEqual(result['state'],'error')
        self.assertFalse(queue.files); self.assertFalse(queue.reusable)
    def test_store_and_cleanup_refuse_symlink_to_unrelated_file(self):
        queue=self.cached_queue([])
        digest=hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        link=queue.store.directory/(digest+'.mp3')
        try: link.symlink_to(self.fixture)
        except (OSError,NotImplementedError): self.skipTest('Symlink creation unavailable on this host.')
        result=self.settled(queue,{'url':TRACK,'request_id':'storage-symlink-reject'})
        self.assertEqual(result['state'],'error')
        self.assertTrue(link.is_symlink())
        before=self.fixture.read_bytes()
        queue.cleanup_storage({})
        self.assertTrue(link.is_symlink()); self.assertEqual(self.fixture.read_bytes(),before)
    def test_api_authorization_transfer_and_modified_file(self):
        queue=self.queue()
        server=ThreadingHTTPServer(('127.0.0.1',0),handler_for(queue,'127.0.0.1',0,'x'*32))
        port=server.server_port
        server.RequestHandlerClass=handler_for(queue,'127.0.0.1',port,'x'*32)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        root=f'http://127.0.0.1:{port}/'+('x'*32)
        try:
            with urlopen(root+'/hello') as response: self.assertEqual(json.load(response)['version'],2)
            payload=json.dumps({'url':TRACK,'request_id':'test-http-12345678'}).encode()
            request=Request(root+'/jobs',data=payload,headers={'Content-Type':'application/json'})
            with urlopen(request) as response: job=json.load(response)
            queue.pool.shutdown(wait=True)
            with urlopen(root+'/jobs/'+job['id']) as response: done=json.load(response)
            ident=done['items'][0]['id']
            with urlopen(root+'/file/'+ident) as response: self.assertEqual(hashlib.sha256(response.read()).hexdigest(),ident)
            for bad in (Request(root+'/jobs',data=payload,headers={'Content-Type':'application/json','Origin':'https://evil.example'}),
                        Request(root+'/hello',headers={'Host':'evil.example'}),root.replace('x'*32,'bad')+'/hello'):
                with self.assertRaises(HTTPError): urlopen(bad)
            path=queue.files[ident][0]
            path.write_bytes(path.read_bytes()+b'changed')
            with self.assertRaises(HTTPError) as error: urlopen(root+'/file/'+ident)
            self.assertEqual(error.exception.code,409)
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == '__main__': unittest.main(verbosity=2)
