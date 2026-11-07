from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from sidestore_source import RELEASE_REPO, build_site


class SideStoreSourceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.ipa = self.root / "app.ipa"
        self.output = self.root / "site"
        self.write_ipa()

    def tearDown(self):
        self.folder.cleanup()

    def write_ipa(self, version="1.2.3", build="7", platform="iPhoneOS", bundle="com.streamanime.iphone"):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/StreamAnime.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": bundle, "CFBundleShortVersionString": version, "CFBundleVersion": build,
                "CFBundleSupportedPlatforms": [platform], "MinimumOSVersion": "17.0"}))

    def test_feed_matches_ipa_and_uses_classic_permissions(self):
        source = build_site(self.ipa, self.output, "New charts", "2026-11-06")
        app = source["apps"][0]
        self.assertEqual(app["versions"][0]["version"], "1.2.3")
        self.assertEqual(app["versions"][0]["size"], self.ipa.stat().st_size)
        self.assertEqual(app["versions"][0]["downloadURL"], f"https://github.com/{RELEASE_REPO}/releases/download/v1.2.3/StreamAnime-1.2.3-7.ipa")
        self.assertNotIn("marketplaceID", app)
        self.assertNotIn("buildVersion", app["versions"][0])
        self.assertEqual(app["appPermissions"], {"entitlements": [], "privacy": {}})
        self.assertFalse(any(self.output.rglob("*.ipa")), "Firebase Spark must only host the source and images")

    def test_preserves_history_and_refuses_stale_or_undetectable_updates(self):
        previous = build_site(self.ipa, self.output, "First", "2026-11-06")
        self.write_ipa(version="1.2.4", build="8")
        newer = build_site(self.ipa, self.output, "Second", previous=previous)
        self.assertEqual([v["version"] for v in newer["apps"][0]["versions"]], ["1.2.4", "1.2.3"])
        self.write_ipa(version="1.2.4", build="9")
        with self.assertRaisesRegex(ValueError, "marketing version"):
            build_site(self.ipa, self.output, "Same version", previous=newer)
        self.write_ipa(version="1.2.2", build="1")
        with self.assertRaisesRegex(ValueError, "older release"):
            build_site(self.ipa, self.output, "Old", previous=newer)

    def test_rejects_simulator_and_wrong_application(self):
        self.write_ipa(platform="iPhoneSimulator")
        with self.assertRaises(ValueError):
            build_site(self.ipa, self.output, "Invalid")
        self.write_ipa(bundle="com.example.other")
        with self.assertRaises(ValueError):
            build_site(self.ipa, self.output, "Invalid")

    def test_release_notes_are_escaped_in_download_page(self):
        build_site(self.ipa, self.output, '<script>alert("bad")</script>')
        page = (self.output / "index.html").read_text(encoding="utf-8")
        self.assertNotIn('<script>alert("bad")</script>', page)
        self.assertIn("&lt;script&gt;", page)


if __name__ == "__main__":
    unittest.main()
