import hashlib
import os
import pathlib
import shutil
import ssl
import sys
import tarfile
import tempfile
import urllib.request

version, digest, destination, cacert = sys.argv[1:]
output = pathlib.Path(destination)
if os.path.lexists(output):
    sys.exit(f"Refusing to replace {output}")
output.parent.mkdir(parents=True, exist_ok=True)
temporary = pathlib.Path(tempfile.mkdtemp(prefix="otp-download-", dir=output.parent))
try:
    archive = temporary / "otp.tar.gz"
    checksum = hashlib.sha256()
    url = f"https://github.com/cocoa-xu/otp-build/releases/download/v{version}/otp-arm64-apple-darwin.tar.gz"
    context = ssl.create_default_context(cafile=cacert)
    with urllib.request.urlopen(url, context=context, timeout=60) as response, archive.open("wb") as stream:
        while True:
            data = response.read(1024 * 1024)
            if not data:
                break
            checksum.update(data)
            stream.write(data)
    if checksum.hexdigest() != digest:
        sys.exit("OTP archive SHA-256 does not match")
    extracted = temporary / "extracted"
    extracted.mkdir()
    with tarfile.open(archive) as bundle:
        links = []
        for member in bundle.getmembers():
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                sys.exit(f"Unsafe archive member: {member.name}")
            if not (member.isfile() or member.isdir() or member.issym()):
                sys.exit(f"Unsupported archive member: {member.name}")
            if member.issym():
                links.append(member)
            else:
                bundle.extract(member, extracted)
        for member in links:
            path = extracted / member.name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(member.linkname)
        for member in links:
            target = (extracted / member.name).resolve(strict=True)
            if extracted not in target.parents:
                sys.exit(f"Unsafe archive symlink: {member.name}")
    root = extracted / "usr/local/lib/erlang"
    versions = list(root.glob("releases/*/OTP_VERSION"))
    if len(versions) != 1 or versions[0].read_text().strip() != version:
        sys.exit("Extracted OTP version does not match")
    extracted.rename(output)
    print(output / "usr/local/lib/erlang")
finally:
    shutil.rmtree(temporary)
