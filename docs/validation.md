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
| Automated tests | Seven ExUnit tests and two Python tests passed |

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

This validation covers the macOS 26 application workflow. A macOS 27 guest,
VirtualBuddy import, physical Mac installation, OTA updates, and Linux-specific
Nerves runtime packages are outside these results.

To reproduce, follow the runtime download and example build steps in
[`README.md`](../README.md), then run `mix nerves.macos.verify` on the completed
firmware directory. `make validate` runs the checks that do not require a VM.
