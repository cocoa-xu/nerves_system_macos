import hashlib
import http.client
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1] / "experiments/layers/registry.py"
spec = importlib.util.spec_from_file_location("layer_registry", MODULE)
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)


class RegistryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.server = registry.Registry(pathlib.Path(self.temporary.name) / "registry")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temporary.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def upload(self, data):
        status, headers, _ = self.request("POST", "/v2/test/image/blobs/uploads/")
        self.assertEqual(status, 202)
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        status, _, _ = self.request("PUT", headers["Location"] + "?digest=" + digest, data)
        self.assertEqual(status, 201)
        return "/v2/test/image/blobs/" + digest

    def test_chunked_upload_range_and_head(self):
        _, headers, _ = self.request("POST", "/v2/test/image/blobs/uploads/")
        location = headers["Location"]
        self.assertEqual(self.request("PATCH", location, b"hello ")[0], 202)
        digest = "sha256:" + hashlib.sha256(b"hello world").hexdigest()
        self.assertEqual(self.request("PUT", location + "?digest=" + digest, b"world")[0], 201)
        path = "/v2/test/image/blobs/" + digest
        status, headers, body = self.request("HEAD", path)
        self.assertEqual((status, headers["Content-Length"], body), (200, "11", b""))
        status, headers, body = self.request("GET", path, headers={"Range": "bytes=6-"})
        self.assertEqual((status, body), (206, b"world"))
        self.assertEqual(headers["Content-Range"], "bytes 6-10/11")
        self.assertEqual(self.request("GET", path, headers={"Range": "bytes=11-"})[0], 416)

    def test_rejects_incorrect_digest(self):
        _, headers, _ = self.request("POST", "/v2/test/image/blobs/uploads/")
        digest = "sha256:" + "0" * 64
        self.assertEqual(self.request("PUT", headers["Location"] + "?digest=" + digest, b"bad")[0], 400)
        self.assertEqual(self.request("GET", "/v2/test/image/blobs/" + digest)[0], 404)

    def test_manifest_digest_lookup_and_payload_accounting(self):
        path = self.upload(b"123456789")
        self.assertEqual(self.request("GET", path)[2], b"123456789")
        data = json.dumps({"schemaVersion": 2, "layers": []}).encode()
        status, headers, _ = self.request("PUT", "/v2/test/image/manifests/v1", data)
        self.assertEqual(status, 201)
        self.assertEqual(self.request("GET", "/v2/test/image/manifests/" + headers["Docker-Content-Digest"])[2], data)
        self.server.shutdown()
        events = [json.loads(line) for line in (self.server.root / "requests.jsonl").read_text().splitlines()]
        downloads = [event for event in events if event["method"] == "GET" and "/blobs/" in event["path"]]
        self.assertEqual(sum(event["bytes"] for event in downloads), 9)

    def test_refuses_to_resume_an_unowned_directory(self):
        with self.assertRaises(ValueError):
            registry.Registry(self.temporary.name, resume=True)


if __name__ == "__main__":
    unittest.main()
