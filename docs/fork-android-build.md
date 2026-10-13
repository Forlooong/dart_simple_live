# Fork Android APK build

The `Fork Android release APK` workflow builds the checked-out commit on pushes to
`hotfix/player-lifecycle` or `hotfix/player-lifecycle-locked`, or when started with `workflow_dispatch`. It uploads
GitHub Actions artifacts only. It does not create tags or publish a GitHub Release.

## Download and install

1. Open the successful workflow run in the fork's **Actions** tab.
2. Download `simple-live-android-release-<signing-mode>-<commit>` and unzip it.
3. For Samsung Galaxy S20+, install the `arm64-v8a` APK. `armeabi-v7a` and `x86_64`
   builds are also included. Checksums, commit/signing details, Flutter version,
   and the resolved dependency lockfile are in the ZIP.

All APKs use Flutter's optimized **release** build mode. Their filenames identify
whether they use a configured release certificate or a test-only debug certificate.
The application ID remains `com.xycz.simple_live`.

## Signing behavior

When all existing release secrets (`KEYSTORE_BASE64`, `STORE_PASSWORD`,
`KEY_PASSWORD`, and `KEY_ALIAS`) are configured, the workflow uses those credentials
and the original release signing configuration. If only some are present, the
build fails rather than silently switching certificates. No private key or
password is included in artifacts.

When none are configured, this dedicated workflow explicitly sets the Gradle
property `allowDebugReleaseSigning=true`. This allows an installable, debug-signed
release APK for fork testing. Other release builds still require signing settings
unless they explicitly opt in. A supplied `android/key.properties` always takes
precedence and must be complete.

A debug-signed build cannot update an installed app signed with a different key.
The CI debug key may change on each fresh runner, so it is not suitable for a
stable update channel. Before choosing to uninstall another build, export any
settings/data you need: uninstalling removes its local data. A matching, persistent
release keystore is required for normal in-place updates. The workflow does not
change the package ID or uninstall anything on your device.

For an intentional local test-only release build without a keystore:

```sh
cd simple_live_app
ORG_GRADLE_PROJECT_allowDebugReleaseSigning=true flutter build apk --release --split-per-abi
```

The workflow verifies APK signatures before uploading, uses Java 17 and Flutter
3.38.10, and runs focused checks on the player lifecycle changes. These checks do
not replace on-device testing of rotation, background/foreground, picture-in-picture,
rapid source changes, and repeated enter/exit behavior.

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
The lockfile, Flutter version and exact commit also travel with the APK artifact.
