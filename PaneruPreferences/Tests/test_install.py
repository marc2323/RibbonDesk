"""Exercise the real installer against a built app in isolated roots."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
APP = PROJECT.parent / ".build/paneru-preferences/RibbonDesk.app"
INSTALLER = PROJECT / "Scripts/install-app.sh"
CONFIGURATION = PROJECT / "paneru-init.lua"


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="RibbonDesk install ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / ".config/paneru"
        self.config.mkdir(parents=True)
        self.apps = self.root / "Applications"
        self.apps.mkdir()

    def old_app(self, name, identifier="local.paneru.preferences"):
        app = self.apps / name
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        (app / "old-build-marker").write_text(name)
        return app

    def install(self, configuration=CONFIGURATION):
        return subprocess.run(
            ["zsh", str(INSTALLER), str(APP), str(configuration)],
            env={**os.environ, "RIBBONDESK_INSTALL_ROOT": str(self.root)},
            text=True, capture_output=True,
        )

    def assert_installed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = self.apps / "RibbonDesk.app"
        plist = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
        self.assertEqual(plist["CFBundleExecutable"], "RibbonDesk")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
        self.assertEqual((self.config / "init.lua").read_bytes(), CONFIGURATION.read_bytes())
        self.assertEqual((self.config / "init.lua").stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.apps.glob(".ribbondesk-install.*")), [])

    def test_fresh_install(self):
        self.assert_installed(self.install())
        self.assertFalse((self.apps / "Paneru Settings.app").exists())

    def test_upgrade_preserves_settings_and_backs_up_both_names(self):
        for name in ["RibbonDesk.app", "Paneru Settings.app"]:
            self.old_app(name)
        saved = {name: f"saved {name}\n".encode() for name in
                 ["init.lua", "preferences.json", "preferences.lua", "scroll-presets.json"]}
        for name, data in saved.items():
            (self.config / name).write_bytes(data)
        self.assert_installed(self.install())
        backups = list((self.config / "backups").iterdir())
        self.assertEqual(len(backups), 1)
        for name, data in saved.items():
            self.assertEqual((backups[0] / name).read_bytes(), data)
            if name != "init.lua":
                self.assertEqual((self.config / name).read_bytes(), data)
        for name in ["RibbonDesk.app", "Paneru Settings.app"]:
            self.assertEqual((backups[0] / (name + ".backup") / "old-build-marker").read_text(), name)
        self.assertFalse((self.apps / "Paneru Settings.app").exists())

    def test_legacy_only_upgrade(self):
        self.old_app("Paneru Settings.app")
        self.old_app("Paneru.app", "com.github.karinushka.paneru.launcher")
        self.assert_installed(self.install())
        self.assertFalse((self.apps / "Paneru Settings.app").exists())
        self.assertFalse((self.apps / "Paneru.app").exists())
        backups = list((self.config / "backups").iterdir())
        self.assertTrue((backups[0] / "Paneru.app.backup/old-build-marker").exists())

    def test_unrelated_launcher_is_preserved(self):
        launcher = self.old_app("Paneru.app", "example.another-launcher")
        self.assert_installed(self.install())
        self.assertTrue((launcher / "old-build-marker").exists())

    def test_refuses_unrelated_app_without_modifying_it(self):
        old = self.old_app("RibbonDesk.app", "example.another-app")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrelated app", result.stderr)
        self.assertTrue((old / "old-build-marker").exists())
        self.assertFalse((self.config / "backups").exists())

    def test_missing_configuration_leaves_old_app_in_place(self):
        old = self.old_app("Paneru Settings.app")
        result = self.install(self.root / "missing.lua")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((old / "old-build-marker").exists())
        self.assertFalse((self.apps / "RibbonDesk.app").exists())


if __name__ == "__main__":
    unittest.main()
