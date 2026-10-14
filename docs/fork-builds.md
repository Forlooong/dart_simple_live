# Fork build artifacts

The `app-build-action-*` workflows build this fork on `master` pushes or manual runs. The main app's Android, iOS, macOS, Windows and Linux packages all read `simple_live_app/pubspec.yaml`. TV reads `simple_live_tv_app/pubspec.yaml` independently. These committed pubspecs are the source of truth for installed versions; CI does not override them with a run counter.

## Before committing a fix

Run this once per batch of main-app fixes, from the repository root:

```shell
python tool/version.py bump main
```

This increments both the patch version and build number (for example, `1.12.3+11104` → `1.12.4+11105`) and updates all five main-app workflow titles together. Include those files in the same commit as the fix. Use `bump tv` for TV changes, or `bump both` for changes in `simple_live_core` that affect both apps. For an intentional major/minor release, edit the pubspec version and increase its build number, then run `python tool/version.py sync main` (or `tv`) to refresh the titles without another increment.

Check the versions locally with `python tool/version.py check both`. On a push, CI also compares app/core changes against the previous branch tip and refuses to build if either the version name or build number has not increased. A push containing multiple commits needs one version increment for that batch. Documentation/build-tool-only changes and rebuilding the same commit may reuse the committed version.

The command updates files locally; it does not commit or push. CI validates versions and never creates version-bump commits. Remember to run the command before committing new application changes.

## Identifying builds

- Actions titles include the complete source version and workflow run number: `Release Android · 1.12.4+11105 · #25`.
- Artifact and package names include the source version, run number, attempt and short commit SHA: `Simple-Live-1.12.4+11105-r25.1-abcdef0-Android-arm64-TestSigned.apk`.
- A rerun uses the same installed version but a different attempt suffix. The workflow summary includes the commit and build identity; Android/TV also include these in `BUILD-INFO.txt`.
- GitHub evaluates `run-name` before checkout, so the version in the title must be committed. The shared script updates and validates these titles against pubspec; the run number is supplied by GitHub.
- Flutter 3.38.10 split APKs add ABI offsets to the committed build number: arm32 `+1000`, arm64 `+2000`, x64 `+4000`. For source `1.12.4+11105`, arm64 reports `1.12.4+13105`. Android/TV workflows inspect the finished APK manifests and fail if these versions do not match, and package an ABI-specific `VERSION.txt` with the actual values.

## Downloads

- Android: one artifact containing arm32, arm64 and x64 release APKs, plus a smaller arm64-only artifact linked in the build summary.
- Android TV: one artifact containing all three APK architectures.
- Android/TV missing signing secrets opt into test signing explicitly; incomplete secrets fail. In-place updates require the same signing key. Test keys may change between runs. Keep the old app until a migration is explicitly chosen; main-app follows and settings require separate exports, verified outside the app before any uninstall. Do not assume TV offers the same export UI. Nothing uninstalls automatically.
- iOS: unsigned arm64 IPA, minimum iOS 14 (required by workmanager_apple). Requires appropriate Apple signing before installation.
- macOS: unsigned, unnotarized universal (Apple Silicon + Intel) application ZIP. macOS may block it.
- Windows: unsigned x64 portable ZIP. Extract all files together; requires the Microsoft Visual C++ 2015–2022 x64 runtime.
- Linux: x64 tar.gz bundle, built on Ubuntu 22.04. Extract all files together; requires GTK 3 and libmpv runtime libraries on a compatible distribution.

Artifacts include SHA-256 checksums and are retained for 14 days. Download from the workflow summary or Artifacts section. These workflows do not create tags or GitHub Releases. The original tag-triggered release/development workflows remain separate.

See [release gates](release-gates.md) before publishing or claiming stable/upgrade compatibility. The TV tag workflow now validates its tag against pubspec and prepares a draft prerelease; it does not trust stale update-channel JSON as the release version.
