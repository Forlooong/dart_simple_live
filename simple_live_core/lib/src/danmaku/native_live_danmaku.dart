import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:danmaku_native/danmaku_native.dart';
import '../interface/live_danmaku.dart';
import '../model/live_message.dart';
import '../common/web_socket_util.dart';

abstract class NativeLiveDanmaku extends LiveDanmaku {
  NativeLiveDanmaku(this.protocol);
  final int protocol;
  WebScoketUtils? webScoketUtils;
  NativeWorker? _decoder, _filter;
  Future<bool>? _initializing;
  Future<void>? _decodeDrain, _filterDrain, _stopping;
  final _jobs = Queue<_DecodeJob>();
  final _events = Queue<_Event>();
  final _refilterJobs = Queue<_RefilterJob>();
  final _ruleWaiters = <(int, Completer<void>)>[];
  final _reported = <String>{};
  int _generation = 0, _rawBytes = 0, _ruleVersion = 0, _installedVersion = -1;
  int _lifecycle = 0;
  bool _closed = true;
  int droppedChats = 0;

  bool get nativeActive => !_closed;

  void sendWire(List<int> wire) => webScoketUtils?.sendMessage(wire);
  void reconnectNative() => webScoketUtils?.restartAfterProtocolError();

  @override
  Future<void> stop() {
    webScoketUtils?.close();
    webScoketUtils = null;
    // Clear the old owner's callbacks before awaiting. A subsequent start may
    // install new callbacks while the previous workers are still shutting down.
    onMessage = null;
    onMessages = null;
    onDiagnostic = null;
    onClose = null;
    onReady = null;
    return stopNative();
  }

  Future<bool> initializeNative() {
    final lifecycle = ++_lifecycle;
    final previousInitialization = _initializing;
    final previousStop = _stopping;
    webScoketUtils?.close();
    webScoketUtils = null;
    _cancelPendingWork();
    late final Future<bool> initializing;
    initializing =
        (() async {
          if (previousStop != null) await previousStop;
          if (previousInitialization != null) {
            try {
              await previousInitialization;
            } catch (_) {
              /* A new start may retry. */
            }
          }
          if (lifecycle != _lifecycle) return false;
          await _disposeWorkers();
          if (lifecycle != _lifecycle) return false;
          NativeWorker? decoder, filter;
          try {
            decoder = await NativeWorker.start(protocol);
            if (lifecycle == _lifecycle) {
              filter = await NativeWorker.start(0, filtering: true);
            }
            if (lifecycle != _lifecycle) {
              await Future.wait([
                decoder.close(),
                if (filter != null) filter.close(),
              ]);
              return false;
            }
            _decoder = decoder;
            _filter = filter;
            _closed = false;
            _reported.clear();
            _installedVersion = -1;
            _ensureFiltering();
            return true;
          } catch (error) {
            await Future.wait([
              if (decoder != null) decoder.close(),
              if (filter != null) filter.close(),
            ]);
            if (lifecycle != _lifecycle) return false;
            _closed = true;
            onClose?.call('弹幕原生模块加载失败：$error');
            rethrow;
          }
        })().whenComplete(() {
          if (identical(_initializing, initializing)) _initializing = null;
        });
    _initializing = initializing;
    return initializing;
  }

  void connectionReady() {
    if (_closed) return;
    _generation++;
    _jobs.clear();
    _events.clear();
    _cancelRefilterJobs();
    _rawBytes = 0;
    _jobs.add(_DecodeJob('reset', Uint8List(0), _generation));
    _ensureDecoding();
  }

  void decodeMessage(dynamic input) {
    if (_closed) return;
    if (input is! List<int>) {
      _diagnose('忽略非二进制弹幕数据');
      return;
    }
    if (input.length > 4 * 1024 * 1024 ||
        _rawBytes + input.length > 8 * 1024 * 1024 ||
        _jobs.length >= 512) {
      _failConnection('弹幕输入超过处理上限，正在重连');
      return;
    }
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    _jobs.add(_DecodeJob('decode', bytes, _generation));
    _rawBytes += bytes.length;
    _ensureDecoding();
  }

  void encodeAndSend(Map<String, dynamic> request) {
    if (_closed) return;
    final bytes = encodeWire({'v': 1, ...request});
    if (_jobs.length >= 512 || _rawBytes + bytes.length > 8 * 1024 * 1024) {
      _failConnection('弹幕发送队列超过上限');
      return;
    }
    _rawBytes += bytes.length;
    _jobs.add(_DecodeJob('encode', bytes, _generation));
    _ensureDecoding();
  }

  void _ensureDecoding() {
    if (_decodeDrain != null || _decoder == null || _closed) return;
    _decodeDrain = _drainDecode().whenComplete(() {
      _decodeDrain = null;
      if (_jobs.isNotEmpty && !_closed) _ensureDecoding();
    });
  }

  Future<void> _drainDecode() async {
    while (!_closed && _jobs.isNotEmpty) {
      final job = _jobs.removeFirst();
      _rawBytes -= job.bytes.length;
      if (job.generation != _generation) continue;
      try {
        final result = await _decoder!.call(job.operation, job.bytes);
        if (_closed || job.generation != _generation) continue;
        if (job.operation == 'encode') {
          if (result['wire'] is Uint8List) {
            sendWire(result['wire'] as Uint8List);
          }
          continue;
        }
        // Acknowledgements precede all filtering, but user event order is kept.
        for (final ack in result['acks'] as List? ?? const []) {
          sendWire(ack as Uint8List);
        }
        _diagnostics(result);
        if (job.operation == 'decode' && result['status'] == 0) {
          webScoketUtils?.markValidPayload();
        }
        if (result['fatal'] == true || (result['status'] as int? ?? 0) >= 2) {
          _failConnection('弹幕解析超过限制或连续数据损坏');
          continue;
        }
        for (final value in result['events'] as List? ?? const []) {
          _events.add(_Event(Map<String, dynamic>.from(value as Map)));
        }
        if (!_boundEvents()) continue;
        _ensureFiltering();
      } catch (error) {
        if (!_closed && job.generation == _generation) {
          _failConnection('弹幕处理失败：$error');
        }
      }
    }
  }

  bool _boundEvents() {
    var count = 0, bytes = 0, controls = 0, controlCount = 0;
    final retained = <_Event>[];
    for (final event in _events.toList().reversed) {
      if (event.chat) {
        if (++count > 200 || bytes + event.bytes > 1024 * 1024) {
          droppedChats++;
          continue;
        }
        bytes += event.bytes;
      } else {
        controls += event.bytes;
        controlCount++;
      }
      retained.add(event);
    }
    if (controls > 1024 * 1024 || controlCount > 1024) {
      _failConnection('弹幕控制事件队列超过上限');
      return false;
    }
    _events
      ..clear()
      ..addAll(retained.reversed);
    return true;
  }

  @override
  Future<void> updateFilterRules(List<DanmakuFilterRule> rules) {
    filterRules = List.unmodifiable(rules);
    _ruleVersion++;
    if (_closed || _filter == null) return Future.value();
    final waiter = Completer<void>();
    _ruleWaiters.add((_ruleVersion, waiter));
    _ensureFiltering();
    return waiter.future;
  }

  @override
  Future<List<LiveMessage>> refilterMessages(List<LiveMessage> messages) {
    if (_closed || messages.isEmpty) return Future.value(<LiveMessage>[]);
    if (messages.length > 200 ||
        _refilterJobs.length >= 4 ||
        messages.fold<int>(
              0,
              (size, message) => size + message.message.length * 2,
            ) >
            1024 * 1024) {
      return Future.error(StateError('Pending filter batch limit exceeded'));
    }
    final job = _RefilterJob(List.of(messages), _generation);
    _refilterJobs.add(job);
    _ensureFiltering();
    return job.completer.future;
  }

  void _ensureFiltering() {
    if (_filterDrain != null || _filter == null || _closed) return;
    _filterDrain = _drainFilter().whenComplete(() {
      _filterDrain = null;
      if (!_closed &&
          (_events.isNotEmpty ||
              _refilterJobs.isNotEmpty ||
              _installedVersion != _ruleVersion)) {
        _ensureFiltering();
      }
    });
  }

  Future<void> _drainFilter() async {
    while (!_closed) {
      try {
        if (_installedVersion != _ruleVersion) {
          final version = _ruleVersion;
          final result = await _filter!.call(
            'rules',
            encodeWire({
              'v': 1,
              'version': version,
              'rules': filterRules
                  // Send only enough data to prove a limit violation. The
                  // original stored rules remain intact in filterRules.
                  .take(2001)
                  .map(
                    (rule) => {
                      'regex': rule.regex,
                      'text': utf16Bytes(
                        rule.text.length > 4096
                            ? rule.text.substring(0, 4097)
                            : rule.text,
                      ),
                    },
                  )
                  .toList(),
            }),
          );
          if (_closed) return;
          _installedVersion = version;
          _diagnostics(result);
          if (version != _ruleVersion) continue;
          for (final entry in _ruleWaiters.where(
            (entry) => entry.$1 <= version,
          )) {
            entry.$2.complete();
          }
          _ruleWaiters.removeWhere((entry) => entry.$1 <= version);
        }
        if (_refilterJobs.isNotEmpty) {
          final job = _refilterJobs.first;
          final version = _ruleVersion;
          final chats = job.messages
              .where((m) => m.type == LiveMessageType.chat)
              .toList();
          final result = chats.isEmpty
              ? <String, dynamic>{'keep': <bool>[]}
              : await _filter!.call(
                  'filter',
                  encodeWire({
                    'v': 1,
                    'version': version,
                    'texts': chats
                        .map((message) => utf16Bytes(message.message))
                        .toList(),
                  }),
                );
          if (_closed) return;
          if (job.generation != _generation || !_refilterJobs.contains(job)) {
            continue;
          }
          if (version != _ruleVersion) continue;
          _refilterJobs.removeFirst();
          _diagnostics(result);
          final keep = List<bool>.from(result['keep'] as List);
          var index = 0;
          job.completer.complete(
            job.generation != _generation
                ? <LiveMessage>[]
                : job.messages
                      .where(
                        (message) =>
                            message.type != LiveMessageType.chat ||
                            keep[index++],
                      )
                      .toList(),
          );
          continue;
        }
        if (_events.isEmpty) return;
        final generation = _generation, version = _ruleVersion;
        final batch = _events.take(200).toList();
        final chats = batch.where((event) => event.chat).toList();
        final result = chats.isEmpty
            ? <String, dynamic>{'keep': <bool>[]}
            : await _filter!.call(
                'filter',
                encodeWire({
                  'v': 1,
                  'version': version,
                  'texts': chats.map((event) => event.data['text']).toList(),
                }),
              );
        if (_closed || generation != _generation) continue;
        // Leave pending entries in place until a result from current rules exists.
        if (version != _ruleVersion) continue;
        _diagnostics(result);
        final keep = List<bool>.from(result['keep'] as List);
        var chatIndex = 0;
        final publish = <LiveMessage>[];
        for (final event in batch) {
          final accepted = !event.chat || keep[chatIndex++];
          if (_events.remove(event) && accepted) {
            try {
              publish.add(_toMessage(event.data));
            } catch (error) {
              // One invalid SC timestamp or future payload extension must not
              // discard other messages already parsed from the same frame.
              _diagnose('忽略格式不正确的弹幕消息：$error');
            }
          }
        }
        if (publish.isNotEmpty) {
          final batchCallback = onMessages;
          if (batchCallback != null) {
            batchCallback(publish);
          } else {
            for (final message in publish) {
              onMessage?.call(message);
            }
          }
        }
      } catch (error) {
        if (_closed) return;
        _diagnose('弹幕过滤处理停止：$error');
        _events.clear();
        _installedVersion = _ruleVersion;
        for (final entry in _ruleWaiters) {
          entry.$2.completeError(error);
        }
        _ruleWaiters.clear();
        for (final job in _refilterJobs) {
          job.completer.completeError(error);
        }
        _refilterJobs.clear();
        return;
      }
    }
  }

  void _diagnostics(Map<String, dynamic> result) {
    for (final diagnostic in (result['diagnostics'] as List? ?? const []).take(
      8,
    )) {
      _diagnose('$diagnostic');
    }
  }

  void _diagnose(String text) {
    if (_reported.length < 100 && _reported.add(text)) onDiagnostic?.call(text);
  }

  void _failConnection(String diagnostic) {
    _diagnose(diagnostic);
    _generation++;
    _jobs.clear();
    _events.clear();
    _cancelRefilterJobs();
    _rawBytes = 0;
    reconnectNative();
  }

  Future<void> stopNative() {
    ++_lifecycle;
    _cancelPendingWork();
    if (_stopping != null) return _stopping!;
    final initialization = _initializing;
    late final Future<void> stopping;
    stopping =
        (() async {
          if (initialization != null) {
            try {
              await initialization;
            } catch (_) {
              /* Failed initialization owns its local cleanup. */
            }
          }
          await _disposeWorkers();
        })().whenComplete(() {
          if (identical(_stopping, stopping)) _stopping = null;
        });
    _stopping = stopping;
    return stopping;
  }

  void _cancelRefilterJobs() {
    for (final job in _refilterJobs) {
      if (!job.completer.isCompleted) job.completer.complete(<LiveMessage>[]);
    }
    _refilterJobs.clear();
  }

  void _cancelPendingWork() {
    _closed = true;
    _generation++;
    _jobs.clear();
    _events.clear();
    _rawBytes = 0;
    for (final entry in _ruleWaiters) {
      if (!entry.$2.isCompleted) entry.$2.complete();
    }
    _ruleWaiters.clear();
    _cancelRefilterJobs();
  }

  Future<void> _disposeWorkers() async {
    await Future.wait([
      if (_decodeDrain != null) _decodeDrain!,
      if (_filterDrain != null) _filterDrain!,
    ]);
    final decoder = _decoder, filter = _filter;
    _decoder = null;
    _filter = null;
    await Future.wait([
      if (decoder != null) decoder.close(),
      if (filter != null) filter.close(),
    ]);
  }
}

class _DecodeJob {
  _DecodeJob(this.operation, this.bytes, this.generation);
  final String operation;
  final Uint8List bytes;
  final int generation;
}

class _RefilterJob {
  _RefilterJob(this.messages, this.generation);
  final List<LiveMessage> messages;
  final int generation;
  final completer = Completer<List<LiveMessage>>();
}

class _Event {
  _Event(this.data);
  final Map<String, dynamic> data;
  bool get chat => data['type'] == 0;
  int get bytes {
    int size(Object? value) {
      if (value is Uint8List) return value.length;
      if (value is Map) {
        return value.values.fold(64, (total, value) => total + size(value));
      }
      return 8;
    }

    return size(data);
  }
}

LiveMessage _toMessage(Map<String, dynamic> event) {
  final type = event['type'] as int;
  if (type == 2) {
    return LiveMessage(
      type: LiveMessageType.online,
      userName: '',
      message: '',
      color: LiveMessageColor.white,
      data: event['online'],
    );
  }
  if (type == 3) {
    final sc = event['sc'] as Map;
    return LiveMessage(
      type: LiveMessageType.superChat,
      userName: 'SUPER_CHAT_MESSAGE',
      message: 'SUPER_CHAT_MESSAGE',
      color: LiveMessageColor.white,
      data: LiveSuperChatMessage(
        userName: utf16String(sc['user']),
        face: utf16String(sc['face']),
        message: utf16String(sc['text']),
        price: sc['price'] as int,
        startTime: DateTime.fromMillisecondsSinceEpoch(sc['start'] as int),
        endTime: DateTime.fromMillisecondsSinceEpoch(sc['end'] as int),
        backgroundColor: utf16String(sc['background']),
        backgroundBottomColor: utf16String(sc['bottom']),
      ),
    );
  }
  final color = event['color'] as int;
  return LiveMessage(
    type: LiveMessageType.chat,
    userName: utf16String(event['user']),
    message: utf16String(event['text']),
    color: LiveMessageColor(
      (color >> 16) & 255,
      (color >> 8) & 255,
      color & 255,
    ),
  );
}
