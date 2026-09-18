"""Isolated audio worker. Uses public YT Music song results, never Spotify audio."""
import argparse
import json
import math
import re
import unicodedata
from pathlib import Path


def words(value):
    return set(re.findall(r"[a-z0-9]+", unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode().lower()))


def acceptable(result, song):
    # A song-library result, not a random video, cover, slowed edit or live recording.
    variants = {"live", "cover", "remix", "slowed", "sped", "reverb", "instrumental", "karaoke", "acoustic"}
    if not words(song.name) or not words(song.artists[0]) or not result.verified or not result.duration or not math.isfinite(result.duration):
        return False
    if abs(result.duration - song.duration) > max(2, song.duration * .012):
        return False
    if (words(result.name) & variants) - (words(song.name) & variants):
        return False
    if not result.artists or not (words(song.artists[0]) <= words(" ".join(result.artists))):
        return False
    return words(song.name) <= words(result.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("folder", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    args = parser.parse_args()
    folder = args.folder.resolve(strict=True)
    profile = folder / "profile"
    profile.mkdir(exist_ok=True)
    Path.home = classmethod(lambda cls: profile)
    from download_metadata import canonical, entity
    from spotdl.types.song import Song
    from spotdl.download.downloader import Downloader
    from spotdl.providers.audio.ytmusic import YouTubeMusic
    from ytmusicapi import YTMusic
    from mutagen.mp3 import MP3
    from mutagen.id3 import TALB
    url = canonical(args.url)
    data = entity(url)
    artists = [a["name"] for a in data.get("artists", []) if a.get("name")]
    if not artists or not data.get("title") or not 1000 <= data.get("duration", 0) <= 1800000:
        raise ValueError("Titre, artiste ou durée manquants.")
    (folder / "metadata.json").write_text(json.dumps({"title": data["title"], "artist": ", ".join(artists)}, ensure_ascii=False), encoding="utf-8")
    images = data.get("visualIdentity", {}).get("image", [])
    cover = max(images, key=lambda item: item.get("maxWidth", 0)).get("url") if images else None
    if not cover:
        raise ValueError("Pochette indisponible ; aucun fichier incomplet ajouté.")
    song = Song(name=data["title"], artists=artists, artist=artists[0], genres=[],
        disc_number=0, disc_count=0, album_name="", album_artist=artists[0],
        duration=round(data["duration"] / 1000), year=0, date="", track_number=0,
        tracks_count=0, song_id=data["id"], explicit=bool(data.get("isExplicit")),
        publisher="", url=url, isrc="", cover_url=cover, copyright_text=None, album_id="")
    # Use the API's English parsing consistently, including its retry clients.
    YouTubeMusic._create_client = staticmethod(lambda: YTMusic(language="en"))
    engine = Downloader({"output": str(folder / "audio.{output-ext}"), "format": "mp3",
        "bitrate": "auto", "ffmpeg": args.ffmpeg, "lyrics_providers": [], "threads": 1,
        "audio_providers": ["youtube-music"], "only_verified_results": True,
        "yt_dlp_args": "--socket-timeout 20 --retries 1 --max-filesize 100M", "simple_tui": True})
    candidates = []
    provider = engine.audio_providers[0]
    provider.GET_RESULTS_OPTS = [{"filter": "songs", "ignore_spelling": True, "limit": 50}]
    original = provider.get_results
    def filtered(*a, **kw):
        rows = original(*a, **kw)
        candidates.extend({"title": r.name, "artists": r.artists, "duration": r.duration,
            "url": r.url, "accepted": acceptable(r, song)} for r in rows)
        return [r for r in rows if acceptable(r, song)]
    provider.get_results = filtered
    try:
        _, file = engine.download_song(song)
        if not file:
            raise ValueError("Aucune version suffisamment fiable trouvée.")
        audio = MP3(file)
        if abs(audio.info.length - data["duration"] / 1000) > max(2, song.duration * .012):
            raise ValueError("Durée du fichier incompatible avec le morceau demandé.")
        if not audio.tags.getall("APIC"):
            raise ValueError("Pochette intégrée manquante.")
        # Explicit stable empty album (rather than a made-up album); local URI uses these exact tags.
        audio.tags.delall("TALB")
        audio.tags.add(TALB(encoding=1, text=[""]))
        for key in ("TRCK", "TPOS"):
            if str(audio.tags.get(key, "")) == "0/0": audio.tags.delall(key)
        audio.tags.update_to_v23()
        audio.save(v2_version=3)
        (folder / "audio-ready.json").write_text(json.dumps({"spotify": url,
            "title": str(audio.tags["TIT2"]), "artist": str(audio.tags["TPE1"]),
            "album": str(audio.tags.get("TALB", "")), "seconds": audio.info.length,
            "source": next((str(v) for v in audio.tags.getall("COMM") if str(v).startswith("https://")), ""),
            "quality": "Source YouTube Music ; pas de garantie de qualité studio."}, ensure_ascii=False), encoding="utf-8")
    finally:
        (folder / "candidates.json").write_text(json.dumps(candidates, ensure_ascii=False), encoding="utf-8")
        engine.progress_handler.close()


if __name__ == "__main__":
    main()
