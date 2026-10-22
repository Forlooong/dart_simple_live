# Known-issues repair and release plan

Historical base: `e279e70c9207cec5af9f256e94df0241078bba77` (`fix/follow-list-refresh`).

The original plan and validation notes below describe that earlier repair. The
2026-10-18 audit implementation record at the end supersedes its pending-work
statements; neither record is proof of installed-device validation.

## Review decision

Implementation was approved after independent review of the plan, with the following mandatory data-safety additions: retain original tag records in a durable, first-write-preserving backup before removing aliases; serialize mutations and migration; retain a resumable migration plan; write the completion marker last; verify restart after injected failures. Selecting a UUID-keyed record over an integer-keyed duplicate is a deterministic reconciliation policy, not proof that one copy is newer. Final approval requires code review and executable regression checks.

## Repair sequence and acceptance criteria

1. **P2: refreshed membership misses status polling.** Track object identity in a single active refresh transaction. Reconcile membership immediately, admit newly added/replaced records through a subsequent delta batch, and share one completion future across callers. Membership notifications that request no new refresh still join new records to an already-active transaction. Unchanged repeated loads must cause no extra round. Removed/replaced records cannot publish late results. Test delayed requests, import-style replacements, insert/delete overlap, and request counts.
2. **P2: interrupted manual refresh never resumes when periodic polling is off.** Preserve work that has not been admitted when the app backgrounds. Drain already-admitted requests without admitting more. Keep the caller's completion pending until foreground work finishes or the service closes. Resume directly, independently of periodic polling, including resume before the prior batch drains. Calls made in the background must not admit network requests. Disposal settles waiters and prevents late state writes. Test all these transitions and configured/playback concurrency limits.
3. **P2: legacy tag ordering corrupts record keys.** Preserve UUID-keyed records and store ordering separately. Detect legacy integer/mismatched keys and duplicate IDs. Persist original records to a recoverable backup first; use a resumable canonicalization plan and do not clear the tag box. Write canonical records/order before obsolete aliases are removed. Serialize migration, rename, delete, and reorder; never resurrect a deleted ID from an older reorder snapshot. Preserve unknown existing IDs. Test fresh/legacy/mixed data, conflicting aliases, injected interruption/reopen, backup retention, repeat migration, reorder/rename/delete, and ordering after reopen.
4. **P3: asynchronous status completion undoes tag reorder visually.** Publish reordered tags to FollowService synchronously before saving, so controller event snapshots preserve the chosen order. Test reorder during an outstanding automatic status request.
5. **Upgrade safety.** Release instructions must distinguish settings export from follow-list export and require both before uninstalling an incompatible-signature installation. Never claim a test-signed APK can update an installation with a different certificate. No signing credentials are generated or changed by this repair.
6. **Android packaging gate.** Check every packaged ELF library's architecture and load-segment alignment, not just two selected native libraries. Verify APK ZIP alignment with the Android SDK's zipalign tool. Add synthetic verifier regressions. Archive inspection alone is not installed-device or 16-KiB-device validation; disclose the remaining device gap.
7. **TV release metadata.** Derive release metadata from the current TV package version, validate tag/version consistency, and stage publication as a draft. Avoid stale hard-coded release version text.
8. **Release integration.** Increment the app version once after integrating fixes. Run formatting, focused analysis, deterministic regressions, existing app/core suites, and release-tool tests. Review the final diff independently. Push a feature branch/draft PR, build the exact final SHA for Android, TV, iOS, macOS, Linux and Windows, inspect run conclusions and artifacts, and report platform/signing/device limits accurately. A failed or unverified check is not a pass. Never change repository security, credentials, or release signing identity without separate authorization.

## Stop and recovery conditions

Recoverable code/test/build failures remain part of this task and must be repaired and rechecked. If a build or publication needs credentials, security changes, new legal acceptance, or a real device unavailable in the current environment, request the specific missing action and retain the exact-head evidence already established. Do not delete user data to work around a migration or signing failure.

## Additional playback review

- Confirmed main-app defect: a manual room refresh can report a fully offline room while previous native playback continues. Stop playback only for confirmed offline/non-recording detail, through the existing serialized player queue with generation checks before execution and after awaiting. Preserve recording playback and current transient-fetch-error behavior. Regression tests exercise real room loading and stale queued stops.
- Frequent Android buffering is a user-observed symptom, not yet tied to one reproducible cause. This patch does not claim to solve all stalls or guarantee every phone/tablet. Keep platform-specific defaults conservative; do not install a blanket restart watchdog without distinguishing paused, offline, buffering, opening, and recovering states. Provider/network variability and real-device playback remain validation targets.
- TV still uses the older playback lifecycle/retry implementation. Porting main-app command serialization/source refresh is a separate scoped repair requiring equivalent TV tests, not evidence of a new main-app regression. Track and disclose this remaining risk rather than silently rewriting TV playback during the main-app fix.

### Historical pending work: TV playback parity

The static audit found these pre-existing TV risks, which remain pending rather than being counted as repaired by this release:

1. Error and EOF callbacks can launch duplicate recovery because TV lacks the main-app single-flight/generation recovery state machine.
2. Delayed retries and asynchronous quality/URL completions can outlive room changes or disposal; native open/stop/dispose commands are not fully serialized.
3. Retry paths reuse old stream URLs instead of re-fetching expiring provider URLs.
4. TV retains `force-seekable=yes`; compatibility must be assessed before porting main-app defaults.

Next bounded TV work: first add delayed-provider/native-boundary regression fixtures, then port generation-guarded request selection, command serialization, single-flight capped recovery and fresh-source retrieval; verify close/change-room/error+EOF races and retry budget before enabling the behavior. Run TV tests/builds and installed-device smoke checks independently. The current TV packaging build validates packaging gates, not this unimplemented lifecycle port.

### Historical validation status before CI

- Plan and code received independent static review, including backup/replay and asynchronous tag persistence.
- Twenty Python tooling tests passed.
- Seven diagnostics tests passed against the production pure-Dart class with a package:test harness; its standalone analyzer passed.
- Flutter app/DB/player integration tests and platform builds are still pending. Local Flutter initialization was blocked by an incidental cloud-metadata probe; it is not counted as successful validation.
- GitHub publication/CI awaits explicit destination approval. No release installation or universal device-compatibility claim is made.


## 2026-10-18 audit implementation record

Audit: [Simple Live 深度审计与长期优化报告 · 2026-10-17](https://app.notion.com/p/3fc683d76dac817c88f0d97988f438cb?pvs=204),
reviewed baseline `1b7384c72a051604d7060d72940bc6e7fa4287ff`. The changes below
are local working-tree changes, not a published release or completed six-platform
build. Historical plans above do not authorize changing signing credentials.

| Audit item | Implemented behavior | Deterministic evidence |
| --- | --- | --- |
| D1, D7 | App/TV listen only during an explicit ten-minute pairing session; authenticated AES-GCM requests/responses, receiver approval, replay rejection, bounded bodies and awaited generation-safe shutdown. | `sync_session_test.dart`: closed/expired sessions, incorrect key, replay (including alternate nonce encoding), approval/stop race and restart. |
| D2, D3 | Cookies/passwords move to platform secure storage before legacy keys are removed and the live Hive file compacted. HTTP request logs contain safe metadata only. Notification JSON, local configuration exports and new WebDAV backups exclude credentials. Legacy backup account restore is opt-in. | `credential_safety_test.dart`, account session tests and configuration/restore tests check canary exclusion and stale account requests. |
| D4 | Desktop directory migration copies and validates each missing file, flushes and renames temporary files, retains original files and writes its completion marker last. | `storage_restore_test.dart`: interrupted copy resumes, originals remain and no partial file is committed; a real profile remains a release check. |
| D5 | Follow/tag imports, rename/delete/move and history mutations use serialized repositories. Entire input is validated before mutation, including supported sites; durable undo journals recover interrupted transactions. Tag order and relationships commit together. | DB/import tests cover duplicate/bad input, rollback/reopen, concurrent writes, rename/move/delete and history clear. |
| D6 | TV foreground refresh resumes work not yet admitted, including manual work with polling disabled; completed stale records cannot publish. | Core refresh and TV follow refresh tests. |
| D8 | WebDAV upload/restore are awaited and single-flight; loading always clears; results distinguish complete/partial failure. Upload uses a temporary object and MOVE. | Storage restore tests cover preflight, category failures and success metadata. |
| R1 | TARS has explicit connection/send/receive durations; App/TV provider chains carry cancellation and a total deadline. | Local fake transport and delayed room tests. |
| R2, R3 | TV room/quality/URL results carry generations, player commands serialize, recovery is single-flight and capped, and retries fetch fresh sources. EOF alone does not declare a room offline. | TV playback recovery and room-switch/close tests. |
| R4, R5 | Two concurrent candidate requests retain successful URLs after individual candidate failures, in server order; stable host-based Bilibili CDN partition replaces the invalid comparator. The overall request deadline still applies. | Core transport/response fixtures. |
| R6 (bounded change) | Shared typed failures preserve cancellation, timeout, transport, auth, rate-limit and schema categories. Source response and URL validation mainly cover Bilibili, Douyu and Huya; Douyin retains its existing quality parsing and URL-copy path. | Core transport/schema fixtures; complete four-provider adapter uniformity is not claimed. |
| R7, R8 | Shared session diagnostics record bounded stage timings and frozen-stall evidence; navigation offers cancellation when native cleanup is slow, while retaining serialized cleanup. | Diagnostics, lifecycle and cleanup-wait tests. Position progress is not represented as a rendered first frame. |
| R9 (bounded change) | Recovery selects stable provider quality IDs before legacy display-name fallback; command queue and diagnostics are shared. | Playback recovery tests. Full stable CDN identities are not introduced without a provider contract. |
| QuickJS | UTF-8 byte lengths, native execution budget, isolate ownership and finally-based runtime cleanup; freed return values are copied before native memory is released. | Unicode/emoji/NUL/empty/escaped input, quoted Douyin parameters, exceptions and infinite execution tests on the local native ABI; Douyin remains synchronous with a native deadline and bounded retries. |
| Display | System text scaling and real safe-area insets remain enabled. The Android window inset workaround is explicit opt-in and preserves side insets/keyboard behavior. TV buttons can grow with text. | App media-query and TV large-text widget tests. |
| Build | Actions are pinned to resolved SHAs; core/renderer test graphs are locked. CI analyzes App/TV/core and separates network tests from deterministic tests; build summaries record actual tool versions. | Locked dependency resolution and local analysis; six-platform CI and installed upgrades still require execution. |

Configuration imports and shield updates use the same command boundaries across
local files, LAN, remote sync and WebDAV. Shield rules share native limits (count,
pattern length and total input), are validated before mutation, and recover their
previous snapshot after interrupted writes. Importing an older export does not
restore credentials through its ordinary settings map.

### Compatibility and remaining evidence

The user confirmed this iteration delivers code and builds possible in the local
environment; phone/TV installation, playback and 16 KiB acceptance run separately.

- LAN protocol v2 requires both peers to update. Its key is carried in the pairing
  QR/link fragment and must be treated as a credential. Leaving the page or
  session expiry closes its listener. Existing remote relay synchronization uses
  its existing transport; this LAN change is not a claim of relay end-to-end encryption.
- Secure storage requires the platform keychain/credential service. Linux packages
  include libsecret/jsoncpp dependencies and need an available desktop Secret
  Service. No insecure fallback is installed when that service fails.
- Old logs, exported ZIPs and retained desktop migration sources may still contain
  old credentials; migration does not silently delete those historical files.
  Downgrading to a build that only reads ordinary settings requires signing in again.
- TV keeps its current native `force-seekable` compatibility setting. Real playback,
  TV remote focus, PiP/foldable/large-font layouts, radio/network transitions and
  same-ABI signed upgrades need device evidence. No connected-device test, universal
  compatibility or resolution of every intermittent loading spinner is claimed.
- QuickJS is bounded inside the native engine; it does not provide a general way
  to kill arbitrary hung native player calls. Slow cleanup is cancellable in the
  navigation UI without racing native disposal.
- Candidate collection preserves partial success after individual failures, but
  expiry of the whole 30-second request budget still invalidates the attempt,
  including URLs already received. Earlier partial return requires a separate
  collection budget and cancellable child requests while preserving user
  cancellation; that boundary is a follow-up, not a completed R4 guarantee.
- Follow/tag relations retain their legacy display-name representation behind a
  single command boundary. A versioned stable-tag-ID data migration, complete
  adapter capability/DTO contracts, renewable anonymous platform sessions and
  stable CDN candidate identities remain architectural follow-ups. Their current
  compatibility paths are preserved; they are not counted as completed migrations.
- Performance work requiring P50/P95, memory/handle trends or renderer frame
  measurements is not substituted with guessed optimizations. Broader Linux
  targets, dependency major upgrades and formal signing/notarization remain scoped
  decisions with the exit conditions recorded in `fork-builds.md`.

Validation records cover only checks actually executed. Package signing identity,
repository credentials and user data are not changed by this implementation.


### Local validation evidence

- Version tooling: 40 tests passed; synchronized final source versions are App
  `1.12.17+11118` and TV `1.7.8+10613`.
- Core transport, deadline/cancellation, CDN/schema, sync encryption/replay,
  refresh and native/QuickJS contracts passed. The final QuickJS run passed all
  five tests, including Douyin quoted inputs and repeated timeout cleanup.
- App storage/import/rollback/restart, configuration export/import/reset, account
  races, notification scheduling and playback lifecycle/recovery tests passed in
  focused runs. Credential tests passed all three cases, including a persisted
  deletion followed by process restart before physical compaction. The final
  notification change passed nine permission/scheduling/import-concurrency cases.
- TV import/rollback, follow refresh, account races, playback recovery and the
  large-text button widget passed. App safe-area/text-scale widget tests passed.
- App full analysis and TV full analysis reported no errors or warnings; the few
  new style infos were fixed. Core `lib` and `test` analysis reported no errors or
  warnings; pre-existing core style infos remain. This does not suppress errors
  in CI. The workflow YAML parses and retains exactly six jobs.
- Real WebDAV server MOVE semantics, installed-device upgrades, live provider
  playback and platform keychain behavior outside the local host remain untested.

- Windows x64 Release built successfully from this working tree. The existing
  native-bundle verifier loaded `danmaku_native.dll` and `dart_quickjs.dll`, and
  executable numeric version `1.12.17.11118` matched the source. The complete
  unpackaged bundle is in `simple_live_app/build/windows/x64/runner/Release`.
  This is a compile/native-load check, not an installer or interactive playback test.
- Local Windows setup required an ASCII directory junction, a process-local
  `/utf-8` MSVC option, same-version Flutter wrapper files, a signed NuGet tool
  and locally cached packages obtained from their original feeds. No system
  developer-mode, signing or repository credential settings were changed.
  Initial missing dependency, path-encoding and code-page failures were resolved;
  only the final successful build is counted as passed. Other platform builds
  were not run locally; Android command-line SDK components are unavailable.
  The temporary junction, audit text copy and Windows build intermediates were
  removed after verification; the complete Release bundle was retained unchanged.
