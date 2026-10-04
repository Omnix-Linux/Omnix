"""Exercise the installer's real flavor-selection block without touching disks."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAMES = {
    "atrium": "KDE Plasma - Atrium",
    "autarchy-stable": "Hyprland - Omarchy (stable)",
    "autarchy-latest": "Hyprland - Omarchy (latest)",
    "minimal": "Minimal",
}


class FlavorNames(unittest.TestCase):
    def select(self, flavor="", choice=""):
        source = (ROOT / "installer/omnix-install.sh").read_text()
        block = "# 3. Flavor:" + source.split("# 3. Flavor:", 1)[1].split("# 4. User.", 1)[0]
        block = block.replace("REGISTRY=/tmp/omnix-flavors.json", 'REGISTRY="$TEST_REGISTRY"')
        confirmation = source.split('if [ -z "${OMNIX_YES:-}" ]; then\n  gum confirm "Erase', 1)[1]
        confirmation = 'if [ -z "${OMNIX_YES:-}" ]; then\n  gum confirm "Erase' + confirmation.split("# Partition,", 1)[0]
        harness = """
set -euo pipefail
curl() { return 0; }
die() { echo "$*" >&2; exit 1; }
gum() {
  if [ "$1" = confirm ]; then printf '%s\\n' "$2" >&2; return 0; fi
  while IFS= read -r line; do
    printf '%s\\n' "$line" >&2
    if [[ "$line" == "$TEST_CHOICE — "* ]]; then printf '%s\\n' "$line"; fi
  done
}
""" + block + confirmation + '\nprintf "%s\\n" "$flavor_json"\n'
        return subprocess.run(
            ["bash", "-c", harness], capture_output=True, text=True,
            env=dict(os.environ, OMNIX_FLAVOR=flavor, TEST_CHOICE=choice,
                     OMNIX_YES="", OMNIX_DISK="/dev/test", OMNIX_FS="btrfs", OMNIX_LUKS="1",
                     TEST_REGISTRY=str(ROOT / "flavors.json")),
        )

    def test_menu_uses_desktop_names_and_resolves_original_ids(self):
        for flavor, name in NAMES.items():
            with self.subTest(name=name):
                result = self.select(choice=name)
                self.assertEqual(result.returncode, 0, result.stderr)
                selected = json.loads(result.stdout)
                self.assertEqual(selected["id"], flavor)
                self.assertEqual(selected["name"], name)
                self.assertNotIn("autarchy", result.stderr.lower())
                self.assertNotIn("\t", result.stderr)

    def test_existing_unattended_ids_still_work(self):
        for flavor, name in NAMES.items():
            with self.subTest(flavor=flavor):
                result = self.select(flavor=flavor)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["name"], name)
                self.assertIn(f"install Omnix ({name}, btrfs, encrypted)", result.stderr)
                self.assertNotIn("autarchy", result.stderr.lower())

    def test_unknown_id_is_rejected(self):
        self.assertNotEqual(self.select(flavor="unknown").returncode, 0)


if __name__ == "__main__":
    unittest.main()
