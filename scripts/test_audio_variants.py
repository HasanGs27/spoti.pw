"""Independent synthetic speed variants, no user tracks or network sources."""
import array
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
from mutagen.mp3 import MP3
from mutagen.id3 import TIT2, TPE1, TALB, APIC

import audio_variants as variants


class SpeedVariantsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = Path(os.environ.get('SG_TEST_FFMPEG') or shutil.which('ffmpeg') or '')
        if not cls.ffmpeg.is_file(): raise RuntimeError('SG_TEST_FFMPEG is required for real synthetic speed tests.')
        cls.fixture_dir = tempfile.TemporaryDirectory(prefix='speed-fixtures-')
        cls.fixture = Path(cls.fixture_dir.name) / 'tone.mp3'
        cls.ffmpeg_run(['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=5',
                        '-ac', '2', '-c:a', 'libmp3lame', '-q:a', '0', str(cls.fixture)])
        image = io.BytesIO(); Image.new('RGB', (32, 32), 'orange').save(image, format='JPEG')
        cls.cover = image.getvalue()
        audio = MP3(cls.fixture)
        audio.tags.add(TIT2(encoding=1, text=['Synthetic tone']))
        audio.tags.add(TPE1(encoding=1, text=['Test artist']))
        audio.tags.add(TALB(encoding=1, text=['Test album']))
        audio.tags.add(APIC(encoding=1, mime='image/jpeg', type=3, data=cls.cover))
        audio.save(v2_version=3)

    @classmethod
    def tearDownClass(cls):
        cls.fixture_dir.cleanup()

    @classmethod
    def ffmpeg_run(cls, arguments, capture=False):
        return subprocess.run([str(cls.ffmpeg), '-hide_banner', '-nostdin', *arguments],
            check=True, timeout=15, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).stdout

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='speed-variant-test-')
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source.mp3'
        shutil.copyfile(self.fixture, self.source)
        self.original = self.source.read_bytes()
        self.original_stat = self.source.stat()

    def tearDown(self):
        self.assertEqual(self.original, self.source.read_bytes())
        self.assertEqual(self.original_stat.st_mtime_ns, self.source.stat().st_mtime_ns)
        self.temporary.cleanup()

    def make(self, speed=1.25, **kwargs):
        return variants.create_speed_variant(self.root, self.source, speed, self.ffmpeg, **kwargs)

    def frequency(self, path):
        raw = self.ffmpeg_run(['-v', 'error', '-i', str(path), '-ss', '0.2', '-t', '1',
                               '-ac', '1', '-ar', '44100', '-f', 's16le', '-'], capture=True)
        samples = array.array('h', raw)
        crosses = sum(left < 0 <= right for left, right in zip(samples, samples[1:]))
        return crosses / (len(samples) / 44100)

    def test_all_supported_speeds_real_aac_duration_pitch_cover_and_manifest(self):
        source_duration = MP3(self.source).info.length
        folders = []
        for speed in variants.SPEEDS:
            with self.subTest(speed=speed):
                result = self.make(speed)
                folder = Path(result.pop('directory')); folders.append(folder)
                target = folder / result['audio']['file']
                self.assertEqual(json.loads((folder / 'variant.json').read_text(encoding='utf-8')), result)
                self.assertEqual({p.name for p in folder.iterdir()}, {'audio.m4a', 'variant.json'})
                self.assertEqual(result['kind'], 'speed')
                self.assertEqual(result['speed'], speed)
                self.assertEqual(result['source']['sha256'], hashlib.sha256(self.original).hexdigest())
                self.assertTrue(result['processing']['pitchPreserved'])
                self.assertTrue(result['validation']['finiteSamples'])
                self.assertAlmostEqual(result['audio']['seconds'], source_duration / speed, delta=.12)
                self.assertAlmostEqual(self.frequency(target), 440, delta=3)
                metadata = variants.read_audio(target)
                self.assertEqual((metadata['codec'], metadata['channels'], metadata['sampleRate']), ('AAC-LC', 2, 44100))
                self.assertEqual((metadata['title'], metadata['artist'], metadata['cover']),
                                 ('Synthetic tone · ×' + format(speed, 'g').replace('.', ','), 'Test artist', self.cover))
                self.assertEqual(metadata['album'], 'Test album · ' + result['label'])
                self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), result['audio']['sha256'])
        self.assertEqual(len(set(folders)), 5)

    def test_mp3_output_and_m4a_input(self):
        first = self.make(1.25)
        m4a = Path(first['directory']) / first['audio']['file']
        old = m4a.read_bytes()
        second = variants.create_speed_variant(self.root, m4a, .75, self.ffmpeg, output_format='mp3')
        target = Path(second['directory']) / second['audio']['file']
        self.assertEqual(variants.read_audio(target)['codec'], 'MP3')
        self.assertEqual(variants.read_audio(target)['cover'], self.cover)
        self.assertAlmostEqual(self.frequency(target), 440, delta=3)
        self.assertEqual(m4a.read_bytes(), old)
        self.assertEqual(second['source']['sha256'], hashlib.sha256(old).hexdigest())

    def test_instrumental_wrapper_preserves_source_tags_and_validates_rendered_copy(self):
        def render(studio, source, output, ffmpeg, log, remaining):
            self.assertEqual(source.name, 'input.wav')
            self.ffmpeg_run(['-v', 'error', '-i', str(source), '-af', 'volume=0.5', str(output)])
        with patch.object(variants, 'studio_configuration', return_value=(Path('python'), Path('models'))), \
                patch.object(variants, 'run_instrumental', side_effect=render):
            result = variants.create_instrumental_variant(self.root, self.source, self.ffmpeg)
        path = Path(result['directory']) / result['audio']['file']
        self.assertEqual(result['kind'], 'instrumental')
        self.assertNotIn('speed', result)
        self.assertEqual(result['audio']['title'], 'Synthetic tone · Instrumental')
        self.assertEqual(result['audio']['album'], 'Test album · Instrumental')
        self.assertEqual(variants.read_audio(path)['cover'], self.cover)
        self.assertEqual({p.name for p in path.parent.iterdir()}, {'audio.m4a', 'variant.json'})
        self.assertAlmostEqual(result['audio']['seconds'], MP3(self.source).info.length, delta=.12)
        self.assertEqual(result['processing']['modelSHA256'], variants.MODEL_SHA)

    def test_instrumental_not_ready_creates_nothing(self):
        with patch.dict(os.environ, {'SG_AUDIO_STUDIO_CONFIG':str(self.root / 'missing-config.json')}):
            self.assertFalse(variants.instrumental_available())
            with self.assertRaises(OSError):
                variants.create_instrumental_variant(self.root, self.source, self.ffmpeg)
        self.assertFalse((self.root / '.audio-variants').exists())
        malformed = self.root / 'bad-config.json'; malformed.write_text('[]')
        with patch.dict(os.environ, {'SG_AUDIO_STUDIO_CONFIG':str(malformed)}):
            self.assertFalse(variants.instrumental_available())

    def test_instrumental_timeout_removes_private_staged_files(self):
        with patch.object(variants, 'studio_configuration', return_value=(Path('python'), Path('models'))), \
                patch.object(variants, 'run_instrumental', side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):
                variants.create_instrumental_variant(self.root, self.source, self.ffmpeg)
        self.assertEqual(list((self.root / '.audio-variants').iterdir()), [])

    def test_gpu_worker_lock_and_unapproved_model_rejected(self):
        from audio_studio_worker import gpu_lock, verified_models
        models = self.root / 'models'; models.mkdir()
        with gpu_lock(models):
            with self.assertRaises(OSError):
                with gpu_lock(models): self.fail('Second GPU worker admitted')
        with gpu_lock(models): pass
        (models / 'vocals_mel_band_roformer.ckpt').write_bytes(b'wrong model')
        with self.assertRaises(ValueError): verified_models(models)

    def test_model_install_hash_mismatch_and_existing_files_are_preserved(self):
        from setup_audio_studio import fetch_reviewed
        models = self.root / 'models'; models.mkdir()
        expected = hashlib.sha256(b'expected').hexdigest()
        with patch('setup_audio_studio.urllib.request.urlopen', return_value=io.BytesIO(b'changed!')):
            with self.assertRaises(ValueError):
                fetch_reviewed(models, 'model', 'https://example.invalid', 8, expected)
        self.assertEqual(list(models.iterdir()), [])
        target = models / 'model'; target.write_bytes(b'keep existing')
        with self.assertRaises(ValueError): fetch_reviewed(models, 'model', 'https://example.invalid', 8, expected)
        self.assertEqual(target.read_bytes(), b'keep existing')
        target.unlink()
        partial = models / 'model.partial'; partial.write_bytes(b'keep interrupted')
        with patch('setup_audio_studio.urllib.request.urlopen', return_value=io.BytesIO(b'expected')):
            with self.assertRaises(FileExistsError): fetch_reviewed(models, 'model', 'https://example.invalid', 8, expected)
        self.assertEqual(partial.read_bytes(), b'keep interrupted')

    def test_invalid_inputs_do_not_create_outputs(self):
        for speed in (True, False, float('nan'), float('inf'), 0, -1, .5, 3, '1.25'):
            with self.subTest(speed=speed), self.assertRaises(ValueError): self.make(speed)
        with self.assertRaises(ValueError): self.make(output_format='wav')
        outside = Path(self.fixture_dir.name) / self.fixture.name
        with self.assertRaises(ValueError): variants.create_speed_variant(self.root, outside, 1.25, self.ffmpeg)
        with self.assertRaises(ValueError):
            variants.create_speed_variant(self.root, self.root / 'nested/../source.mp3', 1.25, self.ffmpeg)
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_timeout_or_encoder_failure_removes_only_its_own_artifacts(self):
        store = self.root / '.audio-variants'; store.mkdir()
        neighbor = store / 'keep.txt'; neighbor.write_text('keep', encoding='utf-8')
        for error in (subprocess.TimeoutExpired('ffmpeg', 1), subprocess.CalledProcessError(1, 'ffmpeg')):
            with patch.object(variants, 'run_ffmpeg', side_effect=error), self.assertRaises(type(error)):
                self.make()
            self.assertEqual(list(store.iterdir()), [neighbor])
            self.assertEqual(neighbor.read_text(encoding='utf-8'), 'keep')

    def test_repeat_never_overwrites_existing_variant(self):
        first = self.make(1.5)
        old = {p.name: p.read_bytes() for p in Path(first['directory']).iterdir()}
        second = self.make(1.5)
        self.assertNotEqual(first['directory'], second['directory'])
        self.assertEqual(old, {p.name: p.read_bytes() for p in Path(first['directory']).iterdir()})

    def test_source_and_private_output_symlinks_are_refused(self):
        with tempfile.TemporaryDirectory(prefix='speed-outside-') as temp:
            outside = Path(temp).resolve(); external = outside / 'external.mp3'
            external.write_bytes(self.original)
            link = self.root / 'linked.mp3'
            try: link.symlink_to(external)
            except OSError: self.skipTest('Symlink permission unavailable')
            with self.assertRaises(ValueError): variants.create_speed_variant(self.root, link, 1.25, self.ffmpeg)
            link.unlink()
            (self.root / '.audio-variants').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError): self.make()
            self.assertEqual(external.read_bytes(), self.original)
            self.assertEqual(list(outside.iterdir()), [external])

    def test_decoder_validation_rejects_nonfinite_samples(self):
        path = self.root / 'fake-audio.m4a'; path.write_bytes(b'not actually decoded')
        log = self.root / 'fake-validation.log'
        for nan, inf in ((1, 0), (0, 1)):
            def fake_run(*args):
                log.write_text('[Parsed_astats_0 @ 0x1] Number of NaNs: ' + str(nan) + '\n'
                               '[Parsed_astats_0 @ 0x1] Number of Infs: ' + str(inf) + '\n'
                               '[Parsed_astats_0 @ 0x1] Number of samples: 44100\n'
                               '[Parsed_astats_0 @ 0x1] Peak level dB: 0\n', encoding='utf-8')
            with patch.object(variants, 'run_ffmpeg', side_effect=fake_run), self.assertRaises(ValueError):
                variants.validate_decode(self.ffmpeg, path, log, 10)


if __name__ == '__main__':
    unittest.main()
