import 'dart:collection';

import 'package:simple_live_core/simple_live_core.dart';

/// Latest history and not-yet-published messages have independent hard bounds.
/// A visible history snapshot is a copy of [latest], never this mutable queue.
class ChatMessageBuffer {
  static const maxMessages = 200;
  static const maxBytes = 1024 * 1024;
  final _latest = ListQueue<LiveMessage>();
  final _pending = ListQueue<PendingChatMessage>();
  int latestBytes = 0;
  int pendingBytes = 0;
  int droppedMessages = 0;

  Iterable<LiveMessage> get latest => _latest;
  List<LiveMessage> get unfilteredPending => _pending
      .where((entry) => entry.filter)
      .map((entry) => entry.message)
      .toList(growable: false);

  // Dart strings occupy at most two bytes per code unit. Include a conservative
  // fixed allowance for the message object, color and queue references.
  static int messageBytes(LiveMessage message) =>
      (message.message.length + message.userName.length) * 2 + 128;

  bool add(LiveMessage message, {bool overlay = true, bool filter = true}) {
    final bytes = messageBytes(message);
    if (bytes > maxBytes) {
      droppedMessages++;
      return false;
    }
    _latest.addLast(message);
    latestBytes += bytes;
    while (_latest.length > maxMessages || latestBytes > maxBytes) {
      latestBytes -= messageBytes(_latest.removeFirst());
    }
    _pending
        .addLast(PendingChatMessage(message, overlay: overlay, filter: filter));
    pendingBytes += bytes;
    while (_pending.length > maxMessages || pendingBytes > maxBytes) {
      pendingBytes -= messageBytes(_pending.removeFirst().message);
      droppedMessages++;
    }
    return true;
  }

  List<LiveMessage> takePending() {
    final result =
        _pending.map((entry) => entry.message).toList(growable: false);
    clearPending();
    return result;
  }

  List<LiveMessage> takeOverlay() {
    final result = <LiveMessage>[];
    for (final entry in _pending) {
      if (entry.overlay) result.add(entry.message);
      entry.overlay = false;
    }
    return result;
  }

  void discardOverlay() {
    for (final entry in _pending) {
      entry.overlay = false;
    }
  }

  void markPublished() {
    for (final entry in _pending) {
      entry.filter = false;
    }
  }

  void discardUnpublished() {
    final unpublished = _pending
        .where((entry) => entry.filter)
        .map((entry) => entry.message)
        .toSet();
    _latest.removeWhere(unpublished.contains);
    latestBytes =
        _latest.fold(0, (sum, message) => sum + messageBytes(message));
    clearPending();
  }

  /// Only remove rejected messages that were not yet published. Messages in
  /// the visible history snapshot are never passed to this operation.
  void applyFilterResult(
      List<LiveMessage> evaluated, List<LiveMessage> accepted) {
    final rejected = evaluated.toSet()..removeAll(accepted);
    _latest.removeWhere((message) => rejected.contains(message));
    _pending.removeWhere((entry) => rejected.contains(entry.message));
    latestBytes =
        _latest.fold(0, (sum, message) => sum + messageBytes(message));
    pendingBytes =
        _pending.fold(0, (sum, entry) => sum + messageBytes(entry.message));
  }

  void clearPending() {
    _pending.clear();
    pendingBytes = 0;
  }

  void clear() {
    _latest.clear();
    latestBytes = 0;
    clearPending();
  }
}

class PendingChatMessage {
  PendingChatMessage(this.message,
      {required this.overlay, required this.filter});
  final LiveMessage message;
  bool overlay;
  bool filter;
}
