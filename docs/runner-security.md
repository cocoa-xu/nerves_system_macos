# Release runners

Use the Mac mini for base builds when adopting a new IPSW or changing the initial
guest setup. Developers can build their systems and applications from the saved
base on their own Macs. The release runner can stay off between base builds.

## Limit access

For a personal public project, register the runner with a separate private
repository used for releases. Give access only to trusted release maintainers.
Keep public pull-request checks on GitHub-hosted runners.

Start with a manual workflow that builds a reviewed full commit SHA from the
public project. Review the workflow, builder, dependencies and image inputs.
Pin third-party actions to full commit SHAs and give the job only the permissions
needed to build or publish its output.

Enterprise runner groups can restrict access to selected workflow paths and refs.
Personal repository runners do not have that workflow allowlist. Runner labels
only select a machine; another eligible workflow can request the same labels.
See GitHub's [runner group documentation](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access).

## Run a build

Before starting the runner, check the release inputs and queued jobs in its
private repository. Jobs can wait for an offline runner and run when it connects.
GitHub describes this in [job routing](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#routing-precedence-for-self-hosted-runners).

Use a dedicated build account without personal files or credentials. Keep network
access limited to what the build needs. Run one image build at a time, set a job
timeout, and preserve the logs before deleting scratch VMs and caches. Stop the
runner after the build.

An ephemeral registration accepts one job and then unregisters. It does not clean
the Mac afterward. Neither a separate account nor approval of a workflow run
makes untrusted code safe to execute on a personal machine. See GitHub's
[self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use).

This repository does not register runners or publish base images yet.
