/// Serializes commands for one player and drains its active command on close.
///
/// Commands which have not started are discarded as soon as closing begins.
/// A failure is reported to its caller without preventing later cleanup.
class PlayerCommandQueue {
  PlayerCommandQueue({this.onError});

  final void Function(Object error, StackTrace stackTrace)? onError;

  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closing = false;

  bool get isClosing => _closing;

  Future<void> run(Future<void> Function() command) {
    if (_closing) return Future<void>.value();
    final result = _tail.then((_) async {
      if (_closing) return;
      await command();
    });
    _observe(result);
    return result;
  }

  /// Synchronous guard, used before canceling timers and subscriptions.
  void stopAcceptingCommands() {
    _closing = true;
  }

  Future<void> close(Future<void> Function() dispose) {
    stopAcceptingCommands();
    if (_closeFuture != null) return _closeFuture!;
    final result = _tail.then((_) => dispose());
    _closeFuture = result;
    _observe(result);
    return result;
  }

  void _observe(Future<void> result) {
    // Attach an error listener even for fire-and-forget UI commands, while
    // retaining the original result for callers that await it.
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        try {
          onError?.call(error, stack);
        } catch (_) {
          // A failed logger must not prevent the native player being disposed.
        }
      },
    );
  }
}
