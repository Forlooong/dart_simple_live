# Release gates and honest artifact labels

A successful compile is not proof of upgrade compatibility, runtime reliability,
or a production-ready release. Do not promote a build to a public stable release
until the applicable gates below have evidence for the **same full commit SHA**.

## Required evidence

- All four independent jobs in `Build installers` succeed on the
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
- Verify native loading and packaging on each build host. Windows packages are
  unsigned. Record this limitation.

Reference: [Android's 16 KiB page-size guidance](https://developer.android.com/guide/practices/page-sizes).
The verifier examines every `lib/<abi>/*.so`, matches ELF class/machine to its split
APK, validates PT_LOAD table/segment bounds and congruence, and rejects duplicate
ZIP entries. All 64-bit ELF segments require at least 16 KiB alignment. Our own
arm32 native libraries also require 16 KiB; third-party arm32 permits 4 KiB because
Android's 16 KiB device requirement applies to 64-bit. All stored shared objects,
including arm32, use the stricter 16 KiB ZIP offset policy matching `zipalign -P 16`.
Compressed shared objects still receive the ELF checks. This is an APK check, not
an AAB verification or substitute for runtime tests.

## 候选净变更与运行验收

- 审核整合基线到候选完整 SHA 的净变更，逐项关联改动依据、有效调用链、数据或兼容影响和验证结果。检查被替代路径已清理、原有功能与发布门禁得到保留。
- 在成功的主线安装包运行后，手动运行 Candidate runtime checks，提供该运行号、用于覆盖安装的公开旧版标签和 Windows 探针所用的公开直播间。工作流复用发布准备的来源、签名和摘要校验。记录安装包启动检查、同 SHA Release 探针和实际使用场景的结果。
- 生成发布审阅材料，以同一候选 SHA、安装包运行号和审阅材料取得维护者明确批准后公开发布。受环境限制的适用检查保留为待验证项。源代码、包或审阅对象变化后重新取得对应证据和批准。

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

The unified workflow uploads only APK, EXE and DEB files as individual
Actions artifacts, retained for 14 days. It does not create tags or GitHub Releases.
Checksums/build details stay in the workflow summary, not extra downloaded files.
Never advertise historical TestSigned builds as seamless upgrades. A green build
does not establish a matching old signing key or replace actual device upgrade tests.

Windows CI checks repeated installation, previous-directory reuse and a
data sentinel; that is a packaging regression check, not an old-version/user-data
migration certification. Missing gates remain visible as blockers.

## Follow, restore and search regression matrix

| Target | Release candidate exercise |
| --- | --- |
| Android phone | Start, aggregate search, play, follow, preview WebDAV changes, apply and roll back offline. Check notification permission, background polling, a quiet-hours summary, its tap target and a subscription cancelled during a check. Repeat the main flow with TalkBack and enlarged text. |
| Android TV | Start, search, open playback, adjust quality and return to follows using the remote. Verify focus after a list refresh and after closing a player panel. Check that paired account transfer asks for permission on the receiving device. |
| Windows and Linux | Start, perform an aggregate search with one unavailable platform, adjust playback with the keyboard and return to follows. Verify the WebDAV preview and rollback dialogs with the keyboard. |

The PR workflow runs deterministic regression suites for core, the main app and
TV using the release Flutter version. Record the results and each manual matrix
entry against the same commit used to build the candidate.

## Local checks for the 1.12.24 / 1.7.15 candidate

The candidate uses the regular Android signing baselines and the next build
numbers, `1.12.24+11125` and `1.7.15+10620`.

| Local check | Result |
| --- | --- |
| Source versions, build numbers and version history | Passed |
| Python packaging, version, signing and publisher fixtures | 84 passed |
| Main and TV Dart and widget tests with native build hooks isolated | 215 main and 25 TV passed |
| Selected Dart core transport, status, synchronization and update tests | 32 passed |

The signed Android packages, packaged native runtimes and installed-device
matrix require evidence from the six-platform build and the corresponding
devices. The Windows test host could not create Flutter plugin symlinks and
the widget checks did not build native libraries.
