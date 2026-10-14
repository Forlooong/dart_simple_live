import 'dart:async';

import 'package:simple_live_core/src/model/live_message.dart';

class LiveDanmaku {
  Function(LiveMessage msg)? onMessage;
  void Function(List<LiveMessage> messages)? onMessages;
  void Function(String diagnostic)? onDiagnostic;
  Function(String msg)? onClose;
  Function()? onReady;
  List<DanmakuFilterRule> filterRules = const [];

  Future<void> updateFilterRules(List<DanmakuFilterRule> rules) async {
    filterRules = List.unmodifiable(rules);
  }

  Future<List<LiveMessage>> refilterMessages(
    List<LiveMessage> messages,
  ) async => messages;

  /// 心跳时间
  int heartbeatTime = 0;

  /// 发生心跳
  void heartbeat() {}

  /// 开始接收信息
  Future start(dynamic args) {
    return Future.value();
  }

  /// 停止接收信息
  Future stop() {
    return Future.value();
  }
}

class DanmakuFilterRule {
  const DanmakuFilterRule({required this.text, this.regex = false});
  final String text;
  final bool regex;
}
