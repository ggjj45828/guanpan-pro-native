import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from verify_ipa import verify_ipa


class VerifyIPATests(unittest.TestCase):
    def make_ipa(self, *, app_name="GuanpanPro.app", executable="GuanpanPro"):
        temp = tempfile.NamedTemporaryFile(suffix=".ipa", delete=False)
        temp.close()
        self.addCleanup(lambda: Path(temp.name).unlink(missing_ok=True))
        with zipfile.ZipFile(temp.name, "w") as archive:
            base = f"Payload/{app_name}/"
            archive.writestr(base + "Info.plist", plistlib.dumps({
                "CFBundleExecutable": executable,
                "CFBundleName": "GuanpanPro",
                "CFBundleIdentifier": "com.guanpan.pro.native",
            }))
            archive.writestr(base + executable, b"\xcf\xfa\xed\xfe" + b"binary")
        return temp.name

    def test_accepts_ascii_bundle_and_matching_executable(self):
        result = verify_ipa(self.make_ipa())
        self.assertEqual(result["executable"], "GuanpanPro")

    def test_rejects_unicode_bundle_path_that_breaks_windows_signing_tools(self):
        with self.assertRaisesRegex(ValueError, "ASCII"):
            verify_ipa(self.make_ipa(app_name="观盘 Pro.app"))

    def test_rejects_unicode_executable_from_legacy_build(self):
        with self.assertRaisesRegex(ValueError, "ASCII filename"):
            verify_ipa(self.make_ipa(executable="观盘 Pro"))

    def test_rejects_missing_executable_path(self):
        temp = tempfile.NamedTemporaryFile(suffix=".ipa", delete=False)
        temp.close()
        self.addCleanup(lambda: Path(temp.name).unlink(missing_ok=True))
        with zipfile.ZipFile(temp.name, "w") as archive:
            base = "Payload/GuanpanPro.app/"
            archive.writestr(base + "Info.plist", plistlib.dumps({
                "CFBundleExecutable": "WrongName",
                "CFBundleName": "GuanpanPro",
                "CFBundleIdentifier": "com.guanpan.pro.native",
            }))
            archive.writestr(base + "GuanpanPro", b"\xcf\xfa\xed\xfe" + b"binary")
        with self.assertRaisesRegex(ValueError, "path is missing"):
            verify_ipa(temp.name)


if __name__ == "__main__":
    unittest.main()
