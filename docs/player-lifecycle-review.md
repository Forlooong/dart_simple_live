# Player lifecycle hotfix review

## 2026-10-14: five-minute playback failure follow-up

The workspace was fast-forwarded to the user's fork commit
`7ece84d2eca2e4ddf961732fb3095e4c85715a22`, matching successful
[Android Actions run 38385154501](https://github.com/Forlooong/dart_simple_live/actions/runs/38385154501).
The source version is `1.12.3+11104`; Flutter's split-per-ABI build adds 2000
to the arm64 version code, explaining `1.12.3+13104` in both device logs.
TV's source version is `1.7.0+10605`. The four synchronized commits do not
change the playback controller investigated here.

### Evidence from the supplied logs

Only redacted observations are recorded here; signed URLs are not copied.

| Log | Initial playback | Connection reset | Subsequent behavior |
| --- | --- | --- | --- |
| `2026-10-14 01-13-40..log` | 01:13:44 | 01:18:44 | At 01:18:50, failed `seek(0)` and multiple CDN opens in one second; later corrupt FLV/NAL and hardware decoder warnings. |
| `2026-10-14 01-42-51..log` | 01:42:54 | 01:47:54 | At 01:48:00, the same seek/reopen pattern; truncated FLV/NAL and software H.264 decoder errors follow. |

Both connections reset after 300 seconds. The URLs also contain `expire=300`.
Expiry or a CDN connection-lifetime policy is a plausible trigger, but these
application logs do not prove the server's policy. The reproducible application
defects are in recovery after that disconnect:

- All alternate CDN URLs were passed as a native playlist. libmpv could move to
  the next entry at EOF while the application independently retried its own
  selected index. The UI index and native playlist could diverge.
- `media_kit` 1.2.6 `NativePlayer.jump()` calls `play()`, which seeks completed
  media back to zero before changing playlist position. This is inappropriate
  for reconnecting an ended live HTTP FLV.
- Retries reused the old URLs. Merely re-calling `getPlayUrls` would also reuse
  Douyu's timestamped signing arguments in `detail.data`, or Douyin's URLs in
  `quality.data`.
- Error and EOF from one native open could reserve two recovery attempts.
  There was no sustained-playback signal to replenish the retry budget.

`osc` property errors and failed disk-cache creation occurred before successful
playback, so neither alone explains the five-minute failure. The first log
contains a normal room close and navigation to settings; the second ends after
decoder errors. Neither contains a Dart fatal exception or Android native crash
backtrace. Software decoding reproduces the connection/recovery failure, so
hardware decoding alone cannot explain both logs.

### Changes

- Open one `Media` at a time, including manual line changes. Reopening replaces
  the HTTP/demuxer session instead of jumping/seeking the old live stream.
- Recover using fresh room details, quality metadata and signed URLs; retain
  the selected quality when available and pass refreshed HTTP headers.
- Coalesce terminal events per native open, retaining a failure that occurs
  during the replacement open. Space retries by 300 ms, allow two per line
  and at most six until ten seconds of advancing playback replenishes the
  budget. Provider/open exceptions obey the same limit.
- Reject stale refresh responses after selection changes, room changes or
  close. Continue to serialize native open and disposal through the existing
  command queue. Show a single failure toast after exhaustion, and report
  offline only when fresh room metadata confirms it (replays remain playable).
- Disable forced seeking and disk caching for live playback; retain the
  existing bounded memory cache. See the
  [mpv cache and seeking options](https://mpv.io/manual/stable/).
- Include `test/live_playback_recovery_test.dart` in Android Actions.
- Upload a separate arm64 Actions artifact with its checksum, signing details
  and source commit so device testing can download only the required APK.

### Verification and limits

Before the fix, the focused recovery test reported three failures: native
playlist instead of single media, only one URL request instead of a refreshed
request, and two reserved retries instead of one. Tests exercise the real room
controller, event subscriptions, `Player` wrapper and command queue; only the
HTTP provider and native endpoint are replaced. Additional cases cover stale
responses, errors during open, retry exhaustion, sustained progress, offline
rooms and close during both a retry delay and an in-flight open.

Final local verification: all 86 tests in the Android Actions test selection
passed, including 12 new recovery tests. Static analysis of the Actions scope
plus the new tests reported no issues. `git diff --check` passed. This local
verification did not build an APK or exercise the affected device; the
corresponding Android Actions run supplies build and signing results.

Run from `simple_live_app`:

```sh
flutter test --no-pub test/live_playback_recovery_test.dart test/player_command_queue_test.dart test/live_room_lifecycle_test.dart test/danmaku_lifecycle_test.dart
flutter analyze --no-pub --no-fatal-infos lib/modules/live_room/live_room_controller.dart lib/modules/live_room/player/player_controller.dart test/live_playback_recovery_test.dart
```

No Android device is attached to this workspace. These tests do not reproduce
or prove the absence of an Android native crash, nor verify a live CDN session
past 300 seconds. On the affected S20+, verify repeated recovery beyond five
minutes and rapid line/room switching with the patched build. A remaining
process crash needs time-correlated `adb logcat -b all` output or a tombstone,
including `AndroidRuntime`, `libc`, MediaCodec and native backtrace entries.

The sections below describe the earlier lifecycle patch, before this follow-up.

## Scope and evidence

This patch is based on fork commit `ba828e6783b176ea5709fcd09f0eb01dfaceeb51`
(`simple_live_app` version `1.11.4+11104`). The previously discussed Android
installation was reported as 1.11.7. Those are not identical source/build inputs.

The shared troubleshooting conversation describes room-switch/exit crashes on a
Samsung S20+, plus playback/codec errors about five minutes into one session. Its
quoted application logs do not establish a fatal Dart exception, native crash
stack, or a demonstrated use-after-free. Native disposal races, decoder/resource
pressure, live-stream expiry and reconnect/seek behavior remain hypotheses.

The prior generated hotfix ZIP is not retrievable from the public conversation
(the attachment link has no usable download target). Its exact contents and any
claims about execution cannot be verified. This is an independently reconstructed
source patch, not a claim that the old patch was applied or tested.

## Verified source defects addressed

- GetX `onClose` returned `void` while asynchronously resetting system state and
  disposing the player. Closing now becomes visible synchronously; native
  disposal is idempotent and follows in-flight application commands. Stream and
  timer producers are stopped, and navigation waits for already-started cleanup.
- Room details, quality requests, playback URL requests, and delayed retries could
  finish after a room switch, newer selection, or close. Generation checks now
  reject stale continuations; invalidated quality/line selections are cleared.
- Application open/jump/stop/volume/screenshot operations could overlap disposal.
  A per-player queue serializes these commands and rejects pending commands on
  close. Failures do not poison the disposal queue.
- Retry counters were incremented after an asynchronous delay, permitting
  overlapping attempts. Retry ownership is now generation-specific; terminal
  events during open/retry are coalesced and processed with bounded attempts.
- `e as Error` could itself throw when the original failure was an Exception.
  The original `Object` and its caught `StackTrace` are retained instead.

## Deliberate limits

The playback patch does not change decoder defaults, `force-seekable`, media_kit
dependency constraints, or media_kit internals. CI exposed a separate Android
build incompatibilities in newly resolved `auto_orientation_v2` 2.4.7 and
`dynamic_color` 1.9.0 plugins. They are pinned to the originally requested 2.3.6
and 1.8.1 respectively for this AGP 8.9.1 project (see the build guide). The Video widget's internal lifecycle
pause/resume calls are outside the application queue. This does not prove that a
native crash is fixed, and automated fake/queue tests cannot validate Android
MediaCodec, Surface or libmpv behavior.

The fork workflow builds release-mode APKs and identifies their actual signing
mode. See [the build guide](fork-android-build.md) before installation.

## Device regression checklist

On the S20+, test repeated enter/exit, rapid A→B→A room changes, overlapping
quality/line changes, refresh then immediately back, background/foreground,
rotation/fullscreen and PiP. Also play beyond the previously observed five-minute
boundary. Keep an existing settings export before changing installations.

If a crash persists, preserve a time-correlated Android `logcat`/bug report with
`AndroidRuntime`, `libc`, native backtrace/tombstone, and codec messages. Redact
account identifiers and stream URLs/tokens before sharing. Application logs alone
are insufficient to assign a native root cause.
