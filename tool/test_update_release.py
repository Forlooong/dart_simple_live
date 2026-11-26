"""Offline checks for the manual unified-release trust boundary."""
import copy
import base64
import unittest
from pathlib import Path
import tempfile
from subprocess import CompletedProcess
from unittest.mock import patch
from prepare_update_release import (
    JOBS, TARGETS, minimum_sdk, notes_for_app, release_body, release_changes, sha,
    validate_run, verify_uploaded,
)


class UpdateReleaseTest(unittest.TestCase):
    def test_versioned_notes_can_target_main_and_tv(self):
        notes = '## 共通\n修复播放器\n\n## 主应用\n修复提醒\n\n## TV\n修复焦点'
        self.assertEqual(notes_for_app(notes, 'main'), '共通\n修复播放器\n\n主应用\n修复提醒')
        self.assertEqual(notes_for_app(notes, 'tv'), '共通\n修复播放器\n\nTV\n修复焦点')
        self.assertEqual(notes_for_app('旧版说明', 'tv'), '旧版说明')

    def test_prefers_reviewed_notes_for_exact_version_and_falls_back_to_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes_dir = root / 'docs' / 'release-notes'
            notes_dir.mkdir(parents=True)
            tag = 'fork-main-1.12.30-build11131-tv-1.7.20-build10625'
            notes = '抖音搜索\n• 支持按关键词查找主播。'
            (notes_dir / f'{tag}.txt').write_text(notes + '\n', encoding='utf-8')
            history = CompletedProcess([], 0, stdout='fix: older title\n')
            with patch('prepare_update_release.subprocess.run', return_value=history) as git:
                self.assertEqual(release_changes(root, 'a' * 40, 'b' * 40, tag), notes)
                git.assert_not_called()
                self.assertEqual(
                    release_changes(root, 'a' * 40, 'b' * 40, 'another-tag'),
                    '- fix: older title',
                )

    def test_release_body_embeds_exact_manifest_bytes(self):
        data = '{"notes":"更新详情"}\n'.encode('utf-8')
        notes, blank, marker, encoded, end = release_body('版本说明', data).splitlines()
        self.assertEqual(notes, '版本说明')
        self.assertEqual(blank, '')
        self.assertEqual(marker, '<!-- simple-live-update-manifest:v1')
        self.assertEqual(base64.b64decode(encoded), data)
        self.assertEqual(end, '-->')

    def test_build_tools_minimum_sdk_spacing(self):
        for row in ("sdkVersion:'24'", "sdkVersion: '24'", "  sdkVersion: '24'\r\n", "minSdkVersion:'24'"):
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

    def test_complete_run_and_eight_target_packages(self):
        validate_run(self.run, self.jobs)
        self.assertEqual(len(TARGETS), 8)
        self.assertEqual(len(set(TARGETS)), 8)
        self.assertEqual(JOBS, {'android-apk', 'tv-apk', 'windows', 'linux'})
        self.assertEqual({target[2] for target in TARGETS}, {'android', 'windows', 'linux'})
        for name in ('ios', 'macos'):
            extra = {'name': name, 'conclusion': 'success', 'run_attempt': 2}
            with self.subTest(name=name), self.assertRaises(ValueError):
                validate_run(self.run, [*self.jobs, extra])

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
