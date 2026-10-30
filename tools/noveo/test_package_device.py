import tempfile
import unittest
from pathlib import Path
from package_device import link_archive, validate_device


class DevicePackagingTests(unittest.TestCase):
    def test_both_extensions_share_original_inode_and_retry_is_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'original.ipa'
            source.write_bytes(b'device archive content')
            for suffix in ('ipa', 'tipa'):
                artifact = Path(directory) / ('Noveo-test.' + suffix)
                link_archive(source, artifact)
                link_archive(source, artifact)
                self.assertTrue(source.samefile(artifact))
                self.assertEqual(source.read_bytes(), artifact.read_bytes())
            self.assertEqual(source.stat().st_nlink, 3)

    def test_refuses_to_overwrite_an_unrelated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'original.ipa'
            source.write_bytes(b'new archive')
            target = Path(directory) / 'Noveo-test.tipa'
            target.write_bytes(b'previous archive')
            with self.assertRaises(FileExistsError):
                link_archive(source, target)
            self.assertEqual(target.read_bytes(), b'previous archive')

    def test_arm64_simulator_binary_cannot_be_published_as_device(self):
        info = {'CFBundleSupportedPlatforms': ['iPhoneOS'], 'CFBundleIdentifier': 'ir.noveo.ios'}
        validate_device(info, 'platform IOS\narchitecture arm64')
        with self.assertRaises(ValueError):
            validate_device(info, 'platform IOSSIMULATOR\narchitecture arm64')


if __name__ == '__main__':
    unittest.main()
