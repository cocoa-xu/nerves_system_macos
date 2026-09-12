import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
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
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True, timeout=10)
    for line in linked.splitlines()[1:]:
        dependency = line.strip().split(" (")[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            sys.exit(f"Native file requires a non-system library: {path}: {dependency}")
print(f"Verified {count} portable arm64 Mach-O files")
