# One-shot verified repair prerelease

This publisher is **disabled by default**. It uses the existing short-lived
GitHub Actions token only. It creates no credentials, secrets, persistent access,
repository permission changes, or signing keys. The dedicated job requests only
`contents: write` and `actions: read`; checkout does not persist credentials.

## Activation checklist

1. Finish fixes on `fix/known-issues-release` and obtain review. Wait for the six
   Android, TV, iOS, macOS, Windows and Linux fork workflows to succeed at the
   **same full source SHA**. A later workflow/source fix needs a new SHA and six
   successful runs. A failed, cancelled or skipped check does not count.
2. Inspect the packages, signing mode and test limits. Review the publisher and
   run `python3 -B -m unittest discover -s tool -p test_publish_prerelease.py`.
   Its fixtures exercise offline failures, interrupted drafts, idempotent reruns,
   source mismatches, artifact integrity and publication races; they do not prove
   a live GitHub publication or device installation succeeded.
3. Edit `tool/prerelease-target.json`: set the full reviewed source SHA, exact
   source main/TV package versions, and each platform's numeric workflow run ID
   and latest attempt number. Select `TestSigned` or `ReleaseSigned` explicitly
   for Android and TV; this is checked against the exact artifact name and
   metadata, with actual APK signature and certificate verification separately.
4. Only after all checks and publication authorization, set `enabled` to `true`.
   Push a publisher-only follow-up commit to the same authorized branch. Between
   source SHA and this commit, only these files may differ:
   - `.github/workflows/publish_verified_prerelease.yml`
   - `tool/prerelease-target.json`
   - `tool/publish_prerelease.py`
   - `tool/test_publish_prerelease.py`
   - `docs/verified-prerelease.md`

The push trigger watches only the publisher workflow and target JSON on
`fix/known-issues-release`. Other commits do not activate it. There is no PR,
`workflow_run`, tag, external input or dispatch trigger. A trusted branch push
associated with a PR is allowed; a `pull_request`/`pull_request_target` run is not.
The target is intentionally a previous verified source commit; the publisher
follow-up is not falsely presented as the compiled source. Existing build
workflows may also run on the publisher commit, but their results are not silently
substituted for the six pinned runs.

## Gates before public publication

- Repository, branch, event, source ancestry and publisher-only diff must match.
  Both pubspec versions must equal the pinned version values.
- Each pinned workflow path, run ID, latest attempt, source SHA, source repository,
  branch, required job and expected gate step must match and finish successfully.
  The native composite step must succeed. Missing or skipped expected steps fail.
- Exactly one expected version/run/attempt/SHA-named Actions artifact per platform
  must exist, not be expired, and have at least 45 minutes of retention remaining.
  The Android arm64 convenience artifact is not mistaken for the all-ABI bundle.
- Each Actions archive must have a server-provided SHA-256 digest that matches the
  downloaded bytes. The token is never forwarded to signed storage redirects.
- Outer archives contain only the exact flat package and metadata file set.
  Checksums must cover every package. Inner ZIP/TAR packages are read for CRC or
  stream integrity, with path, duplicate-entry, file-type, count, expansion and
  size bounds. Relative framework/library symlinks are allowed only when their
  targets contain no parent traversal, absolute path or drive prefix. Contents
  are inspected, never installed or executed. Missing digests cannot be waived.
- APK bytes are independently checked with the runner's Android SDK `apksigner`,
  `aapt2` and `zipalign`; package name, versionName, ABI-specific versionCode,
  native ABI and signer digest must match. All split APK certificates must match
  within their platform. The reviewed static native verifier checks every `.so`.
  These checks do not establish a match to an existing user's installed signer.
- Actual APK/IPA/desktop package bytes are uploaded as release assets, alongside
  platform-prefixed build metadata, `PROVENANCE.json` and `SHA256SUMS.txt`. Provenance
  includes the six workflow attempts, artifact IDs, archive hashes and per-APK
  verification categories. `SHA256SUMS.txt` covers all other assets.

## Draft, promotion, retries and failures

The deterministic tag is
`repair-pre-<main version>-build<build number>-<source SHA prefix>`.
It does not match any legacy `v*`, `tv_*`, `dev_v*` or `dev_tv_v*` tag publisher.
The release target is the full source SHA. A tag already pointing elsewhere is a
hard failure. The publisher creates a **draft prerelease** with qualified notes,
uploads each missing asset once, verifies the exact remote asset set and SHA-256
digests, rechecks every pinned run attempt and artifact, then publishes with
`prerelease: true` and `make_latest: false`.

An interrupted attempt leaves a draft; a rerun can add missing assets only when
all existing release identity, notes, tag, assets, sizes and digests match.
Conflicting assets are never replaced or deleted. A partial failed upload,
changed artifact, newer workflow attempt, missing digest or conflicting tag
requires investigation and an explicit new reviewed plan. A fully matching
published release returns success without mutation. Re-running cannot create a
second release for the same deterministic tag. No automatic remote cleanup or
force-update is performed.

The release notes explicitly retain these limits:

- TestSigned APKs cannot update an installation with a different certificate.
  Export main-app follows and settings separately and verify both backups outside
  the app before any user-chosen uninstall. Uninstall deletes local data. TV needs
  its own verified backup/migration route; the main-app export UI is not assumed.
- iOS is unsigned; macOS is unsigned/unnotarized; Windows is unsigned. Desktop
  runtime requirements are disclosed. A `universal` macOS filename describes its
  two packaged CPU architectures, not universal device compatibility.
- Installed-device/16 KiB runtime tests remain unperformed. Static APK/native
  checks and signature verification are distinct from real-device validation.
- Frequent Android spinner/buffering has no established root cause. Legacy TV
  playback/retry/lifecycle defects remain pending. A green build is not evidence
  that these issues were repaired.

API references: [Actions artifacts](https://docs.github.com/en/rest/actions/artifacts),
[workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs),
[releases](https://docs.github.com/en/rest/releases/releases).
