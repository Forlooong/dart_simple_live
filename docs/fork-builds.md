# Unified installer builds and version management

One workflow, `app build action` (`fork_all_platforms.yml`), runs on
`master` pushes or manually. Its six independent jobs build Android, Android TV,
iOS, macOS, Windows and Linux. A failed platform does not prevent the other jobs
from completing. No tags or GitHub Releases are created.

## Version source of truth

The main app's five platforms share `simple_live_app/pubspec.yaml`; TV uses
`simple_live_tv_app/pubspec.yaml`. Installed versions come from these committed
files, never GitHub run counters. Replacing a workflow or rerunning a build cannot
reset the installed version. Artifact filenames additionally include run number,
attempt and short commit SHA so separate attempts remain identifiable.

Before committing installer-affecting changes, run from the repository root:

```sh
python tool/version.py bump main  # main app only
python tool/version.py bump tv    # TV only
python tool/version.py bump both  # core, shared renderer or shared build changes
python tool/version.py check both
```

A bump increases both the semantic patch version and build number, and updates the
single workflow title with both versions. Include the bump in the final
installer-affecting commit of the change. For intentional major/minor releases,
edit the pubspec while increasing its build number, then run `sync main` or
`sync tv`. Commands edit local files; they never commit or push.

The guard covers application files, shared core/packages, build scripts, Actions
and workflow packaging. Top-level name/run-name display-only workflow changes do not force a TV bump for a
main-only change. Documentation-only edits and rebuilds reuse the source version.
Both push and manual builds check history: a failed unversioned change cannot be
bypassed just by manually rebuilding or adding a documentation commit. If source
changes follow a version-only commit, put a fresh bump in the final source commit.
All jobs fetch full history for this check. Version bounds are checked before
building, including Android's maximum versionCode and Windows uint16 components.

## Installer and update contracts

- Android and TV: separate arm32, arm64 and x64 APK downloads. Application IDs stay
  `com.xycz.simple_live` and `com.xycz.simple_live_tv`. Flutter split APKs add ABI
  offsets to the committed build number: arm32 +1000, arm64 +2000 and x64 +4000.
  CI checks actual manifest IDs and version values. Updates must use the same ABI,
  package ID and signing identity with an increased versionCode. Switching ABI is
  not guaranteed to be an upgrade, because offsets differ.
- iOS: unsigned arm64 IPA, with unchanged bundle ID `com.xycz.simple-live` and
  checked source version/build metadata. It requires appropriate Apple signing
  and provisioning before installation. Consistent signing/entitlements and
  signed-distribution version compliance remain separate prerequisites. Existing
  build-number representation is preserved rather than reset or remapped lower.
- macOS: unsigned/unnotarized universal DMG. The bundle ID remains
  `com.xycz.simpleLiveApp`; CI checks bundle version/build and both architectures.
  Replace the application in Applications without deleting its user data. macOS
  may block an unsigned application; no notarization claim is made.
- Windows: unsigned x64 installer EXE. Inno AppId remains `com.xycz.simplelive` and
  the default per-user path is `%LOCALAPPDATA%\Programs\Simple Live`. Existing
  install locations are reused. CI verifies executable numeric version and a
  repeated install without `/DIR`, file restoration and a data sentinel. This
  checks packaging behavior, not migration from every historic user installation.
  Microsoft Visual C++ 2015–2022 x64 runtime is required.
- Linux: amd64 DEB, package name `simple-live`, app path `/opt/simple-live`. CI
  verifies package version/architecture and runtime libraries. Install with
  `sudo apt install ./Simple-Live-*.deb` on Ubuntu 22.04 or a compatible system
  providing libmpv1. Package upgrades retain the stable package identity.

## Stable signing from the new baseline onward

Android/TV need a persistent signing key before the first new-baseline installer
can be produced. Keep that same key and alias for every later version, and keep a
secure offline backup. CI pins every APK certificate to the public fingerprint in
`tool/signing-baseline.json`. Empty fingerprints or missing signing settings fail; it
never generates a new key or falls back to ephemeral runner debug signing.

Main uses `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`; TV uses
the matching `TV_` names. Configure credentials only through an explicitly
authorized secure setup. Do not paste keys or passwords into chat, commit them,
or include them in artifacts. This change does not generate keys or modify secrets. See the user-operated
[secure baseline setup guide](signing-baseline-setup.md).

The user has chosen a new update baseline; compatibility with historical
TestSigned installers is outside this baseline. Installing the baseline over an
old app with a different key will still fail. A new key cannot recover that old
update path. Do not automatically uninstall or clear old data. After choosing and
installing the new baseline, subsequent builds must retain its signing identity.
`ReleaseSigned` means configured signing was used, not that every historical
certificate was matched. Verify an actual baseline-to-next-version device update
before claiming end-to-end upgrade success.

## Downloads and evidence

Only the ten installer files are uploaded: six APKs, one IPA, one DMG, one EXE and
one DEB. Each is an individual artifact with `archive: false`, retained for 14 days.
No outer ZIPs, source bundles, checksum files or lockfiles are extra downloads.
Checksums and build details appear in the workflow summaries. Native libraries,
ABI/alignment checks and existing main/TV regression tests remain enabled.

See [release gates](release-gates.md) for signing, runtime and real-device upgrade
requirements. A version check and successful compile alone do not prove an
in-place device update or preservation of all user data.
