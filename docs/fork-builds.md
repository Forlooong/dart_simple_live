# Fork build artifacts

The `app-build-action-*` workflows build this fork on `master` pushes or manual runs. Run titles identify the platform, CI run number and attempt, and branch, for example `Release Android · build #42.2 · master`. GitHub evaluates these titles before checking out the repository, so they do not contain a hardcoded package version.

App builds read the full version from `simple_live_app/pubspec.yaml`; TV reads its own version from `simple_live_tv_app/pubspec.yaml`. Artifact names, packaged filenames, and build summaries include the actual package version, including its `+` build metadata. Artifacts and filenames also include a `build.<run>.<attempt>-<short-commit>` suffix, distinguishing rebuilds without changing the application version. Updating a package version automatically updates these names; no workflow title edits are needed.

- Android / Android TV: one artifact per platform containing arm32, arm64 and x64 release APKs. Missing signing secrets opt into test signing explicitly; incomplete signing secrets fail. Test keys may change between runs, and cannot update installations signed with a different key. Back up settings before uninstalling.
- iOS: unsigned arm64 IPA. Requires appropriate Apple signing before installation.
- macOS: unsigned, unnotarized universal (Apple Silicon + Intel) application ZIP. macOS may block it.
- Windows: unsigned x64 portable ZIP. Extract all files together; requires the Microsoft Visual C++ 2015–2022 x64 runtime.
- Linux: x64 tar.gz bundle, built on Ubuntu 22.04. Extract all files together; requires GTK 3 and libmpv runtime libraries on a compatible distribution.

Each workflow uploads a single package artifact with SHA-256 checksums, retained for 14 days. Download from that workflow run’s Artifacts section. These workflows do not create tags or GitHub Releases. The original tag-triggered release/development workflows remain separate and are not needed for these fork builds.
