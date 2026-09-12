# Layer distribution experiment

This experiment builds a macOS base, a dependency layer containing pinned jq,
and two sibling application layers. It uses real Tart OCI push and clone commands
against an instrumented registry bound to `127.0.0.1`. Separate producer and
consumer Tart homes provide independent caches on one physical Mac.

```text
macOS base
  └── jq 1.8.1
       ├── application 1.0.0
       └── application 2.0.0

Consumer: 1.0.0 → 2.0.0 → 1.0.0
              shared application data
```

The experiment measures actual HTTP blob response payloads for installation,
update and rollback. It rejects an update that downloads an unchanged base or
dependency disk blob, and rejects a cached rollback that downloads any blob.
Every deployed version must boot and pass application RPC, native NIF, crypto,
SSL, dependency, guest identity and persistent-data checks.

## Requirements

- An Apple silicon host running macOS 27 with DiskImageKit support in Tart.
- Tart 2.36.0, Python 3.9 or later, GNU tar, and sshpass.
- A verified system artifact and the example's dependencies already built.
- At least 120 GiB of free APFS space for temporary distribution storage.

The ordinary raw firmware workflow remains available on macOS 26 hosts. This
experiment requires macOS 27 on the host even when the guest runs macOS 26.
It does not flatten the image for older hosts or other VM applications.

## Run

Build the system and native example as described in the root README first.
From the repository root, create a new input directory and download jq using an
explicit PEM CA bundle:

```sh
mkdir -p .nerves/layer-inputs/dependency
curl --fail --location --cacert /opt/homebrew/etc/openssl@3/cert.pem \
  https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-macos-arm64 \
  --output .nerves/layer-inputs/dependency/jq
chmod 755 .nerves/layer-inputs/dependency/jq
```

The runner requires SHA-256
`a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603`,
published for the [jq 1.8.1 arm64 release](https://github.com/jqlang/jq/releases/tag/jq-1.8.1).
jq retains its [upstream license](https://github.com/jqlang/jq/blob/jq-1.8.1/COPYING).

Build two releases from `examples/hello`:

```sh
MIX_TARGET=macos mix release hello_macos --version 1.0.0 \
  --path ../../.nerves/layer-inputs/v1
MIX_TARGET=macos mix release hello_macos --version 2.0.0 \
  --path ../../.nerves/layer-inputs/v2
```

From the repository root:

```sh
python3 experiments/layers/run.py \
  --system examples/system/.nerves/artifacts/nerves_system_macos_example-portable-0.1.0 \
  --release-v1 .nerves/layer-inputs/v1 \
  --release-v2 .nerves/layer-inputs/v2 \
  --dependency .nerves/layer-inputs/dependency/jq \
  --workdir .nerves/layer-experiment
```

The work directory must be new. Commands have deadlines, VM readiness uses
bounded polling, and Tart network concurrency is two. Completed phases are
recorded in `state.json`. To continue an interrupted run, repeat the command with
`--resume`, preserving all inputs and the work directory. The registry must be
able to bind its original port. A partially transferred phase may produce a
warm-cache measurement; use a new work directory for clean benchmark results.

The registry has no authentication challenge and uses explicit dummy Tart
credentials. It neither publishes externally nor invokes `tart login`. SSH
disables host configuration, agents and Keychain use. Only newly named VMs in
the private experiment homes are started or stopped.

After success, retain `state.json`, `registry/requests.jsonl`, and session logs,
then remove the large temporary disks and blob storage:

```sh
python3 experiments/layers/run.py --workdir .nerves/layer-experiment --cleanup
```

Cleanup requires a successful experiment and checks that its disks are closed.
It preserves measurements and consumer data. Remove the input releases when
they are no longer needed. Never delete a retained source VM to clean this run.

## What the result means

Tart's immutable disk files are addressed by content digest. Each application
image references the same base and dependency files. The consumer downloads
missing files and reconstructs the disk stack locally; unchanged parents stay
cached. Booting creates a private writable overlay. Updating starts a new VM
from the selected image, with downtime between versions.

The application data in this experiment is a host directory exposed through
Tart's directory sharing at `/Volumes/My Shared Files/nerves-data`. It is not a
separate block volume. The example requires a mount sentinel and writes boot
records there. A value written under v1 must survive v2 and rollback to v1.
Only application data survives this switch; writes elsewhere in a deployed VM
are not merged into its replacement.

An application disk layer also contains macOS writes made during provisioning,
including logs and filesystem metadata. Its transfer size is not just the size
of the changed application files. This is a disk-layer experiment, not a
reproducible package-level filesystem builder.

The registry is a local test fixture. The results cover independent caches on
one Mac. Production deployment, automatic rollback and a dependency recipe API
remain unimplemented. The controller currently uses Python; production
orchestration will move to Elixir and the Nerves build interfaces.

See [Tart's stacked-disk documentation](https://github.com/cirruslabs/tart/blob/main/docs/quick-start.md)
and [Apple DiskImageKit](https://developer.apple.com/documentation/diskimagekit).
