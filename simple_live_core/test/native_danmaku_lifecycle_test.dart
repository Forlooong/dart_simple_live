import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/native_live_danmaku.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart' as dy;
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:test/test.dart';

class FakeSocket extends WebScoketUtils {
  FakeSocket(this.trace) : super(url: 'wss://unused.invalid', heartBeatTime: 0);
  final List<String> trace;
  final sent = <Uint8List>[];
  int reconnects = 0, closes = 0;
  @override
  void sendMessage(dynamic data) {
    trace.add('wire');
    sent.add(Uint8List.fromList(data as List<int>));
  }

  @override
  void restartAfterProtocolError() {
    reconnects++;
  }

  @override
  void close() {
    closes++;
  }
}

class Harness extends NativeLiveDanmaku {
  Harness(super.protocol);
  final trace = <String>[];
  final received = <LiveMessage>[];
  final diagnostics = <String>[];
  final sockets = <FakeSocket>[];
  FakeSocket get socket => sockets.last;
  void observe() {
    onMessages = (messages) {
      trace.addAll(messages.map((message) => 'event:${message.type.name}'));
      received.addAll(messages);
    };
    onDiagnostic = diagnostics.add;
  }

  @override
  Future<void> start(dynamic args) async {
    if (!await initializeNative() || !nativeActive) return;
    final next = FakeSocket(trace);
    sockets.add(next);
    webScoketUtils = next;
    connectionReady();
  }
}

Uint8List frame(int operation, List<int> body) {
  final bytes = Uint8List(body.length + 16);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, bytes.length);
  data.setUint16(4, 16);
  data.setUint32(8, operation);
  data.setUint32(12, 1);
  bytes.setAll(16, body);
  return bytes;
}

Uint8List chat(String message) => frame(
  5,
  utf8.encode(
    jsonEncode({
      'cmd': 'DANMU_MSG',
      'info': [
        [0, 0, 0, 0xffffff],
        message,
        [1, 'user'],
      ],
    }),
  ),
);

Uint8List concatenate(Iterable<Uint8List> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for worker result');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

LiveMessage liveChat(String message) => LiveMessage(
  type: LiveMessageType.chat,
  userName: 'user',
  message: message,
  color: LiveMessageColor.white,
);

Uint8List douyinPacket(String message, int logId) {
  final response = dy.Response()
    ..needAck = true
    ..internalExt = 'extension'
    ..messagesList.addAll([
      dy.Message()
        ..method = 'WebcastChatMessage'
        ..payload =
            (dy.ChatMessage()
                  ..content = message
                  ..user = (dy.User()..nickName = 'name'))
                .writeToBuffer(),
      dy.Message()
        ..method = 'WebcastRoomUserSeqMessage'
        ..payload = (dy.RoomUserSeqMessage()..totalUser = Int64(42))
            .writeToBuffer(),
    ]);
  return (dy.PushFrame()
        ..logId = Int64(logId)
        ..payload = response.writeToBuffer())
      .writeToBuffer();
}

void main() {
  test(
    'stop cancels an initializing session and never opens a late socket',
    () async {
      final harness = Harness(1)..observe();
      final starting = harness.start(null);
      await harness.stop();
      await starting;
      expect(harness.nativeActive, isFalse);
      expect(harness.sockets, isEmpty);
      harness.decodeMessage(chat('late'));
      expect(harness.received, isEmpty);
    },
  );

  test(
    'overlapping starts have one owner and stop does not erase new callbacks',
    () async {
      final harness = Harness(1)..observe();
      addTearDown(harness.stop);
      final first = harness.start(null);
      final second = harness.start(null);
      await Future.wait([first, second]);
      expect(harness.sockets, hasLength(1));
      final stopping = harness.stop();
      harness.observe();
      final restarting = harness.start(null);
      await Future.wait([stopping, restarting]);
      expect(harness.nativeActive, isTrue);
      expect(harness.sockets.first.closes, 1);
      harness.decodeMessage(chat('new owner'));
      await until(() => harness.received.isNotEmpty);
      expect(harness.received.single.message, 'new owner');
    },
  );

  test(
    'old connection decode and ACK results cannot cross a generation',
    () async {
      final harness = Harness(4)..observe();
      addTearDown(harness.stop);
      await harness.start(null);
    // Drain the initial reset and rule installation first, so the old decode
    // below is actually in flight when the connection generation changes.
    harness.decodeMessage(douyinPacket('warm up', 0));
    await until(() => harness.received.length == 2);
    harness.received.clear();
    harness.trace.clear();
    harness.socket.sent.clear();
      harness.decodeMessage(douyinPacket('old', 1));
      harness.connectionReady();
      harness.decodeMessage(douyinPacket('new', 2));
      await until(() => harness.received.length == 2);
      expect(harness.received.first.message, 'new');
      expect(harness.socket.sent, hasLength(1));
      expect(
        dy.PushFrame.fromBuffer(harness.socket.sent.single).logId,
        Int64(2),
      );
      expect(harness.trace, ['wire', 'event:chat', 'event:online']);
    },
  );

  test(
    'ACK and online continue when ordinary chat is blocked by rules',
    () async {
      final harness = Harness(4)..observe();
      addTearDown(harness.stop);
      await harness.start(null);
      await harness.updateFilterRules([
        const DanmakuFilterRule(text: 'blocked'),
      ]);
      harness.decodeMessage(douyinPacket('blocked', -8));
      await until(() => harness.received.isNotEmpty);
      expect(harness.received.map((message) => message.type), [
        LiveMessageType.online,
      ]);
      expect(harness.trace, ['wire', 'event:online']);
      final ack = dy.PushFrame.fromBuffer(harness.socket.sent.single);
      expect(ack.logId, Int64(-8));
      expect(ack.payloadType, 'ack');
      expect(utf8.decode(ack.payload), 'extension');
    },
  );

  test(
    'rule barrier refilters pending chat and preserves refilter identities',
    () async {
      final harness = Harness(1)..observe();
      addTearDown(harness.stop);
      await harness.start(null);
      harness.decodeMessage(concatenate([chat('blocked'), chat('kept')]));
      await harness.updateFilterRules([
        const DanmakuFilterRule(text: 'blocked'),
      ]);
      await until(() => harness.received.isNotEmpty);
      expect(harness.received.map((message) => message.message), ['kept']);
      final first = liveChat('blocked'), second = liveChat('kept');
      final filtered = await harness.refilterMessages([first, second]);
      expect(filtered, hasLength(1));
      expect(identical(filtered.single, second), isTrue);
      final pending = harness.refilterMessages([second]);
      harness.connectionReady();
      expect(await pending, isEmpty);
      final ending = harness.refilterMessages([second]);
      final stopping = harness.stop();
      expect(await ending, isEmpty);
      await stopping;
    },
  );

  test(
    'large decoded payload keeps latest 200 chats in order with drop count',
    () async {
      final harness = Harness(1)..observe();
      addTearDown(harness.stop);
      await harness.start(null);
      harness.decodeMessage(
        concatenate(List.generate(500, (i) => chat('message $i'))),
      );
      await until(() => harness.received.length == 200);
      expect(harness.droppedChats, 300);
      expect(harness.received.first.message, 'message 300');
      expect(harness.received.last.message, 'message 499');
    },
  );

  test(
    'input and control event overflow reset connection without publishing',
    () async {
      final harness = Harness(1)..observe();
      addTearDown(harness.stop);
      await harness.start(null);
      harness.decodeMessage(Uint8List(4 * 1024 * 1024 + 1));
      expect(harness.socket.reconnects, 1);
      harness.connectionReady();
      harness.decodeMessage(
        concatenate(List.generate(1025, (_) => frame(3, [0, 0, 0, 42]))),
      );
      await until(() => harness.socket.reconnects == 2);
      expect(harness.received, isEmpty);
      expect(harness.diagnostics.length, greaterThanOrEqualTo(2));
    },
  );
}
