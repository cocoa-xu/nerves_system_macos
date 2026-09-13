# Release runners

Use the Mac mini for base builds when adopting a new IPSW or changing the initial
guest setup. Developers can build their systems and applications from the saved
base on their own Macs. The release runner can stay off between base builds.

## Limit access

For a personal public project, register the runner with a separate private
repository used for releases. Give access only to trusted release maintainers.
Keep public pull-request checks on GitHub-hosted runners.

The [base workflow](../.github/workflows/base-image.yml) accepts manual runs on
`main` and tags named `ci-macos15-*`. It allows only the repository owner's
original runs and reruns. A GitHub-hosted job checks that the commit belongs to
`main` before the Mac mini receives work. It has no pull-request trigger.

Actions are pinned to full commit SHAs. The job has read access to repository
contents, does not retain checkout credentials, and has no package write access.
These workflow checks are not a runner access policy: anyone who can change
eligible workflows could request the same runner. A private release repository
remains preferable when other contributors receive write access.

Enterprise runner groups can restrict access to selected workflow paths and refs.
Personal repository runners do not have that workflow allowlist. Runner labels
only select a machine; another eligible workflow can request the same labels.
See GitHub's [runner group documentation](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).

## Run a build

The first workflow builds macOS 15.6.1 from its pinned IPSW, verifies the blank
guest, builds the Nerves example with OTP 29.0.2, and checks two cold boots.
[ci/macos15.json](../ci/macos15.json) records the image version, builder revision,
IPSW size and SHA-256, and OTP SHA-256. It does not reuse a prepared local VM.

Install the README prerequisites, Tart 2.36.0, Packer 1.16.0, Go 1.25.0 and the
Tart Packer plugin 1.21.0 before starting the runner. The builder's pinned Go
dependencies must already be in its module cache; CI disables Go module downloads.
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
SHA-256. The checkout must be clean at the revision in `ci/macos15.json`. The job
copies that revision into its work directory and checks the executable hash.
`NERVES_MACOS_RUNNER_CONFIG` can select another configuration file.

Start **Build macOS base** from Actions on `main`, or tag a reviewed commit:

```sh
git tag ci-macos15-20260913-1 COMMIT_SHA
git push origin ci-macos15-20260913-1
```

Use a new tag for each run. Builds run one at a time, require 100 GiB free, and
have a two-hour job timeout. Logs and result metadata are retained as an Actions
artifact for 14 days. Cleanup stops only this run's VMs and checks that their
disks are closed before removing downloads and build outputs. This first workflow
does not publish images to GHCR or upload VM disks as Actions artifacts.

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
