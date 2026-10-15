# Fork Android APK build

The `app build action` workflow builds Android, Android TV, iOS,
macOS, Windows and Linux as independent jobs on `master` pushes and manual runs.
It uploads installer files only and does not create tags or GitHub Releases.
See [version management](fork-builds.md) before committing installer changes.

## Download and install

1. Open the workflow run in the fork's Actions tab and choose the Android job.
2. Download the individual `Simple-Live-<version>-Android-<arch>-ReleaseSigned.apk`.
   No outer ZIP extraction is needed. Checksums are in the workflow summary.
3. For Samsung Galaxy S20+, choose arm64. Other devices may require arm32 or x64.
   For an update, keep the same ABI as the installed build.

All APKs use Flutter's optimized release build mode. The main application ID
remains `com.xycz.simple_live`; TV remains `com.xycz.simple_live_tv`.

## Signing behavior

All four main-app secrets (`KEYSTORE_BASE64`, `STORE_PASSWORD`,
`KEY_PASSWORD`, `KEY_ALIAS`) are required. TV uses the corresponding `TV_` names.
A public certificate fingerprint in `tool/signing-baseline.json` is also required.
Every ABI must match it. Missing fingerprints, absent/incomplete signing settings
or an unexpected certificate fail the affected Android job. See
[baseline setup](signing-baseline-setup.md). CI
never generates a replacement key and no longer falls back to runner debug keys.
Other platform jobs run independently. Private keys/passwords are never artifacts.

The chosen new baseline needs a persistent signing key, reused for every future
update. Compatibility with older TestSigned builds is not part of this baseline.
For later updates, the key must match the installed baseline app. A
`ReleaseSigned` filename only means configured signing was used; compare its
certificate with the old installed APK before claiming an in-place update.
Previously published `TestSigned` builds used ephemeral runner keys. If that
private key was lost, a newly generated key cannot update them, regardless of
version number. This workflow cannot recover a historical private key.

Keep the old app and data unless you explicitly choose a migration. Main-app
follows and settings require separate exports, checked outside the app before
any user-chosen uninstall. These exports do not guarantee every session/history
item is preserved. Do not assume TV has the same export UI. Nothing in this
workflow uninstalls the app, clears data, changes app IDs or provisions credentials.

Explicit local test-only Gradle signing remains available to developers, but its
output is not an upgrade-compatible distribution channel. CI verifies APK
signatures, application IDs, ABI-specific version codes and native libraries
before upload. Real-device upgrade/runtime testing is still required.

## Orientation dependency compatibility

The app pins `auto_orientation_v2` to `2.3.6`. The previous caret constraint
allowed Pub to resolve `2.4.7`, whose Android build script invokes `kotlin { ... }`
without applying the Kotlin Android plugin. With this project's AGP `8.9.1`,
configuration fails with `Could not find method kotlin()` before APK compilation.
See the [upstream Android build script](https://github.com/rizkyghofur/auto_orientation_v2/blob/1d966da33ac6a32d7f0f9a54284b049dd14bf59b/android/build.gradle).

The published [2.3.6 package](https://pub.dev/packages/auto_orientation_v2/versions/2.3.6)
uses a Java Android plugin, includes the AGP-8 namespace declaration, and exposes
the `landscapeAutoMode` and `portraitAutoMode` methods used by the app. Its
[Android build script](https://github.com/rizkyghofur/auto_orientation_v2/blob/121bd6f91f13021847db734b0f97af088df98891/android/build.gradle)
does not require the incompatible Kotlin configuration. Keep the version exact
until a newer release is verified with this app's Android toolchain. This targeted
pin does not change playback/decoder dependencies or the build toolchain.

## Dynamic color dependency compatibility

The app also pins `dynamic_color` to `1.8.1`. The previous caret constraint selected
`1.9.0`, whose [changelog](https://pub.dev/packages/dynamic_color/versions/1.9.0/changelog)
records migration to Kotlin DSL and AGP 9 support. Its published Android script
applies only `com.android.library` before using `kotlin { compilerOptions { ... } }`,
which fails to compile with this app's AGP `8.9.1`. The
[1.8.1 package](https://pub.dev/packages/dynamic_color/versions/1.8.1)
explicitly applies `kotlin-android` and provides the app's `DynamicColorBuilder` API.

The Android implementations in the dependency set resolved by
[CI run 38351500372](https://github.com/Forlooong/dart_simple_live/actions/runs/38351500372)
were inspected for this missing-Kotlin-plugin pattern using published archives
verified against Pub's SHA-256 metadata. No additional matching issue was found:
in particular, `screen_brightness_android` `2.1.6` applies Kotlin conditionally on
AGP versions below 9, and `url_launcher_android` `6.3.30` applies it explicitly.
This source review does not replace building the final dependency set in CI.

## Reproducible package resolution

The mobile app commits `simple_live_app/pubspec.lock` from the reviewed CI
dependency snapshot. The fork workflow uses `flutter pub get --enforce-lockfile`
so it fails instead of silently resolving newer packages or changed checksums.
The committed lockfile is enforced during builds; the workflow summary records the version and commit. Downloads contain only the APK.

## Final release verification

See [release gates](release-gates.md) for exact-commit platform builds, whole-APK
ELF/ABI/ZIP validation, signing compatibility and real 16 KiB device testing.
Successful static checks alone do not establish runtime compatibility.

