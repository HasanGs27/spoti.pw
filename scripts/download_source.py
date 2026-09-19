"""One bounded public audio fetch. Invoked only by download_worker.py."""
import argparse
import math
import time
from pathlib import Path


class QuietLogger:
    # Upstream messages can contain signed media URLs. Only sanitized failure.json
    # crosses the process boundary; do not print upstream URLs or credentials.
    def debug(self, message): pass
    def warning(self, message): pass
    def error(self, message): pass


def fetch(url, folder, seconds):
    from download_worker import atomic_json, downloader_arguments, source_url
    from spotdl.utils.formatter import args_to_ytdlp_options
    from yt_dlp import YoutubeDL
    import shlex
    if source_url(url) != url:
        raise ValueError("Unsupported source identity")
    deadline = time.monotonic() + seconds

    def progress(event):
        if time.monotonic() >= deadline:
            raise TimeoutError("Audio deadline exceeded")

    options = args_to_ytdlp_options(shlex.split(downloader_arguments()), {})
    options.update(format="bestaudio/best", outtmpl=str(folder / "source.%(ext)s"),
                   quiet=True, no_warnings=True, logger=QuietLogger(), noplaylist=True,
                   cookiefile=None, cookiesfrombrowser=None, usenetrc=False,
                   cachedir=False, progress_hooks=[progress],
                   fragment_retries=1, extractor_retries=1, concurrent_fragment_downloads=1)
    with YoutubeDL(options) as client:
        info = client.extract_info(url, download=True)
        if not isinstance(info, dict) or info.get("id") != url.rsplit("=", 1)[1]:
            raise ValueError("Unexpected source identity")
        file = Path(client.prepare_filename(info))
    if (file.is_symlink() or file.resolve(strict=True).parent != folder or
            not 1024 <= file.stat().st_size <= 100 * 1024 * 1024):
        raise ValueError("Invalid downloaded file")
    record = {"file":file.name, "source":url, "extension":str(info.get("ext", "")),
              "sourceCodec":str(info.get("acodec", ""))[:80]}
    for key, out in (("abr", "sourceBitrate"), ("duration", "seconds")):
        value = info.get(key)
        if isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value) and value > 0:
            record[out] = value
    atomic_json(folder / "source-info.json", record)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("folder", type=Path)
    parser.add_argument("--seconds", type=float, required=True)
    args = parser.parse_args()
    folder = args.folder.resolve(strict=True)
    profile = folder / "profile"
    profile.mkdir(exist_ok=True)
    Path.home = classmethod(lambda cls: profile)
    from download_worker import atomic_json, source_failure
    try:
        fetch(args.url, folder, max(1, min(args.seconds, 65)))
    except Exception as error:
        failure = source_failure(error)
        atomic_json(folder / "failure.json", {"code":failure.code, "message":str(failure),
                    "transient":failure.transient, "stop":failure.stop})
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
