import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_quickjs/controlled_regex.dart';
import 'bindings.dart';
import 'wire.dart';

/// One in-flight call, enforced before SendPort.send, so the isolate mailbox
/// cannot become an unbounded queue. The owner supplies the bounded queue.
class NativeWorker {
  NativeWorker._();
  final _ready = Completer<void>();
  final _responses = ReceivePort();
  final _errors = ReceivePort();
  SendPort? _send;
  Completer<Map<String, dynamic>>? _pending;
  bool _closing = false;
  Future<void>? _closeFuture;

  static Future<NativeWorker> start(
    int protocol, {
    bool filtering = false,
  }) async {
    final worker = NativeWorker._();
    worker._responses.listen(worker._receive);
    worker._errors.listen((error) {
      worker._send = null;
      final failure = StateError('Native worker terminated: $error');
      if (!worker._ready.isCompleted) worker._ready.completeError(failure);
      worker._pending?.completeError(failure);
      worker._pending = null;
    });
    try {
      await Isolate.spawn(
        _entry,
        [worker._responses.sendPort, protocol, filtering],
        onError: worker._errors.sendPort,
        errorsAreFatal: true,
      );
      await worker._ready.future;
    } catch (_) {
      worker._responses.close();
      worker._errors.close();
      rethrow;
    }
    return worker;
  }

  void _receive(dynamic value) {
    if (value is SendPort) {
      _send = value;
      _ready.complete();
      return;
    }
    if (value is Map && value['startupError'] != null) {
      _ready.completeError(StateError(value['startupError'] as String));
      return;
    }
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    if (value is Map && value['error'] != null) {
      pending.completeError(StateError(value['error'] as String));
    } else {
      pending.complete(Map<String, dynamic>.from(value as Map));
    }
  }

  Future<Map<String, dynamic>> call(String operation, Uint8List bytes) {
    if (_closing || _send == null) throw StateError('Worker closed');
    if (_pending != null)
      throw StateError('Worker already has an in-flight call');
    if (bytes.length > 16 * 1024 * 1024) throw StateError('Worker input limit');
    final pending = _pending = Completer<Map<String, dynamic>>();
    _send!.send([
      operation,
      TransferableTypedData.fromList([bytes]),
    ]);
    return pending.future;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    try {
      await _pending?.future;
    } catch (_) {
      /* Still release the owner. */
    }
    try {
      if (_send != null) {
        final done = _pending = Completer<Map<String, dynamic>>();
        _send!.send(['dispose', null]);
        await done.future;
      }
    } finally {
      _send = null;
      _responses.close();
      _errors.close();
    }
  }
}

void _entry(List<dynamic> args) {
  final reply = args[0] as SendPort;
  NativeSession session;
  try {
    session = NativeSession(args[1] as int);
  } catch (error) {
    reply.send({'startupError': '$error'});
    return;
  }
  final port = ReceivePort();
  ControlledRegex? compatibility;
  var quarantined = false;
  var ruleVersion = 0;
  reply.send(port.sendPort);
  port.listen((dynamic command) {
    final operation = command[0] as String;
    if (operation == 'dispose') {
      compatibility?.dispose();
      session.dispose();
      port.close();
      reply.send({'v': 1});
      return;
    }
    try {
      var bytes = (command[1] as TransferableTypedData)
          .materialize()
          .asUint8List();
      if (operation == 'rules') {
        final request = decodeWire(bytes);
        ruleVersion = request['version'] as int;
        final accepted = <dynamic>[];
        final diagnostics = <String>[];
        final rules = request['rules'] as List;
        quarantined = rules.length > 2000;
        var ruleBytes = 0;
        for (var i = 0; i < rules.length && !quarantined; i++) {
          final rule = rules[i] as Map;
          ruleBytes += (rule['text'] as Uint8List).length;
          if (ruleBytes > 1024 * 1024) {
            quarantined = true;
            diagnostics.add('Rule text exceeds 1 MiB compilation limit');
            break;
          }
          final text = utf16String(rule['text']);
          if (text.length > 4096) {
            quarantined = true;
            diagnostics.add('Rule ${i + 1} exceeds 4096 UTF-16 units');
            continue;
          }
          if (rule['regex'] == true) {
            try {
              RegExp(text);
            } on FormatException {
              diagnostics.add('Invalid stored rule ${i + 1} ignored');
              continue;
            }
          }
          accepted.add(rule);
        }
        request['rules'] = accepted;
        final result = session.call('rules', encodeWire(request));
        quarantined =
            quarantined ||
            result['blocked'] == true ||
            (result['status'] as int? ?? 0) != 0;
        compatibility?.dispose();
        compatibility = null;
        final unsupported = <int>{
          ...List<int>.from(result['unsupported'] as List? ?? const []),
          ...List<int>.from(result['invalid'] as List? ?? const []),
        };
        if (!quarantined && unsupported.isNotEmpty) {
          try {
            compatibility = ControlledRegex(
              unsupported
                  .map((i) => utf16String((accepted[i] as Map)['text']))
                  .toList(),
            );
          } catch (error) {
            quarantined = true;
            diagnostics.add('Compatibility compilation stopped: $error');
          }
        }
        if (quarantined)
          diagnostics.add('Rule set paused; edit rules to resume chat');
        result['diagnostics'] = [
          ...?result['diagnostics'] as List?,
          ...diagnostics,
        ];
        result['quarantined'] = quarantined;
        reply.send(result);
      } else if (operation == 'filter') {
        final request = decodeWire(bytes);
        if (request['version'] != ruleVersion)
          throw StateError('Stale rule version');
        final texts = request['texts'] as List;
        if (quarantined) {
          reply.send({
            'v': 1,
            'version': ruleVersion,
            'keep': List.filled(texts.length, false),
            'quarantined': true,
            'diagnostics': <String>[],
          });
          return;
        }
        final result = session.call('filter', bytes);
        quarantined = result['quarantined'] == true;
        if (!quarantined && compatibility != null) {
          final keep = List<bool>.from(result['keep'] as List);
          final indexes = [
            for (var i = 0; i < keep.length; i++)
              if (keep[i]) i,
          ];
          try {
            final compatible = compatibility!.keep(
              indexes.map((i) => utf16String(texts[i])).toList(),
            );
            for (var i = 0; i < indexes.length; i++)
              keep[indexes[i]] = compatible[i];
            result['keep'] = keep;
          } catch (error) {
            quarantined = true;
            result['diagnostics'] = [
              'Compatibility execution stopped; edit rules to resume chat: $error',
            ];
          }
        }
        if (quarantined) {
          result['keep'] = List.filled(texts.length, false);
          result['quarantined'] = true;
        }
        reply.send(result);
      } else {
        reply.send(session.call(operation, bytes));
      }
    } catch (error) {
      reply.send({'error': '$error'});
    }
  });
}
