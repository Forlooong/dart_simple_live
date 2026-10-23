"""Offline checks for the manual unified-release trust boundary."""
import copy
import unittest
from pathlib import Path
import tempfile
from prepare_update_release import JOBS, TARGETS, validate_run, verify_uploaded, sha, minimum_sdk


class UpdateReleaseTest(unittest.TestCase):
    def test_build_tools_minimum_sdk_spacing(self):
        for row in ("sdkVersion:'24'", "sdkVersion: '24'", "  sdkVersion: '24'\r\n"):
            self.assertEqual(minimum_sdk(row), 24)
        with self.assertRaises(ValueError):
            minimum_sdk("targetSdkVersion:'36'")

    def setUp(self):
        self.run = {'repository': {'full_name': 'Forlooong/dart_simple_live'},
            'head_repository': {'full_name': 'Forlooong/dart_simple_live'},
            'head_branch': 'master', 'event': 'push',
            'path': '.github/workflows/installers.yml', 'status': 'completed',
            'conclusion': 'success', 'run_attempt': 2}
        self.jobs = [{'name': name, 'conclusion': 'success', 'run_attempt': 2}
                     for name in JOBS]

    def test_complete_run_and_ten_target_packages(self):
        validate_run(self.run, self.jobs)
        self.assertEqual(len(TARGETS), 10)
        self.assertEqual(len(set(TARGETS)), 10)

    def test_untrusted_or_incomplete_run_is_rejected(self):
        for key, value in [('event', 'pull_request'), ('head_branch', 'other'),
                           ('conclusion', 'failure'), ('status', 'in_progress'),
                           ('path', '.github/workflows/other.yml')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_run({**self.run, key: value}, self.jobs)
        run = copy.deepcopy(self.run)
        run['head_repository']['full_name'] = 'someone/fork'
        with self.assertRaises(ValueError):
            validate_run(run, self.jobs)
        with self.assertRaises(ValueError):
            validate_run(self.run, self.jobs[:-1])
        jobs = copy.deepcopy(self.jobs)
        jobs[0]['run_attempt'] = 1
        with self.assertRaises(ValueError):
            validate_run(self.run, jobs)

    def test_promotion_requires_exact_uploaded_files_and_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'test.apk'
            package.write_bytes(b'test installer')
            asset = {'name': package.name, 'size': package.stat().st_size,
                     'state': 'uploaded', 'digest': 'sha256:' + sha(package)}
            verify_uploaded([asset], root)
            for assets in ([], [asset, asset], [{**asset, 'state': 'new'}],
                           [{**asset, 'digest': 'sha256:' + '00' * 32}]):
                with self.assertRaises(ValueError):
                    verify_uploaded(assets, root)


if __name__ == '__main__':
    unittest.main()
