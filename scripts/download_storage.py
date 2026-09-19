"""Private content-addressed audio storage. Never scans or deletes user directories."""
import json
import os
import re
import secrets
import stat
import threading
from pathlib import Path
from mutagen import MutagenError

MAX_AUDIO = 100 * 1024 * 1024


def safe_path(path, root, *, exists=True):
    path, root = Path(path), Path(root)
    if path.is_symlink() or path.resolve(strict=exists) != path or not path.is_relative_to(root):
        raise ValueError('Chemin privé invalide.')
    return path


def atomic_document(path, value):
    """Durable replace; caller serializes changes and owns the parent directory."""
    safe_path(path.parent, path.parent)
    if path.is_symlink(): raise ValueError('Fichier privé invalide.')
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8) + '.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False)
            output.flush(); os.fsync(output.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class AudioStore:
    def __init__(self, root, verifier):
        self.root, self.verify = Path(root), verifier
        self.directory = self.root / '.audio-store'
        self.directory.mkdir(exist_ok=True)
        safe_path(self.directory, self.root)
        self.lock = threading.RLock()

    def path(self, row):
        ident, extension = row.get('id'), row.get('extension', 'mp3')
        if not isinstance(ident, str) or not re.fullmatch('[a-f0-9]{64}', ident) or extension not in ('mp3', 'm4a'):
            raise ValueError('Identité audio invalide.')
        return self.directory / (ident + '.' + extension)

    def verified(self, path, row):
        safe_path(path, self.root)
        checked = self.verify(path, row)
        if checked['id'] != row['id'] or checked['bytes'] != row['bytes']:
            raise ValueError('Audio modifié sur le PC.')
        return checked

    def install(self, source, row):
        """Verify a single canonical copy; leave source until its job is persisted."""
        with self.lock:
            safe_path(self.directory, self.root)
            checked = self.verified(source, row)
            target = self.path(checked)
            if source == target: return target, checked
            if target.exists() and not target.is_symlink():
                try:
                    self.verified(target, checked)
                    return target, checked
                except (ValueError, OSError, MutagenError): pass
            if target.is_symlink(): raise ValueError('Fichier audio privé invalide.')
            temporary = self.directory / (secrets.token_hex(16) + '.tmp')
            try:
                with source.open('rb') as incoming, temporary.open('xb') as outgoing:
                    remaining = checked['bytes']
                    while remaining:
                        chunk = incoming.read(min(131072, remaining))
                        if not chunk: raise ValueError('Audio incomplet.')
                        outgoing.write(chunk); remaining -= len(chunk)
                    if incoming.read(1): raise ValueError('Audio modifié.')
                    outgoing.flush(); os.fsync(outgoing.fileno())
                self.verified(temporary, checked)
                temporary.replace(target)
                return target, checked
            finally:
                temporary.unlink(missing_ok=True)

    def inventory(self):
        safe_path(self.directory, self.root)
        result = []
        for path in self.directory.iterdir():
            if not re.fullmatch(r'(?:[a-f0-9]{64}\.(?:mp3|m4a)|[a-f0-9]{32}\.tmp)', path.name): continue
            try:
                safe_path(path, self.root)
                info = path.stat()
                if not stat.S_ISREG(info.st_mode) or not 0 <= info.st_size <= MAX_AUDIO: continue
                result.append((path, info))
            except (ValueError, OSError): continue
        return result

    def remove_snapshot(self, path, snapshot):
        """Unlink one owned orphan only if its identity still matches the inventory."""
        safe_path(self.directory, self.root)
        safe_path(path, self.root)
        current = path.stat()
        if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (
            snapshot.st_dev, snapshot.st_ino, snapshot.st_size, snapshot.st_mtime_ns): return False
        path.unlink()
        return True
