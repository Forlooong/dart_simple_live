import unittest

from release_metadata import tv_release_metadata


class ReleaseMetadataTest(unittest.TestCase):
    def test_source_version_controls_release(self):
        metadata = tv_release_metadata("1.7.1+10606", "tv_1.7.1")
        self.assertEqual(metadata["release_name"], "Simple Live TV 1.7.1+10606")
        self.assertEqual(metadata["build_number"], "10606")

    def test_stale_or_wrong_tag_fails_closed(self):
        for tag in ("tv_1.3.5", "v1.7.1", "tv_1.7.1-rc1", "tv_1.7.1\n"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                tv_release_metadata("1.7.1+10606", tag)


if __name__ == "__main__":
    unittest.main()
