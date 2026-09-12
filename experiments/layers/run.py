import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import threading
import time
import uuid

from registry import Registry

ROOT = pathlib.Path(__file__).resolve().parents[2]
JQ_SHA256 = "a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603"


def downloaded(events):
    return [event for event in events if event["method"] == "GET"
            and "/blobs/" in event["path"] and event["status"] in (200, 206)]


def disk_layers(manifest):
    return [layer for layer in manifest["layers"] if ".disk." in layer["mediaType"]]


def verify_layout(manifests):
    layers = {tag: disk_layers(manifest) for tag, manifest in manifests.items()}
    for parent, child in (("base", "dependency"), ("dependency", "v1"), ("dependency", "v2")):
        parent_ids = [layer["digest"] for layer in layers[parent]]
        child_ids = [layer["digest"] for layer in layers[child]]
        if not parent_ids or child_ids[:len(parent_ids)] != parent_ids or len(child_ids) <= len(parent_ids):
            raise AssertionError(f"{child} does not extend the unchanged {parent} disk layers")
    if layers["v1"] == layers["v2"]:
        raise AssertionError("Application versions have identical disk layers")
    base = sum(layer["size"] for layer in layers["base"])
    dependency = sum(layer["size"] for layer in layers["dependency"])
    return {"base_disk_bytes": base, "dependency_disk_bytes": dependency - base,
            "v1_application_disk_bytes": sum(layer["size"] for layer in layers["v1"]) - dependency,
            "v2_application_disk_bytes": sum(layer["size"] for layer in layers["v2"]) - dependency}


class Experiment:
    def __init__(self, args):
        self.args = args
        for key in ("system", "release_v1", "release_v2", "dependency"):
            setattr(args, key, getattr(args, key).resolve())
        self.work = args.workdir.resolve()
        self.state_file = self.work / "state.json"
        inputs = {key: str(getattr(args, key).resolve())
                  for key in ("system", "release_v1", "release_v2", "dependency")}
        if args.resume:
            self.state = json.loads(self.state_file.read_text())
            if self.state.get("cleaned"):
                raise ValueError("A cleaned experiment cannot be resumed")
            if self.state["inputs"] != inputs:
                raise ValueError("Resume inputs differ from the original experiment")
        else:
            if shutil.disk_usage(self.work.parent).free < 120 * 1024**3:
                raise RuntimeError("A new experiment requires at least 120 GiB free")
            self.work.mkdir(parents=True, exist_ok=False)
            self.state = {"inputs": inputs, "completed": [], "measurements": {}, "vms": []}
        self.registry = Registry(self.work / "registry", self.state.get("port", 0), args.resume)
        self.state["port"] = self.registry.server_port
        self.address = f"127.0.0.1:{self.registry.server_port}"
        self.remote = self.address + "/nerves/macos"
        self.metadata = json.loads((args.system / "nerves-macos.json").read_text())
        self.save()

    def save(self):
        temporary = self.state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, indent=2) + "\n")
        temporary.replace(self.state_file)

    def environment(self, role):
        env = dict(os.environ)
        env.update(TART_HOME=str(self.work / role), TART_NO_AUTO_PRUNE="1", CI="true",
                   TART_REGISTRY_USERNAME="local", TART_REGISTRY_PASSWORD="local",
                   TART_REGISTRY_HOSTNAME=self.address, GUEST_USERNAME="admin", SSHPASS="admin",
                   EXPECTED_VERSION=self.metadata["macos_version"],
                   EXPECTED_BUILD=self.metadata["macos_build"])
        return env

    def command(self, arguments, role="producer", timeout=1200):
        print("Running:", " ".join(map(str, arguments)), flush=True)
        subprocess.run(["/usr/bin/python3", ROOT / "priv/scripts/run-command.py",
                        str(timeout * 1000), *map(str, arguments)],
                       env=self.environment(role), check=True)

    def phase(self, name, operation):
        if name in self.state["completed"]:
            print("Already completed:", name, flush=True)
            return
        if shutil.disk_usage(self.work).free < 35 * 1024**3:
            raise RuntimeError("Less than 35 GiB free; refusing another experiment phase")
        print("Starting phase:", name, flush=True)
        operation()
        self.state["completed"].append(name)
        self.save()

    def name(self, role, label):
        name = f"nerves-layers-{label}-{uuid.uuid4().hex[:8]}"
        self.state["vms"].append({"role": role, "name": name})
        self.save()
        return name

    def clone(self, role, tag, label, stacked=False):
        name = self.name(role, label)
        args = ["tart", "clone", self.remote + ":" + tag, name, "--insecure", "--concurrency", "2"]
        if stacked:
            args.append("--stacked")
        self.command(args, role)
        self.command(["tart", "set", name, "--cpu", "4", "--memory", "4096"], role)
        return name

    def push(self, name, tag):
        self.command(["tart", "push", name, self.remote + ":" + tag,
                      "--insecure", "--concurrency", "2", "--populate-cache"])

    def manifest(self, tag):
        key = hashlib.sha256(f"nerves/macos:{tag}".encode()).hexdigest()
        return json.loads((self.work / "registry/manifests" / key).read_text())

    def guest(self, role, name, script, archive="", data=""):
        session = self.work / "sessions" / uuid.uuid4().hex
        session.mkdir(parents=True)
        script_path = session / "guest.sh"
        script_path.write_text((ROOT / "priv/guest/verify-system.sh").read_text() + "\n" + script)
        self.command(["/bin/bash", ROOT / "priv/scripts/provision.sh", name, session,
                      script_path, archive, data], role, timeout=480)

    def volume(self, name):
        directory = self.work / name
        directory.mkdir(exist_ok=True)
        (directory / ".nerves-volume").touch()
        return directory

    def base(self):
        source = self.args.system / "system.tart"
        opened = subprocess.run(["/usr/sbin/lsof", "-t", str(source / "disk.img")],
                                capture_output=True, timeout=10)
        if opened.returncode != 1 or opened.stdout:
            raise RuntimeError("The source disk is open or its cold state cannot be confirmed")
        name = self.name("producer", "base")
        target = self.work / "producer/vms" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        self.command(["/bin/cp", "-cR", source, target])
        self.command(["tart", "set", name, "--random-mac"])
        self.push(name, "base")

    def dependency(self):
        if hashlib.sha256(self.args.dependency.read_bytes()).hexdigest() != JQ_SHA256:
            raise ValueError("The jq binary does not match the pinned upstream checksum")
        archive = self.work / "dependency.tar.gz"
        self.command(["gtar", "-czf", archive, "-C", self.args.dependency.parent, "jq"])
        name = self.clone("producer", "base", "dependency", stacked=True)
        self.guest("producer", name, """
test ! -e /usr/local/bin/jq
mkdir /tmp/nerves-dependency
tar -xzf /tmp/nerves-release.tar.gz -C /tmp/nerves-dependency
sudo -n mkdir -p /usr/local/bin
sudo -n install -m 755 /tmp/nerves-dependency/jq /usr/local/bin/jq
rm -rf /tmp/nerves-dependency /tmp/nerves-release.tar.gz
test "$(/usr/local/bin/jq --version)" = jq-1.8.1
echo 'Verified dependency jq-1.8.1'
""", archive)
        self.push(name, "dependency")

    def application(self, tag, release):
        archive = self.work / f"{tag}.tar.gz"
        self.command(["gtar", "-czf", archive, "-C", release, "."])
        name = self.clone("producer", "dependency", "build-" + tag)
        script = (ROOT / "priv/guest/install-release.sh").read_text()
        script += "\n" + (ROOT / "priv/guest/verify-release.sh").read_text()
        self.guest("producer", name, script, archive, self.volume("build-data-" + name))
        self.push(name, tag)

    def consume(self, tag, label, version):
        start = len(self.registry.events)
        began = time.monotonic()
        name = self.clone("consumer", tag, label)
        events = downloaded(self.registry.events[start:])
        base_digests = {layer["digest"] for layer in self.manifest("dependency")["layers"]
                        if ".disk." in layer["mediaType"]}
        reused_downloads = [event for event in events if event["path"].split("/")[-1] in base_digests]
        if label != "first-install" and reused_downloads:
            raise AssertionError("An unchanged base or dependency disk blob was downloaded")
        if label == "rollback" and any("/blobs/" in event["path"] for event in events):
            raise AssertionError("The cached rollback downloaded blobs")
        measurement = {"blob_bytes": sum(event["bytes"] for event in events),
                       "blob_requests": len(events), "elapsed_seconds": round(time.monotonic() - began, 2),
                       "unchanged_disk_blob_requests": len(reused_downloads), "events": events}
        self.state["measurements"].setdefault(label, measurement)
        self.save()
        print("Download measurement:", json.dumps(measurement), flush=True)
        script = (ROOT / "priv/guest/verify-release.sh").read_text()
        script += f"""
test "$(/usr/local/bin/jq --version)" = jq-1.8.1
test "$(/usr/local/bin/jq -r .version /opt/nerves/app/nerves-release.json)" = {version}
data='/Volumes/My Shared Files/nerves-data'
test -f "$data/.nerves-volume"
"$root/bin/$name" rpc '"{version}" = System.get_env("RELEASE_VSN"); IO.puts("Verified running release {version}")'
"""
        if label == "first-install":
            script += 'printf "persistent-user-value\\n" > "$data/user-value.txt"\n'
        else:
            script += 'test "$(cat "$data/user-value.txt")" = persistent-user-value\n'
        self.guest("consumer", name, script, data=self.volume("consumer-data"))

    def run(self):
        thread = threading.Thread(target=self.registry.serve_forever, daemon=True)
        thread.start()
        try:
            self.phase("base", self.base)
            self.phase("dependency", self.dependency)
            self.phase("v1", lambda: self.application("v1", self.args.release_v1))
            self.phase("v2", lambda: self.application("v2", self.args.release_v2))
            self.state["layers"] = verify_layout({tag: self.manifest(tag)
                                                 for tag in ("base", "dependency", "v1", "v2")})
            self.save()
            self.phase("first-install", lambda: self.consume("v1", "first-install", "1.0.0"))
            self.phase("update", lambda: self.consume("v2", "update", "2.0.0"))
            self.phase("rollback", lambda: self.consume("v1", "rollback", "1.0.0"))
            lines = (self.work / "consumer-data/boot.txt").read_text().splitlines()
            if len(lines) != 3 or any(f"release {version};" not in line
                                    for line, version in zip(lines, ("1.0.0", "2.0.0", "1.0.0"))):
                raise AssertionError(f"Unexpected persistent boot records: {lines}")
            if len({line.split("boot ")[-1] for line in lines}) != 3:
                raise AssertionError("Boot identifiers were reused")
            self.state["boot_records"] = lines
            self.state["passed"] = True
            self.save()
            print("LAYERED INSTALL, UPDATE AND ROLLBACK PASSED", flush=True)
        finally:
            for vm in self.state["vms"]:
                subprocess.run(["tart", "stop", vm["name"]], env=self.environment(vm["role"]),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            self.registry.shutdown()
            self.registry.server_close()
            thread.join(timeout=5)


def cleanup(work):
    work = work.resolve()
    state = json.loads((work / "state.json").read_text())
    if not state.get("passed") or not (work / "registry/.layer-experiment").is_file():
        raise ValueError("Cleanup requires a completed, owned experiment")
    for vm in state["vms"]:
        if vm["role"] not in ("producer", "consumer") or not vm["name"].startswith("nerves-layers-"):
            raise ValueError("Unexpected VM ownership record")
        home = work / vm["role"]
        env = dict(os.environ, TART_HOME=str(home), TART_NO_AUTO_PRUNE="1")
        result = subprocess.run(["tart", "stop", vm["name"]], env=env, timeout=15,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode not in (0, 2):
            raise RuntimeError("Cannot confirm the experiment VM is stopped")
        for disk in (home / "vms" / vm["name"]).glob("*.*"):
            if disk.suffix not in (".img", ".asif"):
                continue
            opened = subprocess.run(["/usr/sbin/lsof", "-t", str(disk)], capture_output=True, timeout=10)
            if opened.returncode != 1 or opened.stdout:
                raise RuntimeError("An experiment disk is still open")
    for name in ("producer", "consumer", "registry/blobs", "registry/uploads"):
        directory = work / name
        if directory.exists():
            shutil.rmtree(directory)
    for archive in work.glob("*.tar.gz"):
        archive.unlink()
    for directory in work.glob("build-data-nerves-layers-*"):
        shutil.rmtree(directory)
    state["cleaned"] = True
    (work / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    print("Removed experiment disks, caches and blob storage; retained measurements and logs")


def main():
    parser = argparse.ArgumentParser(description="Measure Tart layer reuse and persistent application data")
    for flag in ("system", "release-v1", "release-v2", "dependency"):
        parser.add_argument("--" + flag, type=pathlib.Path)
    parser.add_argument("--workdir", type=pathlib.Path, required=True)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    if args.cleanup:
        cleanup(args.workdir)
        return
    if not all((args.system, args.release_v1, args.release_v2, args.dependency)):
        parser.error("A run requires --system, --release-v1, --release-v2 and --dependency")
    Experiment(args).run()


if __name__ == "__main__":
    main()
