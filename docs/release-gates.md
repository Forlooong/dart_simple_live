# Release gates and honest artifact labels

A successful compile is not proof of upgrade compatibility, runtime reliability,
or a production-ready release. Do not promote a build to a public stable release
until the applicable gates below have evidence for the **same full commit SHA**.

## Required evidence

- Main app: Android, iOS, macOS, Windows and Linux fork workflows succeed on the
  final SHA. TV: the TV fork workflow succeeds on that SHA. A previous green run
  does not validate later source or packaging changes. Record workflow URLs,
  attempt numbers, artifact names and SHA-256 checksums.
- Run the Python packaging/version regressions, Rust/native/core checks, renderer
  lifecycle checks, and app follow/player/notification regression tests. Record
  failed or not-run checks, including real-device tests, rather than omitting them.
- APKs: inspect manifest version and ABI-specific versionCode, validate the signing
  certificate, and compare it to the installed/previous release certificate before
  promising in-place updates. A `ReleaseSigned` label alone does not prove the
  certificate is the correct historical key. Verify all packaged native libraries,
  not only our two Rust libraries, and run `zipalign -c -P 16 4` on final APKs.
- Smoke-test a 16 KiB Android environment (confirm `adb shell getconf PAGE_SIZE`
  returns `16384`) and a normal device: launch, each playback backend, follow-list
  refresh/error recovery, notifications and repeated enter/exit. Static ELF/ZIP
  checks do not establish runtime compatibility. Repeat relevant tests on TV.
- Verify native loading and platform packaging checks on each host. iOS artifacts
  are unsigned and require authorized Apple signing; macOS artifacts are unsigned
  and unnotarized; Windows packages are unsigned. Record these limitations.

Reference: [Android's 16 KiB page-size guidance](https://developer.android.com/guide/practices/page-sizes).
The verifier examines every `lib/<abi>/*.so`, matches ELF class/machine to its split
APK, validates PT_LOAD table/segment bounds and congruence, and rejects duplicate
ZIP entries. All 64-bit ELF segments require at least 16 KiB alignment. Our own
arm32 native libraries also require 16 KiB; third-party arm32 permits 4 KiB because
Android's 16 KiB device requirement applies to 64-bit. All stored shared objects,
including arm32, use the stricter 16 KiB ZIP offset policy matching `zipalign -P 16`.
Compressed shared objects still receive the ELF checks. This is an APK check, not
an AAB verification or substitute for runtime tests.

## Signing and data preservation

`TestSigned` means optimized release code signed by an ephemeral test key. Fresh
runners can use different keys, including from the old 1.12.5 APK. A certificate
mismatch prevents an in-place update; a version bump cannot repair that mismatch.
Keep the old app and its data unless the user explicitly chooses a migration.
Never automatically uninstall or clear app data to work around signing errors.

For the main app, export follows from the follow page and export settings from
Settings → Other → Export configuration **separately**. Configuration export
contains settings and shield rules, not the follows database. Check both exported
files outside the app before any user-chosen uninstall. Do not claim these exports
back up every account/session/history item. For TV, establish a verified backup or
migration route before replacing an existing installation; do not assume the main
app's export UI exists there. Uninstalling removes local app data.

Do not create a persistent key, upload credentials, modify secrets or change
security permissions as part of this build task. A matching historical signing
identity must be provided through an explicitly authorized secure workflow.

## Publication

The fork build workflows upload Actions artifacts only; they do not create tags
or GitHub releases. Artifacts are retained for 14 days. TestSigned artifacts may be
shared as clearly labelled test/prerelease builds with the above caveats; never
advertise them as seamless upgrades or as having passed unperformed device tests.

The legacy TV tag workflow derives its name from `simple_live_tv_app/pubspec.yaml`
and rejects tags other than `tv_<pubspec version name>` before signing/building.
It creates a **draft prerelease**, never a public stable release. The legacy
`assets/tv_app_version.json` is not build/release identity and is not silently
updated here. Do not push a release tag merely to test CI. Main-app legacy `v*`
tag workflows remain publication workflows: use the fork workflows for validation
and do not trigger tag publication until the release target and evidence are
reviewed. Before promoting any draft, explicitly review artifacts, signing,
runtime evidence and release notes. Missing gates stay visible as blockers or
prerelease caveats, not claimed successes.
