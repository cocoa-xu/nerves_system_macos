import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "experiments/layers"))
from run import downloaded, verify_layout
sys.path.pop(0)


def layer(digest, size):
    return {"mediaType": "application/vnd.cirruslabs.tart.disk.asif.overlay.v1",
            "digest": digest, "size": size}


class LayoutTest(unittest.TestCase):
    def test_rejects_a_rebuilt_parent_in_an_application_image(self):
        base, dependency = layer("base", 1000), layer("jq", 20)
        manifests = {
            "base": {"layers": [base]},
            "dependency": {"layers": [base, dependency]},
            "v1": {"layers": [base, dependency, layer("app-v1", 30)]},
            "v2": {"layers": [base, dependency, layer("app-v2", 40)]},
        }
        self.assertEqual(verify_layout(manifests)["v2_application_disk_bytes"], 40)
        altered = copy.deepcopy(manifests)
        altered["v2"]["layers"][1] = layer("rebuilt-jq", 20)
        with self.assertRaisesRegex(AssertionError, "unchanged dependency"):
            verify_layout(altered)

    def test_measurements_exclude_head_errors_and_manifests(self):
        events = [
            {"method": "GET", "path": "/v2/test/blobs/a", "status": 200, "bytes": 30},
            {"method": "GET", "path": "/v2/test/blobs/a", "status": 206, "bytes": 10},
            {"method": "HEAD", "path": "/v2/test/blobs/a", "status": 200, "bytes": 0},
            {"method": "GET", "path": "/v2/test/blobs/b", "status": 404, "bytes": 5},
            {"method": "GET", "path": "/v2/test/manifests/v1", "status": 200, "bytes": 50},
        ]
        self.assertEqual(sum(event["bytes"] for event in downloaded(events)), 40)


if __name__ == "__main__":
    unittest.main()
