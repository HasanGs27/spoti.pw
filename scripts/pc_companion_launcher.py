"""Start the existing paired PC companion; --check is strictly read-only."""
import argparse
import contextlib
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.metadata
import ipaddress
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

LOCAL_NODE = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
PRIVATE = tuple(ipaddress.ip_network(net) for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))
ZEROCONF_VERSION = '0.151.3'
NETWORK_ISSUE = 'Adresse LAN indisponible. Connecte le PC au Wi-Fi ou au réseau local.'

@dataclass(frozen=True)
class Config:
    root: Path
    folder: Path
    pythonw: Path
    backend: Path
    ffmpeg: Path
    launcher: Path

    @classmethod
    def workspace(cls, root, folder=None):
        root = Path(root).resolve()
        return cls(root, Path(folder).resolve() if folder else root / 'work/auto-download-test',
                   root / 'work/offline-tools/Scripts/pythonw.exe',
                   Path(__file__).resolve().with_name('automatic_downloads.py'),
                   root / 'work/offline-test/profile/.spotdl/ffmpeg.exe', Path(__file__).resolve())

    @property
    def session(self):
        return self.folder / 'session.json'

    @property
    def mutex_name(self):
        ident = hashlib.sha256(str(self.folder.resolve()).casefold().encode('utf-8')).hexdigest()
        return 'Local\\SpotiPC-' + ident

    def command(self, *arguments):
        return [str(self.pythonw), '-X', 'utf8', str(self.launcher), '--root', str(self.root),
                '--folder', str(self.folder), *arguments]

def lan_address(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in net for net in PRIVATE):
        raise ValueError('Une adresse IPv4 du réseau local est nécessaire.')
    return str(address)

def detect_lan():
    # UDP connect selects a local route without transmitting a packet.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(('192.0.2.1', 9))
        return lan_address(probe.getsockname()[0])

def paired_session(config):
    if config.session.is_symlink():
        raise ValueError('Le fichier d’association ne doit pas être un lien symbolique.')
    value = json.loads(config.session.read_text(encoding='utf-8'))
    parsed = urlsplit(value['url'])
    token = parsed.path.strip('/')
    if (parsed.scheme != 'http' or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.port is None or not 1024 <= parsed.port <= 65535
            or not re.fullmatch(r'[A-Za-z0-9_-]{32}', token) or parsed.path != '/' + token + '/'):
        raise ValueError('Le fichier d’association existant est invalide.')
    return value, lan_address(parsed.hostname), parsed.port, token

def update_address(config, address):
    """Only called while holding the backend lock; preserve all session fields."""
    value, previous, port, token = paired_session(config)
    address = lan_address(address)
    if previous != address:
        value['url'] = f'http://{address}:{port}/{token}/'
        temporary = None
        try:
            with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=config.folder,
                                             prefix='session-', suffix='.tmp', delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(value, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(config.session)
        finally:
            if temporary and temporary.exists(): temporary.unlink()
    return port, token

def ready(address, port, token):
    connection = http.client.HTTPConnection(address, port, timeout=2)
    try:
        connection.request('GET', '/' + token + '/hello')
        reply = connection.getresponse()
        data = reply.read(4096)
        return reply.status == 200 and json.loads(data) == {'version': 2, 'service': 'spoti-auto-downloads'}
    except (OSError, ValueError, http.client.HTTPException):
        return False
    finally:
        connection.close()

def node_runtime():
    candidates = [os.environ.get('SG_NODE_RUNTIME'), shutil.which('node'), str(LOCAL_NODE)]
    for candidate in dict.fromkeys(path for path in candidates if path):
        path = Path(candidate)
        if not path.is_file():
            continue
        try:
            version = subprocess.run([str(path), '--version'], capture_output=True, text=True, timeout=5,
                check=True, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).stdout.strip()
            match = re.fullmatch(r'v(\d+)\.\d+\.\d+', version)
            if match and int(match.group(1)) >= 22:
                return path.resolve(), version
        except (OSError, subprocess.SubprocessError):
            continue
    return None, None

def installation(config):
    issues, versions = [], {}
    for package in ('requests', 'spotdl', 'yt-dlp', 'yt-dlp-ejs', 'ytmusicapi', 'mutagen', 'Pillow', 'zeroconf'):
        try:
            versions[package] = importlib.metadata.version(package)
            if package == 'zeroconf' and versions[package] != ZEROCONF_VERSION:
                issues.append('Dépendance requise : zeroconf==' + ZEROCONF_VERSION)
        except importlib.metadata.PackageNotFoundError:
            issues.append('Dépendance absente : ' + package)
    for path in (config.pythonw, config.backend, config.ffmpeg, config.launcher):
        if not path.is_file():
            issues.append('Fichier requis absent : ' + path.name)
    if sys.version_info < (3, 11):
        issues.append('Python 3.11 ou plus récent est nécessaire.')
    runtime, runtime_version = node_runtime()
    if runtime is None:
        issues.append('Le moteur audio nécessite Node.js 22 ou plus récent.')
    else:
        versions['node'] = runtime_version
    try:
        paired_session(config)
    except (OSError, ValueError, KeyError, TypeError):
        issues.append("Association absente ou invalide ; aucune nouvelle clé n'a été créée.")
    return issues, versions

def inspect(config, address=None):
    issues, versions = installation(config)
    try:
        detected = lan_address(address) if address else detect_lan()
    except (OSError, ValueError):
        detected = None
        issues.append(NETWORK_ISSUE)
    try:
        _, previous, port, token = paired_session(config)
    except (OSError, ValueError, KeyError, TypeError):
        previous, port, token = None, 8768, None
    # Do not send the saved pairing path to an old address assigned to another PC.
    active = bool(token and detected and previous == detected and ready(detected, port, token))
    try:
        resident = resident_running(config)
    except OSError:
        resident = None
    try:
        boot = startup(config)
    except (OSError, ValueError, subprocess.SubprocessError):
        boot = {'enabled': False, 'owned': False, 'available': False}
    return {'ready': active, 'resident': resident, 'startup': boot, 'lanAddress': detected, 'port': port, 'paired': token is not None,
            'addressChanged': bool(previous and detected and previous != detected),
            'dependencies': versions, 'issues': issues, 'logs': str(config.folder)}

class PrivateLog:
    def __init__(self, stream, token):
        self.stream, self.token = stream, token
    def write(self, value):
        self.stream.write(value.replace(self.token, '[association-masquee]'))
        self.stream.flush()
        return len(value)
    def flush(self):
        self.stream.flush()

def _kernel():
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.OpenMutexW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.OpenMutexW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.ReleaseMutex.argtypes = [wintypes.HANDLE]
    kernel.ReleaseMutex.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    return kernel

@contextlib.contextmanager
def resident_lock(config):
    """Windows releases an abandoned mutex on exit; there are no stale PID files."""
    import ctypes
    kernel = _kernel()
    handle = kernel.CreateMutexW(None, False, config.mutex_name)
    if not handle: raise ctypes.WinError(ctypes.get_last_error())
    acquired = False
    try:
        result = kernel.WaitForSingleObject(handle, 0)
        if result == 0xFFFFFFFF: raise ctypes.WinError(ctypes.get_last_error())
        acquired = result in (0, 0x80)
        yield acquired
    finally:
        if acquired: kernel.ReleaseMutex(handle)
        kernel.CloseHandle(handle)

def resident_running(config):
    """Open an existing object only: --check creates neither locks nor files."""
    import ctypes
    kernel = _kernel()
    handle = kernel.OpenMutexW(0x100001, False, config.mutex_name)
    if not handle:
        if ctypes.get_last_error() in (2, 3): return False
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        result = kernel.WaitForSingleObject(handle, 0)
        if result in (0, 0x80):
            kernel.ReleaseMutex(handle)
            return False
        if result == 0x102: return True
        raise ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel.CloseHandle(handle)

def startup(config, mode='check', directory=None):
    script = config.launcher.with_name('install-pc-startup.ps1')
    command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
               '-File', str(script), '-Mode', mode, '-Python', str(config.pythonw),
               '-Launcher', str(config.launcher), '-Workspace', str(config.root),
               '-Arguments', subprocess.list2cmdline(config.command('--resident')[1:]),
               '-Owner', config.mutex_name]
    if directory is not None: command += ['-StartupDirectory', str(directory)]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=10,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), check=True)
    value = json.loads(result.stdout.lstrip('\ufeff'))
    if not isinstance(value, dict) or not isinstance(value.get('enabled'), bool) or not isinstance(value.get('owned'), bool):
        raise ValueError('Invalid startup status')
    return value

@contextlib.contextmanager
def logs(config):
    _, _, _, token = paired_session(config)
    with (config.folder / 'server-output.log').open('a', encoding='utf-8') as output, \
         (config.folder / 'server-error.log').open('a', encoding='utf-8') as error, \
         contextlib.redirect_stdout(PrivateLog(output, token)), contextlib.redirect_stderr(PrivateLog(error, token)):
        yield

def serve(config, address):
    import msvcrt
    address = lan_address(address)
    paired_session(config)  # Refuse an absent association before creating any file.
    # Compatible with the old nonresident launcher's file lock.
    with (config.folder / 'companion.lock').open('a+b') as lock:
        if lock.tell() == 0:
            lock.write(b'0'); lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            return 0
        with logs(config):
            try:
                runtime, _ = node_runtime()
                if runtime is None: raise RuntimeError('Node.js 22 ou plus récent est nécessaire.')
                os.environ['SG_NODE_RUNTIME'] = str(runtime)
                os.environ['SG_METADATA_CACHE_DIR'] = str(config.folder / 'jobs/.metadata-cache')
                os.environ['SG_ARTWORK_CACHE_DIR'] = str(config.folder / 'jobs/.artwork-cache')
                port, _ = update_address(config, address)
                print(datetime.now(timezone.utc).isoformat(), 'Compagnon PC lancé sur', address, 'port', port)
                sys.path.insert(0, str(config.backend.parent))
                sys.argv = [str(config.backend), '--bind', address, '--port', str(port), '--data', str(config.folder / 'jobs'),
                            '--session', str(config.session), '--ffmpeg', str(config.ffmpeg), '--lifetime-seconds', '0']
                runpy.run_path(str(config.backend), run_name='__main__')
                return 0
            except Exception:
                import traceback
                traceback.print_exc()
                return 1

class OwnedChild:
    """This kill-on-close job contains only our new child and its workers."""
    def __init__(self, config, address):
        from download_worker import windows_child_job
        self.job, self.process = windows_child_job(), None
        try:
            self.process = subprocess.Popen(config.command('--serve', '--bind', address), cwd=config.root,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if not self.job[0].AssignProcessToJobObject(self.job[1], int(self.process._handle)):
                import ctypes
                raise ctypes.WinError(ctypes.get_last_error())
        except Exception:
            self.close()
            raise

    def poll(self):
        return self.process.poll()

    def close(self):
        if self.job:
            self.job[0].CloseHandle(self.job[1]); self.job = None
        if self.process is not None:
            if self.process.poll() is None: self.process.kill()
            self.process.wait(timeout=10)

class Supervisor:
    """One step every five seconds, with injectable dependencies for offline tests."""
    def __init__(self, config, bind=None, *, clock=time.monotonic, detector=detect_lan,
                 health=ready, spawn=OwnedChild):
        self.config, self.bind = config, bind
        self.clock, self.detector, self.health, self.spawn = clock, detector, health, spawn
        self.child, self.address, self.started = None, None, 0
        self.failures, self.next_start, self.state = 0, 0, None

    def set_state(self, state):
        if self.state != state:
            print(datetime.now(timezone.utc).isoformat(), state, flush=True)
            self.state = state

    def close(self):
        if self.child is not None:
            child, self.child = self.child, None
            child.close()

    def step(self):
        now = self.clock()
        try:
            address = lan_address(self.bind) if self.bind else self.detector()
        except (OSError, ValueError):
            address = None
        if self.child is not None:
            exited = self.child.poll() is not None
            if exited or address != self.address:
                self.close()
                if exited:
                    self.failures += 1
                    self.next_start = now + min(60, 2 ** min(self.failures, 6))
                else:
                    self.failures, self.next_start = 0, now
                self.set_state('Relance du compagnon en attente.' if address else 'En attente du réseau local.')
            elif now - self.started >= 60:
                self.failures = 0
        if not address:
            self.set_state('En attente du réseau local.'); return
        if self.child is not None or now < self.next_start: return
        _, previous, port, token = paired_session(self.config)
        if previous == address and self.health(address, port, token):
            self.set_state('Compagnon existant disponible ; aucun autre processus lancé.'); return
        self.address = address
        try:
            self.child = self.spawn(self.config, address)
            self.started = now
            self.set_state('Compagnon démarré ; surveillance active.')
        except OSError:
            self.failures += 1
            self.next_start = now + min(60, 2 ** min(self.failures, 6))
            self.set_state('Démarrage indisponible ; nouvelle tentative différée.')

def resident(config, address=None):
    with resident_lock(config) as acquired:
        if not acquired: return 0
        issues, _ = installation(config)
        if issues: return 1  # In particular, never create a missing pairing session.
        with logs(config):
            supervisor = Supervisor(config, address)
            try:
                while True:
                    supervisor.step()
                    time.sleep(5)
            except KeyboardInterrupt:
                return 0
            except Exception:
                print('Superviseur arrêté ; vérifie la session et les fichiers du compagnon.', file=sys.stderr)
                return 1
            finally:
                supervisor.close()

def main(argv=None, defaults=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=defaults.root if defaults else None)
    parser.add_argument('--folder', type=Path, default=defaults.folder if defaults else None)
    parser.add_argument('--check', action='store_true', help='Vérifier sans lancer ni modifier la session.')
    parser.add_argument('--json', action='store_true', help='Diagnostic sans clé ni lien privé.')
    parser.add_argument('--show-link', action='store_true', help='Afficher le lien privé seulement dans cette fenêtre.')
    parser.add_argument('--bind', type=lan_address, help='Adresse LAN explicite en cas de plusieurs interfaces réseau.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--resident', action='store_true')
    mode.add_argument('--serve', action='store_true', help=argparse.SUPPRESS)
    mode.add_argument('--startup-enable', action='store_true')
    mode.add_argument('--startup-disable', action='store_true')
    args = parser.parse_args(argv)
    if args.root is None: parser.error('--root est nécessaire (dossier contenant work/offline-tools).')
    config = Config.workspace(args.root, args.folder)
    if args.check:
        report = inspect(config, args.bind)
        print(json.dumps(report, ensure_ascii=False, indent=2) if args.json else
              ('PC connecté.' if report['ready'] else 'Compagnon PC arrêté.') + '\n' +
              '\n'.join(report['issues'] or ['Installation prête ; aucun service lancé.']))
        return 1 if report['issues'] else 0
    if args.startup_enable or args.startup_disable:
        if args.startup_enable:
            issues, _ = installation(config)
            if issues: print('\n'.join(issues)); return 1
        try:
            result = startup(config, 'enable' if args.startup_enable else 'disable')
        except (OSError, ValueError, subprocess.SubprocessError):
            print("Le raccourci n'a pas été modifié. Vérifie les permissions Windows et une éventuelle entrée portant déjà ce nom.")
            return 1
        print(json.dumps(result) if args.json else ('Démarrage Windows activé.' if result['enabled'] else 'Démarrage Windows désactivé.'))
        return 0
    if args.serve:
        if not args.bind: parser.error('--serve nécessite --bind')
        return serve(config, args.bind)
    if args.resident: return resident(config, args.bind)
    report = inspect(config, args.bind)
    issues = [issue for issue in report['issues'] if issue != NETWORK_ISSUE]
    if issues: print('\n'.join(issues)); return 1
    if not report['resident']:
        command = config.command('--resident')
        if args.bind: command += ['--bind', args.bind]
        subprocess.Popen(command, cwd=config.root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    for _ in range(12):
        try:
            address = args.bind or detect_lan()
            _, current, port, token = paired_session(config)
            if address == current and ready(address, port, token):
                print("PC prêt. Garde le PC allumé et l'iPhone sur le même réseau local.")
                break
        except (OSError, ValueError):
            pass
        time.sleep(1)
    else:
        if not resident_running(config):
            print('Le superviseur ne répond pas. Consulte les journaux du compagnon.'); return 1
        print('Le superviseur est actif ; le compagnon attend le réseau ou termine son démarrage.')
    if args.show_link:
        print('Lien privé à copier dans « Connecter le PC » :\n' + paired_session(config)[0]['url'])
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
