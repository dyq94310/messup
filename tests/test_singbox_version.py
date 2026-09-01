from __future__ import annotations

import re
import unittest
from pathlib import Path


PLAYBOOK = Path(__file__).resolve().parents[1] / "playbooks" / "01-deploy-singbox.yml"
VERSION_LINE = re.compile(r"(?m)^sing-box version\s+([^\s]+)(?:\s|$)")


class SingboxVersionCheckTest(unittest.TestCase):
    def test_stable_version_does_not_match_prerelease(self) -> None:
        output = "sing-box version 1.14.0-rc.1 (linux/amd64)\n"
        match = VERSION_LINE.search(output)

        self.assertIsNotNone(match)
        self.assertNotEqual(match.group(1), "1.14.0")

    def test_stable_version_matches_exactly(self) -> None:
        output = "sing-box version 1.14.0 (linux/amd64)\n"
        match = VERSION_LINE.search(output)

        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "1.14.0")

    def test_playbook_uses_exact_version_match(self) -> None:
        source = PLAYBOOK.read_text(encoding="utf-8")

        self.assertIn("regex_escape", source)
        self.assertIn("is search(", source)
        self.assertNotIn("singbox_version not in (_installed_ver.stdout", source)


if __name__ == "__main__":
    unittest.main()
