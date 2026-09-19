"""Bonjour discovery without publishing the pairing credential.

The TXT identifier only filters services. A fresh HMAC challenge authenticates
the resolved address before an iPhone sends its private pairing path there.
"""
from contextlib import contextmanager
import hashlib
import hmac
import ipaddress
import re
import socket
from urllib.parse import urlsplit, parse_qs

SERVICE = '_spoti-pc._tcp.local.'


def identity(token):
    if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{32}', token):
        raise ValueError('Invalid pairing credential')
    return hashlib.sha256(token.encode('ascii')).hexdigest()


def discovery_reply(path, host, port, token):
    parsed = urlsplit(path)
    if parsed.path != '/discover' or parsed.fragment or parsed.netloc:
        return None
    values = parse_qs(parsed.query, keep_blank_values=True)
    nonce = values.get('nonce', [])
    if set(values) != {'nonce'} or len(nonce) != 1 or not re.fullmatch('[a-f0-9]{32}', nonce[0]):
        return None
    address = ipaddress.IPv4Address(host)
    if not any(address in ipaddress.ip_network(net) for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        return None
    if type(port) is not int or not 1024 <= port <= 65535:
        return None
    identity(token)
    message = f'spoti-pc-v1\n{nonce[0]}\n{host}\n{port}'.encode('ascii')
    return dict(service='spoti-auto-downloads', version=1, nonce=nonce[0], host=host, port=port,
                proof=hmac.new(token.encode('ascii'), message, hashlib.sha256).hexdigest())


@contextmanager
def advertise(host, port, token):
    """Failure to advertise must not break already-paired direct connections."""
    zeroconf, info = None, None
    try:
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
        ident = identity(token)
        zeroconf = Zeroconf(interfaces=[host], ip_version=IPVersion.V4Only)
        info = ServiceInfo(SERVICE, f'Spoti-PC-{ident[:16]}.{SERVICE}',
                           addresses=[socket.inet_aton(host)], port=port,
                           properties={'id': ident, 'v': '1'},
                           server=f'spoti-pc-{ident[:16]}.local.')
        zeroconf.register_service(info)
    except Exception as error:
        # Never print a credential or external exception text containing it.
        print('Découverte locale indisponible (' + type(error).__name__ + '). Le lien associé reste utilisable.', flush=True)
    try:
        yield
    finally:
        if zeroconf is not None:
            try:
                if info is not None:
                    zeroconf.unregister_service(info)
            finally:
                zeroconf.close()
