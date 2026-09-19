import hashlib
import hmac
import unittest
from companion_discovery import identity, discovery_reply


class DiscoveryTests(unittest.TestCase):
    def test_proof_binds_fresh_challenge_address_and_port(self):
        token, nonce = 'A' * 32, 'b' * 32
        result = discovery_reply('/discover?nonce=' + nonce, '192.168.1.8', 8768, token)
        expected = hmac.new(token.encode(), f'spoti-pc-v1\n{nonce}\n192.168.1.8\n8768'.encode(), hashlib.sha256).hexdigest()
        self.assertEqual(result['proof'], expected)
        self.assertNotIn(token, str(result))
        self.assertNotEqual(result['proof'], discovery_reply('/discover?nonce=' + 'c' * 32, '192.168.1.8', 8768, token)['proof'])
        self.assertNotEqual(result['proof'], discovery_reply('/discover?nonce=' + nonce, '192.168.1.9', 8768, token)['proof'])
        self.assertNotEqual(result['proof'], discovery_reply('/discover?nonce=' + nonce, '192.168.1.8', 8769, token)['proof'])
        self.assertNotEqual(result['proof'], discovery_reply('/discover?nonce=' + nonce, '192.168.1.8', 8768, 'B' * 32)['proof'])

    def test_rejects_malformed_public_challenges(self):
        for path in ('/discover', '/discover?nonce=x', '/discover?nonce=' + 'a' * 33,
                     '/discover?nonce=' + 'a' * 32 + '&nonce=' + 'b' * 32,
                     '/discover?nonce=' + 'a' * 32 + '&token=no', '/other?nonce=' + 'a' * 32,
                     'http://example.com/discover?nonce=' + 'a' * 32):
            self.assertIsNone(discovery_reply(path, '192.168.1.8', 8768, 'A' * 32))
        self.assertIsNone(discovery_reply('/discover?nonce=' + 'a' * 32, '8.8.8.8', 8768, 'A' * 32))

    def test_identifier_is_stable_and_has_no_secret(self):
        self.assertEqual(identity('A' * 32), hashlib.sha256(b'A' * 32).hexdigest())
        self.assertNotEqual(identity('A' * 32), identity('B' * 32))
        with self.assertRaises(ValueError):
            identity('invalid')


if __name__ == '__main__':
    unittest.main()
