# Validation

Validated on September 13–14, 2026, on an Apple M4 Pro Mac mini running macOS 27.0
(26A5425a), with Tart 2.36.0, Elixir 1.20.4, and host OTP 29.0.6.

## Published bases

All three image version `0.1.0` bases were built from pinned Apple IPSWs in CI.
Each run completed Setup Assistant and Packer provisioning, checked a blank-base
cold boot, built the Nerves system and native C NIF, installed the example release,
and verified two cold boots with distinct application boot IDs. Guest checks
confirmed the exact macOS version and build, admin account/full name/password,
standard English, `en_US`, `en-US`, and U.S. keyboard.

| macOS | Apple build | Fresh CI build | Compressed OCI blobs |
| --- | --- | --- | ---: |
| 15.6.1 | 24G90 | [34752571489](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34752571489) | 21,028,862,718 bytes |
| 26.6.2 | 25G83 | [34755074300](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34755074300) | 24,714,730,299 bytes |
| 27.0 RC | 26A428 | [34758635823](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34758635823) | 30,985,468,901 bytes |

The guest runtime was OTP 29.0.2, ERTS 17.0.2, and OpenSSL 3.6.3. The NIF
reported Darwin/arm64, and RPC checks confirmed the running release, crypto and
SSL. Each guest shut down cleanly. Builds used fixed scripts and bounded waits,
without screenshots, OCR, or manual setup. Packer update checks and telemetry
were disabled.

After publication, CI downloaded every image anonymously from GHCR, verified
all blob hashes, imported it into Tart and passed an independent blank-base boot.
The byte counts above include each unique compressed blob once, including OCI
configuration, VM configuration and NVRAM. They exclude manifests and headers.
The public manifests are:

```text
15.6.1-24G90-v0.1.0   sha256:66abe3cfb88852a3ac04704adbcf16e1bd4aa920a1f5a5180ab51792e902dac8
26.6.2-25G83-v0.1.0   sha256:101d8fbd84556f209179bf43b8fe8ff259bb8af44733a79d0748437c7b9020a1
27.0-26A428-v0.1.0    sha256:726ff8e5dd9fc90393db6b461a4173f5edcd76918b5b9d710b4e9b69765dcb39
```

The macOS 15 build passed before its original publication step failed.
[34762495999](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34762495999)
resumed publication from that verified base, preserving source revision
`69f8e8f78f835761967b7c9db94f20a142c92d04`, then passed the complete anonymous
acquisition and blank-base boot.
[34765334480](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34765334480)
created the GitHub release from those saved results with GitHub CLI.

Each [release](base-images.md#choose-a-version) includes `base-spec.json`,
`inputs.json`, `result.json`, and `oci-manifest.json`. Their public bytes and hashes,
OCI labels, manifest digest and tag commit were independently checked. macOS 27
is a prerelease and is not Latest. Local CI images, retained publication copies,
diagnostic VMs and temporary registry blobs were removed after verification.

Public acquisition was tested on the publishing host. Acquisition from a second
physical host, VirtualBuddy import, physical Mac installation, production OTA
updates and Linux-specific Nerves runtime packages remain outside these results.

## Base selection and caching

A second `macos26` application build reused the Nerves system artifact without
acquiring or booting the base again. It rebuilt the C NIF for the selected
deployment target. Changing the image version selected a new system artifact.
Native-file checks accepted a macOS 26 extension for that target and rejected it
for macOS 15.

A 16 MiB test disk exercised the prebuilt provider with anonymous Bearer
authentication. Altering a blob caused a SHA-256 failure; a mismatched image version
was rejected after reading the OCI config, before requesting disk blobs. Both
failure paths removed their temporary caches.

The local builder checks rejected modified executable and Git revision pins.
The sparse archive writer preserved a test disk's logical size after extraction.
A complete Nerves system archive was not compressed and redistributed in these
checks.

After the base releases, a separate 16 MiB Tart export passed conversion to an OCI
image layout, copying with ORAS 1.3.0, and import through Tart 2.36.0. The manifest,
blobs, disk and NVRAM remained unchanged. ORAS also resolved the published macOS 15
tag anonymously using an explicit PEM CA bundle. This format check did not upload
another image to GHCR or boot the test disk.

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
temporary releases and the earlier tiny-disk probe.

To reproduce, follow the runtime download and example build steps in
[`README.md`](../README.md), then run `mix nerves.macos.verify` on the completed
firmware directory. `make validate` runs the checks that do not require a VM.
