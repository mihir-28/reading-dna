import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.package_release import build


class ReleasePackageTests(unittest.TestCase):
    def test_archive_contains_install_and_license_docs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            archive = build(Path(temp_dir))
            with zipfile.ZipFile(archive) as bundle:
                self.assertEqual(
                    set(bundle.namelist()),
                    {"reading_dna.lua", "README.md", "CHANGELOG.md", "LICENSE"},
                )
                self.assertIn(b"MODULE_VERSION = \"0.2.2\"", bundle.read("reading_dna.lua"))
            self.assertEqual(archive.name, "reading-dna-v0.2.2.zip")


if __name__ == "__main__":
    unittest.main()
