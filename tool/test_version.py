"""Regression checks for shared titles, package limits and build version guards."""

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
        self.workflow = self.root / version.WORKFLOW
        self.workflow.parent.mkdir(parents=True)
        self.workflow.write_text('name: build\nrun-name: "Old title"\njobs: {}\n', encoding="utf-8")
        for app, directory in version.APPS.items():
            package = self.root / directory
            package.mkdir()
            initial = "1.12.3+11104" if app == "main" else "1.7.0+10605"
            (package / "pubspec.yaml").write_text(f"name: {directory}\nversion: {initial}\n", encoding="utf-8")
        version.update_versions(self.root, ("main", "tv"), bump=False)
        version.git(self.root, "init", "--quiet")
        version.git(self.root, "config", "user.name", "Version test")
        version.git(self.root, "config", "user.email", "version-test@example.invalid")
        self.base = self.commit("Initial")

    def commit(self, message):
        version.git(self.root, "add", ".")
        version.git(self.root, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message)
        return version.git(self.root, "rev-parse", "HEAD").strip()

    def change(self, relative_path, text="changed\n"):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        version.git(self.root, "add", relative_path)

    def set_version(self, app, value):
        self.change(f"{version.APPS[app]}/pubspec.yaml", f"version: {value}\n")

    def metadata(self, event_name="workflow_dispatch", app="main", before=None, extra_args=()):
        event = self.root / "event.json"
        event.write_text(json.dumps({"before": self.base if before is None else before}), encoding="utf-8")
        environment = {
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_NUMBER": "25",
            "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_EVENT_NAME": event_name,
            "GITHUB_EVENT_PATH": str(event),
            "GITHUB_OUTPUT": str(self.root / "output.txt"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary.md"),
        }
        with patch.object(version, "ROOT", self.root), patch.dict(os.environ, environment), \
                patch.object(sys, "argv", ["version.py", "metadata", app, *extra_args]), \
                redirect_stdout(io.StringIO()):
            version.main()
        return dict(line.split("=", 1) for line in (self.root / "output.txt").read_text(encoding="utf-8").splitlines())

    def test_bump_main_updates_shared_title_and_preserves_tv_pubspec(self):
        tv_before = (self.root / version.APPS["tv"] / "pubspec.yaml").read_bytes()
        versions = version.update_versions(self.root, ("main",), bump=True)
        self.assertEqual(versions, {"main": "1.12.4+11105"})
        self.assertEqual(version.check_sync(self.root, "main"), "1.12.4+11105")
        self.assertEqual(version.check_sync(self.root, "tv"), "1.7.0+10605")
        self.assertEqual(tv_before, (self.root / version.APPS["tv"] / "pubspec.yaml").read_bytes())
        self.assertIn('run-name: "Build all platforms · Main 1.12.4+11105 · TV 1.7.0+10605 · #${{ github.run_number }}"', self.workflow.read_text(encoding="utf-8"))
        version.check_changes(self.root, "main", self.base)
        version.check_changes(self.root, "tv", self.base)

    def test_bump_tv_preserves_main_pubspec(self):
        main_before = (self.root / version.APPS["main"] / "pubspec.yaml").read_bytes()
        self.assertEqual(version.update_versions(self.root, ("tv",), bump=True), {"tv": "1.7.1+10606"})
        self.assertEqual(main_before, (self.root / version.APPS["main"] / "pubspec.yaml").read_bytes())
        version.check_sync(self.root, "main")
        version.check_sync(self.root, "tv")
        version.check_changes(self.root, "main", self.base)

    def test_bump_both_updates_shared_title_once(self):
        self.assertEqual(version.update_versions(self.root, ("main", "tv"), bump=True), {
            "main": "1.12.4+11105", "tv": "1.7.1+10606",
        })
        for app in version.APPS:
            version.check_sync(self.root, app)
            version.check_changes(self.root, app, self.base)
        self.assertEqual(len(version.TITLE_LINE.findall(self.workflow.read_text(encoding="utf-8"))), 1)

    def test_sync_changes_no_pubspec(self):
        before = {app: (self.root / directory / "pubspec.yaml").read_bytes() for app, directory in version.APPS.items()}
        self.change(version.WORKFLOW, 'name: build\nrun-name: "stale"\njobs: {}\n')
        version.update_versions(self.root, ("main",), bump=False)
        for app, directory in version.APPS.items():
            self.assertEqual((self.root / directory / "pubspec.yaml").read_bytes(), before[app])
            version.check_sync(self.root, app)

    def test_source_edit_requires_both_increments(self):
        self.change("simple_live_app/lib/main.dart")
        for candidate in ("1.12.3+11104", "1.12.4+11104", "1.12.3+11105", "1.12.2+11105", "1.12.4+11103"):
            with self.subTest(candidate=candidate):
                self.set_version("main", candidate)
                with self.assertRaisesRegex(ValueError, "both version name and build number"):
                    version.check_changes(self.root, "main", self.base)
        self.set_version("main", "1.12.4+11105")
        version.update_versions(self.root, ("main",), bump=False)
        version.check_changes(self.root, "main", self.base)
        version.check_sync(self.root, "main")
        version.check_changes(self.root, "tv", self.base)

    def test_semver_comparison_is_numeric(self):
        self.set_version("main", "1.13.0+11105")
        version.check_changes(self.root, "main", self.base)
        self.set_version("main", "2.0.0+11105")
        version.check_changes(self.root, "main", self.base)
        self.set_version("main", "1.9.99+11105")
        with self.assertRaisesRegex(ValueError, "both version name and build number"):
            version.check_changes(self.root, "main", self.base)

    def test_app_specific_change_does_not_require_other_app_bump(self):
        self.change("simple_live_tv_app/lib/main.dart")
        version.check_changes(self.root, "main", self.base)
        with self.assertRaisesRegex(ValueError, "tv source changed"):
            version.check_changes(self.root, "tv", self.base)

    def test_shared_inputs_require_both_apps_to_bump(self):
        for path in ("simple_live_core/lib/core.dart", "packages/canvas_danmaku/lib/canvas_danmaku.dart",
                     ".github/actions/setup/action.yml", "tool/build.py"):
            with self.subTest(path=path):
                self.change(path)
                for app in version.APPS:
                    with self.assertRaisesRegex(ValueError, f"{app} source changed"):
                        version.check_changes(self.root, app, self.base)
                version.git(self.root, "reset", "--quiet", "HEAD", "--", path)
                (self.root / path).unlink()
        self.change("simple_live_core/lib/core.dart")
        version.update_versions(self.root, ("main",), bump=True)
        version.check_changes(self.root, "main", self.base)
        with self.assertRaisesRegex(ValueError, "tv source changed"):
            version.check_changes(self.root, "tv", self.base)
        version.update_versions(self.root, ("tv",), bump=True)
        version.check_changes(self.root, "tv", self.base)

    def test_workflow_content_change_requires_both_apps_to_bump(self):
        self.change(version.WORKFLOW, self.workflow.read_text(encoding="utf-8").replace("jobs: {}", "jobs: {build: {}}"))
        for app in version.APPS:
            with self.assertRaisesRegex(ValueError, f"{app} source changed"):
                version.check_changes(self.root, app, self.base)
        version.update_versions(self.root, ("main", "tv"), bump=True)
        for app in version.APPS:
            version.check_changes(self.root, app, self.base)

    def test_workflow_title_only_edit_is_not_a_shared_input_change(self):
        self.change(version.WORKFLOW, version.TITLE_LINE.sub('run-name: "different title"', self.workflow.read_text(encoding="utf-8")))
        for app in version.APPS:
            version.check_changes(self.root, app, self.base)
        with self.assertRaisesRegex(ValueError, "title does not match"):
            version.check_sync(self.root, "main")

    def test_deleted_installer_input_requires_bump(self):
        self.change("tool/package.py")
        version.update_versions(self.root, ("main", "tv"), bump=True)
        base = self.commit("Add packaging input")
        version.git(self.root, "rm", "--quiet", "tool/package.py")
        for app in version.APPS:
            with self.assertRaisesRegex(ValueError, f"{app} source changed"):
                version.check_changes(self.root, app, base)

    def test_rebuild_and_docs_edit_reuse_committed_version(self):
        for app in version.APPS:
            version.check_changes(self.root, app, self.base)
            version.check_history(self.root, app)
        self.change("docs/readme.md")
        self.change("README.md")
        self.commit("Docs only")
        for app in version.APPS:
            version.check_changes(self.root, app, self.base)
            version.check_history(self.root, app)
        self.assertEqual(self.metadata()["package_version"], "1.12.3+11104")

    def test_stale_workflow_title_fails_for_either_app(self):
        self.change(version.WORKFLOW, 'run-name: "Release iOS · 1.12.3"\n')
        for app in version.APPS:
            with self.assertRaisesRegex(ValueError, "fork_all_platforms.yml"):
                version.check_sync(self.root, app)

    def test_invalid_workflow_does_not_partially_bump_files(self):
        before = {app: (self.root / directory / "pubspec.yaml").read_bytes() for app, directory in version.APPS.items()}
        for text in ("name: missing-title\n", 'run-name: "a"\nrun-name: "b"\n'):
            with self.subTest(text=text):
                self.change(version.WORKFLOW, text)
                with self.assertRaisesRegex(ValueError, "expected one run-name"):
                    version.update_versions(self.root, ("main", "tv"), bump=True)
                for app, directory in version.APPS.items():
                    self.assertEqual((self.root / directory / "pubspec.yaml").read_bytes(), before[app])

    def test_invalid_other_app_prevents_partial_bump(self):
        main = self.root / version.APPS["main"] / "pubspec.yaml"
        before = main.read_bytes()
        title_before = self.workflow.read_bytes()
        self.set_version("tv", "not-a-version")
        with self.assertRaisesRegex(ValueError, "pubspec version"):
            version.update_versions(self.root, ("main",), bump=True)
        self.assertEqual(main.read_bytes(), before)
        self.assertEqual(self.workflow.read_bytes(), title_before)

    def test_malformed_versions_rejected(self):
        for value in ("1.2+3", "1.2.3", "1.2.3-beta+4", "01.2.3+4", "1.2.3+-1", "1.2.3+4 extra", "１.2.3+4"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "pubspec version"):
                version.read_version(f"version: {value}\n")
        with self.assertRaisesRegex(ValueError, "pubspec version"):
            version.read_version("version: 1.2.3+4\nversion: 1.2.4+5\n")
        with self.assertRaisesRegex(ValueError, "pubspec version"):
            version.read_version("version: 1.2.3+4\nversion: malformed duplicate\n")

    def test_windows_component_upper_bound_inclusive(self):
        version.validate_version("main", "65535.65535.65535+65535")
        for value in ("65536.1.2+3", "1.65536.2+3", "1.2.65536+3", "1.2.3+65536"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "Windows version components"):
                version.validate_version("main", value)
        version.validate_version("tv", "65536.65536.65536+65536")

    def test_android_abi_offset_upper_bound_inclusive(self):
        version.validate_version("tv", "1.2.3+2099996000")
        for app in version.APPS:
            # Isolate the Android rule; main normally hits its stricter Windows limit first.
            with patch.object(version, "WINDOWS_MAX_COMPONENT", 3000000000):
                version.validate_version(app, "1.2.3+2099996000")
                with self.assertRaisesRegex(ValueError, "Android build number"):
                    version.validate_version(app, "1.2.3+2099996001")

    def test_bound_failure_does_not_partially_bump_files(self):
        for app, value in (("main", "1.2.65535+11104"), ("main", "1.2.3+65535"), ("tv", "1.2.3+2099996000")):
            with self.subTest(app=app, value=value):
                self.set_version("main", "1.12.3+11104")
                self.set_version("tv", "1.7.0+10605")
                self.set_version(app, value)
                version.update_versions(self.root, ("main", "tv"), bump=False)
                paths = [self.workflow, *(self.root / directory / "pubspec.yaml" for directory in version.APPS.values())]
                before = {path: path.read_bytes() for path in paths}
                with self.assertRaisesRegex(ValueError, "Windows version components|Android build number"):
                    version.update_versions(self.root, ("main", "tv"), bump=True)
                for path in paths:
                    self.assertEqual(path.read_bytes(), before[path])

    def test_sync_rejects_out_of_range_committed_version(self):
        self.set_version("main", "1.12.3+65536")
        with self.assertRaisesRegex(ValueError, "Windows version components"):
            version.check_sync(self.root, "main")

    def test_retries_and_commits_have_distinct_artifact_names(self):
        environment = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_NUMBER": "999999", "GITHUB_RUN_ATTEMPT": "1"}
        first = version.build_metadata("1.12.4+11105", environment)
        self.assertEqual(first["artifact_version"], "1.12.4+11105-r999999.1-aaaaaaa")
        environment["GITHUB_RUN_ATTEMPT"] = "2"
        retry = version.build_metadata("1.12.4+11105", environment)
        environment.update(GITHUB_RUN_NUMBER="1000000", GITHUB_SHA="b" * 40)
        other = version.build_metadata("1.12.4+11105", environment)
        self.assertEqual(len({item["artifact_version"] for item in (first, retry, other)}), 3)
        for item in (first, retry, other):
            self.assertEqual(item["version"], "1.12.4")
            self.assertEqual(item["package_version"], "1.12.4+11105")
            self.assertEqual(item["build_number"], "11105")

    def test_invalid_build_identity_rejected(self):
        environment = {"GITHUB_SHA": "a" * 40, "GITHUB_RUN_NUMBER": "25", "GITHUB_RUN_ATTEMPT": "1"}
        for key, value in (("GITHUB_SHA", "HEAD"), ("GITHUB_RUN_NUMBER", "0"), ("GITHUB_RUN_ATTEMPT", "-1")):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Invalid GitHub build identity"):
                version.build_metadata("1.12.4+11105", {**environment, key: value})

    def test_push_metadata_rejects_missing_bump_then_emits_committed_version(self):
        self.change("simple_live_app/lib/main.dart")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata("push")
        self.assertFalse((self.root / "output.txt").exists())
        version.update_versions(self.root, ("main",), bump=True)
        values = self.metadata("push")
        self.assertEqual(values["version"], "1.12.4")
        self.assertEqual(values["build_number"], "11105")
        self.assertEqual(values["artifact_version"], "1.12.4+11105-r25.1-aaaaaaa")
        self.assertIn("1.12.4+11105", (self.root / "summary.md").read_text(encoding="utf-8"))

    def test_manual_metadata_cannot_bypass_failed_push(self):
        self.change("simple_live_app/lib/main.dart")
        bad = self.commit("Forgot version")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata("push")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata(extra_args=("--base", bad))
        self.assertFalse((self.root / "output.txt").exists())

    def test_docs_after_unversioned_source_do_not_bypass_history_guard(self):
        self.change("simple_live_app/lib/main.dart")
        bad = self.commit("Forgot version")
        self.change("docs/readme.md")
        self.commit("Docs only")
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event), self.assertRaisesRegex(ValueError, "main source changed"):
                self.metadata(event, before=bad)
        self.assertFalse((self.root / "output.txt").exists())

    def test_corrective_bump_unblocks_history_guard(self):
        self.change("simple_live_app/lib/main.dart")
        self.commit("Forgot version")
        self.change("docs/readme.md")
        self.commit("Docs only")
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Correct package version")
        self.assertEqual(self.metadata()["package_version"], "1.12.4+11105")
        version.check_history(self.root, "tv")

    def test_source_change_after_version_commit_requires_new_bump(self):
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Version first")
        self.change("simple_live_app/lib/main.dart")
        self.commit("Changed source later")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata()
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Bump after final source change")
        self.assertEqual(self.metadata()["package_version"], "1.12.5+11106")

    def test_shared_change_history_requires_tv_bump_even_after_main_bump(self):
        self.change("tool/build.py")
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Changed tooling and bumped main only")
        version.check_history(self.root, "main")
        with self.assertRaisesRegex(ValueError, "tv source changed"):
            self.metadata(app="tv")
        version.update_versions(self.root, ("tv",), bump=True)
        self.commit("Bump TV too")
        self.assertEqual(self.metadata(app="tv")["package_version"], "1.7.1+10606")

    def test_title_only_history_does_not_force_other_app_bump(self):
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Bump main only")
        self.change("docs/readme.md")
        self.commit("Docs after main bump")
        self.assertEqual(self.metadata(app="tv")["package_version"], "1.7.0+10605")

    def test_new_branch_push_with_zero_before_still_checks_history(self):
        self.change("simple_live_app/lib/main.dart")
        self.commit("Unversioned source on new branch")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata("push", before="0" * 40)

    def test_missing_push_before_still_checks_history(self):
        self.change("simple_live_app/lib/main.dart")
        self.commit("Unversioned source")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata("push", before="")

    def test_shallow_history_fails_closed(self):
        (self.root / ".git/shallow").write_text(self.base + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "fetch-depth: 0"):
            self.metadata()
        self.assertFalse((self.root / "output.txt").exists())

    def test_merge_with_unversioned_inputs_fails_history_guard(self):
        primary = version.git(self.root, "symbolic-ref", "--short", "HEAD").strip()
        version.git(self.root, "checkout", "--quiet", "-b", "feature")
        self.change("simple_live_app/lib/main.dart")
        self.commit("Unversioned feature")
        version.git(self.root, "checkout", "--quiet", primary)
        self.change("docs/readme.md")
        self.commit("Mainline docs")
        version.git(self.root, "-c", "commit.gpgsign=false", "merge", "--quiet", "--no-ff", "--no-edit", "feature")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata()

    def test_merge_with_versioned_inputs_passes_history_guard(self):
        primary = version.git(self.root, "symbolic-ref", "--short", "HEAD").strip()
        version.git(self.root, "checkout", "--quiet", "-b", "feature")
        self.change("simple_live_app/lib/main.dart")
        version.update_versions(self.root, ("main",), bump=True)
        self.commit("Versioned feature")
        version.git(self.root, "checkout", "--quiet", primary)
        self.change("docs/readme.md")
        self.commit("Mainline docs")
        version.git(self.root, "-c", "commit.gpgsign=false", "merge", "--quiet", "--no-ff", "--no-edit", "feature")
        self.assertEqual(self.metadata()["package_version"], "1.12.4+11105")
        version.check_history(self.root, "tv")

    def test_initial_version_is_a_valid_history_baseline(self):
        for app in version.APPS:
            version.check_history(self.root, app)
        self.assertEqual(self.metadata("push", before="0" * 40)["package_version"], "1.12.3+11104")

    def test_uncommitted_installer_changes_are_guarded(self):
        self.change("simple_live_app/lib/main.dart")
        with self.assertRaisesRegex(ValueError, "main source changed"):
            self.metadata()

    def test_metadata_requires_exactly_one_app(self):
        with self.assertRaisesRegex(ValueError, "exactly one app"):
            self.metadata(app="both")
        self.assertFalse((self.root / "output.txt").exists())

    def test_base_requires_full_sha(self):
        for value in ("HEAD", "a" * 39, "--help", "z" * 40):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "full Git commit SHA"):
                version.check_changes(self.root, "main", value)


if __name__ == "__main__":
    unittest.main()
