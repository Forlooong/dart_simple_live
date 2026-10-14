# Known-issues repair and release plan

Base: `e279e70c9207cec5af9f256e94df0241078bba77` (`fix/follow-list-refresh`).

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

### Explicitly pending: TV playback parity

The static audit found these pre-existing TV risks, which remain pending rather than being counted as repaired by this release:

1. Error and EOF callbacks can launch duplicate recovery because TV lacks the main-app single-flight/generation recovery state machine.
2. Delayed retries and asynchronous quality/URL completions can outlive room changes or disposal; native open/stop/dispose commands are not fully serialized.
3. Retry paths reuse old stream URLs instead of re-fetching expiring provider URLs.
4. TV retains `force-seekable=yes`; compatibility must be assessed before porting main-app defaults.

Next bounded TV work: first add delayed-provider/native-boundary regression fixtures, then port generation-guarded request selection, command serialization, single-flight capped recovery and fresh-source retrieval; verify close/change-room/error+EOF races and retry budget before enabling the behavior. Run TV tests/builds and installed-device smoke checks independently. The current TV packaging build validates packaging gates, not this unimplemented lifecycle port.

### Validation status before CI

- Plan and code received independent static review, including backup/replay and asynchronous tag persistence.
- Twenty Python tooling tests passed.
- Seven diagnostics tests passed against the production pure-Dart class with a package:test harness; its standalone analyzer passed.
- Flutter app/DB/player integration tests and platform builds are still pending. Local Flutter initialization was blocked by an incidental cloud-metadata probe; it is not counted as successful validation.
- GitHub publication/CI awaits explicit destination approval. No release installation or universal device-compatibility claim is made.
