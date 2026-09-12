# Changelog

## 0.1.0

- Add a native macOS Nerves system platform with isolated Tart builds.
- Pin and verify precompiled Apple silicon OTP runtimes and record OpenSSL provenance.
- Export the Darwin SDK and Erlang headers for native extensions.
- Build launchd-managed application firmware and verify two cold boots.
- Include an example system and an application with a native extension.
- Support shared application data during VM provisioning.
- Validate layered OCI installation, updates and rollback on a macOS 27 host.
- Select exact macOS 15, 26 or 27 bases from local, pinned OCI or local build sources.
- Verify OCI downloads with Elixir and isolate Tart from remote registry credentials.
- Separate base selections in the Nerves cache and check native deployment targets.
