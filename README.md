# nerves_system_macos

Nerves System macOS provides the common logic for building
[Nerves](https://nerves-project.org) systems for Apple silicon virtual machines.
It uses Tart and OpenSSH to prepare VM images, supplies the Darwin SDK environment
for native compilation, and installs Elixir releases as launchd services.

System packages use this platform in the same way that Linux system packages use
`nerves_system_br`. Start with the
[LiveView example](https://github.com/cocoa-xu/nerves_system_macos_info),
or read about [selecting a base](docs/base-images.md)
to choose macOS 15, 26 or 27. All three have passed native application builds and
two cold boots. Public base images are available for each profile; macOS 27
remains a prerelease.

## Requirements

- An Apple silicon Mac with an APFS build volume. Base specifications require
  a host macOS major at least as new as the selected guest (15, 26 or 27).
- Xcode or Command Line Tools with an SDK supporting the guest deployment target.
- Elixir 1.16 or later, with the same OTP major version as the selected runtime.
- Nerves 1.15 and `nerves_bootstrap`.
- Tart 2.36, Python 3.9 or later, GNU tar (`gtar`), and `sshpass` 1.10.
- A prepared macOS base, supplied locally, downloaded by digest, or restored by
  a local builder. A local base is a stopped raw VM bundle containing
  `config.json`, `disk.img`, and `nvram.bin`. Keep these files together; the
  configuration includes the VM's hardware model and machine identifier.

The guest must have completed Setup Assistant, enabled SSH password login, and
configured passwordless sudo. The development account, full name, and password
default to `admin`. Its language must be standard English (`en-US`), locale
`en_US`, and keyboard U.S. or ABC. The build checks these settings; it never
inherits the host's language or region.

The platform does not modify the source VM. Builds use APFS copies with new names
and MAC addresses in a private `TART_HOME`, with automatic pruning disabled.
Existing output paths are rejected. No host Keychain access is used.

## Get the runtime

The example pins [cocoa-xu/otp-build](https://github.com/cocoa-xu/otp-build)'s
OTP 29.0.2 for `arm64-apple-darwin`. Its crypto NIF statically includes OpenSSL
3.6.3 from [cocoa-xu/openssl-build](https://github.com/cocoa-xu/openssl-build).
The artifact records the OpenSSL version reported by the running OTP build.

From this directory:

```sh
export HEX_CACERTS_PATH=/opt/homebrew/etc/openssl@3/cert.pem
mix archive.install hex nerves_bootstrap
mix deps.get
mix nerves.macos.otp \
  --version 29.0.2 \
  --sha256 cdf2382ffd0d7d79eb37e0e4b59549cfc8343fdffc9855eea235f12ecfb1ccf3 \
  --output .nerves/otp-29.0.2 \
  --cacert "$HEX_CACERTS_PATH"
```

Use a PEM CA bundle available on your host. The downloader requires an explicit
trust store and digest, rejects existing destinations, and verifies the extracted
OTP version. It never resolves a moving `latest` release.

You can supply another self-contained native OTP installation. The builder
checks its exact version, arm64 binaries, internal symlinks, and native library
dependencies. This initial platform accepts Apple system libraries and statically
linked dependencies; runtime dependencies on Homebrew or other external library
paths are rejected.

## Build an application

The [LiveView example](https://github.com/cocoa-xu/nerves_system_macos_info)
contains a complete system package and application, with build instructions.
It serves macOS metrics and uses `stb_image` for native image decoding.

Pin the macOS and OTP versions in your system package's checksum inputs.
Changing the base or OTP contents requires a new system package version or an
explicit artifact clean and rebuild.

Nerves builds and caches the system artifact, activates the SDK, and compiles the
application. Firmware assembly installs the release into a fresh copy of
the system, checks the running applications over local RPC, and shuts it down.

Each firmware output contains:

```text
nerves-firmware.json
firmware.tart/
  config.json
  disk.img
  nvram.bin
```

Use `mix firmware --output /absolute/new/directory` to choose the destination. The output
must not exist. The release assembly directory is rebuilt by Mix; completed VM
outputs are never replaced.

Verify the saved firmware through two cold boots of a temporary copy:

```sh
mix nerves.macos.verify /absolute/path/to/firmware
```

Each boot checks the OS, account, locale, keyboard, stable launchd process,
started OTP applications, crypto, and SSL. Verification uses fixed scripts and
bounded waits, without screenshots, OCR, or GUI automation. Add application
specific acceptance tests for your own services.

## Define a system package

For macOS 15, 26 or 27 with a prebuilt, local or locally restored base, see
[selecting a base](docs/base-images.md). Each public release includes a base
specification pinned to its GHCR manifest digest.

The essential package configuration is:

```elixir
nerves_package: [
  type: :system,
  platform: Nerves.System.MacOS,
  build_runner: Nerves.Artifact.BuildRunners.Local,
  platform_config: [
    base_image: "/absolute/path/to/base.tart",
    macos_version: "26.6.2",
    macos_build: "25G83",
    otp_root: "/absolute/path/to/erlang",
    otp_version: "29.0.2"
  ],
  checksum: ["mix.exs"]
]
```

Include `:nerves_package` after the normal Mix compilers, start
`nerves_bootstrap`, and depend on `nerves_system_macos` with `runtime: false`.
The example uses a path dependency for development; no published Hex package is
required to run it.

For an application, configure the macOS release and firmware task:

```elixir
releases: [my_app: &Nerves.System.MacOS.Release.options/0],
aliases: [firmware: ["nerves.macos.firmware"]]
```

The system artifact contains `runtime/`, `system.tart/`, and
`nerves-macos.json`. Standard `mix nerves.artifact` creates a sparse gzip tar
archive for Nerves caching and distribution. Archiving a macOS disk can take
significant time and space; sparse extents are retained by GNU tar. An artifact
archive contains the complete guest disk and selected runtime.

## Guest runtime

The release lives at `/opt/nerves/app`, persistent application data at
`/var/lib/nerves`, and logs at `/var/log/nerves/application.log`. Launchd runs
`org.nerves.application` as the configured development user. It starts on boot
and restarts after exit with a ten-second throttle.

Erlang distribution and epmd bind to guest loopback for health checks and local
RPC. The development password is used only for SSH provisioning. Set
`NERVES_MACOS_PASSWORD` for firmware and verification if your system uses a
different password, and set the matching `:password` in its platform config.

## Current scope

This is an experimental macOS Nerves platform. It provides system artifacts,
native compilation, bootable application VMs, launchd supervision, and cold-boot
verification. It starts from a prepared macOS base. The local build option calls
an external builder for IPSW restoration and Setup Assistant automation.

Linux-specific `erlinit`, fwup images, `firmware.burn`, `Nerves.Runtime`,
`nerves_system_shell`, A/B updates, and Linux hardware drivers are not macOS
implementations. Use the macOS firmware alias above rather than the stock Linux
firmware task. Physical Mac installation and VirtualBuddy import are not
implemented here. The output preserves the disk and Apple platform identity
needed by a future VM adapter.

See the [layer distribution experiment](experiments/layers/README.md) for a
macOS 27 host workflow with separate base, dependency and application layers,
measured OCI downloads, and application data shared across version changes.
Its Python controller is an experiment; the intended integration uses Elixir
and the Nerves build interfaces.

Elixir runs on the host and controls the guest during builds and verification.
A public API for managing long-running VMs and arbitrary guest applications is
planned. The current firmware task installs a Mix release.

## Development

```sh
make validate
```

This checks formatting, compilation and shell syntax. For a smoke test, build the
example with `mix firmware` and run `mix nerves.macos.verify` on the result. It
checks the application through two cold boots. See [validation results](docs/validation.md).
For a dedicated base-image build machine, see [release runners](docs/runner-security.md).

The platform source is licensed under Apache-2.0. macOS, Erlang/OTP, OpenSSL,
and application dependencies retain their respective upstream licenses.
