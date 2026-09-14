# Selecting a macOS base

A base is a macOS installation with Setup Assistant completed and SSH enabled.
It has an `admin` development account, standard English (`en-US`), the `en_US`
locale, and a U.S. or ABC keyboard. It contains no Nerves application. The system
package adds Erlang/OTP, and the application build installs the release.

Keep base builds separate from application builds. Build a new base when adopting
another Apple IPSW or changing the initial setup. Developers can reuse that base
for their own systems and applications without running Setup Assistant again.
The base builder does not need to run for each application release.

## Choose a version

Run `mix nerves.macos.base profiles` to list the defaults:

| macOS | Version | Apple build | Nerves runtime tested | Base release |
| --- | --- | --- | --- | --- |
| 15 | 15.6.1 | 24G90 | Yes | [0.1.0](https://github.com/cocoa-xu/nerves_system_macos/releases/tag/15.6.1-24G90-v0.1.0) |
| 26 | 26.6.2 | 25G83 | Yes | [0.1.0](https://github.com/cocoa-xu/nerves_system_macos/releases/tag/26.6.2-25G83-v0.1.0) |
| 27 | 27.0 RC | 26A428 | Yes | [0.1.0 prerelease](https://github.com/cocoa-xu/nerves_system_macos/releases/tag/27.0-26A428-v0.1.0) |

Use `--version` and `--build` together to select a different release. Both values
are saved in `base.json` and checked inside the guest. The host must run at least
the selected guest's macOS major. Native files are also checked for a compatible
minimum macOS version.

All three images are available from `ghcr.io/cocoa-xu/nerves_system_macos`. Each
release includes a `base-spec.json` with the immutable manifest digest. Download
that specification and use it with the prebuilt workflow below.

## Tart compatibility

Bases use Tart's standalone raw VM format and OCI media types. Tart can clone
and run them without Nerves, and Packer's `tart-cli` builder can provision them
over SSH with `admin` / `admin`.

This is the same VM and registry format used by
[Cirrus's macOS templates](https://github.com/cirruslabs/macos-image-templates).
Our blank base corresponds to their `vanilla` variant. Their `base` and `xcode`
variants include additional tools; recipes that need those tools must install
them. Package names, tags and provisioning interfaces are separate.

Importing another Tart image as a Nerves base also requires the exact macOS
identity, account and English/U.S. settings described here. Prebuilt acquisition
checks the image version label before downloading the disk, then boots a copy
to verify the guest. A shared file format alone does not satisfy these checks.

## Image versions

Each base also has an `image_version`, independent of macOS and the Mix package
version. For example, macOS `26.6.2`, Apple build `25G83`, and image version `0.1.0`
produce the tag `26.6.2-25G83-v0.1.0`. Use this tag for the OCI image and its
GitHub release.

Assign a new image version whenever a published base is rebuilt. A setup fix can
be `0.1.1` even if the macOS build stays the same. Keep the old tag and digest so
existing projects can continue using it. Use semantic versions such as `0.1.0`
or `0.2.0-rc.1`, without `+` build metadata.

Pass `--image-version` when creating a specification. It is required, saved in
the artifact metadata, and included in the Nerves checksum and base fingerprint.
Changing it selects a new cache entry. Print the release tag with:

```sh
mix nerves.macos.base tag --spec base.json
```

Prebuilt images must carry the same version in their OCI
`org.opencontainers.image.version` label. The downloader checks this before
requesting disk blobs. The manifest digest still identifies the exact image bytes.

## Download a prebuilt base

Use the image's manifest digest, not a tag:

```sh
mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source prebuilt \
  --reference 'ghcr.io/cocoa-xu/nerves_system_macos@sha256:101d8fbd84556f209179bf43b8fe8ff259bb8af44733a79d0748437c7b9020a1' \
  --output base.json
```

This selects the published macOS 26 base. For another release, use its attached
`base-spec.json` or its manifest digest. The registry must allow anonymous pulls.
To download and check the base:

```sh
export NERVES_MACOS_CACERT=/opt/homebrew/etc/openssl@3/cert.pem
mix nerves.macos.base prepare --spec base.json --output /absolute/new/base.tart
```

Set `NERVES_MACOS_CACERT` to a PEM CA bundle on your host. Elixir/OTP downloads
the manifest and blobs over HTTPS and checks their sizes and hashes. It handles
anonymous Bearer authentication when required. Tart imports the verified files
from a temporary loopback registry, without consulting host credentials.

The download uses a temporary cache, removed when preparation finishes. Leave
space for both the compressed blobs and the extracted disk. Nerves caches the
completed system artifact, so application builds do not download the base again.

Bases must use standalone raw Tart disks. Stacked disk images are used separately
in the [layer experiment](../experiments/layers/README.md), which requires a
macOS 27 host.

## Restore a base locally

Use a local builder if you want to restore Apple's IPSW and run the initial setup
yourself. This option requires a reviewed builder checkout and its compiled CLI:

```sh
mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source build \
  --builder /absolute/path/to/builder \
  --repository /absolute/path/to/checkout \
  --recipe config/selected-release.env \
  --output base.json
```

The command records the executable's SHA-256 and the checkout's full Git revision.
The recipe must be tracked, with no tracked changes in the checkout. Pin the IPSW
and tool versions in that recipe. Dependencies outside the checkout need their
own pins.

By default, the builder is called with
`build vanilla --config RECIPE --repository CHECKOUT --target NAME`. For a different
CLI, edit `source.arguments` in `base.json`. Each item is passed as one argument;
`{vm}` is replaced with a new VM name.

The builder receives a private `TART_HOME` and must leave a stopped raw VM at
`$TART_HOME/vms/NAME`. Automatic pruning is disabled. The default timeout is one
hour, configurable up to two hours through `source.timeout_seconds`. The result
must pass the same guest checks as a downloaded base. The builder runs as your
host user, so review it before use.

Run `mix nerves.macos.base prepare` as above to build and verify the base.

## Use an existing local base

```sh
mix nerves.macos.base lock --macos 26 --image-version 0.1.0 --source local \
  --image /absolute/path/to/stopped/base.tart --output base.json
```

This records the hashes of `config.json`, `disk.img` and `nvram.bin`. Preparation
checks them before making an APFS copy. Hashing a large disk can take several
minutes. If the source changes, generate a new specification.

## Use the base in a system package

Commit `base.json` with the system package and include it in the Nerves checksum:

```elixir
nerves_package: [
  type: :system,
  platform: Nerves.System.MacOS,
  build_runner: Nerves.Artifact.BuildRunners.Local,
  platform_config: [
    base_spec: "base.json",
    otp_root: "/absolute/path/to/erlang",
    otp_version: "29.0.2"
  ],
  checksum: ["mix.exs", "base.json"]
]
```

`base_spec` replaces `base_image`, `macos_version` and `macos_build`. Listing it
in `checksum` is required. Changing the version, digest or source creates a
different artifact path; earlier artifacts are kept. Existing output directories
are never overwritten.

The [LiveView example](https://github.com/cocoa-xu/nerves_system_macos_info)
includes a system package with a pinned macOS 26 base. To support several targets
in your own package, select a specification using `Mix.target()` and include that
file in the checksum. Set `NERVES_MACOS_OTP_ROOT` before building the application.

## Remaining work

Native-file validation, OTP downloading and process supervision still use Python
helpers. These responsibilities will move to Elixir/OTP before production use.
The Python layer experiment is also separate from the current firmware task.
Tart remains the VM backend.
