# Unified installer builds and version management

One workflow, `Build installers` (`installers.yml`), runs on
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
Summaries contain only the package version and download links. Checksums and
build details remain in the step logs. Native libraries,
ABI/alignment checks and existing main/TV regression tests remain enabled.

The iOS simulator command has a 25-minute deadline covering compilation and
execution. Flutter's default 12-minute suite-loading timeout is disabled because
it also counts the cold Xcode build; test assertions and native execution budgets
remain enabled.

See [release gates](release-gates.md) for signing, runtime and real-device upgrade
requirements. A version check and successful compile alone do not prove an
in-place device update or preservation of all user data.

## Local component provenance and replacement gates

Reviewed against repository metadata on 2026-10-18. Versions below describe the
vendored files, not a claim that upstream is current. `unknown` means the local
tree does not establish an exact origin revision or license; a repository-wide
license does not supply missing third-party permission. The component maintainer
listed below owns retaining notices, reviewing the patch and running the gate
before a replacement. These are maintenance responsibilities, not named assignees.

| Component / maintainer | Recorded origin, version and license evidence | Local changes / replacement gate |
| --- | --- | --- |
| QuickJS binding and engine / core native | [`UPSTREAM.md`](../simple_live_core/packages/dart_quickjs/UPSTREAM.md): `xiaoyaocz/dart_quickjs` at `a31682801e209f925cdb90fcf4e379e512b713d2`, package `1.0.0`; README declares MIT. Bundled QuickJS-ng header says `0.11.0`, retains [MIT license](../simple_live_core/packages/dart_quickjs/third_party/quickjs-ng/LICENSE); separate engine commit is **unknown**. | Preserve UTF-8 byte lengths, value ownership/exception cleanup, stack refresh, native deadline, output bounds, controlled UTF-16 regex and iOS libc exclusion. Require core `quickjs_runtime_test.dart`, `native_danmaku_test.dart`, native lifecycle tests and native loading on every packaged ABI. A passing host test alone is insufficient to remove the fork. |
| `native_toolchain_c` / core native build | [pubspec](../simple_live_core/packages/dart_quickjs/packages/native_toolchain_c/pubspec.yaml): `dart-lang/native/pkgs/native_toolchain_c`, `0.17.4`; [BSD-3-Clause text](../simple_live_core/packages/dart_quickjs/packages/native_toolchain_c/LICENSE). Exact upstream commit is **unknown**. | QuickJS `UPSTREAM.md` records Windows Unicode environment paths, direct native-tool argument handling and no environment values in diagnostics. Replacement must preserve these behaviours, build from a Unicode Windows path and pass platform native packaging/load gates; no standalone vendored toolchain test suite is present. |
| `regress` / core native filtering | [`SIMPLE_LIVE_PATCHES.md`](../simple_live_core/packages/danmaku_native/rust/vendor/regress/SIMPLE_LIVE_PATCHES.md): `ridiculousfish/regress` at `771e6c8fa1e472ef86c45b5206b37fa4e4494e25`, Cargo version `0.12.0`; retained [MIT](../simple_live_core/packages/danmaku_native/rust/vendor/regress/LICENSE-MIT) or [Apache-2.0](../simple_live_core/packages/danmaku_native/rust/vendor/regress/LICENSE-APACHE). | Budgeted UCS-2 search reports consumed backtracks and stops new start positions at exhaustion; workspace metadata is adapted for embedding. Require locked Rust tests and Dart/native regex parity, lone-surrogate and shared-budget regressions before replacing this patch. |
| `canvas_danmaku` / App and TV renderer | [`LOCAL_CHANGES.md`](../packages/canvas_danmaku/LOCAL_CHANGES.md) and pubspec: `Predidit/canvas_danmaku` `0.2.7`; retained [MIT license](../packages/canvas_danmaku/LICENSE). Exact upstream commit is **unknown**. | Preserve enabled/foreground gating, no idle periodic work, cancellable cleanup, cleared old messages and controller initialization before callback. Require renderer `test/lifecycle_test.dart` plus App/TV danmaku lifecycle tests. |
| `tars_dart` / core Huya adapter | [README](../simple_live_core/packages/tars_dart/README.md) identifies `brooklet/TarsFlutter`; local package `0.1.0`, retained [BSD-3-Clause license](../simple_live_core/packages/tars_dart/LICENSE). Exact fork commit is **unknown**; the historical `dart_tars_protocol` reference is not this package's provenance. | Dart package/TUP2 changes plus bounded Dio timeouts, cancellation, per-request content length and payload-free logging. Require core `playback_transport_test.dart` and existing Huya native protocol fixtures; review TUP2 wire compatibility separately before replacing the codec. |
| Douyu/Douyin signing scripts / core platform adapters | [`douyu_sign.dart`](../simple_live_core/lib/src/scripts/douyu_sign.dart) embeds a `CryptoJS`-named blob and executes platform-supplied signing code. [`douyin_sign.dart`](../simple_live_core/lib/src/scripts/douyin_sign.dart) embeds A-Bogus/web SDK code, including a learning-only/noncommercial comment. Exact script versions, original commits and complete licensing evidence are **unknown**; do not infer a license from a familiar algorithm name. | Preserve script text while resolving attribution/license evidence before adopting replacement code. Douyu executes in an isolate; Douyin remains synchronous. Both use function arguments, finally-based cleanup, bounded native execution/output; Douyin retries at most eight times. Core `quickjs_runtime_test.dart` covers quoting/Unicode, failure cleanup and deadlines; it does not prove current platform acceptance or script provenance. |
| Huya anticode derivation / core Huya adapter | [`huya_site.dart`](../simple_live_core/lib/src/huya_site.dart) names `iceking2nd/real-url` and `SeaHOH/ykdl`; commented historical code also names `wbt5/real-url`. Exact copied revision and applicable file licenses are **unknown** locally. | Retain source comments and resolve file-level provenance before importing updates. Current `sv`/`sdk_sid` constants remain compatibility assumptions; replacing them needs controlled signature/URL fixtures and an opt-in live contract check, not a guess from a newer repository. |

## Toolchain and dependency pin exit conditions

Pins are changed in a dedicated compatibility change with freshly resolved,
committed lockfiles. The checks below are exit conditions, not claims that a new
toolchain or real-device run has already passed. Keep the old baseline until the
replacement passes; an upstream release number alone is not sufficient evidence.

| Baseline / local evidence | Exit condition |
| --- | --- |
| Flutter `3.38.10` / Dart `3.10.9`: workflow and [native build notes](danmaku-performance.md). | Native build hooks and all six installer jobs pass on the proposed Flutter/Dart pair, with core/renderer/App/TV tests and package identity checks. Record actual SDK/NDK/Xcode versions; do not claim byte-for-byte reproducibility from lockfiles alone. |
| Rust `1.90.0`: [`rust-toolchain.toml`](../simple_live_core/packages/danmaku_native/rust/rust-toolchain.toml), Cargo `rust-version` and locked graph. | Run locked Rust tests/clippy and native load/ABI checks for Android, Apple, Windows and Linux targets; preserve regex budget and FFI ownership contracts. Update toolchain metadata and CI together. |
| Android AGP `8.9.1`, Gradle `8.12`, Kotlin `2.1.0`, CI JDK `17`: both Android projects and workflow. | Migrate as one compatible build set; verify all plugin Gradle configuration, native ABI/16 KiB gates, final APK signing/identity and installed upgrade. Keep orientation, color, notification and playback device checks in the same acceptance evidence. |
| Main `auto_orientation_v2 2.3.6`, `dynamic_color 1.8.1`: [documented AGP 8 incompatibilities](fork-android-build.md). | A candidate must configure/build with the retained AGP 8 stack, or pass the coordinated AGP migration. Verify actual rotation restoration and dynamic theme behaviour before relaxing either exact constraint. |
| Main Workmanager `0.9.0+3`, Android `0.9.0+2`, interface `0.9.1+1`, Apple `0.9.1+2`; notifications `19.5.0`: [background notification contract](selected-room-live-notifications.md). | Review federated Pigeon codecs as a group; test native initialization, a real scheduled background run, notification permission/channel and tap navigation on target devices. Static analysis or a single upgraded Dart package cannot establish codec compatibility. |
| App/TV `flutter_secure_storage 9.2.4`: exact pubspec/lockfile baseline. | Verify candidate toolchain support and credential read/write/delete, legacy migration and failure/restart behaviour on each supported desktop/mobile platform before changing this pin. Keep secrets outside backup exports. |
| Media graph divergence: main locks `media_kit 1.2.6` / `media_kit_video 2.0.1`; TV locks `1.2.2` / `1.3.1`; both use `media_kit_libs_video 1.0.7`. | Unify only after both controllers pass playback recovery/command-queue/lifecycle tests and Android mobile/TV device runs cover rapid room/quality changes, background/resume, network recovery, remote focus and decoder options. This divergence is maintenance cost, not proof of a runtime defect; decoder defaults and lockfiles are not changed merely to align numbers. |

`LiveSite` currently has four production adapters, each explicitly overriding its
existing methods; no production direct construction was found. Making mandatory
methods abstract and declaring optional capabilities remains a gradual contract
improvement. It should accompany adapter/UI contract tests, rather than changing
all test doubles solely to remove currently unused defaults in this repair.
