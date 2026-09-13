# Validation

Validated on September 13, 2026, on an Apple M4 Pro Mac mini running macOS 27.0
(26A5425a), with Tart 2.36.0, Elixir 1.20.4, and host OTP 29.0.6.

## macOS 26

| Component | Result |
| --- | --- |
| Guest | macOS 26.6.2, build 25G83, arm64 |
| Base image version | 0.1.0 (`26.6.2-25G83-v0.1.0`) |
| Runtime input | OTP 29.0.2, ERTS 17.0.2, `arm64-apple-darwin` |
| OpenSSL reported by crypto | OpenSSL 3.6.3, 9 Jun 2026 |
| Download | SHA-256 verified; exact extracted OTP version checked |
| System build | Built through the Nerves system package compiler and artifact cache |
| Native compilation | C NIF built with the Darwin SDK and artifact ERTS headers |
| Firmware | Release installed and all expected applications checked over local RPC |
| Boot persistence | Two cold boots of an independent firmware copy passed |
| Guest settings | admin account/full name/password, en_US, en-US, U.S. keyboard |
| Static checks | Formatting, compilation without warnings, Bash syntax |

The example's NIF reported Darwin/arm64 from inside the guest. Each verified boot
produced a new application boot ID, while preserving the previous boot records.
The running release reported ERTS 17.0.2 and OpenSSL 3.6.3 through RPC. Both
verification boots ended with a clean guest shutdown.

A cold boot exposed an early exit in the launchd readiness check: a missing job
caused `set -e` to exit before the retry loop could continue. The check now retries
within its existing 90-second deadline. Both cold boots passed after this fix.

The build and verification required no GUI interaction, screenshots, or OCR.
They used private Tart homes and new VM names and MAC addresses. Original base
VMs remained stopped and unchanged. Temporary VM copies were removed after
verification.

The system's sparse archive writer was checked by extracting a sparse test disk
and checking its logical size and compressed archive size. A full macOS system
archive was not compressed and redistributed during this validation.

The application workflow has also passed on macOS 15, as described below.
macOS 27 guest runtimes, VirtualBuddy import, physical Mac installation, production
OTA updates, and Linux-specific Nerves runtime packages are outside these results.

## Base selection

The `macos26` target built a system from a local base pinned by SHA-256. The build
checked macOS 26.6.2/25G83, the admin account, English/U.S. settings, and the absence
of a Nerves application. The guest shut down cleanly. Nerves then assembled the
native hello release with OTP 29.0.2. A second release build reused the system
artifact and rebuilt the C NIF for the selected deployment target without starting
a VM or acquiring the base again.

The image version was then added to the specification. A fresh system and native
hello firmware build passed with version `0.1.0` recorded in the base provenance,
followed by the two cold boots above.

A 16 MiB test disk exercised the prebuilt provider through a real Tart push and
import. The test registry required anonymous Bearer authentication. Elixir/OTP
downloaded and verified the manifest and blobs before Tart imported them from
loopback. Altering a blob caused a SHA-256 failure, and both paths removed their
temporary caches. A separate HTTPS check fetched a GHCR token and manifest using
an explicit PEM CA bundle; it did not download image blobs.

The versioned Tart roundtrip also passed. A mismatched image version was rejected
after downloading the OCI config, before any disk blobs were requested.

The local builder test checked executable and Git revision pins, rejected modified
inputs, and removed its temporary output. It did not restore an IPSW. Native-file
checks accepted a macOS 26 extension for the macOS 26 target and rejected it for
macOS 15.

The temporary selected-system artifact and release were removed after validation.
The original base VMs and previously verified system and firmware were retained,
along with an application-free `0.1.0` base prepared for publication. No base has
been uploaded to GHCR yet.

## macOS 15

macOS 15.6.1 (24G90), image version `0.1.0`, passed a clean build in
[GitHub Actions](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34740512619).
The Mac mini restored the pinned IPSW, completed the fixed Setup Assistant
scripts and Packer provisioning, and verified an independent blank-base boot.
Nerves then built the system, compiled the example's C NIF, installed the firmware,
and verified two cold boots with distinct application boot IDs. The entire run
completed without manual intervention, screenshots, OCR, or phase retries.
Packer update checks and telemetry were disabled throughout this run.

The build job took 31 minutes 45 seconds. Cleanup removed its VMs, IPSW, system
artifact and firmware. Guest logs and result metadata were uploaded as a small
Actions artifact with 14-day retention. No VM image was published by this job.

A separate local run passed a full Tart OCI roundtrip and the `macos15`
application workflow on the same host. Its fresh IPSW restore used
the existing fixed Setup Assistant scripts. Packer installed Command Line Tools
16.4, and an independent clone passed the base builder's cold-boot checks.

The initial Packer connection failed in the host application's launch context.
The same TCP probe and Packer template connected through an existing localhost
SSH session, where provisioning resumed. No guest repair or setup-script changes
were needed. This was not an uninterrupted base build.

The complete base was pushed to a loopback OCI registry. With an empty cache,
the production Elixir downloader checked the manifest digest, image version and
all blobs before Tart imported the disk. The transfer used 57 blob GET requests
and 21,029,519,648 response bytes (19.59 GiB), excluding manifests and headers.
The imported guest passed the exact OS, admin, English/U.S. and blank-base checks.

Nerves built the system artifact with OTP 29.0.2 and compiled the example's C NIF
with a minimum macOS version of 15.6.1. Firmware installation and two cold boots
passed application startup, Darwin/arm64 NIF, crypto and SSL checks. Both cold
boots produced distinct boot IDs and ended with clean shutdowns. The full OCI
acquisition, firmware build and two-boot sequence completed without retries.

The local blank base, restore download, registry blobs, temporary VMs, application
firmware and system cache were removed after saving the results. This used
independent caches on one Mac; GHCR publication and acquisition from another
physical host have not been tested.

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
