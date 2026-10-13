# Fork Android APK build

The `Fork Android release APK` workflow builds the checked-out commit on pushes to
`hotfix/player-lifecycle`, or when started with `workflow_dispatch`. It uploads
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
