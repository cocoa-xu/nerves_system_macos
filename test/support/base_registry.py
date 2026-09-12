import hashlib
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "experiments/layers"))
from registry import Registry

root = pathlib.Path(sys.argv[1])
registry = Registry(root / "registry")
thread = threading.Thread(target=registry.serve_forever, daemon=True)
thread.start()
try:
    home = root / "publisher"
    name = "nerves-base-registry-fixture"
    vm = home / "vms" / name
    vm.mkdir(parents=True)
    identity = subprocess.check_output(
        ["/usr/bin/swift", str(pathlib.Path(__file__).with_name("base_identity.swift"))],
        text=True, timeout=30
    ).strip()
    (vm / "config.json").write_text(json.dumps({
        "version": 1, "os": "darwin", "arch": "arm64", "cpuCount": 2, "cpuCountMin": 2,
        "memorySize": 4294967296, "memorySizeMin": 4294967296,
        "macAddress": "02:00:00:00:00:01", "displayRefit": False, "diskFormat": "raw",
        "display": {"width": 1024, "height": 768}, "ecid": identity,
        "hardwareModel": "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc"
    }))
    (vm / "nvram.bin").write_bytes(b"fixture")
    with (vm / "disk.img").open("wb") as stream:
        stream.truncate(16 * 1024 * 1024)
    host = f"127.0.0.1:{registry.server_port}"
    env = dict(os.environ, TART_HOME=str(home), TART_NO_AUTO_PRUNE="1", CI="true",
               TART_REGISTRY_USERNAME="unused", TART_REGISTRY_PASSWORD="unused", TART_REGISTRY_HOSTNAME=host)
    subprocess.run(["tart", "push", name, host + "/test/base:fixture", "--insecure", "--concurrency", "2"],
                   env=env, check=True, timeout=45)
    manifest = (registry.root / "manifests" / hashlib.sha256(b"test/base:fixture").hexdigest()).read_bytes()
    reference = host + "/test/base@sha256:" + hashlib.sha256(manifest).hexdigest()
    registry.require_bearer = True
    (root / "ready.json").write_text(json.dumps({"reference": reference}))
    deadline = time.monotonic() + 90
    while not (root / "stop").exists() and time.monotonic() < deadline:
        time.sleep(0.1)
finally:
    registry.shutdown()
    registry.server_close()
    thread.join(timeout=5)
