"""Contract and file-boundary tests; no music downloads and no external server."""
import importlib.util
import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location("local_library", Path(__file__).with_name("local-library.py"))
library = importlib.util.module_from_spec(spec)
spec.loader.exec_module(library)


class LibraryTest(unittest.TestCase):
    def test_lan_only(self):
        for value in ["10.0.0.1", "172.16.1.2", "172.31.255.254", "192.168.1.148"]:
            self.assertEqual(library.lan_address(value), value)
        for value in ["127.0.0.1", "0.0.0.0", "8.8.8.8", "172.32.0.1", "169.254.1.2", "example.com"]:
            with self.assertRaises(ValueError):
                library.lan_address(value)

    def test_manifest_and_exact_file_routes(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "audio.mp3"
            content = b"test file bytes - not used as real audio"
            file.write_bytes(content)
            ident = library.hashlib.sha256(content).hexdigest()
            manifest = {"version": 1, "tracks": [{"id": ident}]}
            files = {ident: (file.resolve(), len(content), file.stat().st_mtime_ns)}
            token = "A" * 32
            server = library.ThreadingHTTPServer(("127.0.0.1", 0), library.BaseHTTPRequestHandler)
            port = server.server_port
            server.RequestHandlerClass = library.handler_for(manifest, files, "127.0.0.1", port, token)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{port}/{token}"
            try:
                with urlopen(base + "/manifest") as response:
                    self.assertEqual(json.load(response), manifest)
                with urlopen(base + "/file/" + ident) as response:
                    self.assertEqual(response.read(), content)
                for path in ["/../audio.mp3", "/file/../audio.mp3", "/file/" + "0"*64, "/manifest?x=1"]:
                    with self.assertRaises(HTTPError) as caught:
                        urlopen(base + path)
                    self.assertEqual(caught.exception.code, 404)
                with self.assertRaises(HTTPError):
                    urlopen(Request(base + "/manifest", headers={"Host": "external.example"}))
                # A modified file cannot silently be served under an earlier digest.
                file.write_bytes(content + b"changed")
                with self.assertRaises(HTTPError) as caught:
                    urlopen(base + "/file/" + ident)
                self.assertEqual(caught.exception.code, 409)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def test_invalid_audio_not_offered(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "bad.mp3").write_bytes(b"not audio" * 200)
            manifest, files, rejected = library.index_library(directory)
            self.assertEqual(manifest["tracks"], [])
            self.assertFalse(files)
            self.assertEqual(rejected, ["bad.mp3"])


if __name__ == "__main__":
    unittest.main()
