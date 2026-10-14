"""Offline fixtures: publisher gates and release state machine never use GitHub."""

import copy
import datetime as dt
import io
import json
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import publish_prerelease as p


def plan():
    value = json.loads((p.ROOT / "tool/prerelease-target.json").read_text())
    value["enabled"] = True
    for index, pin in enumerate(value["runs"].values(), 1):
        pin["id"], pin["attempt"] = index, 1
    return value


def run_fixture(platform, target):
    workflow, job, _, steps = p.PLATFORMS[platform]
    run = {"id": target["runs"][platform]["id"], "run_attempt": 1, "run_number": 11,
           "head_sha": target["source_sha"], "head_branch": p.BRANCH, "event": "push",
           "repository": {"id": 12, "full_name": p.REPOSITORY},
           "head_repository": {"id": 12, "full_name": p.REPOSITORY},
           "path": ".github/workflows/" + workflow, "status": "completed", "conclusion": "success",
           "run_started_at": "2026-10-14T12:00:00Z"}
    jobs = [{"name": job, "status": "completed", "conclusion": "success", "run_attempt": 1,
             "head_sha": target["source_sha"], "steps": [
                 {"name": name, "status": "completed", "conclusion": "success"}
                 for name in p.COMMON_STEPS + steps]}]
    return run, jobs


def artifact_fixture(platform, target, run):
    return {"id": run["id"] * 100, "name": p.artifact_identity(platform, run, target)[1],
            "expired": False, "size_in_bytes": 100, "digest": "sha256:" + "a" * 64,
            "expires_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=5)).isoformat(),
            "created_at": "2026-10-14T12:30:00Z", "workflow_run": {
                "id": run["id"], "repository_id": 12, "head_repository_id": 12,
                "head_sha": target["source_sha"], "head_branch": p.BRANCH}}


class PlanAndRunTests(unittest.TestCase):
    def test_disabled_plan_cannot_request_api(self):
        target = plan()
        target["enabled"] = False
        with patch.object(p.Path, "read_text", return_value=json.dumps(target)), patch.object(p, "GitHub") as api:
            p.main()
        api.assert_not_called()

    def test_plan_pins_all_platforms_and_strict_versions(self):
        target = plan()
        p.validate_plan(target)
        for mutate in (
            lambda value: value["runs"].pop("tv"),
            lambda value: value.update(source_sha="main"),
            lambda value: value.update(main_version="1.12.8"),
            lambda value: value["runs"]["android"].update(id=0),
            lambda value: value["runs"]["android"].update(id=True),
            lambda value: value["runs"]["android"].update(signing="ProductionGuaranteed"),
            lambda value: value["runs"]["tv"].update(id=value["runs"]["android"]["id"]),
        ):
            value = copy.deepcopy(target)
            mutate(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.validate_plan(value)

    def test_tag_cannot_trigger_legacy_workflows(self):
        tag = p.release_tag(plan())
        self.assertFalse(tag.startswith(("v", "tv_", "dev_v", "dev_tv_v")))
        self.assertIn(plan()["source_sha"][:12], tag)

    def test_context_blocks_fork_pr_and_unbuilt_changes(self):
        target = plan()
        env = {"GITHUB_REPOSITORY": p.REPOSITORY, "GITHUB_EVENT_NAME": "push",
               "GITHUB_REF": "refs/heads/" + p.BRANCH, "GITHUB_SHA": "d" * 40}
        def git(*args):
            if args[1] == "rev-parse":
                return "d" * 40
            if args[1] == "diff":
                return "tool/prerelease-target.json\n"
            if args[1] == "show":
                return "version: " + target["tv_version" if "tv_app" in args[2] else "main_version"] + "\n"
            return ""
        with patch.object(p, "command", side_effect=git):
            p.validate_context(target, env)
            for key, value in (("GITHUB_REPOSITORY", "attacker/fork"), ("GITHUB_EVENT_NAME", "pull_request"),
                               ("GITHUB_REF", "refs/heads/master"), ("GITHUB_SHA", "main")):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    p.validate_context(target, {**env, key: value})
        def changed(*args):
            return "simple_live_app/lib/main.dart\n" if args[1] == "diff" else git(*args)
        with patch.object(p, "command", side_effect=changed), self.assertRaisesRegex(ValueError, "unbuilt"):
            p.validate_context(target, env)

    def test_six_exact_runs(self):
        target = plan()
        for platform in p.PLATFORMS:
            run, jobs = run_fixture(platform, target)
            p.validate_run(platform, run, jobs, target)
            for key, value in (("head_sha", "b" * 40), ("head_branch", "other"), ("event", "pull_request_target"),
                               ("run_attempt", 2), ("path", ".github/workflows/other.yml"), ("conclusion", "failure"),
                               ("status", "in_progress")):
                changed = {**run, key: value}
                with self.subTest(platform=platform, key=key), self.assertRaises(ValueError):
                    p.validate_run(platform, changed, jobs, target)
            with self.assertRaises(ValueError):
                p.validate_run(platform, run, [], target)
            changed = copy.deepcopy(jobs)
            changed[0]["steps"][0]["conclusion"] = "skipped"
            with self.assertRaisesRegex(ValueError, "skipped"):
                p.validate_run(platform, run, changed, target)
            changed = copy.deepcopy(jobs)
            changed[0]["steps"].pop()
            with self.assertRaisesRegex(ValueError, "missing"):
                p.validate_run(platform, run, changed, target)
            changed = copy.deepcopy(jobs)
            changed[0]["run_attempt"] = 2
            with self.assertRaises(ValueError):
                p.validate_run(platform, run, changed, target)

    def test_artifact_identity_expiry_digest_and_attempt(self):
        target = plan()
        run, _ = run_fixture("android", target)
        artifact = artifact_fixture("android", target, run)
        self.assertEqual(p.choose_artifact("android", [artifact], run, target), artifact)
        for values in ([], [artifact, artifact], [{**artifact, "expired": True}], [{**artifact, "digest": None}],
                       [{**artifact, "name": artifact["name"].replace("r11.1", "r11.2")}],
                       [{**artifact, "expires_at": "2020-01-01T00:00:00Z"}],
                       [{**artifact, "created_at": "2026-10-14T11:00:00Z"}],
                       [{**artifact, "workflow_run": {**artifact["workflow_run"], "head_repository_id": 99}}]):
            with self.subTest(values=values), self.assertRaises((ValueError, TypeError)):
                p.choose_artifact("android", values, run, target)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def zip(self, entries):
        path = self.root / "test.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, value in entries:
                archive.writestr(name, value)
        return path

    def test_safe_flat_archive_and_checksums(self):
        path = self.zip([("a.apk", b"test"), ("SHA256SUMS.txt", b"example")])
        self.assertEqual(p.inspect_zip(path, flat=True), {"a.apk", "SHA256SUMS.txt"})
        self.assertEqual(p.parse_sums("a" * 64 + "  file.apk\n"), {"file.apk": "sha256:" + "a" * 64})
        for text in ("bad", "a" * 64 + "  ../file", ("a" * 64 + "  file\n") * 2):
            with self.assertRaises(ValueError):
                p.parse_sums(text)

    def test_unsafe_paths_and_flat_subdirectories(self):
        for name in ("../a", "/a", "dir/../../a", "C:/a", "dir\\a", "nested/a"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                p.inspect_zip(self.zip([(name, b"x")]), flat=True)

    def test_duplicate_zip_and_symlink_escape(self):
        with self.assertWarns(UserWarning):
            path = self.zip([("a", b"a"), ("a", b"b")])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            p.inspect_zip(path)
        link = zipfile.ZipInfo("Framework/Current")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for target in ("../../../outside", "/outside", "C:/outside"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                p.inspect_zip(self.zip([(link, target)]))
        p.inspect_zip(self.zip([(link, "Versions/A")]))
        with self.assertRaises(ValueError):
            p.inspect_zip(self.zip([(link, "Versions/A")]), flat=True)

    def test_zip_expansion_limit(self):
        path = self.zip([("a", b"x" * 10)])
        with patch.object(p, "MAX_EXPANDED", 5), self.assertRaisesRegex(ValueError, "size limit"):
            p.inspect_zip(path)

    def test_tar_regular_safe_symlink_and_escape(self):
        path = self.root / "test.tar.gz"
        for target in ("library.so.1", "../../outside"):
            with tarfile.open(path, "w:gz") as archive:
                file = tarfile.TarInfo("library.so.1")
                file.size = 3
                archive.addfile(file, io.BytesIO(b"abc"))
                link = tarfile.TarInfo("library.so")
                link.type = tarfile.SYMTYPE
                link.linkname = target
                archive.addfile(link)
            if target.startswith(".."):
                with self.assertRaises(ValueError):
                    p.inspect_tar(path)
            else:
                p.inspect_tar(path)

    def test_byte_derived_apk_identity_and_cert(self):
        text = "package: name='com.xycz.simple_live' versionCode='13109' versionName='1.12.8'\nnative-code: 'arm64-v8a'\n"
        p.validate_badging(text, "1.12.8+11109", "arm64-v8a", 2000, "com.xycz.simple_live")
        for bad in (text.replace("13109", "11109"), text.replace("simple_live'", "other'"),
                    text.replace("arm64-v8a", "x86_64"), text + text):
            with self.assertRaises(ValueError):
                p.validate_badging(bad, "1.12.8+11109", "arm64-v8a", 2000, "com.xycz.simple_live")
        cert = "Signer #1 certificate SHA-256 digest: " + "A" * 64 + "\n"
        self.assertEqual(p.certificate_digest(cert), "a" * 64)
        for invalid in ("", cert + cert, cert + "Signer #2 certificate SHA-256 digest: " + "b" * 64):
            with self.assertRaises(ValueError):
                p.certificate_digest(invalid)

    def test_packages_and_metadata_exact_set_and_hash(self):
        target = plan()
        run, _ = run_fixture("linux", target)
        name = next(iter(p.expected_packages("linux", p.artifact_identity("linux", run, target)[0], target)))
        package = self.root / name
        with tarfile.open(package, "w:gz") as archive:
            entry = tarfile.TarInfo("binary")
            entry.size = 3
            archive.addfile(entry, io.BytesIO(b"bin"))
        sums = p.digest_file(package).removeprefix("sha256:") + "  " + name + "\n"
        archive = self.zip([(name, package.read_bytes()), ("SHA256SUMS.txt", sums)])
        output = self.root / "out"
        output.mkdir()
        records = p.prepare_artifact("linux", archive, output, run, target, {})
        self.assertEqual(records[0]["sha256"], p.digest_file(package))
        for values in ([(name, package.read_bytes())], [(name, package.read_bytes()), ("SHA256SUMS.txt", sums), ("extra", b"x")],
                       [(name, package.read_bytes()), ("SHA256SUMS.txt", "0" * 64 + "  " + name + "\n")]):
            archive = self.zip(values)
            with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
                p.prepare_artifact("linux", archive, Path(temporary), run, target, {})


class FakeGitHub:
    """In-memory remote with explicit log of all mutation methods."""
    def __init__(self):
        self.release = None
        self.assets = []
        self.tag = None
        self.calls = []
        self.fail_upload = False

    def pages(self, path, key=None):
        if path == "/releases":
            return [copy.deepcopy(self.release)] if self.release else []
        if path == "/releases/7/assets":
            return copy.deepcopy(self.assets)
        raise AssertionError(path)

    def request(self, path, method="GET", value=None, file=None, **kwargs):
        self.calls.append((method, path))
        if path.startswith("/git/ref/tags/"):
            return copy.deepcopy(self.tag)
        if path == "/releases" and method == "POST":
            self.release = {**value, "id": 7, "html_url": "https://github.com/example/release"}
            return copy.deepcopy(self.release)
        if path.startswith("/releases/7/assets?") and method == "POST":
            if self.fail_upload:
                raise ValueError("Simulated interrupted upload")
            asset = {"name": file.name, "size": file.stat().st_size, "digest": p.digest_file(file), "state": "uploaded"}
            self.assets.append(asset)
            return copy.deepcopy(asset)
        if path == "/releases/7":
            if method == "PATCH":
                self.release.update(value)
                self.tag = {"object": {"type": "commit", "sha": self.release["target_commitish"]}}
            return copy.deepcopy(self.release)
        raise AssertionError((method, path))


class PublishStateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.output = Path(self.directory.name)
        (self.output / "test.apk").write_bytes(b"verified bytes")
        (self.output / "SHA256SUMS.txt").write_text("fixture")
        self.target = plan()
        self.api = FakeGitHub()
        self.body = "reviewed caveats"
        self.checks = 0

    def tearDown(self):
        self.directory.cleanup()

    def check(self):
        self.checks += 1

    def publish(self):
        return p.publish(self.api, self.target, self.output, self.body, self.check)

    def test_create_draft_upload_verify_publish_then_idempotent(self):
        self.publish()
        self.assertGreaterEqual(self.checks, 2)
        self.assertFalse(self.api.release["draft"])
        self.assertTrue(self.api.release["prerelease"])
        self.assertEqual(self.api.release["make_latest"], "false")
        writes = [call for call in self.api.calls if call[0] != "GET"]
        self.assertEqual([method for method, _ in writes], ["POST", "POST", "POST", "PATCH"])
        self.api.calls.clear()
        self.publish()
        self.assertTrue(all(method == "GET" for method, _ in self.api.calls))

    def test_interrupted_draft_upload_resumes_without_replacement(self):
        self.api.fail_upload = True
        with self.assertRaisesRegex(ValueError, "interrupted"):
            self.publish()
        self.assertTrue(self.api.release["draft"])
        self.assertNotIn("PATCH", [method for method, _ in self.api.calls])
        self.api.fail_upload = False
        self.api.calls.clear()
        self.publish()
        self.assertEqual(len(self.api.assets), 2)
        self.assertNotIn(("POST", "/releases"), self.api.calls)
        self.assertFalse(any(method == "DELETE" for method, _ in self.api.calls))

    def test_existing_conflicts_abort_without_overwrite(self):
        self.publish()
        for mutation in (lambda: self.api.release.update(target_commitish="0" * 40),
                         lambda: self.api.release.update(body="changed"),
                         lambda: self.api.assets[0].update(digest="sha256:" + "0" * 64),
                         lambda: self.api.assets.append(copy.deepcopy(self.api.assets[0])),
                         lambda: self.api.tag["object"].update(sha="0" * 40)):
            original = copy.deepcopy((self.api.release, self.api.assets, self.api.tag))
            mutation()
            self.api.calls.clear()
            with self.assertRaises(ValueError):
                self.publish()
            self.assertTrue(all(method == "GET" for method, _ in self.api.calls))
            self.api.release, self.api.assets, self.api.tag = original

    def test_missing_or_failed_asset_digest_blocks_promotion(self):
        self.api.fail_upload = True
        with self.assertRaises(ValueError):
            self.publish()
        self.api.fail_upload = False
        self.api.assets = [{"name": "test.apk", "size": 14, "state": "uploaded", "digest": None}]
        with self.assertRaises(ValueError):
            self.publish()
        self.assertTrue(self.api.release["draft"])

    def test_run_changed_before_promotion_preserves_draft(self):
        def changed():
            self.checks += 1
            if self.checks == 2:
                raise ValueError("Workflow rerun replaced pinned attempt")
        with self.assertRaisesRegex(ValueError, "rerun"):
            p.publish(self.api, self.target, self.output, self.body, changed)
        self.assertTrue(self.api.release["draft"])
        self.assertNotIn("PATCH", [method for method, _ in self.api.calls])

    def test_notes_expose_pending_limits(self):
        text = p.notes(self.target, {})
        for required in ("TestSigned", "settings", "follows", "Uninstall deletes", "root cause", "TV legacy", "notarized", "16 KiB", "not a stable"):
            self.assertIn(required, text)


if __name__ == "__main__":
    unittest.main()
