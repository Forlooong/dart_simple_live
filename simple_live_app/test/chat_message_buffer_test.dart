import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/chat_message_buffer.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveMessage message(String text) => LiveMessage(
      type: LiveMessageType.chat,
      userName: 'viewer',
      message: text,
      color: LiveMessageColor.white,
    );

void main() {
  test('latest and pending stay bounded while the viewed snapshot is fixed',
      () {
    final buffer = ChatMessageBuffer();
    for (var i = 0; i < 200; i++) {
      buffer.add(message('$i'));
    }
    final history = buffer.latest.toList();
    for (var i = 200; i < 10000; i++) {
      buffer.add(message('$i'));
    }
    expect(history.first.message, '0');
    expect(history.last.message, '199');
    expect(buffer.latest.length, 200);
    expect(buffer.latest.first.message, '9800');
    expect(buffer.takePending().last.message, '9999');
    expect(buffer.takePending(), isEmpty);
  });

  test('byte limit applies independently of the item count', () {
    final buffer = ChatMessageBuffer();
    for (var i = 0; i < 20; i++) {
      buffer.add(message('x' * 60000));
    }
    expect(buffer.latest.length, lessThan(20));
    expect(buffer.latestBytes, lessThanOrEqualTo(1024 * 1024));
    expect(buffer.pendingBytes, lessThanOrEqualTo(1024 * 1024));
    buffer.add(message('x' * (1024 * 1024)));
    expect(buffer.latestBytes, lessThanOrEqualTo(1024 * 1024));
    buffer.clear();
    expect(buffer.latest, isEmpty);
    expect(buffer.takePending(), isEmpty);
    expect(buffer.latestBytes, 0);
    expect(buffer.pendingBytes, 0);
  });
}
