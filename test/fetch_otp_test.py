import hashlib
import io
import pathlib
import runpy
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "priv/scripts/fetch-otp.py"


class FetchOTPTest(unittest.TestCase):
    def archive(self, name="usr/local/lib/erlang/releases/29/OTP_VERSION", link=None):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as archive:
            member = tarfile.TarInfo(name)
            member.size = len(b"29.0.2\n")
            archive.addfile(member, io.BytesIO(b"29.0.2\n"))
            if link:
                member = tarfile.TarInfo("usr/local/bin/erl")
                member.type = tarfile.SYMTYPE
                member.linkname = link
                archive.addfile(member)
        return data.getvalue()

    def fetch(self, data, destination, digest=None):
        args = [str(SCRIPT), "29.0.2", digest or hashlib.sha256(data).hexdigest(), str(destination), "unused.pem"]
        with patch.object(sys, "argv", args), patch("ssl.create_default_context"), patch("urllib.request.urlopen", return_value=io.BytesIO(data)):
            runpy.run_path(str(SCRIPT), run_name="__main__")

    def test_checksum_and_destination_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "otp"
            data = self.archive()
            with self.assertRaisesRegex(SystemExit, "SHA-256"):
                self.fetch(data, output, "0" * 64)
            self.assertFalse(output.exists())
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])
            self.fetch(data, output)
            with self.assertRaisesRegex(SystemExit, "replace"):
                self.fetch(data, output)

    def test_traversal_and_external_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "otp"
            for data in [self.archive("../../outside"), self.archive(link="/etc/passwd")]:
                with self.assertRaisesRegex(SystemExit, "Unsafe archive"):
                    self.fetch(data, output)
                self.assertFalse(output.exists())
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
