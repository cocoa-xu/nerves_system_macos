import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
deployment_target = tuple(map(int, sys.argv[2].split("."))) if len(sys.argv) > 2 else None
if deployment_target:
    deployment_target = deployment_target + (0,) * (3 - len(deployment_target))
magic_values = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
count = 0
for path in root.rglob("*"):
    if path.is_symlink():
        target = path.resolve(strict=True)
        if root != target and root not in target.parents:
            sys.exit(f"Symlink escapes the runtime: {path}")
        continue
    if not path.is_file():
        continue
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic == b"\x7fELF":
        sys.exit(f"Linux or BSD ELF file in a macOS runtime: {path}")
    if magic not in magic_values:
        continue
    count += 1
    arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True, timeout=10)
    if "arm64" not in arch.split():
        sys.exit(f"Native file has no arm64 slice: {path}")
    if deployment_target:
        commands = subprocess.check_output(
            ["/usr/bin/otool", "-arch", "arm64", "-l", str(path)], text=True, timeout=10
        )
        command = None
        for line in commands.splitlines():
            words = line.split()
            if len(words) != 2:
                continue
            key, value = words
            if key == "cmd":
                command = value
            if command == "LC_BUILD_VERSION" and key == "platform" and value not in ("1", "MACOS"):
                sys.exit(f"Native file targets a non-macOS platform: {path}: {value}")
            if (command == "LC_BUILD_VERSION" and key == "minos") or (
                command == "LC_VERSION_MIN_MACOSX" and key == "version"
            ):
                minimum = tuple(map(int, value.split(".")))
                minimum = minimum + (0,) * (3 - len(minimum))
                if minimum > deployment_target:
                    sys.exit(f"Native file requires macOS {value}, newer than {sys.argv[2]}: {path}")
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True, timeout=10)
    for line in linked.splitlines()[1:]:
        dependency = line.strip().split(" (")[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            sys.exit(f"Native file requires a non-system library: {path}: {dependency}")
print(f"Verified {count} portable arm64 Mach-O files")
