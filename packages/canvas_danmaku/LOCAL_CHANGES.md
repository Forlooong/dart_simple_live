# Simple Live renderer fork

Based on `canvas_danmaku` 0.2.7 by Predidit. The upstream MIT license is retained
in `LICENSE`.

This shared application/TV dependency adds an `enabled` property and removes
idle periodic work. Animation and a single cancellable cleanup timer run only
while enabled, foreground, and holding visible items. Disabling or backgrounding
clears the overlay; resuming accepts new messages without replaying old ones.
The creation callback runs after animation controllers are initialized.

Run `flutter test` from this directory for the lifecycle regression tests.
