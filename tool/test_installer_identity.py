"""Regression tests for installer identity and fail-closed build contracts."""
import os
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

from verify_installer_identity import BUNDLE_IDS, verify
from verify_apk_signer import expected_signer, verify_report

ROOT = Path(__file__).resolve().parents[1]


class InstallerIdentityTest(unittest.TestCase):
    def test_apple_identity_and_both_versions_are_checked(self):
        for platform, identifier in BUNDLE_IDS.items():
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temp:
                bundle = Path(temp)
                path = bundle / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
                path.parent.mkdir(parents=True, exist_ok=True)
                expected = dict(CFBundleIdentifier=identifier,
                                CFBundleShortVersionString="1.12.11", CFBundleVersion="11112")
                path.write_bytes(plistlib.dumps(expected))
                verify(platform, bundle, "1.12.11+11112")
                for key in expected:
                    path.write_bytes(plistlib.dumps({**expected, key: "wrong"}))
                    with self.assertRaisesRegex(ValueError, key):
                        verify(platform, bundle, "1.12.11+11112")

    def test_signer_is_pinned_and_missing_or_changed_identity_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "baseline.json"
            digest = "ab" * 32
            baseline = {"main": {"package_id": "com.xycz.simple_live", "certificate_sha256": digest}}
            path.write_text(json.dumps(baseline), encoding="utf-8")
            report = f"Signer #1 certificate SHA-256 digest: {digest}\n"
            self.assertEqual(verify_report("main", report, path), digest)
            for bad, error in ((report.replace(digest, "cd" * 32), "does not match"),
                               ("", "found 0"),
                               (report + report.replace("#1", "#2"), "multiple or duplicate")):
                with self.assertRaisesRegex(ValueError, error):
                    verify_report("main", bad, path)
            baseline["main"]["certificate_sha256"] = ""
            path.write_text(json.dumps(baseline), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not configured"):
                expected_signer("main", path)
            baseline["main"]["certificate_sha256"] = digest
            baseline["main"]["package_id"] = "changed.package"
            path.write_text(json.dumps(baseline), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "package ID"):
                expected_signer("main", path)

    def test_certificate_report_variants_and_safe_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "baseline.json"
            expected, actual = "ab" * 32, "cd" * 32
            path.write_text(json.dumps({"main": {"package_id": "com.xycz.simple_live",
                                                "certificate_sha256": expected}}))
            for label in ("SHA-256", "SHA256"):
                for newline in ("\n", "\r\n"):
                    report = newline.join(("Signer #1 certificate DN: private-subject",
                        f"Signer #1 certificate {label} digest: {expected.upper()}",
                        f"Signer #1 public key SHA-256 digest: {actual}",
                        f"Source Stamp Signer certificate SHA-256 digest: {actual}", ""))
                    self.assertEqual(verify_report("main", report, path), expected)
            prefix = "Signer #1 certificate SHA-256 digest: "
            self.assertEqual(verify_report("main", prefix + ":".join(["AB"] * 32), path), expected)
            for report, message in (
                (prefix + actual, f"actual SHA-256={actual}"),
                (prefix + "private-sentinel", "unrecognized"),
                (prefix + "ab", "malformed"),
                (prefix + "\n" + expected, "unrecognized"),
                (prefix + expected + "\n" + prefix + expected, "multiple or duplicate"),
                (f"Signer (minSdkVersion=33) certificate SHA-256 digest: {expected}", "unrecognized"),
                (f"Signer #1 public key SHA-256 digest: {expected}", "found 0"),
            ):
                with self.subTest(message=message), self.assertRaises(ValueError) as caught:
                    verify_report("main", report, path)
                self.assertIn(message, str(caught.exception))
                self.assertNotIn("private-sentinel", str(caught.exception))
                self.assertNotIn("private-subject", str(caught.exception))

    def test_real_build_tools_36_and_37_reports(self):
        # Captured by official Google Build-Tools against the same existing
        # debug-signed public test APK; no private key was needed for this test.
        digest = "b1b6d235338403b8a8ae5c6047c52759b0702fc266655484d1c94ba4cf4df6cb"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "baseline.json"
            path.write_text(json.dumps({"tv": {"package_id": "com.xycz.simple_live_tv",
                                              "certificate_sha256": digest}}))
            for version in (36, 37):
                report = (ROOT / f"tool/testdata/apksigner-{version}.txt").read_text()
                self.assertEqual(verify_report("tv", report, path), digest)
                with self.assertRaisesRegex(ValueError, "does not match"):
                    verify_report("tv", report.replace(digest, "cd" * 32), path)

    def test_all_scheme_certificates_must_match_one_identity(self):
        digest, wrong = "ab" * 32, "cd" * 32
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "baseline.json"
            path.write_text(json.dumps({"main": {"package_id": "com.xycz.simple_live",
                                                "certificate_sha256": digest}}))
            v1 = f"V1 Signer: certificate SHA-256 digest: {digest}\n"
            v2 = f"V2 Signer: certificate SHA-256 digest: {digest}\n"
            self.assertEqual(verify_report("main", v1 + v2, path), digest)
            for report in (v1 + v2.replace(digest, wrong), v1 + v1, v2 + v2,
                           v2 + v2.replace("Signer:", "Signer #2:"),
                           v2 + v2.replace("V2", "V9"),
                           v2 + f"Signer #1 certificate SHA-256 digest: {digest}"):
                with self.assertRaises(ValueError):
                    verify_report("main", report, path)

    def test_unified_workflow_keeps_independent_platforms_and_installers(self):
        workflow = (ROOT / ".github/workflows/installers.yml").read_text(encoding="utf-8")
        jobs = re.findall(r"^  ([a-z][a-z0-9-]*):$", workflow.split("jobs:\n", 1)[1], re.M)
        self.assertEqual(jobs, ["android-apk", "tv-apk", "ios", "macos", "windows", "linux"])
        self.assertNotRegex(workflow, r"(?m)^    needs:")
        upload_refs = re.findall(r"uses: actions/upload-artifact@([^\s]+)", workflow)
        self.assertEqual(len(upload_refs), 10)
        for ref in upload_refs:
            self.assertRegex(ref, r"^[0-9a-f]{40}$")
        self.assertEqual(workflow.count("archive: false"), 10)
        self.assertNotIn("allowDebugReleaseSigning=true", workflow)
        self.assertNotIn("gh release", workflow)
        self.assertIn("AppId=com.xycz.simplelive", workflow)
        self.assertIn("DefaultDirName={localappdata}\\Programs\\Simple Live", workflow)
        self.assertIn("UsePreviousAppDir=yes", workflow)
        self.assertIn("Package: simple-live", workflow)
        for identifier in ("com.xycz.simple_live", "com.xycz.simple_live_tv"):
            self.assertIn('actual_package" != "' + identifier + '"', workflow)

    def test_missing_or_partial_keys_cannot_generate_test_signed_apks(self):
        workflow = (ROOT / ".github/workflows/installers.yml").read_text(encoding="utf-8")
        scripts = re.findall(r"python3 - <<'PY'\n(.*?)\n          PY", workflow, re.S)
        self.assertEqual(len(scripts), 2)
        for script in scripts:
            for partial in (False, True):
                with self.subTest(partial=partial), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    (root / "android").mkdir()
                    env = {k: v for k, v in os.environ.items()
                           if k not in ("KEYSTORE_BASE64", "STORE_PASSWORD", "KEY_PASSWORD", "KEY_ALIAS")}
                    env.update(RUNNER_TEMP=temp, GITHUB_ENV=str(root / "env"), GITHUB_OUTPUT=str(root / "output"))
                    if partial:
                        env["KEY_ALIAS"] = "test"
                    result = subprocess.run([sys.executable, "-c", textwrap.dedent(script)],
                                            cwd=temp, env=env, capture_output=True, text=True, encoding="utf-8")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("incomplete" if partial else "Stable release signing is required", result.stderr)
                    self.assertFalse((root / "android/key.properties").exists())
                    self.assertFalse((root / "env").exists())
                    self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
