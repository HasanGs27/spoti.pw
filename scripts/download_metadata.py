"""Public Spotify display metadata; no playback credentials or audio previews."""
import json
import re
from urllib.parse import urlsplit
import requests
from bs4 import BeautifulSoup


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


def entity(value):
    url = canonical(value)
    kind, ident = url.rsplit("/", 2)[1:]
    response = requests.get(f"https://open.spotify.com/embed/{kind}/{ident}", timeout=(10, 25))
    response.raise_for_status()
    if len(response.content) > 8 * 1024 * 1024:
        raise ValueError("Réponse Spotify trop volumineuse.")
    script = BeautifulSoup(response.content.decode("utf-8"), "html.parser").find("script", id="__NEXT_DATA__")
    if not script or not script.string:
        raise ValueError("Métadonnées publiques indisponibles.")
    data = json.loads(script.string)["props"]["pageProps"]["state"]["data"]["entity"]
    if data.get("type") != kind or data.get("id") != ident:
        raise ValueError("Identité Spotify incohérente.")
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
    # Do not silently drop unavailable entries or claim the embed is a full playlist.
    urls = [canonical(row.get("uri", "")) for row in rows]
    return data.get("name", "Playlist").strip(), "Titres visibles sur la page publique ; le total intégral n’est pas garanti.", urls
