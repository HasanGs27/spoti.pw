#!/usr/bin/env python3
"""Share an explicitly chosen MP3 directory with the local-files importer.

Read-only, LAN only, no transcoding and no remote music search. Requires mutagen.
python local-library.py --library /path/to/mp3 --bind 192.168.1.10
"""
import argparse
import hashlib
import ipaddress
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from mutagen.mp3 import MP3

MAX_BYTES = 100 * 1024 * 1024


def lan_address(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in ipaddress.ip_network(n) for n in
               ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Utiliser une adresse IPv4 du réseau local.")
    return str(address)


def index_library(folder):
    root = Path(folder).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Le dossier audio est introuvable.")
    tracks, files, rejected = [], {}, []
    for source in sorted(root.rglob("*")):
        if source.suffix.lower() != ".mp3":
            continue
        if len(tracks) >= 500:
            raise ValueError("Limiter le dossier à 500 MP3 pour ce transfert.")
        if source.is_symlink() or not source.resolve().is_relative_to(root) or not source.is_file():
            rejected.append(source.name)
            continue
        before = source.stat()
        if not 1024 <= before.st_size <= MAX_BYTES:
            rejected.append(source.name)
            continue
        try:
            audio = MP3(source)
            if audio.info.length < 1 or not audio.tags:
                raise ValueError("Audio sans métadonnées")
            title = str(audio.tags.get("TIT2", "")).strip()
            artist = str(audio.tags.get("TPE1", "")).strip()
            if not title or not artist or max(len(title), len(artist)) > 512:
                raise ValueError("Titre ou artiste manquant")
            with source.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            after = source.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise ValueError("Fichier modifié pendant l'indexation")
            if digest in files:
                continue
            tracks.append({"id": digest, "title": title, "artist": artist,
                           "bytes": after.st_size, "seconds": round(audio.info.length, 3),
                           "bitrate": audio.info.bitrate, "cover": bool(audio.tags.getall("APIC"))})
            files[digest] = (source.resolve(), after.st_size, after.st_mtime_ns)
        except Exception:
            # Bad media must not prevent the other files being offered.
            rejected.append(source.name)
    tracks.sort(key=lambda row: (row["artist"].casefold(), row["title"].casefold()))
    return {"version": 1, "tracks": tracks}, files, rejected


def handler_for(manifest, files, host, port, token):
    base = "/" + token
    encoded = json.dumps(manifest, ensure_ascii=False).encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # The pairing token must not end up in request logs.

        def reply(self, status, data, kind="application/json; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.headers.get("Host") != f"{host}:{port}":
                return self.reply(404, b"{}")
            path = urlsplit(self.path)
            if path.query or path.fragment:
                return self.reply(404, b"{}")
            if path.path in (base, base + "/"):
                # No external resources; this link only pairs the phone with this server.
                page = ("<!doctype html><meta name='viewport' content='width=device-width'>"
                        "<meta charset='utf-8'><title>Fichiers locaux</title>"
                        "<style>body{font:18px system-ui;background:#111;color:white;padding:24px}"
                        "p{line-height:1.5}code{overflow-wrap:anywhere}</style>"
                        "<h1>Fichiers locaux</h1>"
                        f"<p>{len(manifest['tracks'])} morceaux prêts au transfert.</p>"
                        "<p>Copie l’adresse de cette page, puis dans Spotify ouvre "
                        "<b>spoti.pw → Player → Fichiers du PC</b> et colle-la dans « Connecter le PC ».</p>"
                        "<p>Les fichiers sont transférés sans conversion. Garde le PC allumé "
                        "et les deux appareils sur le même Wi-Fi.</p>")
                return self.reply(200, page.encode(), "text/html; charset=utf-8")
            if path.path == base + "/manifest":
                return self.reply(200, encoded)
            prefix = base + "/file/"
            ident = path.path[len(prefix):] if path.path.startswith(prefix) else ""
            if ident not in files:
                return self.reply(404, b"{}")
            source, size, stamp = files[ident]
            try:
                if source.is_symlink() or source.resolve() != source:
                    return self.reply(409, b"{}")
                stat = source.stat()
                if (stat.st_size, stat.st_mtime_ns) != (size, stamp):
                    return self.reply(409, b"{}")
                with source.open("rb") as stream:
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/mpeg")
                    self.send_header("Content-Length", str(size))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    while chunk := stream.read(128 * 1024):
                        self.wfile.write(chunk)
            except (OSError, BrokenPipeError):
                self.close_connection = True

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--bind", required=True, type=lan_address)
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--session", type=Path)
    args = parser.parse_args()
    manifest, files, rejected = index_library(args.library)
    if not files:
        raise SystemExit("Aucun MP3 valide avec titre et artiste dans ce dossier.")
    token = secrets.token_urlsafe(24)
    handler = handler_for(manifest, files, args.bind, args.port, token)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    url = f"http://{args.bind}:{args.port}/{token}/"
    if args.session:
        args.session.write_text(json.dumps({"url": url, "tracks": len(files),
                                           "rejected": rejected}), encoding="utf-8")
    print(f"{len(files)} fichiers prêts ; {len(rejected)} ignorés.\n{url}", flush=True)
    timer = threading.Timer(6 * 3600, server.shutdown)
    timer.daemon = True
    timer.start()
    try:
        server.serve_forever()
    finally:
        timer.cancel()
        server.server_close()


if __name__ == "__main__":
    main()
