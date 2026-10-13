# Player lifecycle hotfix review

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
build incompatibility in the newly resolved `auto_orientation_v2` 2.4.7 plugin;
that dependency is pinned to the originally requested 2.3.6 for this AGP 8.9.1
project (see the build guide). The Video widget's internal lifecycle
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
