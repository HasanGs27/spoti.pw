"""Deterministic metadata/cache/retry tests; no external requests."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import requests
import download_metadata as metadata

TRACK = 'https://open.spotify.com/track/aaaaaaaaaaaaaaaaaaaaaa'
OTHER = 'https://open.spotify.com/track/bbbbbbbbbbbbbbbbbbbbbb'
PLAYLIST = 'https://open.spotify.com/playlist/cccccccccccccccccccccc'


def page(data):
    value = {'props':{'pageProps':{'state':{'data':{'entity':data}}}}}
    return ('<script id="__NEXT_DATA__" type="application/json">' + json.dumps(value) + '</script>').encode()


class Response:
    def __init__(self, url, status=200, body=b'', headers=None):
        self.url, self.status_code, self.body = url.replace('/track/', '/embed/track/'), status, body
        self.headers = headers or {}
        self.closed = False
    def __enter__(self): return self
    def __exit__(self, *args): self.closed = True
    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(str(self.status_code), response=self)
    def iter_content(self, size):
        for start in range(0, len(self.body), size): yield self.body[start:start+size]


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        self.environment = patch.dict(os.environ, {'SG_METADATA_CACHE_DIR':str(self.folder)})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.data = {'id':TRACK.rsplit('/',1)[1], 'type':'track', 'uri':'spotify:track:' + TRACK.rsplit('/',1)[1], 'title':'Original'}

    def test_track_cache_avoids_second_request_but_not_playlist_refresh(self):
        with patch.object(metadata, 'public_page', return_value=page(self.data)) as get:
            self.assertEqual(metadata.entity(TRACK), self.data)
            self.assertEqual(metadata.entity(TRACK + '?si=shared'), self.data)
            self.assertEqual(get.call_count, 1)
        collection = {'id':PLAYLIST.rsplit('/',1)[1], 'type':'playlist'}
        with patch.object(metadata, 'public_page', return_value=page(collection)) as get:
            metadata.entity(PLAYLIST); metadata.entity(PLAYLIST)
            self.assertEqual(get.call_count, 2)

    def test_stale_corrupt_and_wrong_identity_cache_are_not_used(self):
        path = metadata.cache_file(TRACK)
        for content in ('{broken', json.dumps({'url':OTHER, 'savedAt':100, 'entity':self.data}),
                        json.dumps({'url':TRACK, 'savedAt':100, 'entity':self.data}),
                        json.dumps({'url':TRACK, 'savedAt':1000000, 'entity':self.data}),
                        json.dumps({'url':TRACK, 'savedAt':100000, 'entity':{**self.data,'uri':'spotify:track:' + OTHER.rsplit('/',1)[1]}})):
            with self.subTest(content=content), patch.object(metadata.time, 'time', return_value=100000):
                path.write_text(content, encoding='utf-8')
                with patch.object(metadata, 'public_page', return_value=page(self.data)) as get:
                    self.assertEqual(metadata.entity(TRACK), self.data)
                    self.assertEqual(get.call_count, 1)

    def test_wrong_entity_or_error_page_is_not_cached(self):
        for body in (page({**self.data,'id':OTHER.rsplit('/',1)[1]}), b'<h1>Unavailable</h1>', page({**self.data,'uri':OTHER})):
            with patch.object(metadata, 'public_page', return_value=body):
                with self.assertRaises(ValueError): metadata.entity(TRACK)
            self.assertFalse(metadata.cache_file(TRACK).exists())

    def test_cache_bound_preserves_unrelated_files(self):
        unrelated = self.folder/'notes.json'; unrelated.write_text('keep', encoding='utf-8')
        with patch.object(metadata, 'CACHE_ENTRIES', 2):
            for char in 'abcd':
                url = 'https://open.spotify.com/track/' + char*22
                metadata.save_cached_entity(metadata.cache_file(url), url, {**self.data,'id':char*22, 'uri':'spotify:track:' + char*22})
        cached = [p for p in self.folder.glob('*.json') if len(p.stem)==64]
        self.assertEqual(len(cached), 2)
        self.assertEqual(unrelated.read_text(), 'keep')

    def test_transient_retry_is_bounded_and_closes_responses(self):
        denied, valid = Response(TRACK,503), Response(TRACK,body=b'ok')
        with patch.object(metadata.requests, 'get', side_effect=[denied,valid]) as get, patch.object(metadata.time,'sleep'):
            self.assertEqual(metadata.public_page(TRACK), b'ok')
            self.assertEqual(get.call_count, 2)
            self.assertTrue(denied.closed and valid.closed)
            self.assertFalse(get.call_args.kwargs['allow_redirects'])
        for status, header in ((403,{}),(429,{'Retry-After':'120'})):
            response = Response(TRACK,status,headers=header)
            with patch.object(metadata.requests, 'get', return_value=response) as get, patch.object(metadata.time,'sleep'):
                with self.assertRaises(requests.HTTPError): metadata.public_page(TRACK)
                self.assertEqual(get.call_count, 1)
        with patch.object(metadata.requests,'get',side_effect=requests.Timeout()) as get, patch.object(metadata.time,'sleep'):
            with self.assertRaises(requests.Timeout): metadata.public_page(TRACK)
            self.assertEqual(get.call_count, 2)
        interrupted, valid = Response(TRACK), Response(TRACK,body=b'complete')
        with patch.object(interrupted, 'iter_content', side_effect=requests.exceptions.ChunkedEncodingError()), \
             patch.object(metadata.requests, 'get', side_effect=[interrupted,valid]) as get, patch.object(metadata.time,'sleep'):
            self.assertEqual(metadata.public_page(TRACK), b'complete')
            self.assertEqual(get.call_count, 2)
            self.assertTrue(interrupted.closed and valid.closed)

    def test_response_is_bounded_even_without_content_length(self):
        for headers in ({}, {'Content-Length':'30'}):
            with patch.object(metadata,'MAX_RESPONSE',20), patch.object(metadata.requests,'get',return_value=Response(TRACK,body=b'x'*30,headers=headers)):
                with self.assertRaises(ValueError): metadata.public_page(TRACK)

    def test_partial_playlist_keeps_valid_order_and_reports_missing_rows(self):
        data = {'type':'playlist','name':'Test','trackList':[{'uri':TRACK},{'uri':'unavailable'},None,{'uri':OTHER},{'uri':TRACK}]}
        with patch.object(metadata,'entity',return_value=data):
            name, scope, urls = metadata.collection(PLAYLIST)
            self.assertEqual(urls,[TRACK,OTHER,TRACK])
            self.assertIn('2 entrée(s) indisponible(s)',scope)
            self.assertIn("n'est pas garanti",scope)


if __name__ == '__main__': unittest.main()
