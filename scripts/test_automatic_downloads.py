"""Offline regression tests. Set SG_TEST_FFMPEG to the ffmpeg executable."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from collections import Counter
from pathlib import Path
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
from PIL import Image
from mutagen.mp3 import MP3
from mutagen.id3 import TIT2, TPE1, TALB, APIC
from automatic_downloads import Queue, handler_for, lan_address, audio_record
from download_metadata import canonical, collection
from download_worker import acceptable, remember_audio, reusable_audio, finish_audio

TRACK = 'https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT'
OTHER = 'https://open.spotify.com/track/7sL89oFc1AcgjG5Q6tCkID'
PLAYLIST = 'https://open.spotify.com/playlist/1Imj2Uc2NVvyHgrAouKQo3'
THIRD = TRACK[:-1]+'U'
FOURTH = TRACK[:-1]+'V'

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
        subprocess.run([ffmpeg,'-v','error','-f','lavfi','-i','sine=frequency=440:duration=3',
                        '-c:a','libmp3lame',str(cls.fixture)],check=True)
        cover = io.BytesIO(); Image.new('RGB',(32,32),'blue').save(cover,format='JPEG')
        audio = MP3(cls.fixture)
        audio.tags.add(TIT2(encoding=1,text=['Test track']))
        audio.tags.add(TPE1(encoding=1,text=['Test artist']))
        audio.tags.add(TALB(encoding=1,text=['']))
        audio.tags.add(APIC(encoding=1,mime='image/jpeg',type=3,data=cover.getvalue()))
        audio.save(v2_version=3)
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
        target = Path(self.folder.name)/second['id']/'1'/'audio.mp3'
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
        for position in (1,2,3,4):
            self.assertTrue((Path(self.folder.name)/first['id']/str(position)/'audio.mp3').is_file())
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
        one = Path(self.folder.name)/first['id']/'1'/'audio.mp3'
        duplicate = Path(self.folder.name)/first['id']/'2'/'audio.mp3'
        original = duplicate.read_bytes()
        one.write_bytes(one.read_bytes()+b'changed')
        self.assertEqual(duplicate.read_bytes(), original) # Copies are independent, not hard links.
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
        source = Path(self.folder.name)/first['id']/'1'/'audio.mp3'
        original = source.read_bytes(); changed = original[:-1]+bytes([original[-1]^1])
        source.write_bytes(changed) # Same size: checking only a file size would accept the wrong bytes.
        second = self.settled(queue, {'url':TRACK, 'request_id':'after-modified-request'})
        self.assertEqual(calls, [TRACK, TRACK])
        self.assertEqual(source.read_bytes(), changed)
        self.assertEqual(second['items'][0]['id'], hashlib.sha256(original).hexdigest())
        self.assertFalse(list((Path(self.folder.name)/second['id']/'1').glob('reuse-*.tmp')))
    def test_modified_audio_is_not_restored_as_reusable(self):
        calls = []; queue = self.cached_queue(calls)
        first = self.settled(queue, {'url':TRACK, 'request_id':'cache-restart-first'})
        queue.pool.shutdown(wait=True)
        source = Path(self.folder.name)/first['id']/'1'/'audio.mp3'
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
        self.assertEqual(restarted.snapshot(job['id'])['state'],'interrupted')
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
