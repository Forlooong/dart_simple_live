# Fork build artifacts

The `app-build-action-*` workflows build this fork on `master` pushes or manual runs. App builds use `simple_live_app/pubspec.yaml` (currently 1.11.4); TV uses `simple_live_tv_app/pubspec.yaml` (currently 1.6.5). Artifacts include the actual package version and commit suffix. Keep each workflow’s readable `run-name` in sync when updating the package version.

- Android / Android TV: one artifact per platform containing arm32, arm64 and x64 release APKs. Missing signing secrets opt into test signing explicitly; incomplete signing secrets fail. Test keys may change between runs, and cannot update installations signed with a different key. Back up settings before uninstalling.
- iOS: unsigned arm64 IPA. Requires appropriate Apple signing before installation.
- macOS: unsigned, unnotarized universal (Apple Silicon + Intel) application ZIP. macOS may block it.
- Windows: unsigned x64 portable ZIP. Extract all files together; requires the Microsoft Visual C++ 2015–2022 x64 runtime.
- Linux: x64 tar.gz bundle, built on Ubuntu 22.04. Extract all files together; requires GTK 3 and libmpv runtime libraries on a compatible distribution.

Each workflow uploads a single package artifact with SHA-256 checksums, retained for 14 days. Download from that workflow run’s Artifacts section. These workflows do not create tags or GitHub Releases. The original tag-triggered release/development workflows remain separate and are not needed for these fork builds.
