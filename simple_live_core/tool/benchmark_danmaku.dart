import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/native_live_danmaku.dart';

class BenchmarkRoom extends NativeLiveDanmaku {
  BenchmarkRoom() : super(1);
  int failures = 0;
  @override
  void sendWire(List<int> wire) {}
  @override
  void reconnectNative() {
    failures++;
  }
}

Uint8List packet(int id) {
  final body = utf8.encode(
    jsonEncode({
      'cmd': 'DANMU_MSG',
      'info': [
        [0, 0, 0, 16777215],
        '$id 正常中文聊天 emoji😀',
        [1, 'viewer'],
      ],
    }),
  );
  final bytes = Uint8List(body.length + 16);
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, bytes.length);
  header.setUint16(4, 16);
  header.setUint16(6, 0);
  header.setUint32(8, 5);
  header.setUint32(12, 1);
  bytes.setRange(16, bytes.length, body);
  return bytes;
}

/// Replay the bounded native core pipeline. This measures input-to-callback
/// latency, including isolate transfer, native decode and filtering; it does
/// not measure Flutter paint time, phone power or video decoding.
Future<void> main(List<String> args) async {
  final duration = args.contains('--quick') ? 500 : 2000;
  final results = <Map<String, dynamic>>[];
  for (final rate in [100, 1000, 5000]) {
    for (final ruleCount in [0, 10, 100, 1000]) {
      final room = BenchmarkRoom();
      await room.updateFilterRules(
        List.generate(
          ruleCount,
          (i) => DanmakuFilterRule(
            text: i % 4 == 0 ? '^blocked_$i|denied_$i' : 'blocked_$i',
            regex: i % 4 == 0,
          ),
        ),
      );
      final clock = Stopwatch()..start();
      final sentAt = <int, int>{};
      final latencies = <int>[];
      final diagnostics = <String>[];
      room.onDiagnostic = diagnostics.add;
      room.onMessages = (messages) {
        for (final message in messages) {
          final id = int.parse(message.message.split(' ').first);
          final sent = sentAt.remove(id);
          if (sent != null) latencies.add(clock.elapsedMicroseconds - sent);
        }
      };
      if (!await room.initializeNative())
        throw StateError('Benchmark startup canceled');
      room.connectionReady();
      await room.updateFilterRules(room.filterRules);
      final batchSize = rate ~/ 50;
      final batches = duration ~/ 20;
      var id = 0;
      for (var tick = 0; tick < batches; tick++) {
        final builder = BytesBuilder(copy: false);
        final ids = <int>[];
        for (var item = 0; item < batchSize; item++) {
          ids.add(id);
          builder.add(packet(id++));
        }
        final payload = builder.takeBytes();
        final sent = clock.elapsedMicroseconds;
        for (final message in ids) sentAt[message] = sent;
        room.decodeMessage(payload);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final deadline = clock.elapsedMilliseconds + 3000;
      while (sentAt.isNotEmpty && clock.elapsedMilliseconds < deadline) {
        if (room.droppedChats >= sentAt.length) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      latencies.sort();
      results.add({
        'messages_per_second': rate,
        'rules': ruleCount,
        'sent': id,
        'received': latencies.length,
        'dropped': room.droppedChats,
        'unaccounted': sentAt.length - room.droppedChats,
        'failures': room.failures,
        'p95_ms': latencies.isEmpty
            ? null
            : latencies[((latencies.length - 1) * .95).round()] / 1000,
        'rss_mib': ProcessInfo.currentRss / (1024 * 1024),
        'diagnostics': diagnostics,
      });
      await room.stop();
    }
  }
  print(
    const JsonEncoder.withIndent('  ').convert({
      'scope':
          'native core input-to-callback, excludes Flutter paint/video/power',
      'runtime': Platform.version,
      'duration_per_case_ms': duration,
      'results': results,
    }),
  );
  if (results.any(
    (result) => result['failures'] != 0 || result['unaccounted'] != 0,
  ))
    exitCode = 1;
}
