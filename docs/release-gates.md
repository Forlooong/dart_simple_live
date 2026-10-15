# Release gates and honest artifact labels

A successful compile is not proof of upgrade compatibility, runtime reliability,
or a production-ready release. Do not promote a build to a public stable release
until the applicable gates below have evidence for the **same full commit SHA**.

## Required evidence

- All six independent jobs in `app build action` succeed on the
  final SHA. Missing Android/TV signing keys are a blocker, not a successful build. A previous green run
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

Historical `TestSigned` builds used optimized release code signed by an ephemeral test key.
The unified workflow now fails closed when configured release signing is absent. Fresh
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
security permissions as part of this build task. A persistent new-baseline signing
identity must be configured through an explicitly authorized secure workflow.
A historical identity is needed only if old-version compatibility is chosen.

## Publication

The unified workflow uploads only APK, IPA, DMG, EXE and DEB files as individual
Actions artifacts, retained for 14 days. It does not create tags or GitHub Releases.
Checksums/build details stay in the workflow summary, not extra downloaded files.
Never advertise historical TestSigned builds as seamless upgrades. A green build
does not establish a matching old signing key or replace actual device upgrade tests.

The iOS IPA remains unsigned and cannot be installed directly. Compatible Apple
signing/provisioning and signed distribution compliance must be verified separately.
Its existing build-number representation is preserved, not remapped to a lower
value. Windows CI checks repeated installation, previous-directory reuse and a
data sentinel; that is a packaging regression check, not an old-version/user-data
migration certification. Missing gates remain visible as blockers.
