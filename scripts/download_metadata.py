"""Public Spotify display metadata; no playback credentials or audio previews."""
import json
import hashlib
import os
import re
import secrets
import time
from pathlib import Path
from urllib.parse import urlsplit
import requests
from bs4 import BeautifulSoup

MAX_RESPONSE = 8 * 1024 * 1024
CACHE_SECONDS = 6 * 3600
CACHE_ENTRIES = 512
MAX_CACHE_FILE = 256 * 1024


def canonical(value):
    if not isinstance(value, str) or len(value) > 1000:
        raise ValueError("Lien Spotify invalide.")
    value = value.strip()
    uri = re.fullmatch(r"spotify:(track|playlist):([A-Za-z0-9]{22})", value)
    if uri:
        return f"https://open.spotify.com/{uri[1]}/{uri[2]}"
    parts = urlsplit(value)
    match = re.fullmatch(r"/(?:intl-[a-z]{2}/)?(track|playlist)/([A-Za-z0-9]{22})/?", parts.path)
    if parts.scheme != "https" or parts.netloc != "open.spotify.com" or not match:
        raise ValueError("Seuls les morceaux et playlists Spotify sont pris en charge.")
    return f"https://open.spotify.com/{match[1]}/{match[2]}"


def validate_entity(data, url):
    kind, ident = url.rsplit("/", 2)[1:]
    if not isinstance(data, dict) or data.get("type") != kind or data.get("id") != ident:
        raise ValueError("Identité Spotify incohérente.")
    if data.get('uri') is not None and canonical(data['uri']) != url:
        raise ValueError("Identité Spotify incohérente.")
    return data


def cache_file(url):
    # Tracks are stable enough for a short cache. Playlists are always refreshed.
    folder = os.environ.get('SG_METADATA_CACHE_DIR')
    if not folder or '/track/' not in url:
        return None
    folder = Path(folder).absolute()
    try:
        if folder.is_symlink() or folder.resolve() != folder:
            return None
        folder.mkdir(parents=True, exist_ok=True)
        return folder / (hashlib.sha256(url.encode()).hexdigest() + '.json')
    except OSError:
        return None


def cached_entity(path, url):
    if path is None:
        return None
    try:
        if path.is_symlink() or not 1 <= path.stat().st_size <= MAX_CACHE_FILE:
            return None
        cached = json.loads(path.read_text(encoding='utf-8'))
        age = time.time() - cached['savedAt']
        if cached['url'] != url or not 0 <= age < CACHE_SECONDS:
            return None
        return validate_entity(cached['entity'], url)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def save_cached_entity(path, url, data):
    if path is None:
        return
    temporary = path.with_suffix('.' + secrets.token_hex(8) + '.tmp')
    try:
        encoded = json.dumps({'url':url, 'savedAt':time.time(), 'entity':data}, ensure_ascii=False).encode('utf-8')
        if len(encoded) > MAX_CACHE_FILE:
            return
        with temporary.open('xb') as output:
            output.write(encoded)
        temporary.replace(path)
        entries = [p for p in path.parent.glob('*.json') if re.fullmatch('[a-f0-9]{64}\\.json', p.name) and not p.is_symlink()]
        if len(entries) > CACHE_ENTRIES:
            # Each file belongs to this cache; never traverse or remove directories.
            for old in sorted(entries, key=lambda p:p.stat().st_mtime)[:len(entries) - CACHE_ENTRIES]:
                if old != path:
                    old.unlink(missing_ok=True)
    except OSError:
        pass # A read-only/full cache must not stop preparation.
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def public_page(url):
    kind, ident = url.rsplit('/', 2)[1:]
    address = f'https://open.spotify.com/embed/{kind}/{ident}'
    for attempt in range(2):
        try:
            with requests.get(address, timeout=(6, 18), stream=True, allow_redirects=False) as response:
                status = response.status_code
                if attempt == 0 and status in (429, 500, 502, 503, 504):
                    try:
                        delay = float(response.headers.get('Retry-After', '0.5'))
                    except ValueError:
                        delay = 4
                    if 0 <= delay <= 3:
                        time.sleep(delay)
                        continue
                response.raise_for_status()
                if status != 200 or response.url != address:
                    raise ValueError('La page Spotify demandée est indisponible.')
                length = response.headers.get('Content-Length', '')
                if length.isdigit() and int(length) > MAX_RESPONSE:
                    raise ValueError('Réponse Spotify trop volumineuse.')
                body = bytearray()
                for chunk in response.iter_content(65536):
                    body.extend(chunk)
                    if len(body) > MAX_RESPONSE:
                        raise ValueError('Réponse Spotify trop volumineuse.')
                return bytes(body)
        except (requests.ConnectionError, requests.Timeout, requests.exceptions.ChunkedEncodingError):
            if attempt:
                raise
            time.sleep(0.5)
    raise ValueError('Métadonnées publiques indisponibles.')


def entity(value):
    url = canonical(value)
    cache = cache_file(url)
    data = cached_entity(cache, url)
    if data is not None:
        return data
    script = BeautifulSoup(public_page(url).decode('utf-8'), 'html.parser').find('script', id='__NEXT_DATA__')
    if not script or not script.string:
        raise ValueError("Métadonnées publiques indisponibles.")
    try:
        data = validate_entity(json.loads(script.string)["props"]["pageProps"]["state"]["data"]["entity"], url)
    except (KeyError, TypeError) as error:
        raise ValueError('Métadonnées publiques indisponibles.') from error
    save_cached_entity(cache, url, data)
    return data


def collection(value, track_urls=None):
    url = canonical(value)
    if track_urls is not None:
        if not isinstance(track_urls, list) or not 1 <= len(track_urls) <= 500:
            raise ValueError("La liste doit contenir entre 1 et 500 titres.")
        urls = [canonical(item) for item in track_urls]
        if not all('/track/' in item for item in urls):
            raise ValueError("Une liste de morceaux est attendue.")
        return "Sélection Spotify", "Titres transmis par l’application.", urls
    data = entity(url)
    if data["type"] == "track":
        return data.get("title", "Morceau"), "Un morceau.", [url]
    rows = data.get("trackList", [])
    if not 1 <= len(rows) <= 500:
        raise ValueError("Playlist vide, privée ou trop volumineuse pour cet essai.")
    urls, unavailable = [], 0
    for row in rows:
        try:
            track = canonical(row.get('uri', ''))
            if '/track/' not in track:
                raise ValueError('Entrée non musicale.')
            urls.append(track)
        except (AttributeError, ValueError):
            unavailable += 1
    if not urls:
        raise ValueError('Aucun morceau accessible dans cette playlist.')
    scope = "Titres visibles sur la page publique ; le total intégral n'est pas garanti."
    if unavailable:
        scope += f' {unavailable} entrée(s) indisponible(s).'
    return data.get("name", "Playlist").strip(), scope, urls
