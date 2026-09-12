import hashlib
import json
import pathlib
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Registry(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, root, port=0, resume=False):
        self.root = pathlib.Path(root)
        if resume:
            if not (self.root / ".layer-experiment").is_file():
                raise ValueError("The registry is not an owned experiment")
        else:
            self.root.mkdir(parents=True, exist_ok=False)
            (self.root / ".layer-experiment").touch()
            for name in ("blobs", "manifests", "uploads"):
                (self.root / name).mkdir()
        self.events = []
        self.events_lock = threading.Lock()
        super().__init__(("127.0.0.1", port), Handler)

    def record(self, method, path, status, size):
        event = {"method": method, "path": path, "status": status, "bytes": size}
        with self.events_lock:
            self.events.append(event)
            with (self.root / "requests.jsonl").open("a") as stream:
                stream.write(json.dumps(event) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(120)

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.read()

    def do_HEAD(self):
        self.read()

    def read(self):
        path = urlsplit(self.path).path
        if path == "/v2/":
            return self.respond(200, b"{}")
        match = re.fullmatch(r"/v2/([a-z0-9_/-]+)/(blobs|manifests)/([a-zA-Z0-9_:.-]+)", path)
        if not match:
            return self.respond(404)
        repository, kind, reference = match.groups()
        if kind == "blobs":
            if not re.fullmatch(r"sha256:[a-f0-9]{64}", reference):
                return self.respond(400)
            file = self.server.root / "blobs" / reference
            media = "application/octet-stream"
        else:
            key = hashlib.sha256(f"{repository}:{reference}".encode()).hexdigest()
            file = self.server.root / "manifests" / key
            media = "application/vnd.oci.image.manifest.v1+json"
        if not file.is_file():
            return self.respond(404)
        size = file.stat().st_size
        start = 0
        status = 200
        headers = {"Content-Type": media}
        if self.headers.get("Range"):
            match = re.fullmatch(r"bytes=(\d+)-", self.headers["Range"])
            if not match or int(match[1]) >= size:
                return self.respond(416)
            start = int(match[1])
            status = 206
            headers["Content-Range"] = f"bytes {start}-{size - 1}/{size}"
        self.send_response(status)
        self.send_header("Content-Length", str(size - start))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        sent = 0
        if self.command != "HEAD":
            with file.open("rb") as stream:
                stream.seek(start)
                while True:
                    data = stream.read(1024 * 1024)
                    if not data:
                        break
                    self.wfile.write(data)
                    sent += len(data)
        self.server.record(self.command, self.path, status, sent)

    def do_POST(self):
        match = re.fullmatch(r"/v2/([a-z0-9_/-]+)/blobs/uploads/", urlsplit(self.path).path)
        if not match:
            return self.respond(404)
        identifier = uuid.uuid4().hex
        (self.server.root / "uploads" / identifier).touch()
        self.respond(202, headers={"Location": self.path + identifier})

    def do_PATCH(self):
        self.write()

    def do_PUT(self):
        self.write()

    def write(self):
        url = urlsplit(self.path)
        upload = re.fullmatch(r"/v2/([a-z0-9_/-]+)/blobs/uploads/([a-f0-9]{32})", url.path)
        manifest = re.fullmatch(r"/v2/([a-z0-9_/-]+)/manifests/([a-zA-Z0-9_:.-]+)", url.path)
        if not upload and not manifest:
            return self.respond(404)
        if upload:
            file = self.server.root / "uploads" / upload[2]
            if not file.is_file():
                return self.respond(404)
        else:
            key = hashlib.sha256(f"{manifest[1]}:{manifest[2]}".encode()).hexdigest()
            file = self.server.root / "manifests" / key
        remaining = int(self.headers.get("Content-Length", "0"))
        with file.open("ab" if upload else "wb") as stream:
            while remaining:
                data = self.rfile.read(min(1024 * 1024, remaining))
                if not data:
                    raise ConnectionError("Incomplete upload")
                stream.write(data)
                remaining -= len(data)
        if upload and self.command == "PATCH":
            return self.respond(202, headers={"Location": url.path})
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            while True:
                data = stream.read(1024 * 1024)
                if not data:
                    break
                digest.update(data)
        reference = "sha256:" + digest.hexdigest()
        if upload:
            if parse_qs(url.query).get("digest") != [reference]:
                return self.respond(400, b"Digest mismatch")
            file.replace(self.server.root / "blobs" / reference)
            location = f"/v2/{upload[1]}/blobs/{reference}"
        else:
            key = hashlib.sha256(f"{manifest[1]}:{reference}".encode()).hexdigest()
            (self.server.root / "manifests" / key).write_bytes(file.read_bytes())
            location = url.path
        self.respond(201, headers={"Docker-Content-Digest": reference, "Location": location})

    def respond(self, status, body=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.server.record(self.command, self.path, status, 0 if self.command == "HEAD" else len(body))
