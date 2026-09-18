"""Offline worker regressions. Synthetic audio only; no public downloads.

Set SG_TEST_FFMPEG to run the MP3/metadata integration cases.
"""
import io
import asyncio
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from PIL import Image
from mutagen.mp3 import MP3
import download_worker as worker

SOURCE = "https://music.youtube.com/watch?v=abcdef12345"
TRACK = "https://open.spotify.com/track/3DaGnKmAAmyZGIbC0KjmxT"
COVER = "https://i.scdn.co/image/test-fixture"


def setUpModule():
    global _test_profile, _home_patch
    _test_profile = tempfile.TemporaryDirectory()
    _home_patch = patch.object(Path, "home", classmethod(lambda cls: Path(_test_profile.name)))
    _home_patch.start()


def tearDownModule():
    _home_patch.stop()
    _test_profile.cleanup()


def song(**changes):
    return SimpleNamespace(**(dict(name="Bandolero", artists=["Moha La Squale"],
        duration=186.2, explicit=True, cover_url=COVER, url=TRACK) | changes))


def result(**changes):
    return SimpleNamespace(**(dict(name="Bandolero", artists=["Moha La Squale"],
        duration=186, explicit=True, verified=True, url=SOURCE) | changes))


def image_bytes(format="JPEG"):
    data = io.BytesIO()
    Image.new("RGB", (32, 32), "blue").save(data, format=format)
    return data.getvalue()


class MatchingTests(unittest.TestCase):
    def test_explicit_spinall_alias_does_not_relax_other_identity_checks(self):
        expected = song(name="Dis Love", artists=["SPINALL", "Wizkid", "Tiwa Savage"], duration=155, explicit=False)
        base = dict(name="Dis Love (feat. Wizkid & Tiwa Savage)", artists=["DJ Spinall"], duration=155, explicit=False)
        self.assertTrue(worker.acceptable(result(**base), expected))
        self.assertTrue(worker.acceptable(result(**(base | {"artists": ["SPINALL"]})),
                                         song(name="Dis Love", artists=["DJ Spinall", "Wizkid", "Tiwa Savage"], duration=155, explicit=False)))
        for change in ({"artists": ["DJ Other"]}, {"artists": ["Spinall Tribute"]},
                       {"name": "Dis Love Remix (feat. Wizkid & Tiwa Savage)"},
                       {"explicit": True}, {"duration": 160}):
            with self.subTest(change=change):
                self.assertFalse(worker.acceptable(result(**(base | change)), expected))
        self.assertFalse(worker.acceptable(result(artists=["DJ Example"]), song(artists=["Example"])))
        # The same explicit equivalence also applies to a known featured credit.
        self.assertTrue(worker.acceptable(result(name="Song (feat. DJ Spinall)", artists=["Wizkid"]),
                                         song(name="Song", artists=["Wizkid", "SPINALL"])))

    def test_exact_title_order_version_and_artist_identity(self):
        self.assertTrue(worker.acceptable(result(), song()))
        for change in ({"name": "Bandolero 2"}, {"name": "Bandolero - Remix"},
                       {"name": "Bandolero - Clean"}, {"name": "Bandolero (sped up)"},
                       {"name": "Bandolero (slowed + reverb)"}, {"name": "Bandolero (Live)"},
                       {"name": "Bandolero instrumental"}, {"name": "Bandolero radio edit"},
                       {"artists": ["Moha La Squale Tribute"]}, {"artists": ["Squale La Moha"]},
                       {"artists": ["Moha La Squale", "Someone else"]},
                       {"explicit": False}, {"explicit": None}, {"duration": 180},
                       {"duration": float("nan")}, {"duration": float("inf")},
                       {"duration": -1}, {"duration": None}, {"verified": False}):
            with self.subTest(change=change):
                self.assertFalse(worker.acceptable(result(**change), song()))
        self.assertFalse(worker.acceptable(result(name="Me Love"), song(name="Love Me")))
        self.assertFalse(worker.acceptable(result(), song(explicit=False)))
        self.assertFalse(worker.acceptable(result(), song(duration=float("nan"))))

    def test_feat_normalization_covers_real_failure_shapes(self):
        # Public song-result shapes from saved jobs; durations are synthetic fixtures.
        cases = [
            ("200 Mph", ["Bad Bunny", "Diplo"], "200 MPH FT Diplo (feat. Diplo)", ["Bad Bunny"]),
            ("Dis Love", ["DJ Spinall", "Wizkid", "Tiwa Savage"], "Dis Love (feat. Wizkid & Tiwa Savage)", ["DJ Spinall"]),
            ("Doktor", ["Kenan Doğulu", "İskender Paydaş"], "Doktor (feat. İskender Paydaş)", ["Kenan Doğulu"]),
            ("Deja Vu - Play & Win Radio Edit", ["INNA", "Bob Taylor"], "Deja Vu [Play & Win Radio Edit] (feat. Bob Taylor)", ["INNA"]),
            ("Sebastian", ["Volga Tamöz", "Hande Yener"], "Sebastian (feat. Hande Yener)", ["Volga Tamöz"]),
        ]
        for name, artists, actual, actual_artists in cases:
            with self.subTest(name=name):
                self.assertTrue(worker.acceptable(result(name=actual, artists=actual_artists), song(name=name, artists=artists)))
        self.assertTrue(worker.acceptable(result(name="Song", artists=["Lead", "Guest"]),
                                         song(name="Song (feat. Guest)", artists=["Lead", "Guest"])))
        self.assertFalse(worker.acceptable(result(name="Song (feat. Wrong Guest)", artists=["Lead"]),
                                          song(name="Song", artists=["Lead", "Guest"])))
        self.assertFalse(worker.acceptable(result(name="Song", artists=["Lead"]),
                                          song(name="Song", artists=["Lead", "Guest"])))
        self.assertFalse(worker.acceptable(result(name="Song (feat. Guest Remix)", artists=["Lead"]),
                                          song(name="Song", artists=["Lead", "Guest"])))
        self.assertFalse(worker.acceptable(result(name="Song", artists=["Lead Guest"]),
                                          song(name="Song", artists=["Lead", "Guest"])))

    def test_unicode_identities_are_preserved(self):
        for title, artist in (("Ночь", "Кино"), ("夜に駆ける", "ヨアソビ"), ("نور العين", "عمرو دياب"),
                              ("Aşkın Ertesi", "Bahadır Tatlıöz")):
            with self.subTest(title=title):
                expected = song(name=title, artists=[artist])
                self.assertTrue(worker.acceptable(result(name=title, artists=[artist]), expected))
                self.assertFalse(worker.acceptable(result(name="別の曲", artists=[artist]), expected))
        self.assertTrue(worker.acceptable(result(name="Señora", artists=["Jul"]), song(name="Senora", artists=["Jul"])))

    def test_search_is_bounded_strict_and_does_not_repeat_success(self):
        expected = song(name="200 Mph", artists=["Bad Bunny", "Diplo"])
        good = result(name="200 MPH (feat. Diplo)", artists=["Bad Bunny"])
        provider = SimpleNamespace(get_results=Mock(side_effect=[[result(name="Wrong")], [good]]))
        candidates = []
        self.assertEqual(worker.choose_source(provider, expected, candidates), SOURCE)
        self.assertEqual(provider.SEARCH_ATTEMPTS, 1)
        self.assertEqual([c.args[0] for c in provider.get_results.call_args_list], ["200 Mph Bad Bunny Diplo", "200 Mph Bad Bunny"])
        self.assertEqual([r["accepted"] for r in candidates], [False, True])
        for call in provider.get_results.call_args_list:
            self.assertEqual(call.kwargs, dict(filter="songs", ignore_spelling=True, limit=20))
        provider.get_results = Mock(return_value=[good])
        worker.choose_source(provider, expected, [])
        self.assertEqual(provider.get_results.call_count, 1)
        provider.get_results = Mock(return_value=[])
        with self.assertRaises(worker.WorkerFailure) as failure:
            worker.choose_source(provider, expected, [])
        self.assertEqual(failure.exception.code, "no_match")
        self.assertEqual(provider.get_results.call_count, 2)
        provider.get_results = Mock(return_value=[result(url="https://evil.test/audio")])
        with self.assertRaises(worker.WorkerFailure): worker.choose_source(provider, song(), [])
        self.assertEqual(provider.get_results.call_count, 1)


class FakeResponse:
    def __init__(self, data=b"", status=200, headers=None):
        self.data, self.status_code, self.headers = data, status, headers or {}
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def raise_for_status(self):
        if self.status_code >= 400: raise RuntimeError(f"HTTP {self.status_code}")
    def iter_content(self, size):
        for i in range(0, len(self.data), size): yield self.data[i:i+size]


class CoverAndProgressTests(unittest.TestCase):
    def test_windows_ffmpeg_spawns_are_hidden_and_module_local(self):
        sync = Mock(return_value="sync child")
        asynchronous = AsyncMock(return_value="async child")
        module = SimpleNamespace(subprocess=SimpleNamespace(Popen=sync, PIPE=-1),
                                 asyncio=SimpleNamespace(create_subprocess_exec=asynchronous, PIPE=-1))
        original_popen, original_exec = subprocess.Popen, asyncio.create_subprocess_exec
        with patch.object(worker.os, "name", "nt"), patch.object(worker.subprocess, "CREATE_NO_WINDOW", 0x08000000, create=True):
            self.assertTrue(worker.configure_hidden_ffmpeg(module))
            self.assertEqual(module.subprocess.Popen(["ffmpeg", "-version"], stdout=-1), "sync child")
            self.assertEqual(asyncio.run(module.asyncio.create_subprocess_exec("ffmpeg", "-nostdin", creationflags=0x200, stdin=-1)), "async child")
            self.assertEqual(sync.call_args.kwargs, {"stdout": -1, "creationflags": 0x08000000})
            self.assertEqual(asynchronous.call_args.kwargs, {"stdin": -1, "creationflags": 0x08000200})
            wrapped = module.subprocess
            worker.configure_hidden_ffmpeg(module)
            self.assertIs(module.subprocess, wrapped)  # Idempotent; no nested wrappers.
        self.assertIs(subprocess.Popen, original_popen)
        self.assertIs(asyncio.create_subprocess_exec, original_exec)
        module = SimpleNamespace()
        with patch.object(worker.os, "name", "posix"):
            self.assertFalse(worker.configure_hidden_ffmpeg(module))
        self.assertEqual(vars(module), {})

    def test_cover_url_and_redirect_validation_before_request(self):
        for url in ("http://i.scdn.co/image/a", "https://i.scdn.co.evil/image/a", "https://127.0.0.1/a",
                    "https://u:p@i.scdn.co/image/a", "https://i.scdn.co:80/a", None, "file:///a"):
            session = Mock()
            with self.subTest(url=url), self.assertRaises(worker.WorkerFailure): worker.fetch_cover(url, session)
            session.get.assert_not_called()
        session = Mock(get=Mock(return_value=FakeResponse(status=302, headers={"Location": "http://127.0.0.1/a"})))
        with self.assertRaises(worker.WorkerFailure): worker.fetch_cover(COVER, session)
        self.assertEqual(session.get.call_count, 1)
        good = image_bytes()
        session.get = Mock(side_effect=[FakeResponse(status=302, headers={"Location": "/image/b"}), FakeResponse(good)])
        self.assertEqual(worker.fetch_cover(COVER, session), (good, "image/jpeg"))
        self.assertFalse(session.get.call_args.kwargs["allow_redirects"])

    def test_rejects_html_errors_oversize_and_invalid_image(self):
        for response in (FakeResponse(b"<html>not a cover</html>"), FakeResponse(image_bytes("GIF")),
                         FakeResponse(status=403), FakeResponse(headers={"Content-Length": str(worker.MAX_COVER_BYTES+1)})):
            with self.subTest(response=response), self.assertRaises(Exception):
                worker.fetch_cover(COVER, Mock(get=Mock(return_value=response)))
        with patch.object(worker, "MAX_COVER_BYTES", 10):
            with self.assertRaises(ValueError): worker.fetch_cover(COVER, Mock(get=Mock(return_value=FakeResponse(b"a"*11))))

    def test_progress_deduplicates_and_failures_do_not_leak_upstream_text(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            progress = worker.Progress(folder)
            with patch.object(worker, "atomic_json", wraps=worker.atomic_json) as write:
                progress.set("search"); progress.set("search"); progress.set("download")
                self.assertEqual(write.call_count, 2)
            self.assertEqual(json.loads((folder/"progress.json").read_text(encoding="utf-8"))["phase"], "download")
            self.assertEqual(list(folder.glob("*.tmp")), [])
        secret = "https://user:password@host/private?token=private"
        for text, phase, code in (("Connection timeout "+secret, "search", "network"),
                                  ("FFmpegError: Failed to convert "+secret, "download", "invalid_audio"),
                                  ("403 forbidden "+secret, "download", "unavailable"),
                                  ("Cannot fetch "+secret, "cover", "cover"),
                                  (secret, "metadata", "error")):
            failure = worker.failure_for(RuntimeError(text), phase)
            self.assertEqual(failure.code, code)
            self.assertNotIn("password", str(failure))
            self.assertNotIn("private", str(failure))

    def test_node_argument_round_trip_handles_windows_spaces(self):
        with tempfile.TemporaryDirectory(prefix="node runtime ") as name:
            executable = Path(name)/"node.exe"; executable.touch()
            with patch.dict(os.environ, {"SG_NODE_RUNTIME": str(executable)}), patch.object(worker.subprocess, "run") as run:
                run.return_value = SimpleNamespace(stdout="v22.16.0\n")
                arguments = shlex.split(worker.downloader_arguments())
                self.assertEqual(arguments[-2:], ["--js-runtimes", "node:"+str(executable.resolve())])
                from spotdl.utils.formatter import args_to_ytdlp_options
                options = args_to_ytdlp_options(arguments, {})
                self.assertEqual(options["js_runtimes"]["node"]["path"], str(executable.resolve()))
                self.assertFalse(options.get("remote_components"))
                run.return_value.stdout = "v20.0.0\n"
                self.assertNotIn("--js-runtimes", shlex.split(worker.downloader_arguments()))


class AudioIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.fixture = Path(cls.temp.name)/"fixture.mp3"
        cls.ffmpeg = os.environ.get("SG_TEST_FFMPEG") or shutil.which("ffmpeg")
        if not cls.ffmpeg: raise RuntimeError("Set SG_TEST_FFMPEG for the synthetic MP3 integration tests.")
        subprocess.run([cls.ffmpeg, "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                        "-c:a", "libmp3lame", str(cls.fixture)], check=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.folder = Path(self.tempdir.name)
        self.file = self.folder/"audio.mp3"
        shutil.copyfile(self.fixture, self.file)
        self.song = song(duration=3)
    def tearDown(self): self.tempdir.cleanup()
    def encoded_audio(self):
        data = self.file.read_bytes()
        offset = int(MP3(self.file).tags.size) if data.startswith(b"ID3") else 0
        return data[offset:]

    def test_missing_cover_repair_keeps_encoded_audio_and_metadata(self):
        before = self.encoded_audio()
        worker.finish_audio(self.file, self.song, SOURCE, lambda url: (image_bytes(), "image/jpeg"))
        self.assertEqual(before, self.encoded_audio())
        audio = MP3(self.file)
        self.assertEqual(str(audio.tags["TIT2"]), self.song.name)
        self.assertEqual(str(audio.tags["TPE1"]), "Moha La Squale")
        self.assertEqual(str(audio.tags.get("TALB", "")), "")
        self.assertEqual(worker.validate_cover(audio.tags.getall("APIC")[0].data), "image/jpeg")
        self.assertEqual(audio.tags.version, (2, 3, 0))
        loader = Mock(side_effect=AssertionError("Existing valid cover must not be downloaded"))
        worker.finish_audio(self.file, self.song, SOURCE, loader)
        loader.assert_not_called()
        self.assertEqual(before, self.encoded_audio())

    @unittest.skipUnless(os.name == "nt", "Windows-specific child process regression")
    def test_installed_spotdl_sync_and_async_ffmpeg_keep_real_exit_codes(self):
        from spotdl.utils import ffmpeg
        worker.configure_hidden_ffmpeg(ffmpeg)
        self.assertIsNotNone(ffmpeg.get_ffmpeg_version(self.ffmpeg)[0])
        sync_output = self.folder/"sync.mp3"
        success, error = ffmpeg.convert(self.fixture, sync_output, ffmpeg=self.ffmpeg, bitrate="128k")
        self.assertTrue(success, error)
        self.assertAlmostEqual(MP3(sync_output).info.length, 3, delta=.1)
        async_output = self.folder/"async.mp3"
        success, error = asyncio.run(ffmpeg.async_convert(self.fixture, async_output, ffmpeg=self.ffmpeg, bitrate="128k"))
        self.assertTrue(success, error)
        self.assertAlmostEqual(MP3(async_output).info.length, 3, delta=.1)
        success, error = asyncio.run(ffmpeg.async_convert(self.folder/"absent.webm", self.folder/"bad.mp3", ffmpeg=self.ffmpeg))
        self.assertFalse(success)
        self.assertNotEqual(error["return_code"], 0)
        self.assertIn("-nostdin", error["arguments"])
        interrupted = SimpleNamespace(returncode=0xC000013A,
            communicate=AsyncMock(return_value=(b"received signal 15", None)))
        with patch.object(ffmpeg.asyncio, "create_subprocess_exec", AsyncMock(return_value=interrupted)), patch.object(ffmpeg, "get_ffmpeg_version", return_value=(7.1, 2024)):
            success, error = asyncio.run(ffmpeg.async_convert(self.fixture, self.folder/"interrupted.mp3", ffmpeg=self.ffmpeg))
        self.assertFalse(success)
        self.assertEqual(error["return_code"], 0xC000013A)  # Never accept the real failure as success.

    def test_failed_cover_keeps_audio_and_identity_bound_retry(self):
        before = self.file.read_bytes()
        worker.remember_audio(self.folder, self.song, SOURCE)
        loader = Mock(side_effect=TimeoutError("offline"))
        with self.assertRaises(TimeoutError): worker.finish_audio(self.file, self.song, SOURCE, loader)
        self.assertEqual(self.file.read_bytes(), before)
        self.assertEqual(worker.reusable_audio(self.folder, self.song), SOURCE)
        self.assertIsNone(worker.reusable_audio(self.folder, song(duration=3, url=TRACK+"wrong")))
        self.file.write_bytes(before+b"changed")
        self.assertIsNone(worker.reusable_audio(self.folder, self.song))

    def test_prepare_bypasses_second_matcher_and_retry_never_redownloads(self):
        metadata = dict(title="Bandolero", artists=[{"name": "Moha La Squale"}], duration=3000,
                        id=TRACK.rsplit("/", 1)[1], isExplicit=True,
                        visualIdentity={"image": [{"maxWidth": 640, "url": COVER}]})
        provider = SimpleNamespace(get_results=Mock(return_value=[result(duration=3)]))
        settings, downloads = [], []
        def factory(options):
            settings.append(options)
            def download(request):
                self.assertEqual(request.download_url, SOURCE)
                downloads.append(request.url)
                shutil.copyfile(self.fixture, self.file)
                return request, self.file
            return SimpleNamespace(audio_providers=[provider], download_song=download,
                                   progress_handler=SimpleNamespace(close=lambda: None), errors=[])
        original_home = Path.__dict__["home"]
        args = SimpleNamespace(url=TRACK, ffmpeg=self.ffmpeg)
        try:
            with patch("download_metadata.entity", return_value=metadata), patch("spotdl.download.downloader.Downloader", side_effect=factory), patch.object(worker, "downloader_arguments", return_value=""), patch.object(worker, "fetch_cover", side_effect=TimeoutError("offline")):
                with self.assertRaises(TimeoutError): worker.prepare(args, self.folder, worker.Progress(self.folder))
            self.assertEqual(downloads, [TRACK])
            self.assertFalse((self.folder/"audio-ready.json").exists())
            self.assertTrue((self.folder/"prepared-audio.json").exists())
            self.assertEqual(settings[0]["bitrate"], "auto")
            self.assertTrue(settings[0]["skip_album_art"])
            with patch("download_metadata.entity", return_value=metadata), patch("spotdl.download.downloader.Downloader", side_effect=AssertionError("Must reuse audio")), patch.object(worker, "fetch_cover", return_value=(image_bytes(), "image/jpeg")):
                worker.prepare(args, self.folder, worker.Progress(self.folder))
            record = json.loads((self.folder/"audio-ready.json").read_text(encoding="utf-8"))
            self.assertEqual(record["source"], SOURCE)
            self.assertEqual(record["spotify"], TRACK)
            self.assertAlmostEqual(record["seconds"], 3, delta=.1)
            self.assertEqual(downloads, [TRACK])
        finally:
            Path.home = original_home


if __name__ == "__main__":
    unittest.main()
