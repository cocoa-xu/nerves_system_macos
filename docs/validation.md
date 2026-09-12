# Validation

Validated on September 13, 2026, on an Apple M4 Pro Mac mini running macOS 27.0
(26A5425a), with Tart 2.36.0, Elixir 1.20.4, and host OTP 29.0.6.

| Component | Result |
| --- | --- |
| Guest | macOS 26.6.2, build 25G83, arm64 |
| Runtime input | OTP 29.0.2, ERTS 17.0.2, `arm64-apple-darwin` |
| OpenSSL reported by crypto | OpenSSL 3.6.3, 9 Jun 2026 |
| Download | SHA-256 verified; exact extracted OTP version checked |
| System build | Built through the Nerves system package compiler and artifact cache |
| Native compilation | C NIF built with the Darwin SDK and artifact ERTS headers |
| Firmware | Release installed and all expected applications checked over local RPC |
| Boot persistence | Two cold boots of an independent firmware copy passed |
| Guest settings | admin account/full name/password, en_US, en-US, U.S. keyboard |
| Static checks | Formatting, compilation without warnings, Bash syntax |
| Automated tests | Eighteen ExUnit tests and eight Python tests passed |

The example's NIF reported Darwin/arm64 from inside the guest. Each verified boot
produced a new application boot ID, while preserving the previous boot records.
The running release reported ERTS 17.0.2 and OpenSSL 3.6.3 through RPC. Both
verification boots ended with a clean guest shutdown.

The build and verification required no GUI interaction, screenshots, or OCR.
They used private Tart homes and new VM names and MAC addresses. Original base
VMs remained stopped and unchanged. Temporary VM copies were removed after
verification.

The system's sparse archive writer was checked by extracting a sparse test disk
and checking its logical size and compressed archive size. A full macOS system
archive was not compressed and redistributed during this validation.

This validation covers the macOS 26 application workflow. macOS 15 and 27 guest
runtimes, VirtualBuddy import, physical Mac installation, production OTA updates,
and Linux-specific Nerves runtime packages are outside these results.

## Base selection

The `macos26` target built a system from a local base pinned by SHA-256. The build
checked macOS 26.6.2/25G83, the admin account, English/U.S. settings, and the absence
of a Nerves application. The guest shut down cleanly. Nerves then assembled the
native hello release with OTP 29.0.2. A second release build reused the system
artifact and rebuilt the C NIF for the selected deployment target without starting
a VM or acquiring the base again.

A 16 MiB test disk exercised the prebuilt provider through a real Tart push and
import. The test registry required anonymous Bearer authentication. Elixir/OTP
downloaded and verified the manifest and blobs before Tart imported them from
loopback. Altering a blob caused a SHA-256 failure, and both paths removed their
temporary caches. A separate HTTPS check fetched a GHCR token and manifest using
an explicit PEM CA bundle; it did not download image blobs.

The local builder test checked executable and Git revision pins, rejected modified
inputs, and removed its temporary output. It did not restore an IPSW. Native-file
checks accepted a macOS 26 extension for the macOS 26 target and rejected it for
macOS 15. Selection and cache tests cover all three majors; they do not replace
guest boot tests.

The temporary selected-system artifact and release were removed after validation.
The original base VMs and previously verified system and firmware were retained.

## Layer distribution

The [layer experiment](../experiments/layers/README.md) also passed on this host.
It published a macOS base, a jq 1.8.1 dependency layer, and sibling application
1.0.0 and 2.0.0 layers through a loopback OCI registry. A separate consumer Tart
home started with an empty cache. The complete run passed without restarting
any build or download phase.

| Consumer operation | HTTP blob payload | Blob GET requests | Base/dependency disk GET requests |
| --- | ---: | ---: | ---: |
| First installation of 1.0.0 | 25,944,336,354 bytes (24.16 GiB) | 156 | 152 |
| Update to 2.0.0 | 363,592,182 bytes (346.75 MiB) | 4 | 0 |
| Cached rollback to 1.0.0 | 0 bytes | 0 | 0 |

The update downloaded two application disk chunks, the VM configuration, and
NVRAM. It reused the complete base and dependency disk files. The application
disk chunks totalled 330,012,509 bytes; they include macOS provisioning writes
as well as the application release. This run reduced blob transfer by about
98.6% compared with the initial installation.

All three consumer boots passed guest identity, launchd health, running release
version, native NIF, crypto, SSL and jq checks. One host directory was shared
with all versions. A value written under 1.0.0 survived the update and rollback,
and exactly three persistent boot records contained the expected versions and
distinct boot identifiers. Every guest shut down cleanly.

Measurements count actual blob response bodies, including VM configuration and
NVRAM. They exclude OCI manifest responses, HTTP headers and transport overhead.
These are independent caches on one physical host, not a WAN speed or separate
physical host benchmark. The data volume is a shared host directory, and
switching versions replaces the running VM; this is not an in-place macOS update.

The [machine-readable result](../experiments/layers/results/macos-26.json)
records the environment, byte counts, immutable manifest digests and boot IDs.
The resumable runner was checked after completion without rerunning the VM
phases. Cleanup then removed all experiment VMs, registry blobs, private caches,
temporary releases and the earlier tiny-disk probe. Original bases and the
previously verified native firmware were retained.

To reproduce, follow the runtime download and example build steps in
[`README.md`](../README.md), then run `mix nerves.macos.verify` on the completed
firmware directory. `make validate` runs the checks that do not require a VM.
