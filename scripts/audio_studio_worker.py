"""Isolated CUDA instrumental worker; models must be installed and verified beforehand."""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import time

MODEL_SHA = '87201f4d31afb5bc79993230fc49446918425574db48c01c405e44f365c7559e'
CONFIG_SHA = '87aabb300193b019159269b69d6fe5f313aae4201a22b4af6268bc2846ab2fe1'
MODEL_NAME = 'vocals_mel_band_roformer.ckpt'


@contextmanager
def gpu_lock(models):
    """OS-backed single-job lock released even when the supervised worker is killed."""
    path = models / 'studio-gpu.lock'
    if path.is_symlink(): raise ValueError('Invalid lock path')
    with path.open('a+b') as stream:
        if stream.seek(0, os.SEEK_END) == 0: stream.write(b'0'); stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt': msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else: fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def verified_models(models):
    models = Path(models).absolute()
    if not models.is_dir() or models.is_symlink() or models.resolve(strict=True) != models:
        raise ValueError('Invalid model directory')
    for name, expected, size in ((MODEL_NAME, MODEL_SHA, 913106900),
                                ('vocals_mel_band_roformer.yaml', CONFIG_SHA, 733)):
        path = models / name
        if path.is_symlink() or path.resolve(strict=True).parent != models or path.stat().st_size != size:
            raise ValueError('Invalid local model')
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                raise ValueError('Local model verification failed')
    return models


def separate(models, source, output, ffmpeg):
    started = time.monotonic()
    models = verified_models(models)
    source, output, ffmpeg = Path(source).absolute(), Path(output).absolute(), Path(ffmpeg).absolute()
    if (source.is_symlink() or source.resolve(strict=True) != source or source.suffix != '.wav' or
            not 44 <= source.stat().st_size <= 750 * 1024 * 1024 or
            output.parent != source.parent or output.exists() or output.is_symlink() or output.name != 'instrumental.wav' or
            not ffmpeg.is_file()):
        raise ValueError('Invalid private audio paths')
    os.environ['PATH'] = str(ffmpeg.parent) + os.pathsep + os.environ.get('PATH', '')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['OMP_NUM_THREADS'] = '4'
    with gpu_lock(models):
        import numpy as np
        import soundfile as sf
        import torch
        from audio_separator.separator import Separator
        if importlib.metadata.version('audio-separator') != '0.47.0': raise ValueError('Unvalidated separator version')
        if torch.__version__ != '2.8.0+cu128' or not torch.cuda.is_available(): raise ValueError('Validated CUDA runtime required')
        torch.set_num_threads(4)
        # Local files only: no runtime model/catalog downloads or remote fallback.
        class LocalSeparator(Separator):
            def download_model_files(self, filename):
                if filename != MODEL_NAME: raise ValueError('Unapproved model')
                self.model_friendly_name, self.model_is_uvr_vip = 'MelBandRoformer (KimberleyJensen)', False
                return filename, 'MDXC', self.model_friendly_name, str(models / filename), 'vocals_mel_band_roformer.yaml'

            def download_file_if_not_exists(self, *args, **kwargs):
                raise RuntimeError('Model downloads are disabled during local rendering')

            def load_model_data_from_yaml(self, filename):
                config = super().load_model_data_from_yaml(filename)
                # The author's configuration expresses its 8 s window in samples;
                # audio-separator expresses the same window in STFT frames.
                if config['model']['stft_hop_length'] != 441 or config['inference']['chunk_size'] != 352800:
                    raise ValueError('Unexpected model timing')
                config['inference']['dim_t'] = 352800 // 441 + 1
                return config

        engine = LocalSeparator(model_file_dir=str(models), output_dir=str(output.parent), output_format='WAV',
            output_single_stem='other', sample_rate=44100, use_soundfile=True,
            use_autocast=False, use_native_fp16=False, use_torch_compile=False,
            normalization_threshold=.98, amplification_threshold=0.0, log_level=logging.WARNING,
            mdxc_params={'segment_size':801, 'override_model_segment_size':False, 'batch_size':1, 'overlap':2, 'pitch_shift':0})
        engine.load_model(MODEL_NAME)
        if engine.torch_device.type != 'cuda' or engine.model_instance.torch_device.type != 'cuda':
            raise ValueError('The instrumental must use CUDA')
        if engine.model_instance.primary_stem_name != 'vocals' or engine.model_instance.secondary_stem_name != 'other':
            raise ValueError('Unexpected model stem mapping')
        products = engine.separate(str(source), custom_output_names={'other':'instrumental'})
        if len(products) != 1 or not output.is_file(): raise ValueError('Instrumental output missing')
        product = Path(products[0]); product = product if product.is_absolute() else output.parent / product
        if product.resolve(strict=True) != output: raise ValueError('Unexpected instrumental output')
        info = sf.info(output)
        if info.samplerate != 44100 or info.channels != 2: raise ValueError('Invalid output format')
        for block in sf.blocks(output, blocksize=65536, dtype='float32', always_2d=True):
            if not np.isfinite(block).all(): raise ValueError('Non-finite instrumental samples')
        return {'ready':True, 'cudaValidated':True, 'gpu':torch.cuda.get_device_name(0),
                'seconds':round(time.monotonic()-started, 3), 'audioSeconds':info.duration,
                'peakGpuMiB':round(torch.cuda.max_memory_allocated() / 1024**2, 1),
                'modelSHA256':MODEL_SHA, 'configSHA256':CONFIG_SHA,
                'separatorVersion':importlib.metadata.version('audio-separator'), 'torchVersion':torch.__version__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('models', 'source', 'output', 'ffmpeg'): parser.add_argument('--' + option, required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(separate(args.models, args.source, args.output, args.ffmpeg), ensure_ascii=False))


if __name__ == '__main__': main()
