"""Bounded explicit-source preparation, with no Spotify identity or catalogue search."""
import argparse
import hashlib
import http.client
import io
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import ssl
from types import SimpleNamespace
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit

from mutagen import File as MutagenFile
from mutagen.id3 import APIC, COMM, TALB, TIT2, TPE1
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover
from PIL import Image, ImageDraw

from download_worker import (Budget, Progress, atomic_json, download_source, install_source,
                             validate_cover, verify_audio, discard_source_attempt)

MAX_AUDIO = 100 * 1024 * 1024
MAX_COVER = 8 * 1024 * 1024


def source_url(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 4096 or
            any(ord(char) < 33 or ord(char) == 127 for char in value)):
        raise ValueError('Lien audio HTTPS invalide.')
    parts = urlsplit(value)
    if (parts.scheme != 'https' or not parts.hostname or parts.username is not None or
            parts.password is not None or parts.port not in (None, 443) or parts.fragment):
        raise ValueError('Un lien HTTPS public sans identifiants est requis.')
    host = parts.hostname.encode('idna').decode('ascii').lower()
    youtube = host in ('youtube.com', 'www.youtube.com', 'music.youtube.com', 'm.youtube.com', 'youtu.be')
    if youtube:
        ident = None
        if host == 'youtu.be': ident = parts.path.removeprefix('/')
        elif parts.path == '/watch':
            values = parse_qs(parts.query).get('v', [])
            if len(values) == 1: ident = values[0]
        elif parts.path.startswith('/shorts/'): ident = parts.path.removeprefix('/shorts/')
        if not ident or not re.fullmatch('[A-Za-z0-9_-]{11}', ident):
            raise ValueError('Choisis le lien d’une seule vidéo YouTube.')
        return 'https://www.youtube.com/watch?v=' + ident, 'youtube'
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', host):
        raise ValueError('Nom de serveur HTTPS invalide.')
    if host == 'localhost' or host.endswith(('.localhost', '.local', '.internal')):
        raise ValueError('Les adresses locales ne sont pas des sources audio publiques.')
    try:
        address = ipaddress.ip_address(host)
        if not public_ip(address): raise ValueError('Adresse audio non publique.')
    except ValueError as error:
        if re.fullmatch('[0-9.]+', host): raise ValueError('Adresse audio non publique.') from error
    path = parts.path or '/'
    if any(ord(char) > 127 for char in path + parts.query):
        raise ValueError('Le lien doit utiliser une adresse URL encodée.')
    return urlunsplit(('https', host, path, parts.query, '')), 'direct'


def public_ip(address):
    return (address.is_global and not address.is_multicast and not address.is_unspecified and
            not address.is_reserved and not address.is_loopback and not address.is_link_local)


def public_address(host):
    addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    if not addresses: raise ValueError('Source audio introuvable.')
    # Reject mixed private/public DNS answers rather than choosing the convenient one.
    for _, _, _, _, endpoint in addresses:
        if not public_ip(ipaddress.ip_address(endpoint[0])): raise ValueError('Adresse audio non publique.')
    return addresses[0][4][0]


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        address = public_address(self.host)
        # Connect to the resolved public IP itself. TLS still authenticates the
        # requested DNS hostname; a second DNS answer cannot redirect us to LAN.
        raw = socket.create_connection((address, 443), self.timeout)
        try: self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
        except BaseException:
            raw.close()
            raise


def fetch_https(url, target, maximum, budget, connection=PublicHTTPSConnection):
    current, kind = source_url(url)
    if kind != 'direct': raise ValueError('Un lien audio HTTPS direct est requis.')
    for _ in range(4):
        parts = urlsplit(current)
        client = connection(parts.hostname, port=443, timeout=min(15, budget.remaining()), context=ssl.create_default_context())
        try:
            path = parts.path + ('?' + parts.query if parts.query else '')
            client.request('GET', path, headers={'Accept':'audio/*, image/jpeg, image/png, application/octet-stream',
                                               'Accept-Encoding':'identity', 'User-Agent':'spoti.pw local import'})
            response = client.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                current, kind = source_url(urljoin(current, response.getheader('Location', '')))
                if kind != 'direct': raise ValueError('Redirection de source non prise en charge.')
                continue
            if response.status != 200: raise ValueError('La source audio publique est indisponible.')
            encoding = response.getheader('Content-Encoding', 'identity')
            if encoding not in ('identity', ''): raise ValueError('Réponse audio compressée non prise en charge.')
            declared = response.getheader('Content-Length')
            if declared is not None and (not declared.isdigit() or not 1 <= int(declared) <= maximum):
                raise ValueError('Fichier source trop volumineux.')
            size = 0
            with target.open('xb') as output:
                while True:
                    budget.remaining()
                    chunk = response.read(min(65536, maximum + 1 - size))
                    if not chunk: break
                    size += len(chunk)
                    if size > maximum: raise ValueError('Fichier source trop volumineux.')
                    output.write(chunk)
                output.flush(); os.fsync(output.fileno())
            if declared is not None and size != int(declared): raise ValueError('Fichier source incomplet.')
            if not size: raise ValueError('La source ne contient aucun fichier.')
            return response.getheader('Content-Type', '').split(';')[0].lower()
        finally: client.close()
    raise ValueError('Trop de redirections pour cette source.')


def neutral_cover():
    image = Image.new('RGB', (512, 512), '#202a26')
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((146, 104, 366, 408), radius=28, outline='#b2c5ba', width=12)
    draw.line((240, 195, 323, 174, 323, 314), fill='#72da99', width=13)
    draw.line((240, 195, 240, 338), fill='#72da99', width=13)
    draw.ellipse((202, 321, 246, 355), fill='#72da99'); draw.ellipse((285, 298, 329, 332), fill='#72da99')
    output = io.BytesIO(); image.save(output, format='JPEG', quality=90)
    return output.getvalue(), 'image/jpeg'


def find_cover(audio, kind, source, folder, budget):
    tags = audio.tags or {}
    covers = tags.get('covr', []) if isinstance(audio, MP4) else [frame.data for frame in tags.getall('APIC')] if tags else []
    for data in covers:
        try: return bytes(data), validate_cover(data)
        except (ValueError, OSError): continue
    if kind == 'youtube':
        image = folder / 'cover-download.jpg'
        try:
            url = 'https://i.ytimg.com/vi/' + source.rsplit('=', 1)[1] + '/hqdefault.jpg'
            fetch_https(url, image, MAX_COVER, budget)
            data = image.read_bytes()
            return data, validate_cover(data)
        except (ValueError, OSError, TimeoutError): pass
        finally: image.unlink(missing_ok=True)
    return neutral_cover()


def tag_local(file, fields, cover):
    data, mime = cover
    validate_cover(data)
    if file.suffix == '.m4a':
        audio = MP4(file)
        if audio.tags is None: audio.add_tags()
        audio.tags.clear()
        for key, value in (('\xa9nam', fields['title']), ('\xa9ART', fields['artist']), ('\xa9alb', fields['album'])):
            audio[key] = [value]
        audio['covr'] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_PNG if mime == 'image/png' else MP4Cover.FORMAT_JPEG)]
        audio['\xa9cmt'] = [fields['source_url']]
        audio.save()
    else:
        audio = MP3(file)
        if audio.tags is None: audio.add_tags()
        audio.tags.clear()
        for frame, value in ((TIT2, fields['title']), (TPE1, fields['artist']), (TALB, fields['album'])):
            audio.tags.add(frame(encoding=1, text=[value]))
        audio.tags.add(APIC(encoding=1, mime=mime, type=3, data=data))
        audio.tags.add(COMM(encoding=1, lang='eng', desc='Source', text=[fields['source_url']]))
        audio.save(v2_version=3)


def prepare(fields, folder, ffmpeg, fetcher=None):
    """User supplied labels are not a claim of catalogue equivalence."""
    from automatic_downloads import audio_record
    from audio_variants import validate_decode
    budget, progress, raw = Budget(220), Progress(folder), None
    try:
        progress.set('download')
        if fields['source_kind'] == 'youtube':
            # Existing isolated downloader canonicalizes to Music, but never
            # searches or changes this exact user-selected video identifier.
            download_url = fields['source_url'].replace('https://www.youtube.com/', 'https://music.youtube.com/', 1)
            raw, info = (fetcher or download_source)(download_url, folder, budget)
            seconds = info.get('seconds')
        else:
            pending = folder / 'source-direct.bin'
            (fetcher or fetch_https)(fields['source_url'], pending, MAX_AUDIO, budget)
            detected = MutagenFile(pending)
            if not isinstance(detected, (MP3, MP4)): raise ValueError('Le lien doit fournir un MP3 ou un M4A.')
            raw = pending.with_suffix('.m4a' if isinstance(detected, MP4) else '.mp3')
            pending.replace(raw)
            seconds = detected.info.length
            info = {}
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 1 <= seconds <= 1800:
            raise ValueError('La source doit durer entre une seconde et trente minutes.')
        progress.set('verify')
        file = install_source(raw, info, folder, SimpleNamespace(duration=seconds), ffmpeg, budget)
        audio = verify_audio(file, seconds)
        progress.set('cover')
        cover = find_cover(audio, fields['source_kind'], fields['source_url'], folder, budget)
        tag_local(file, fields, cover)
        progress.set('verify')
        validate_decode(ffmpeg, file, folder / 'validation.log', min(45, budget.remaining()))
        metadata = {'extension':file.suffix[1:], 'quality':'Import personnel · source choisie explicitement'}
        record = audio_record(file, metadata)
        if any(record[key] != fields[key] for key in ('title', 'artist', 'album')):
            raise ValueError('Les métadonnées de l’import sont incohérentes.')
        record.update(file=file.name, source_url=fields['source_url'], sourceKind=fields['source_kind'])
        atomic_json(folder / 'local-ready.json', record)
        return file, record
    finally:
        if raw is not None:
            if raw.parent != folder: discard_source_attempt(raw.parent, folder)
            else: raw.unlink(missing_ok=True)
        (folder / 'source-direct.bin').unlink(missing_ok=True)
        (folder / 'validation.log').unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path); parser.add_argument('--ffmpeg', required=True)
    args = parser.parse_args()
    folder = args.folder.resolve(strict=True)
    try:
        from local_imports import request_fields
        from automatic_downloads import worker_document
        fields = request_fields(worker_document(folder / 'request.json'))
        prepare(fields, folder, args.ffmpeg)
    except Exception:
        atomic_json(folder / 'failure.json', {'message':'Cette source n’a pas fourni un audio public valide. Vérifie le lien ou choisis un fichier MP3/M4A.'})
        return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())
