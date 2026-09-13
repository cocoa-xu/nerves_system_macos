# Release runners

Use the Mac mini for base builds when adopting a new IPSW or changing the initial
guest setup. Developers can build their systems and applications from the saved
base on their own Macs. The release runner can stay off between base builds.

## Limit access

For a personal public project, register the runner with a separate private
repository used for releases. Give access only to trusted release maintainers.
Keep public pull-request checks on GitHub-hosted runners.

The [base workflow](../.github/workflows/base-image.yml) accepts manual runs on
`main`, formal image version tags, and publication requests pushed to `main`.
It allows only the repository owner's original runs and reruns. A GitHub-hosted
job checks that the commit belongs to
`main` and each pushed tag matches exactly one pinned profile before the Mac mini
receives work. It has no pull-request trigger.

The Mac mini job can write packages. A separate GitHub-hosted Linux job creates
releases with `gh release create --verify-tag` from the verified metadata artifact.
Checkout does not retain credentials; publication steps receive the job's
short-lived `GITHUB_TOKEN`.
These checks are not a runner access policy: anyone who can change eligible
workflows could request the same runner. A private release repository remains
preferable when other contributors receive write access.

Enterprise runner groups can restrict access to selected workflow paths and refs.
Personal repository runners do not have that workflow allowlist. Runner labels
only select a machine; another eligible workflow can request the same labels.
See GitHub's [runner group documentation](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).

## Run a build

The workflow builds macOS 15, 26 or 27 from pinned IPSWs, verifies each blank
guest, builds the Nerves example with OTP 29.0.2, and checks two cold boots.
The profiles in [ci/](../ci) record the image version, builder revision, IPSW
size and SHA-256, and OTP SHA-256. Every new build restores a new VM.

Install the README prerequisites, Tart 2.36.0, Packer 1.16.0, Go 1.25.0 and the
Tart Packer plugin 1.21.0 before starting the runner. The builder's pinned Go
dependencies must already be in its module cache; CI disables Go module downloads.
[Checkout v7](https://github.com/actions/checkout/tree/v7) requires Actions Runner
2.327.1 or newer for its Node 24 runtime.
The job uses `/opt/homebrew/etc/openssl@3/cert.pem` for TLS verification.
Packer's update checks and telemetry are disabled through `ci/packer.json`.

The runner uses a reviewed local builder checkout and compiled CLI. Save their
paths and the executable's SHA-256 in
`~/.config/nerves-system-macos/runner.json`:

```json
{
  "repository": "/absolute/path/to/builder-checkout",
  "executable": "/absolute/path/to/compiled-builder",
  "sha256": "EXECUTABLE_SHA256"
}
```

Replace the placeholders with the installed paths and the executable's lowercase
SHA-256. The checkout must be clean at the revision in the selected profile. The job
copies that revision into its work directory and checks the executable hash.
`NERVES_MACOS_RUNNER_CONFIG` can select another configuration file.

Start **Build macOS base** from Actions on `main` after reviewing the commit.
Select a macOS version or `all`. Leave **Publish verified bases** enabled to
publish; disable it for build-only validation. Pushing a formal version tag,
such as `15.6.1-24G90-v0.1.0`, builds and publishes that profile. Builds run one at a time and
require 100 GiB free. Each version has a 210-minute job limit, including separate
build, publication and cleanup deadlines.

Publication pushes to `ghcr.io/cocoa-xu/nerves_system_macos` with the version tag
from [Image versions](base-images.md#image-versions). Existing tags are rejected.
Tart writes OCI blobs to a loopback registry; Elixir/OTP uploads them with an
explicit PEM CA bundle. The job token is removed from the environment before
Tart or a guest verification process starts.

New GHCR packages default to private. On the first publication, set the package
visibility to **Public** in its GitHub settings. The job waits up to 30 minutes
for anonymous access, then downloads the image through the production OCI
provider and verifies a cold boot. See GitHub's
[package visibility settings](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

The job creates a GitHub release only after remote verification. It attaches the
pinned base specification, build inputs, validation result and OCI manifest.
macOS 27 releases are marked prerelease and are not selected as Latest. All
assets upload before the draft release is published.

If an upload fails before the registry tag is published, run the workflow on
`main`, select the same macOS version, enable publication and set **verified_run**
to the original run ID and attempt, such as `123456789-1`. The runner saves passed
bases under `~/.cache/nerves-system-macos/verified/`. Recovery checks their file
hashes, pinned inputs and the original successful CI build step. It retains the
original build revision in the image and release metadata. The saved base is
removed after publication and anonymous boot verification succeed. Leave this
input empty to build from the IPSW.

Recovery can also be requested through Git. Commit `ci/publication.json` to
`main` with the selected version and original run ID:

```json
{
  "macos": "15",
  "verified_run": "123456789-1"
}
```

Push this request separately from other file changes. The authorization job
checks the push changes only this file and selects a single version and saved run
ID before scheduling the Mac mini. The owner restrictions and saved-base
verification apply to this path too. Other pushes to `main` do not request
publication.

If GHCR publication and the anonymous cold boot passed but GitHub release creation
failed, set **release_run** to that publication run ID and attempt instead.
The Linux job downloads its metadata artifact and creates the release without
scheduling the Mac mini. For a Git request, replace `verified_run` with
`release_run`. These two recovery inputs are mutually exclusive. The existing tag
must point to the original build revision; release creation never moves it.

Cleanup runs after each version, including on failure. It stops only that run's
VMs and checks that their disks are closed before removing downloads and build
outputs. Logs and metadata remain as an Actions artifact for 14 days. VM disks
are not uploaded as Actions artifacts.

Before starting the runner, check the release inputs and queued jobs in its
repository. Jobs can wait for an offline runner and run when it connects.
GitHub describes this in [job routing](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#routing-precedence-for-self-hosted-runners).

Use a dedicated build account without personal files or credentials. Keep network
access limited to what the build needs. Run one image build at a time, set a job
timeout, and preserve the logs before deleting scratch VMs and caches. Stop the
runner after the build.

An ephemeral registration accepts one job and then unregisters. It does not clean
the Mac afterward. Neither a separate account nor approval of a workflow run
makes untrusted code safe to execute on a personal machine. See GitHub's
[self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use).

Runner registration remains a host setup step.
