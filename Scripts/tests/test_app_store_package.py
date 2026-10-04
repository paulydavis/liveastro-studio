import plistlib
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/package_app_store.sh"
ENTITLEMENTS = ROOT / "Scripts/AppStore.entitlements"


class AppStorePackagingContractTests(unittest.TestCase):
    def test_packager_and_entitlements_exist(self):
        self.assertTrue(SCRIPT.is_file())
        self.assertTrue(ENTITLEMENTS.is_file())

    def test_entitlements_are_exactly_the_sandbox_store_set(self):
        self.assertEqual(
            plistlib.loads(ENTITLEMENTS.read_bytes()),
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-write": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.network.client": True,
            },
        )

    def test_packager_fails_closed_on_required_identity_and_uses_app_store_bundle(self):
        text = SCRIPT.read_text()
        self.assertIn('APP_BUNDLE_ID="com.pauldavis.liveastrostudio.appstore"', text)
        self.assertIn('AppStore.entitlements', text)
        self.assertIn('--installer-identity', text)
        self.assertIn('productbuild', text)
        self.assertIn('identity is required', text)

    def test_packager_rejects_unapproved_entitlement_surface(self):
        text = SCRIPT.read_text()
        self.assertIn('com.apple.security.app-sandbox', text)
        self.assertIn('com.apple.security.files.user-selected.read-write', text)
        self.assertIn('com.apple.security.files.bookmarks.app-scope', text)
        self.assertIn('com.apple.security.network.client', text)
        self.assertIn('unexpected entitlement', text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
