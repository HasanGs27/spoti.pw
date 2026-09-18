"""Isolated MP3 worker. Public YT Music song results, never Spotify audio."""
import argparse
import hashlib
import io
import json
import math
import os
import re
import shlex
import shutil
import subprocess
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
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


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


def choose_source(provider, song, candidates):
    # Installed SpotDL's provider controls: no videos and no three-attempt repetition.
    provider.SEARCH_ATTEMPTS = 1
    _, _, title = title_identity(song.name, song.artists)
    queries = list(dict.fromkeys((f"{title} {' '.join(song.artists)}", f"{title} {song.artists[0]}")))
    for query in queries:
        rows = provider.get_results(query, filter="songs", ignore_spelling=True, limit=20)
        matches = []
        for row in rows:
            accepted = acceptable(row, song) and source_url(row.url) is not None
            duration = row.duration if isinstance(row.duration, (int, float)) and math.isfinite(row.duration) else None
            candidates.append({"title": row.name, "artists": row.artists, "duration": duration,
                               "url": source_url(row.url), "accepted": accepted})
            if accepted:
                matches.append(row)
        if matches:
            return source_url(min(matches, key=lambda r: abs(r.duration - song.duration)).url)
    raise WorkerFailure("no_match", "Aucune version avec le bon titre, les bons artistes et la bonne durée. Ajoute un fichier audio pour ce titre.")


def downloader_arguments():
    args = ["--socket-timeout", "20", "--retries", "1", "--max-filesize", "100M"]
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


def fetch_cover(url, session=None):
    import requests
    own_session = session is None
    if own_session:
        session = requests.Session()
        session.trust_env = False  # No implicit netrc credentials/proxy or browser cookies.
    try:
        for _ in range(4):
            validate_cover_url(url)
            with session.get(url, stream=True, timeout=(5, 15), allow_redirects=False) as response:
                if response.status_code in (301, 302, 303, 307, 308):
                    url = urljoin(url, response.headers.get("Location", ""))
                    continue
                response.raise_for_status()
                declared = response.headers.get("Content-Length")
                if declared and int(declared) > MAX_COVER_BYTES:
                    raise ValueError("Cover too large")
                parts, size = [], 0
                for part in response.iter_content(65536):
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


def verify_audio(file, duration):
    from mutagen.mp3 import MP3
    try:
        if not 1024 <= file.stat().st_size <= 100 * 1024 * 1024:
            raise ValueError("Invalid audio size")
        audio = MP3(file)
        if not _duration_ok(audio.info.length, duration):
            raise ValueError("Invalid audio duration")
        return audio
    except Exception as error:
        raise WorkerFailure("invalid_audio", "Le fichier audio est incomplet ou sa durée ne correspond pas au titre.") from error


def file_digest(file):
    with file.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def remember_audio(folder, song, source):
    # Retry tags only after a completed, strictly matched download, never arbitrary MP3s.
    atomic_json(folder / "prepared-audio.json", {"version": 1, "spotify": song.url,
                "source": source, "sha256": file_digest(folder / "audio.mp3")})


def reusable_audio(folder, song):
    try:
        marker = json.loads((folder / "prepared-audio.json").read_text(encoding="utf-8"))
        file = folder / "audio.mp3"
        if (marker.get("version") == 1 and marker.get("spotify") == song.url
                and source_url(marker.get("source")) and marker.get("sha256") == file_digest(file)):
            verify_audio(file, song.duration)
            return source_url(marker["source"])
    except (OSError, ValueError, TypeError, WorkerFailure):
        pass
    return None


def finish_audio(file, song, source, cover_loader=None):
    from mutagen.id3 import APIC, COMM, TALB, TIT2, TPE1, WOAS
    audio = verify_audio(file, song.duration)
    if audio.tags is None:
        audio.add_tags()
    good_cover = None
    for frame in audio.tags.getall("APIC"):
        try:
            good_cover = (frame.data, validate_cover(frame.data))
            break
        except Exception:
            continue
    data, mime = good_cover or (cover_loader or fetch_cover)(song.cover_url)
    # Validate before saving: failed artwork cannot destroy the valid MP3.
    audio.tags.delall("APIC")
    audio.tags.add(APIC(encoding=1, mime=mime, type=3, desc="Cover", data=data))
    for key, frame in (("TIT2", TIT2(encoding=1, text=[song.name])),
                       ("TPE1", TPE1(encoding=1, text=[", ".join(song.artists)])),
                       ("TALB", TALB(encoding=1, text=[""]))):
        audio.tags.delall(key)
        audio.tags.add(frame)
    audio.tags.delall("COMM")
    audio.tags.add(COMM(encoding=1, lang="eng", text=[source]))
    audio.tags.add(WOAS(url=song.url))
    for key in ("TRCK", "TPOS"):
        if str(audio.tags.get(key, "")) == "0/0":
            audio.tags.delall(key)
    audio.tags.update_to_v23()
    audio.save(v2_version=3)  # Metadata only: no ffmpeg/re-encoding on cover repair.
    return audio


def prepare(args, folder, progress):
    profile = folder / "profile"
    profile.mkdir(exist_ok=True)
    # Set before SpotDL imports. Its .spotdl/temp/cache is isolated per worker.
    Path.home = classmethod(lambda cls: profile)
    from download_metadata import canonical, entity
    from spotdl.types.song import Song
    from spotdl.download.downloader import Downloader
    from spotdl.providers.audio.ytmusic import YouTubeMusic
    from ytmusicapi import YTMusic
    configure_hidden_ffmpeg()
    progress.set("metadata")
    url = canonical(args.url)
    data = entity(url)
    artists = [a["name"] for a in data.get("artists", []) if a.get("name")]
    duration = data.get("duration", 0) / 1000
    if not artists or not data.get("title") or not _duration_ok(duration, duration):
        raise WorkerFailure("unavailable", "Titre, artiste ou durée indisponibles pour ce morceau.")
    atomic_json(folder / "metadata.json", {"title": data["title"], "artist": ", ".join(artists)})
    images = data.get("visualIdentity", {}).get("image", [])
    cover = max(images, key=lambda item: item.get("maxWidth", 0)).get("url") if images else None
    song = Song(name=data["title"], artists=artists, artist=artists[0], genres=[],
        disc_number=0, disc_count=0, album_name="", album_artist=artists[0],
        duration=duration, year=0, date="", track_number=0,
        tracks_count=0, song_id=data["id"], explicit=data.get("isExplicit"),
        publisher="", url=url, isrc="", cover_url=cover, copyright_text=None, album_id="")
    candidates, engine = [], None
    file = folder / "audio.mp3"
    try:
        selected = reusable_audio(folder, song)
        if selected is None:
            YouTubeMusic._create_client = staticmethod(lambda: YTMusic(language="en"))
            engine = Downloader({"output": str(folder / "audio.{output-ext}"), "format": "mp3",
                "bitrate": "auto", "ffmpeg": args.ffmpeg, "lyrics_providers": [], "threads": 1,
                "audio_providers": ["youtube-music"], "only_verified_results": True,
                "skip_album_art": True, "overwrite": "force",
                "yt_dlp_args": downloader_arguments(), "simple_tui": True})
            progress.set("search")
            selected = choose_source(engine.audio_providers[0], song, candidates)
            song.download_url = selected  # Bypass SpotDL's second, fuzzy matching pass.
            progress.set("download")
            _, downloaded = engine.download_song(song)
            if not downloaded:
                raise failure_for(RuntimeError(" ".join(engine.errors)))
            verify_audio(file, duration)
            remember_audio(folder, song, selected)
        progress.set("cover")
        finish_audio(file, song, selected)
        remember_audio(folder, song, selected)
        progress.set("verify")
        audio = verify_audio(file, duration)
        atomic_json(folder / "audio-ready.json", {"spotify": url,
            "title": str(audio.tags["TIT2"]), "artist": str(audio.tags["TPE1"]),
            "album": str(audio.tags.get("TALB", "")), "seconds": audio.info.length,
            "source": selected, "quality": "Source YouTube Music ; débit adapté à la source, sans garantie de qualité studio."})
    finally:
        atomic_json(folder / "candidates.json", candidates)
        if engine is not None:
            engine.progress_handler.close()


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
        atomic_json(folder / "failure.json", {"code": failure.code, "message": str(failure)[:400]})
        print(str(failure))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
