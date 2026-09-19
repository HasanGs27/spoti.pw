"""Offline contracts for lightweight source startup; no songs or network needed."""
import importlib.metadata
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import download_source

SOURCE='https://music.youtube.com/watch?v=abcdefghijk'
BASE_ARGS=['--ignore-config','--socket-timeout','20','--retries','1','--max-filesize','100M']


class SourceOptionsTests(unittest.TestCase):
    def test_installed_spotdl_wrapper_and_direct_parser_are_exactly_equivalent(self):
        # Compare the actual installed implementations, not copied test logic.
        with tempfile.TemporaryDirectory(prefix='sg-options-') as temporary, \
             patch.object(Path,'home',return_value=Path(temporary)):
            from spotdl.utils.formatter import args_to_ytdlp_options
            from yt_dlp import parse_options
            for runtime in (None, r'C:\Program Files\Node runtime\node.exe', '/tmp/Node runtime/node'):
                arguments=BASE_ARGS + (['--js-runtimes','node:'+runtime] if runtime else [])
                with self.subTest(runtime=runtime):
                    # The Windows runtime must survive the actual shlex round-trip.
                    round_trip=shlex.split(shlex.join(arguments))
                    before=args_to_ytdlp_options(round_trip,{})
                    after=parse_options(round_trip).ydl_opts
                    self.assertEqual(before,after)
                    self.assertEqual(after['socket_timeout'],20)
                    self.assertEqual(after['retries'],1)
                    self.assertEqual(after['max_filesize'],100*1024*1024)
                    if runtime:self.assertEqual(after['js_runtimes']['node']['path'],runtime)
        self.assertTrue(importlib.metadata.version('yt-dlp'))
        self.assertTrue(importlib.metadata.version('spotdl'))

    def test_source_uses_one_parse_and_preserves_verified_identity_and_safety_overrides(self):
        from yt_dlp import YoutubeDL, parse_options
        captured={}
        with tempfile.TemporaryDirectory(prefix='sg-source-') as temporary:
            folder=Path(temporary).resolve()
            target=folder/'source.webm'
            class Client(YoutubeDL):
                def __init__(self,options):captured.update(options)
                def __enter__(self):return self
                def __exit__(self,*args):return False
                def extract_info(self,url,download):
                    self_url=url
                    assert self_url==SOURCE and download is True
                    target.write_bytes(b'synthetic audio'*200)
                    return {'id':'abcdefghijk','ext':'webm','acodec':'opus','abr':132.5,'duration':180}
                def prepare_filename(self,info):return str(target)
            with patch('download_worker.downloader_arguments',return_value=shlex.join(BASE_ARGS)), \
                 patch('yt_dlp.parse_options',wraps=parse_options) as parsed, patch('yt_dlp.YoutubeDL',Client):
                download_source.fetch(SOURCE,folder,20)
            parsed.assert_called_once_with(BASE_ARGS)
            self.assertEqual(captured['format'],'bestaudio/best')
            self.assertEqual(captured['max_filesize'],100*1024*1024)
            self.assertEqual(captured['retries'],1)
            self.assertEqual(captured['concurrent_fragment_downloads'],1)
            self.assertTrue(captured['noplaylist'])
            self.assertIsNone(captured['cookiefile']);self.assertIsNone(captured['cookiesfrombrowser'])
            self.assertFalse(captured['usenetrc']);self.assertFalse(captured['cachedir'])
            record=json.loads((folder/'source-info.json').read_text(encoding='utf-8'))
            self.assertEqual(record,{'file':'source.webm','source':SOURCE,'extension':'webm',
                'sourceCodec':'opus','sourceBitrate':132.5,'seconds':180})

    def test_lightweight_fetch_does_not_import_spotdl_or_contact_network(self):
        source=r'''
import json,socket,sys
from pathlib import Path
from unittest.mock import patch
def denied(*args,**kwargs):raise AssertionError('No network in offline source test')
socket.socket.connect=denied;socket.create_connection=denied
folder=Path(sys.argv[1]).resolve()
Path.home=classmethod(lambda cls:folder)
import download_source
from yt_dlp import YoutubeDL
class Client(YoutubeDL):
 def __init__(self,options):pass
 def __enter__(self):return self
 def __exit__(self,*args):return False
 def extract_info(self,url,download):
  (folder/'source.m4a').write_bytes(b'fixture'*300)
  return {'id':'abcdefghijk','ext':'m4a','acodec':'mp4a.40.2'}
 def prepare_filename(self,info):return str(folder/'source.m4a')
with patch('download_worker.downloader_arguments',return_value='--ignore-config --socket-timeout 20 --retries 1 --max-filesize 100M'),patch('yt_dlp.YoutubeDL',Client):
 download_source.fetch('https://music.youtube.com/watch?v=abcdefghijk',folder,20)
assert not any(name=='spotdl' or name.startswith('spotdl.') for name in sys.modules)
print(json.dumps({'spotdlImported':False,'ready':(folder/'source-info.json').is_file()}))
'''
        with tempfile.TemporaryDirectory(prefix='sg-source-subprocess-') as temporary:
            environment=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parent),PYTHONDONTWRITEBYTECODE='1')
            result=subprocess.run([sys.executable,'-X','utf8','-c',source,temporary],env=environment,
                check=True,capture_output=True,text=True,timeout=15,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            self.assertEqual(json.loads(result.stdout),{'spotdlImported':False,'ready':True})


if __name__=='__main__':unittest.main(verbosity=2)
