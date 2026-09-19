"""Isolated audio worker. Public YT Music song results, never Spotify audio."""
import argparse
import base64
import hashlib
import io
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import secrets
import sys
import time
import unicodedata
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urljoin, urlsplit


def tokens(value):
    # Keep non-Latin letters. ASCII transliteration erased entire song identities.
    value = unicodedata.normalize("NFKD", str(value or "")).casefold()
    value = "".join(c for c in value if not unicodedata.combining(c))
    return tuple(re.findall(r"[^\W_]+", value, re.UNICODE))


def words(value):
    return set(tokens(value))


# Explicit, established artist alias only; never remove "DJ" from arbitrary names.
# The SPINALL artist page also credits DJ Spinall Essentials / DJ Spinall on Grace:
# https://music.apple.com/us/artist/spinall/813737832
ARTIST_ALIASES = {("dj", "spinall"): ("spinall",)}


def artist_identity(value):
    name = tokens(value)
    return ARTIST_ALIASES.get(name, name)


def _credits(value, artists):
    """Consume whole, known artist names, not loose subsets of their words."""
    pending = tokens(value)
    canonical = {artist_identity(a) for a in artists if tokens(a)}
    names = {tokens(a): artist_identity(a) for a in artists if tokens(a)}
    for alias, identity in ARTIST_ALIASES.items():
        if identity in canonical:
            names[alias] = identity
            names[identity] = identity
    ordered_names = sorted(names, key=len, reverse=True)
    found = set()
    while pending:
        if pending[0] in ("and", "with", "et", "x"):
            pending = pending[1:]
            continue
        name = next((a for a in ordered_names if pending[:len(a)] == a), None)
        if name is None:
            return None
        found.add(names[name])
        pending = pending[len(name):]
    return found or None


def title_identity(value, artists):
    """Remove only trailing featured credits already present in Spotify metadata."""
    value = str(value or "").strip()
    credits = set()
    # Handles '200 MPH FT Diplo (feat. Diplo)' without stripping version labels.
    for _ in range(4):
        match = re.search(r"(?:\(|\[)\s*(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)(?:\)|\])\s*$", value, re.I)
        if match is None:
            match = re.search(r"\s+(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)$", value, re.I)
        if match is None:
            break
        known = _credits(match.group(1), artists)
        if not known:
            break
        credits.update(known)
        value = value[:match.start()].rstrip(" -–—")
    return tokens(value), credits, value


def _duration_ok(actual, expected):
    return (isinstance(actual, (int, float)) and not isinstance(actual, bool)
            and isinstance(expected, (int, float)) and not isinstance(expected, bool)
            and math.isfinite(actual) and math.isfinite(expected)
            and 1 <= actual <= 1800 and 1 <= expected <= 1800
            and abs(actual - expected) <= max(2, expected * .012))


def acceptable(result, song):
    artists = getattr(song, "artists", None) or []
    actual_artists = getattr(result, "artists", None) or []
    expected_names = {artist_identity(a) for a in artists}
    actual_names = {artist_identity(a) for a in actual_artists}
    if not artists or () in expected_names or not actual_names or () in actual_names:
        return False
    if getattr(result, "verified", False) is not True or not _duration_ok(getattr(result, "duration", None), getattr(song, "duration", None)):
        return False
    title, _, _ = title_identity(getattr(song, "name", ""), artists)
    actual, credited, _ = title_identity(getattr(result, "name", ""), artists)
    # Exact sequence rejects longer songs, word-order changes and extra version labels.
    if not title or title != actual:
        return False
    if artist_identity(artists[0]) not in actual_names or not actual_names <= expected_names:
        return False
    if not expected_names <= (actual_names | credited):
        return False
    expected_explicit = getattr(song, "explicit", None)
    actual_explicit = getattr(result, "explicit", None)
    if isinstance(expected_explicit, bool) and actual_explicit is not expected_explicit:
        return False
    return True


class WorkerFailure(Exception):
    def __init__(self, code, message, detail=None):
        self.code, self.detail = code, detail
        super().__init__(message)


class Budget:
    def __init__(self, seconds=210):
        self.end = time.monotonic() + seconds

    def remaining(self, reserve=0):
        remaining = self.end - time.monotonic() - reserve
        if remaining <= 0:
            failure = WorkerFailure("network", "Le délai de préparation est dépassé. Réessaye ce titre plus tard.")
            failure.transient, failure.stop = True, True
            raise failure
        return remaining


def source_failure(error):
    if isinstance(error, WorkerFailure):
        if not hasattr(error, "transient"): error.transient = error.code == "network"
        if not hasattr(error, "stop"): error.stop = False
        return error
    parts, seen = [], set()
    while error is not None and id(error) not in seen and len(parts) < 8:
        seen.add(id(error)); parts.append(type(error).__name__ + " " + str(error))
        error = error.__cause__ or error.__context__
    detail = " ".join(parts).casefold()
    if any(x in detail for x in ("429", "too many requests", "rate limit")):
        failure = WorkerFailure("unavailable", "La source limite les demandes. Réessaye ce titre plus tard.")
        failure.transient, failure.stop = True, True
    elif any(x in detail for x in ("timeout", "timed out", "connection", "network", "dns", "resolve", "502", "503", "504")):
        failure = WorkerFailure("network", "La connexion à la source a été interrompue. Réessaye ce titre.")
        failure.transient, failure.stop = True, False
    elif any(x in detail for x in ("403", "404", "forbidden", "private", "removed", "unavailable", "not available", "sign in", "login")):
        failure = WorkerFailure("unavailable", "Cette source est indisponible. Aucune autre version conforme n’a pu être préparée.")
        failure.transient, failure.stop = False, False
    else:
        failure = WorkerFailure("invalid_audio", "Cette source n’a pas fourni un fichier audio valide.")
        failure.transient, failure.stop = False, False
    return failure


def atomic_json(path, data):
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


class Progress:
    MESSAGES = {"metadata": "Lecture du titre…", "search": "Recherche de la bonne version…",
                "download": "Téléchargement audio…", "cover": "Ajout de la pochette…",
                "verify": "Vérification du fichier…"}

    def __init__(self, folder):
        self.folder, self.phase = folder, None

    def set(self, phase):
        if phase != self.phase:
            atomic_json(self.folder / "progress.json", {"phase": phase, "message": self.MESSAGES[phase]})
            self.phase = phase


def failure_for(error, phase=None):
    if isinstance(error, WorkerFailure):
        return error
    # Classify upstream errors without exposing signed URLs or raw traces.
    detail = (type(error).__name__ + " " + str(error)).casefold()
    if "ffmpegerror" in detail or "failed to convert" in detail:
        return WorkerFailure("invalid_audio", "La conversion audio a échoué sur le PC. Réessaye la préparation.")
    if phase == "cover":
        return WorkerFailure("cover", "Pochette indisponible. L’audio est conservé ; réessaye pour ajouter l’image.")
    if any(s in detail for s in ("timeout", "timed out", "connection", "network", "resolve", "dns", "réseau", "connexion")):
        return WorkerFailure("network", "Connexion interrompue. Vérifie Internet sur le PC puis réessaye.")
    if any(s in detail for s in ("403", "429", "forbidden", "sign in", "login", "unavailable", "not available", "removed", "private video", "indisponible")):
        return WorkerFailure("unavailable", "La source est indisponible ou refuse l’accès. Réessaye plus tard ou ajoute un fichier audio.")
    return WorkerFailure("error", "La préparation a échoué. Réessaye ou ajoute un fichier audio pour ce titre.")


def source_url(value):
    try:
        parsed = urlsplit(value)
        ident = parse_qs(parsed.query).get("v", [""])[0]
        if (parsed.scheme == "https" and parsed.hostname in ("music.youtube.com", "www.youtube.com", "youtube.com")
                and not parsed.username and not parsed.password and parsed.port in (None, 443)
                and parsed.path == "/watch" and re.fullmatch(r"[A-Za-z0-9_-]{11}", ident)):
            return "https://music.youtube.com/watch?v=" + ident
    except (ValueError, TypeError):
        pass
    return None


def avoided_sources():
    raw = os.environ.get("SG_AVOID_SOURCES")
    if raw is None: return frozenset()
    try:
        if len(raw) > 8192: raise ValueError("Oversized exclusions")
        values = json.loads(raw)
        if not isinstance(values, list) or len(values) > 8: raise ValueError("Invalid exclusions")
        normalized = []
        for value in values:
            if not isinstance(value, str) or len(value) > 1000: raise ValueError("Invalid source")
            url = source_url(value)
            if not url: raise ValueError("Invalid source")
            normalized.append(url)
        return frozenset(normalized)
    except (ValueError, TypeError):
        raise WorkerFailure("error", "La demande d’autre version est invalide. Relance-la depuis l’application.",
                            "invalid_avoid_sources") from None


def choose_sources(provider, song, candidates, budget=None, excluded=None):
    excluded = avoided_sources() if excluded is None else excluded
    # Installed SpotDL's provider controls: no videos and no three-attempt repetition.
    provider.SEARCH_ATTEMPTS = 1
    _, _, title = title_identity(song.name, song.artists)
    queries = list(dict.fromkeys((f"{title} {' '.join(song.artists)}", f"{title} {song.artists[0]}")))
    seen, yielded = set(), False
    for query in queries:
        if budget: budget.remaining(10)
        rows = provider.get_results(query, filter="songs", ignore_spelling=True, limit=20)
        matches = []
        for row in rows:
            url = source_url(row.url)
            avoided = url in excluded
            accepted = acceptable(row, song) and url is not None and not avoided
            duration = row.duration if isinstance(row.duration, (int, float)) and math.isfinite(row.duration) else None
            candidate = {"title": row.name, "artists": row.artists, "duration": duration,
                         "url": url, "accepted": accepted}
            if avoided: candidate["excluded"] = True
            candidates.append(candidate)
            if accepted:
                matches.append(row)
        for match in sorted(matches, key=lambda row: abs(row.duration - song.duration)):
            url = source_url(match.url)
            if url in seen: continue
            seen.add(url); yielded = True
            yield url
            if len(seen) >= 3: return
    if not yielded:
        if excluded:
            raise WorkerFailure("no_match", "Aucune autre version avec le bon titre, les bons artistes et la bonne durée n’a été trouvée.",
                                "no_alternative")
        raise WorkerFailure("no_match", "Aucune version avec le bon titre, les bons artistes et la bonne durée. Ajoute un fichier audio pour ce titre.")


def choose_source(provider, song, candidates):
    # Compatibility for callers that only need the best first strict result.
    return next(choose_sources(provider, song, candidates))


def downloader_arguments():
    args = ["--ignore-config", "--socket-timeout", "20", "--retries", "1", "--max-filesize", "100M"]
    runtime = os.environ.get("SG_NODE_RUNTIME") or shutil.which("node")
    if runtime and Path(runtime).is_file():
        try:
            result = subprocess.run([runtime, "--version"], capture_output=True, text=True,
                                    timeout=5, check=True,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            version = re.fullmatch(r"v?(\d+)\.\d+\.\d+\s*", result.stdout)
            if version and int(version.group(1)) >= 22:
                args.extend(["--js-runtimes", "node:" + str(Path(runtime).resolve())])
        except (OSError, subprocess.SubprocessError):
            pass
    return shlex.join(args)


def configure_hidden_ffmpeg(ffmpeg_module=None):
    """Keep SpotDL's FFmpeg children windowless, including its async Windows path.

    SpotDL 4.5.2 launches version checks/convert with subprocess.Popen and
    async_convert with asyncio.create_subprocess_exec. Only those module-local
    references change; process execution elsewhere and exit-code checks stay intact.
    Its argument builder already includes -nostdin for every conversion.
    """
    if os.name != "nt":
        return False
    if ffmpeg_module is None:
        from spotdl.utils import ffmpeg as ffmpeg_module
    if getattr(ffmpeg_module, "_sg_windowless", False):
        return True
    original_subprocess = ffmpeg_module.subprocess
    original_asyncio = ffmpeg_module.asyncio
    flag = subprocess.CREATE_NO_WINDOW

    def hidden_popen(*args, **kwargs):
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | flag
        return original_subprocess.Popen(*args, **kwargs)

    async def hidden_exec(*args, **kwargs):
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | flag
        return await original_asyncio.create_subprocess_exec(*args, **kwargs)

    ffmpeg_module.subprocess = SimpleNamespace(**(vars(original_subprocess) | {"Popen": hidden_popen}))
    ffmpeg_module.asyncio = SimpleNamespace(**(vars(original_asyncio) | {"create_subprocess_exec": hidden_exec}))
    ffmpeg_module._sg_windowless = True
    return True


def windows_child_job():
    """The worker owns this handle: even forced worker exit kills descendants."""
    import ctypes
    from ctypes import wintypes
    class BasicLimits(ctypes.Structure):
        _fields_ = [("processTime", ctypes.c_int64), ("jobTime", ctypes.c_int64),
            ("flags", wintypes.DWORD), ("minWorking", ctypes.c_size_t), ("maxWorking", ctypes.c_size_t),
            ("active", wintypes.DWORD), ("affinity", ctypes.c_size_t),
            ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]
    class ExtendedLimits(ctypes.Structure):
        _fields_ = [("basic", BasicLimits), ("io", ctypes.c_uint64 * 6),
            ("processMemory", ctypes.c_size_t), ("jobMemory", ctypes.c_size_t),
            ("peakProcessMemory", ctypes.c_size_t), ("peakJobMemory", ctypes.c_size_t)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.SetInformationJobObject.restype = wintypes.BOOL
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    job = kernel.CreateJobObjectW(None, None)
    if not job: raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits(); limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
        code = ctypes.get_last_error(); kernel.CloseHandle(job); raise ctypes.WinError(code)
    return kernel, job


def run_bounded(arguments, timeout):
    """Quiet, windowless child with real timeout; no orphaned Windows descendants."""
    job = windows_child_job() if os.name == "nt" else None
    process = None
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if job and not job[0].AssignProcessToJobObject(job[1], int(process._handle)):
            import ctypes
            raise ctypes.WinError(ctypes.get_last_error())
        process.wait(timeout=max(.1, timeout))
        return process.returncode
    finally:
        if job: job[0].CloseHandle(job[1])
        if process is not None:
            if process.poll() is None: process.kill()
            process.wait()


MAX_COVER_BYTES = 8 * 1024 * 1024


def validate_cover_url(value):
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        if (parsed.scheme == "https" and not parsed.username and not parsed.password and not parsed.fragment
                and parsed.port in (None, 443) and (host.endswith(".scdn.co") or host.endswith(".spotifycdn.com"))):
            return value
    except (TypeError, ValueError):
        pass
    raise WorkerFailure("cover", "Le lien de pochette n’est pas un lien HTTPS Spotify valide. L’audio est conservé.")


def validate_cover(data):
    from PIL import Image
    if not data or len(data) > MAX_COVER_BYTES:
        raise ValueError("Invalid cover size")
    with Image.open(io.BytesIO(data)) as image:
        if image.format not in ("JPEG", "PNG") or not 1 <= image.width <= 4096 or not 1 <= image.height <= 4096:
            raise ValueError("Invalid cover format/dimensions")
        mime = Image.MIME[image.format]
        image.verify()
    return mime


def cover_cache_file(url):
    validate_cover_url(url)
    configured = os.environ.get("SG_ARTWORK_CACHE_DIR")
    if not configured and os.environ.get("SG_METADATA_CACHE_DIR"):
        configured = str(Path(os.environ["SG_METADATA_CACHE_DIR"]) / "artwork")
    if not configured: return None
    folder = Path(configured).absolute()
    try:
        if folder.is_symlink() or folder.resolve() != folder: return None
        folder.mkdir(parents=True, exist_ok=True)
        return folder / (hashlib.sha256(url.encode("utf-8")).hexdigest() + ".json")
    except OSError:
        return None


def cached_cover(path, url):
    if path is None: return None
    try:
        if path.is_symlink() or not 1 <= path.stat().st_size <= MAX_COVER_BYTES * 1.4: return None
        record = json.loads(path.read_text(encoding="utf-8"))
        if record["url"] != url or not 0 <= time.time() - record["savedAt"] < 7 * 86400: return None
        data = base64.b64decode(record["data"], validate=True)
        if hashlib.sha256(data).hexdigest() != record["sha256"]: return None
        return data, validate_cover(data)
    except (OSError, ValueError, TypeError, KeyError):
        return None


def save_cached_cover(path, url, data):
    if path is None: return
    temporary = path.with_suffix("." + secrets.token_hex(8) + ".tmp")
    try:
        validate_cover(data)
        record = {"url":url, "savedAt":time.time(), "sha256":hashlib.sha256(data).hexdigest(),
                  "data":base64.b64encode(data).decode("ascii")}
        with temporary.open("x", encoding="utf-8") as output:
            json.dump(record, output, ensure_ascii=False, allow_nan=False)
        temporary.replace(path)
        entries = [(item.stat().st_mtime, item.stat().st_size, item) for item in path.parent.glob("*.json")
                   if re.fullmatch(r"[a-f0-9]{64}\.json", item.name) and not item.is_symlink()]
        total, count = sum(size for _, size, _ in entries), len(entries)
        for _, size, item in sorted(entries):
            if count <= 256 and total <= 64 * 1024 * 1024: break
            if item != path:
                item.unlink(missing_ok=True); total -= size; count -= 1
    except (OSError, ValueError):
        pass  # An unwritable/cache-full disk cannot invalidate an already fetched image.
    finally:
        try: temporary.unlink(missing_ok=True)
        except OSError: pass


def fetch_cover(url, session=None, budget=None):
    path = cover_cache_file(url)
    cached = cached_cover(path, url)
    if cached: return cached
    result = fetch_cover_network(url, session, budget)
    save_cached_cover(path, url, result[0])
    return result


def fetch_cover_network(url, session=None, budget=None):
    import requests
    own_session = session is None
    if own_session:
        session = requests.Session()
        session.trust_env = False  # No implicit netrc credentials/proxy or browser cookies.
    try:
        for _ in range(4):
            validate_cover_url(url)
            remaining = budget.remaining() if budget else 15
            with session.get(url, stream=True, timeout=(min(5, remaining), min(15, remaining)), allow_redirects=False) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    url = urljoin(url, response.headers.get("Location", ""))
                    continue
                response.raise_for_status()
                declared = response.headers.get("Content-Length")
                if declared and int(declared) > MAX_COVER_BYTES:
                    raise ValueError("Cover too large")
                parts, size = [], 0
                for part in response.iter_content(65536):
                    if budget: budget.remaining()
                    size += len(part)
                    if size > MAX_COVER_BYTES:
                        raise ValueError("Cover too large")
                    parts.append(part)
                data = b"".join(parts)
                return data, validate_cover(data)
        raise ValueError("Too many cover redirects")
    finally:
        if own_session:
            session.close()


def m4a_audio_only(file):
    from mutagen.mp4 import Atoms
    with file.open("rb") as handle:
        atoms = Atoms(handle)
        handlers = []
        for track in atoms[b"moov"].findall(b"trak"):
            valid, data = track[b"mdia", b"hdlr"].read(handle)
            if not valid or len(data) < 12: return False
            handlers.append(data[8:12])
        return handlers == [b"soun"]


def verify_audio(file, duration):
    from mutagen.mp3 import MP3
    from mutagen.mp4 import MP4
    try:
        if file.is_symlink() or not 1024 <= file.stat().st_size <= 100 * 1024 * 1024:
            raise ValueError("Invalid audio size")
        if file.suffix.lower() == ".m4a":
            audio = MP4(file)
            if (audio.info.codec != "mp4a.40.2" or audio.info.channels not in (1, 2) or
                    not 8000 <= audio.info.sample_rate <= 48000 or not m4a_audio_only(file)):
                raise ValueError("Unsupported AAC format")
        elif file.suffix.lower() == ".mp3":
            audio = MP3(file)
        else:
            raise ValueError("Unsupported audio extension")
        if not _duration_ok(audio.info.length, duration):
            raise ValueError("Invalid audio duration")
        return audio
    except Exception as error:
        raise WorkerFailure("invalid_audio", "Le fichier audio est incomplet ou sa durée ne correspond pas au titre.") from error


def file_digest(file):
    with file.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def remember_audio(folder, song, source, extension="mp3", source_info=None):
    if extension not in ("mp3", "m4a"): raise ValueError("Unsupported audio extension")
    record = {"version":2, "spotify":song.url, "source":source, "extension":extension,
              "sha256":file_digest(folder / ("audio." + extension))}
    for key in ("sourceCodec", "sourceBitrate"):
        if source_info and source_info.get(key) is not None: record[key] = source_info[key]
    atomic_json(folder / "prepared-audio.json", record)


def prepared_marker(folder):
    file = folder / "prepared-audio.json"
    if file.is_symlink() or not 1 <= file.stat().st_size <= 16384: return {}
    marker = json.loads(file.read_text(encoding="utf-8"))
    if not isinstance(marker, dict): return {}
    if type(marker.get("version")) is not int: return {}
    if marker.get("version") == 1: marker["extension"] = "mp3"
    elif marker.get("version") != 2: return {}
    return marker if marker.get("extension") in ("mp3", "m4a") else {}


def reusable_audio(folder, song, excluded=None):
    excluded = avoided_sources() if excluded is None else excluded
    try:
        marker = prepared_marker(folder)
        source = source_url(marker.get("source"))
        if source in excluded: return None
        file = folder / ("audio." + marker.get("extension", "mp3"))
        if (marker.get("spotify") == song.url and not file.is_symlink()
                and 1024 <= file.stat().st_size <= 100 * 1024 * 1024
                and source and marker.get("sha256") == file_digest(file)):
            verify_audio(file, song.duration)
            return source_url(marker["source"])
    except (OSError, ValueError, TypeError, WorkerFailure):
        pass
    return None


def audio_labels(audio, extension):
    if extension == "m4a":
        return {key:(audio.tags.get(tag) or [""])[0] for key, tag in
                (("title", "\xa9nam"), ("artist", "\xa9ART"), ("album", "\xa9alb"))}
    return {key:str(audio.tags.get(tag, "")) for key, tag in
            (("title", "TIT2"), ("artist", "TPE1"), ("album", "TALB"))}


def finish_audio(file, song, source, cover_loader=None):
    from mutagen.id3 import APIC, COMM, TALB, TIT2, TPE1, WOAS
    from mutagen.mp4 import MP4Cover
    audio = verify_audio(file, song.duration)
    extension = file.suffix[1:].lower()
    covers = (audio.tags or {}).get("covr", []) if extension == "m4a" else (
        [frame.data for frame in audio.tags.getall("APIC")] if audio.tags else [])
    good_cover = None
    for cover in covers:
        try:
            good_cover = (bytes(cover), validate_cover(cover)); break
        except Exception:
            continue
    data, mime = good_cover or (cover_loader or fetch_cover)(song.cover_url)
    # Validate before writing; tag a private copy so failed tag/cover repair cannot
    # damage the identity-bound audio retained for the next attempt.
    validate_cover(data)
    temporary = file.with_name("tagged-" + secrets.token_hex(8) + file.suffix)
    try:
        shutil.copyfile(file, temporary)
        audio = verify_audio(temporary, song.duration)
        if audio.tags is None: audio.add_tags()
        album = getattr(song, "album_name", "") or ""
        if extension == "m4a":
            audio.tags["\xa9nam"], audio.tags["\xa9ART"], audio.tags["\xa9alb"] = [song.name], [", ".join(song.artists)], [album]
            audio.tags["covr"] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_PNG if mime == "image/png" else MP4Cover.FORMAT_JPEG)]
            audio.tags["\xa9cmt"] = [source]
            audio.tags["----:com.apple.iTunes:SPOTIFY_URL"] = [song.url.encode("utf-8")]
            audio.save()
        else:
            audio.tags.delall("APIC")
            audio.tags.add(APIC(encoding=1, mime=mime, type=3, desc="Cover", data=data))
            for key, frame in (("TIT2", TIT2(encoding=1, text=[song.name])),
                               ("TPE1", TPE1(encoding=1, text=[", ".join(song.artists)])),
                               ("TALB", TALB(encoding=1, text=[album]))):
                audio.tags.delall(key); audio.tags.add(frame)
            audio.tags.delall("COMM")
            audio.tags.add(COMM(encoding=1, lang="eng", text=[source])); audio.tags.add(WOAS(url=song.url))
            for key in ("TRCK", "TPOS"):
                if str(audio.tags.get(key, "")) == "0/0": audio.tags.delall(key)
            audio.tags.update_to_v23(); audio.save(v2_version=3)
        saved = verify_audio(temporary, song.duration)
        labels = audio_labels(saved, extension)
        if labels != {"title":song.name, "artist":", ".join(song.artists), "album":album}:
            raise ValueError("Metadata did not persist")
        temporary.replace(file)
        return verify_audio(file, song.duration)
    finally:
        temporary.unlink(missing_ok=True)


def discard_source_attempt(attempt, folder):
    # Only directories generated by this worker, never cached originals/user files.
    if (not attempt.is_symlink() and re.fullmatch(r"source-[a-f0-9]{16}", attempt.name) and
            attempt.resolve().parent == folder.resolve()):
        shutil.rmtree(attempt, ignore_errors=True)


def download_source(url, folder, budget):
    attempt = folder / ("source-" + secrets.token_hex(8))
    attempt.mkdir()
    succeeded = False
    try:
        timeout = min(65, budget.remaining(10))
        try:
            code = run_bounded([sys.executable, "-X", "utf8", str(Path(__file__).with_name("download_source.py")),
                                url, str(attempt), "--seconds", str(timeout)], timeout)
        except subprocess.TimeoutExpired as error:
            raise source_failure(error) from None
        if code:
            failure_path = attempt / "failure.json"
            try:
                if not 1 <= failure_path.stat().st_size <= 16384: raise ValueError("Oversized failure")
                detail = json.loads(failure_path.read_text(encoding="utf-8"))
                if detail.get("code") not in ("network", "unavailable", "invalid_audio", "error"): raise ValueError("Invalid failure")
                failure = WorkerFailure(detail["code"], str(detail["message"])[:400])
                failure.transient, failure.stop = detail.get("transient") is True, detail.get("stop") is True
            except (OSError, ValueError, KeyError, TypeError):
                failure = source_failure(RuntimeError("Invalid source result"))
            raise failure
        manifest = attempt / "source-info.json"
        if manifest.is_symlink() or not 1 <= manifest.stat().st_size <= 16384: raise ValueError("Invalid source manifest")
        record = json.loads(manifest.read_text(encoding="utf-8"))
        file = attempt / record["file"]
        if (record.get("source") != url or file.is_symlink() or file.resolve(strict=True).parent != attempt.resolve() or
                not 1024 <= file.stat().st_size <= 100 * 1024 * 1024):
            raise ValueError("Invalid source result")
        succeeded = True
        return file, record

    finally:
        if not succeeded: discard_source_attempt(attempt, folder)


def install_source(raw, record, folder, song, ffmpeg, budget):
    # The downloader has already selected its best audio, without preferring AAC.
    # Only an actually compatible original stream is copied; never switch to a
    # lower ranked M4A just to avoid conversion.
    extension = "mp3"
    if raw.suffix.lower() == ".m4a":
        try:
            verify_audio(raw, song.duration)
            extension = "m4a"
        except WorkerFailure:
            pass
    temporary = folder / ("prepared-" + secrets.token_hex(8) + "." + extension)
    try:
        if extension == "m4a" or raw.suffix.lower() == ".mp3":
            shutil.copyfile(raw, temporary)
        else:
            # VBR0 avoids introducing a low fixed bitrate on a lossy source. This
            # fallback is still a conversion, and never claims lossless quality.
            code = run_bounded([str(ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", str(raw), "-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "-1",
                "-c:a", "libmp3lame", "-q:a", "0", str(temporary)], min(45, budget.remaining(5)))
            if code: raise WorkerFailure("invalid_audio", "La conversion audio a échoué sur le PC.")
        verify_audio(temporary, song.duration)
        target = folder / ("audio." + extension)
        temporary.replace(target)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def prepare_sources(provider, song, folder, ffmpeg, budget, candidates, progress, excluded=None):
    failures = []
    try:
        for selected in choose_sources(provider, song, candidates, budget, excluded):
            progress.set("download")
            raw = None
            try:
                raw, source_info = download_source(selected, folder, budget)
                file = install_source(raw, source_info, folder, song, ffmpeg, budget)
                return selected, file, source_info
            except Exception as error:
                failure = source_failure(error)
                failures.append({"source":selected, "code":failure.code, "transient":failure.transient})
                if failure.stop: raise failure
                progress.set("search")
            finally:
                if raw is not None: discard_source_attempt(raw.parent, folder)
        if failures:
            raise failure
        raise WorkerFailure("no_match", "Aucune autre version conforme disponible.")
    finally:
        atomic_json(folder / "attempts.json", failures)


def create_provider(budget):
    import requests
    from spotdl.providers.audio.ytmusic import YouTubeMusic
    from ytmusicapi import YTMusic
    session = requests.Session(); session.trust_env = False
    original = session.request
    def request(*args, **kwargs):
        remaining = budget.remaining(10)
        kwargs.setdefault("timeout", (min(5, remaining), min(12, remaining)))
        return original(*args, **kwargs)
    session.request = request
    YouTubeMusic._create_client = staticmethod(lambda: YTMusic(language="en", requests_session=session))
    try:
        return YouTubeMusic(output_format="mp3", yt_dlp_args=downloader_arguments()), session
    except Exception:
        session.close(); raise


def prepare(args, folder, progress):
    excluded = avoided_sources()  # Validate before metadata requests or touching prepared audio.
    label = alternative_label()
    budget = Budget()
    profile = folder / "profile"
    profile.mkdir(exist_ok=True)
    # Set before SpotDL imports; no browser credentials or shared provider temp files.
    Path.home = classmethod(lambda cls: profile)
    from download_metadata import canonical, entity
    from spotdl.types.song import Song
    progress.set("metadata")
    url = canonical(args.url)
    data = entity(url)
    artists = [a["name"] for a in data.get("artists", []) if a.get("name")]
    duration = data.get("duration", 0) / 1000
    if not artists or not data.get("title") or not _duration_ok(duration, duration):
        raise WorkerFailure("unavailable", "Titre, artiste ou durée indisponibles pour ce morceau.")
    atomic_json(folder / "metadata.json", {"title":data["title"], "artist":", ".join(artists)})
    images = data.get("visualIdentity", {}).get("image", [])
    cover = max(images, key=lambda item: item.get("maxWidth", 0)).get("url") if images else None
    album = data.get("album", {})
    album = album.get("name", "") if isinstance(album, dict) else ""
    song = Song(name=data["title"], artists=artists, artist=artists[0], genres=[],
        disc_number=0, disc_count=0, album_name=album if isinstance(album, str) else "", album_artist=artists[0],
        duration=duration, year=0, date="", track_number=0,
        tracks_count=0, song_id=data["id"], explicit=data.get("isExplicit"),
        publisher="", url=url, isrc="", cover_url=cover, copyright_text=None, album_id="")
    candidates, session = [], None
    try:
        selected = reusable_audio(folder, song, excluded)
        if selected is None:
            provider, session = create_provider(budget)
            progress.set("search")
            selected, file, source_info = prepare_sources(provider, song, folder, args.ffmpeg, budget, candidates, progress, excluded)
            remember_audio(folder, song, selected, file.suffix[1:], source_info)
        else:
            source_info = prepared_marker(folder)
            file = folder / ("audio." + source_info["extension"])
        # Spotify's local URI includes album, but not file hash/source. Distinguish
        # a deliberately chosen alternative without changing matching metadata,
        # title, artist or audio samples, or deleting the previous local version.
        if label:
            song.album_name = (song.album_name + " · " if song.album_name else "") + label
        progress.set("cover")
        budget.remaining()
        finish_audio(file, song, selected, lambda url: fetch_cover(url, budget=budget))
        extension = file.suffix[1:]
        remember_audio(folder, song, selected, extension, source_info)
        progress.set("verify")
        audio = verify_audio(file, duration)
        record = {"spotify":url, **audio_labels(audio, extension), "extension":extension,
            "seconds":audio.info.length, "source":selected,
            "quality":("Source YouTube Music ; AAC original conservé sans réencodage." if extension == "m4a" else
                       "Source YouTube Music ; MP3, conversion VBR haute qualité si nécessaire.")}
        for key in ("sourceCodec", "sourceBitrate"):
            if source_info.get(key) is not None: record[key] = source_info[key]
        atomic_json(folder / "audio-ready.json", record)
    finally:
        atomic_json(folder / "candidates.json", candidates)
        if session is not None: session.close()


def alternative_label():
    label = os.environ.get("SG_VARIANT_LABEL", "")
    if label and (not re.fullmatch(r"Version [1-9][0-9]{0,5}", label) or int(label.split()[-1]) < 2):
        raise ValueError("Identifiant de version alternative invalide.")
    return label


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("folder", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    args = parser.parse_args()
    folder = args.folder.resolve(strict=True)
    for stale in ("failure.json", "audio-ready.json"):
        (folder / stale).unlink(missing_ok=True)
    progress = Progress(folder)
    try:
        prepare(args, folder, progress)
    except Exception as error:
        failure = failure_for(error, progress.phase)
        detail = {"code":failure.code, "message":str(failure)[:400]}
        if failure.detail: detail["detail"] = failure.detail
        atomic_json(folder / "failure.json", detail)
        print(str(failure))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
