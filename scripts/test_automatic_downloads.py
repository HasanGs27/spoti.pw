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
from pathlib import Path
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from http.server import ThreadingHTTPServer
from PIL import Image
from mutagen.mp3 import MP3
from mutagen.id3 import TIT2, TPE1, TALB, APIC
from automatic_downloads import Queue, handler_for, lan_address
from download_metadata import canonical, collection
from download_worker import acceptable

TRACK = 'https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT'
OTHER = 'https://open.spotify.com/track/7sL89oFc1AcgjG5Q6tCkID'

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
        queue = Queue(self.folder.name,'unused',prepare=prepare,
                      resolve=lambda url, tracks:('Selection','test',[TRACK,OTHER]), **kwargs)
        self.queues.append(queue)
        return queue
    def submit(self, queue):
        return queue.submit({'url':TRACK,'request_id':'test-idempotency-key'})
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
