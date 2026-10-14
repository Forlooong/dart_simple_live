"""Regression checks for version bumps and the push-time release guard."""

from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import version


class VersionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workflow_dir = self.root / ".github/workflows"
        self.workflow_dir.mkdir(parents=True)
        for app, (directory, workflows) in version.APPS.items():
            package = self.root / directory
            package.mkdir()
            initial = "1.12.3+11104" if app == "main" else "1.7.0+10605"
            (package / "pubspec.yaml").write_text(f"name: {directory}\nversion: {initial}\n")
            for filename in workflows:
                (self.workflow_dir / filename).write_text('name: build\nrun-name: "Old title"\njobs: {}\n')
        version.update_versions(self.root, ("main", "tv"), bump=False)
        version.git(self.root, "init", "--quiet")
        version.git(self.root, "config", "user.name", "Version test")
        version.git(self.root, "config", "user.email", "version-test@example.invalid")
        version.git(self.root, "add", ".")
        version.git(self.root, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Initial")
        self.base = version.git(self.root, "rev-parse", "HEAD").strip()

    def change(self, relative_path, text="changed\n"):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        version.git(self.root, "add", relative_path)

    def test_bump_updates_all_main_titles_and_preserves_tv(self):
        tv_before = (self.workflow_dir / "fork_tv_apk.yml").read_bytes()
        versions = version.update_versions(self.root, ("main",), bump=True)
        self.assertEqual(versions, {"main": "1.12.4+11105"})
        self.assertEqual(version.check_sync(self.root, "main"), "1.12.4+11105")
        self.assertEqual(tv_before, (self.workflow_dir / "fork_tv_apk.yml").read_bytes())
        version.check_changes(self.root, "main", self.base)

    def test_source_edit_requires_both_increments(self):
        self.change("simple_live_app/lib/main.dart")
        for candidate in ("1.12.3+11104", "1.12.4+11104", "1.12.3+11105", "1.12.2+11105", "1.12.4+11103"):
            with self.subTest(candidate=candidate):
                self.change("simple_live_app/pubspec.yaml", f"version: {candidate}\n")
                with self.assertRaisesRegex(ValueError, "both version name and build number"):
                    version.check_changes(self.root, "main", self.base)
        self.change("simple_live_app/pubspec.yaml", "version: 1.12.4+11105\n")
        version.update_versions(self.root, ("main",), bump=False)
        version.check_changes(self.root, "main", self.base)
        version.check_sync(self.root, "main")
        version.check_changes(self.root, "tv", self.base)

    def test_shared_core_change_requires_both_apps_to_bump(self):
        self.change("simple_live_core/lib/core.dart")
        version.update_versions(self.root, ("main",), bump=True)
        version.check_changes(self.root, "main", self.base)
        with self.assertRaisesRegex(ValueError, "tv source changed"):
            version.check_changes(self.root, "tv", self.base)
        version.update_versions(self.root, ("tv",), bump=True)
        version.check_changes(self.root, "tv", self.base)

    def test_rebuild_and_docs_edit_reuse_committed_version(self):
        version.check_changes(self.root, "main", self.base)
        self.change("docs/readme.md")
        version.check_changes(self.root, "main", self.base)
        version.check_changes(self.root, "tv", self.base)

    def test_stale_workflow_title_fails(self):
        self.change(".github/workflows/fork_ios.yml", 'run-name: "Release iOS · 1.12.3"\n')
        with self.assertRaisesRegex(ValueError, "fork_ios.yml"):
            version.check_sync(self.root, "main")

    def test_invalid_workflow_does_not_partially_bump_files(self):
        pubspec = self.root / "simple_live_app/pubspec.yaml"
        before = pubspec.read_bytes()
        self.change(".github/workflows/fork_linux.yml", "name: missing-title\n")
        with self.assertRaisesRegex(ValueError, "expected one run-name"):
            version.update_versions(self.root, ("main",), bump=True)
        self.assertEqual(pubspec.read_bytes(), before)

    def test_retries_and_commits_have_distinct_artifact_names(self):
        environment = {
            "GITHUB_SHA": "a" * 40, "GITHUB_RUN_NUMBER": "25", "GITHUB_RUN_ATTEMPT": "1"
        }
        first = version.build_metadata("1.12.4+11105", environment)
        self.assertEqual(first["artifact_version"], "1.12.4+11105-r25.1-aaaaaaa")
        environment["GITHUB_RUN_ATTEMPT"] = "2"
        retry = version.build_metadata("1.12.4+11105", environment)
        environment.update(GITHUB_RUN_NUMBER="26", GITHUB_SHA="b" * 40)
        other = version.build_metadata("1.12.4+11105", environment)
        self.assertEqual(len({item["artifact_version"] for item in (first, retry, other)}), 3)
        for item in (first, retry, other):
            self.assertEqual(item["package_version"], "1.12.4+11105")
            self.assertEqual(item["build_number"], "11105")

    def test_push_metadata_rejects_missing_bump_then_emits_committed_version(self):
        self.change("simple_live_app/lib/main.dart")
        event = self.root / "event.json"
        event.write_text(json.dumps({"before": self.base}), encoding="utf-8")
        output = self.root / "output.txt"
        summary = self.root / "summary.md"
        environment = {
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_NUMBER": "25",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_EVENT_PATH": str(event),
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(summary),
        }
        with patch.object(version, "ROOT", self.root), patch.dict(os.environ, environment), \
                patch.object(sys, "argv", ["version.py", "metadata", "main"]), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "main source changed"):
                version.main()
            self.assertFalse(output.exists())
            version.update_versions(self.root, ("main",), bump=True)
            version.main()
        values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        self.assertEqual(values["version"], "1.12.4")
        self.assertEqual(values["build_number"], "11105")
        self.assertEqual(values["artifact_version"], "1.12.4+11105-r25.1-aaaaaaa")
        self.assertIn("1.12.4+11105", summary.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
