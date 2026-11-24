import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' as app;
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// Build this entry point in Release to exercise the actual live page while
/// tool/test_windows_resize.ps1 resizes the native window. Keep state isolated.
Future<void> main() async {
  final ready = File(Platform.environment['SIMPLE_LIVE_RESIZE_READY']!);
  final report = File('${ready.path}.json');
  final state = await ready.parent.createTemp('live-resize-data-');
  final metrics = <String, Object>{'dartErrors': 0, 'frames': 0};
  void publish() => report.writeAsStringSync(jsonEncode(metrics));
  void recordError(Object error) {
    metrics['dartErrors'] = (metrics['dartErrors'] as int) + 1;
    metrics['lastErrorType'] = error.runtimeType.toString();
    publish();
  }

  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) => recordError(details.exception);
  PlatformDispatcher.instance.onError = (error, _) {
    recordError(error);
    return true;
  };
  binding.addTimingsCallback((timings) {
    metrics['frames'] = (metrics['frames'] as int) + timings.length;
  });

  try {
    await app.initWindow();
    MediaKit.ensureInitialized();
    Hive.init(state.path);
    await app.initServices();
    AppSettingsController.instance.danmuEnable.value = true;
    runApp(const app.MyApp());
    await binding.endOfFrame;

    final site = Sites.allSites[Constant.kDouyin]!;
    final roomId = Platform.environment['SIMPLE_LIVE_RESIZE_ROOM']!;
    unawaited(
      Get.toNamed(
        '${RoutePath.kLiveRoomDetail}?roomId=$roomId',
        arguments: site,
      ),
    );
    await _until(() => Get.isRegistered<LiveRoomController>());
    final room = Get.find<LiveRoomController>();
    await _until(
      () =>
          room.player.state.playing &&
          room.player.state.position > Duration.zero &&
          room.globalDanmuKey.currentContext != null,
    );
    metrics['playing'] = true;
    publish();
    await ready.writeAsString('ready');

    final startingPosition = room.player.state.position;
    await _until(() {
      final chat = room.messages
          .where((message) => message.type == LiveMessageType.chat)
          .map((message) => message.message)
          .toSet();
      return _paintedChat(room).any(chat.contains);
    });
    metrics['sameChatPainted'] = true;

    room.showDanmakuState.value = false;
    final previous = room.messages.last;
    await _until(
      () =>
          room.messages.last != previous &&
          room.messages.last.type == LiveMessageType.chat &&
          _paintedChat(room).isEmpty,
    );
    metrics['chatWhileHidden'] = true;

    room.showDanmakuState.value = true;
    await _until(() => _paintedChat(room).isNotEmpty);
    metrics['chatAfterEnabling'] = true;
    metrics['playbackAdvanced'] = room.player.state.position > startingPosition;
    publish();
  } catch (error) {
    recordError(error);
  }
}

Iterable<String> _paintedChat(LiveRoomController room) sync* {
  final root = room.globalDanmuKey.currentContext as Element?;
  if (root == null) return;
  final elements = [root];
  while (elements.isNotEmpty) {
    final element = elements.removeLast();
    final widget = element.widget;
    if (widget is CustomPaint && widget.painter is ScrollDanmakuPainter) {
      final painter = widget.painter! as ScrollDanmakuPainter;
      for (final item in painter.scrollDanmakuItems) {
        if (item.lastDrawTick != null) yield item.content.text;
      }
    }
    element.visitChildren(elements.add);
  }
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('live resize');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
