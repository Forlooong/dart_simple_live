# Fork build artifacts

The `app-build-action-*` workflows build this fork on `master` pushes or manual runs. Run titles identify only the platform and application version, for example `Release Android · 1.12.3`. Artifact names and packaged filenames use the same version, without a CI run number, retry number or commit suffix. Rebuilding the same version keeps these names and the application's build number unchanged. GitHub keeps artifacts scoped to each workflow run; commit and CI details remain in the build summary for traceability.

The main app's Android, iOS, macOS, Windows and Linux packages all read `simple_live_app/pubspec.yaml`, currently `1.12.3+11104`. TV reads `simple_live_tv_app/pubspec.yaml`, currently `1.7.0+10605`. The number after `+` is the fixed application build number, not a CI counter. The main app keeps its existing `11104`, and TV keeps `10605`, so these version-name changes do not lower Android's version code. Flutter's split APKs apply their existing, deterministic ABI offsets. In-place Android updates still require a matching signing key.

When changing a version, update its pubspec and the corresponding workflows' `run-name` values together. GitHub evaluates titles before checkout, so they are static; each workflow checks its title against pubspec and fails before building if they disagree. Do not derive `--build-name` or `--build-number` from CI run numbers, attempts or commits. For a future release, choose and commit its build number once, preserving platform upgrade requirements; retries must reuse it.

- Android / Android TV: one artifact per platform containing arm32, arm64 and x64 release APKs. Missing signing secrets opt into test signing explicitly; incomplete signing secrets fail. Test keys may change between runs, and cannot update installations signed with a different key. Back up settings before uninstalling.
- iOS: unsigned arm64 IPA, minimum iOS 14 (required by workmanager_apple). Requires appropriate Apple signing before installation.
- macOS: unsigned, unnotarized universal (Apple Silicon + Intel) application ZIP. macOS may block it.
- Windows: unsigned x64 portable ZIP. Extract all files together; requires the Microsoft Visual C++ 2015–2022 x64 runtime.
- Linux: x64 tar.gz bundle, built on Ubuntu 22.04. Extract all files together; requires GTK 3 and libmpv runtime libraries on a compatible distribution.

Each workflow uploads a single package artifact with SHA-256 checksums, retained for 14 days. Download from that workflow run’s Artifacts section. These workflows do not create tags or GitHub Releases. The original tag-triggered release/development workflows remain separate and are not needed for these fork builds.
