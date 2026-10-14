import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Site extends LiveSite {
  int requests = 0;
  int detailRequests = 0;
  int qualityRequests = 0;
  Completer<LivePlayUrl>? nextResponse;
  bool offline = false;
  bool record = false;
  bool failRefresh = false;
  final requestedDetails = <LiveRoomDetail>[];
  final requestedQualities = <LivePlayQuality>[];

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    detailRequests++;
    if (failRefresh) throw StateError('provider unavailable');
    return _detail(
      data: 'fresh-signature-$detailRequests',
      status: !offline,
      isRecord: record,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    qualityRequests++;
    return [LivePlayQuality(quality: 'high', data: detail.data)];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    requests++;
    requestedDetails.add(detail);
    requestedQualities.add(quality);
    return nextResponse == null
        ? LivePlayUrl(
            urls: [
              'https://first.example/live?generation=$requests',
              'https://second.example/live?generation=$requests',
            ],
            headers: {'Referer': 'https://room.example/'},
          )
        : await nextResponse!.future;
  }
}

// The controller, command queue, Player wrapper and event subscriptions are
// real. Only the native boundary and HTTP provider are replaced.
class _NativePlayer extends PlatformPlayer {
  _NativePlayer() : super(configuration: const PlayerConfiguration());

  final opens = <Playable>[];
  final jumps = <int>[];
  Completer<void>? holdOpen;
  void Function()? onOpen;
  int disposals = 0;
  int stops = 0;

  void emitError(String message) => errorController.add(message);
  void emitCompleted() => completedController.add(true);
  void emitPlaying() => playingController.add(true);
  void emitPosition(Duration position) => positionController.add(position);

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens.add(playable);
    completedController.add(false);
    onOpen?.call();
    await holdOpen?.future;
  }

  @override
  Future<void> jump(int index) async {
    jumps.add(index);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

class _Room extends LiveRoomController {
  _Room(_Site provider, this.native)
    : super(
        pSite: Site(id: 'douyu', liveSite: provider, logo: '', name: 'test'),
        pRoomId: '71415',
      );

  final _NativePlayer native;
  int failureNotifications = 0;
  late final _testPlayer = Player(platformPlayer: native);

  @override
  Player get player => _testPlayer;

  @override
  void showPlaybackFailure() => failureNotifications++;

  @override
  Future<void> resetSystem() async {}

  @override
  Future<void> loadData() async {}

  // Exercise the real room refresh while keeping unrelated chat/history
  // services out of the native-playback fixture.
  Future<void> refreshFromProvider() => super.loadData();

  @override
  void addHistory() {}

  @override
  void getSuperChatMessage() {}

  @override
  void initDanmau() {}

  @override
  void startLiveDurationTimer() {}

  @override
  void addSysMsg(String message) {}

  @override
  Future<int> getQualityLevel() async => 2;
}

class _Database extends DBService {
  @override
  bool getFollowExist(String id) => false;
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'recovery did not reach its expected state',
  );
}

LiveRoomDetail _detail({
  dynamic data,
  bool status = true,
  bool isRecord = false,
}) => LiveRoomDetail(
  roomId: '71415',
  title: 'test',
  cover: '',
  userName: '',
  userAvatar: '',
  online: 1,
  status: status,
  isRecord: isRecord,
  url: '',
  data: data,
);

Future<_Room> _start(_Site provider, _NativePlayer native) async {
  final room = _Room(provider, native);
  room.detail.value = _detail(data: 'expired-signature');
  room.liveStatus.value = true;
  room.qualites.value = [LivePlayQuality(quality: 'high', data: 1)];
  room.currentQuality = 0;
  room.initStream();
  await room.getPlayUrl();
  addTearDown(() async {
    await room.closePlayer();
    room.scrollController.dispose();
  });
  return room;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.put<AppSettingsController>(_Settings());
    Get.put<DBService>(_Database());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
          (_) async => const StandardMessageCodec().encodeMessage([null]),
        );
  });
  tearDown(() => Get.reset());

  const loadingKey = ValueKey('playback-refresh-loading');

  Future<void> prepareDialogs(WidgetTester tester) async {
    // These tests exercise playback refresh, not dialog animation. The real
    // controller shows/dismisses loading inside runAsync; an indeterminate
    // spinner can otherwise keep pumpAndSettle alive across that zone boundary.
    final previousLoading = SmartDialog.config.loading;
    SmartDialog.config.loading = SmartConfigLoading(
      useAnimation: false,
      leastLoadingTime: Duration.zero,
    );
    addTearDown(() => SmartDialog.config.loading = previousLoading);
    await tester.pumpWidget(
      MaterialApp(
        builder: FlutterSmartDialog.init(
          loadingBuilder: (_) => const SizedBox(key: loadingKey),
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
  }

  Future<void> finishDialogs(WidgetTester tester) async {
    // Let the controller's unawaited dismiss finish in the same real async
    // environment as showLoading, while explicitly checking the visible UI.
    // Do not merely unmount a still-visible loading dialog to make tests pass.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    await tester.pump();
    while (find.byKey(loadingKey).evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() =>
          Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.byKey(loadingKey), findsNothing,
        reason: 'room refresh must dismiss its loading dialog');
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('manual refresh stops a confirmed offline stream', (
    tester,
  ) async {
    await prepareDialogs(tester);
    await tester.runAsync(() async {
      final provider = _Site();
      final native = _NativePlayer();
      final room = await _start(provider, native);
      provider.offline = true;

      await room.refreshFromProvider();

      expect(room.loadError.value, isFalse);
      expect(room.liveStatus.value, isFalse);
      expect(native.stops, 1);
      expect(native.opens, hasLength(1));
    });
    await finishDialogs(tester);
  });

  testWidgets('offline recordings remain playable on manual refresh', (
    tester,
  ) async {
    await prepareDialogs(tester);
    await tester.runAsync(() async {
      final provider = _Site();
      final native = _NativePlayer();
      final room = await _start(provider, native);
      provider.offline = true;
      provider.record = true;

      await room.refreshFromProvider();
      await _until(() => native.opens.length == 2);

      expect(room.loadError.value, isFalse);
      expect(room.liveStatus.value, isTrue);
      expect(native.stops, 0);
    });
    await finishDialogs(tester);
  });

  testWidgets('failed refresh does not stop an existing stream', (
    tester,
  ) async {
    await prepareDialogs(tester);
    await tester.runAsync(() async {
      final provider = _Site();
      final native = _NativePlayer();
      final room = await _start(provider, native);
      provider.failRefresh = true;

      await room.refreshFromProvider();

      expect(room.loadError.value, isTrue);
      expect(native.stops, 0);
      expect(native.opens, hasLength(1));
    });
    await finishDialogs(tester);
  });

  testWidgets('stale queued offline stop cannot stop a newer refresh', (
    tester,
  ) async {
    await prepareDialogs(tester);
    await tester.runAsync(() async {
      final provider = _Site();
      final native = _NativePlayer();
      final room = await _start(provider, native);
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final started = Completer<void>();
      final held = room.runPlayerCommand(() async {
        started.complete();
        await release.future;
      });
      await started.future;
      provider.offline = true;
      final oldRefresh = room.refreshFromProvider();
      await _until(() => !room.liveStatus.value);
      provider.offline = false;
      await room.refreshFromProvider();
      release.complete();
      await held;
      await oldRefresh;
      await _until(() => native.opens.length == 2);

      expect(room.loadError.value, isFalse);
      expect(room.liveStatus.value, isTrue);
      expect(native.stops, 0);
    });
    await finishDialogs(tester);
  });

  test('alternate CDN lines are not an auto-advancing native playlist',
      () async {
    final native = _NativePlayer();
    await _start(_Site(), native);

    expect(native.opens.single, isA<Media>(),
        reason: 'EOF must not independently start the next CDN in libmpv');
  });

  test('five-minute EOF refreshes signed URLs and reopens without jump/seek',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    await _start(provider, native);

    // Replay the terminal event following the connection reset in both logs.
    native.emitCompleted();
    await _settle();

    expect(provider.requests, 2, reason: 'the expired URL must be refreshed');
    expect(provider.detailRequests, 1);
    expect(provider.qualityRequests, 1);
    expect(provider.requestedDetails.last.data, 'fresh-signature-1');
    expect(provider.requestedQualities.last.data, 'fresh-signature-1');
    expect(native.jumps, isEmpty,
        reason: 'jump calls play/seek on ended media');
    expect(native.opens, hasLength(2));
    final reopened = native.opens.last as Media;
    expect(reopened.uri, contains('generation=2'));
    expect(reopened.httpHeaders, {'Referer': 'https://room.example/'});
  });

  test('error plus EOF from one failed stream reserves only one retry',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    provider.nextResponse = Completer<LivePlayUrl>();

    native.emitError('tcp: ffurl_read returned 0xdfb9b0bb');
    native.emitCompleted();
    await _settle();
    final attempts = room.mediaErrorRetryCount;
    await room.closePlayer();
    provider.nextResponse!.complete(
      LivePlayUrl(urls: ['https://fresh.example/live']),
    );
    await _settle();

    expect(attempts, 1, reason: 'error and EOF describe the same failure');
    expect(native.opens, hasLength(1), reason: 'close invalidates URL refresh');
    expect(native.jumps, isEmpty);
  });

  test('manual line selection rejects an older refresh response', () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    provider.nextResponse = Completer<LivePlayUrl>();
    room.mediaEnd();
    await _until(() => provider.requests == 2);

    room.changePlayLine(1);
    await _until(() => native.opens.length == 2);
    provider.nextResponse!.complete(
      LivePlayUrl(urls: ['https://stale.example/live']),
    );
    await _settle();

    expect(native.opens, hasLength(2));
    expect((native.opens.last as Media).uri, contains('second.example'));
    expect(room.currentLineIndex, 1);
    expect(room.mediaErrorRetryCount, 0);
  });

  test('room switch invalidates a refresh before it can open old media',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    provider.nextResponse = Completer<LivePlayUrl>();
    room.mediaEnd();
    await _until(() => provider.requests == 2);

    room.resetRoom(room.site, 'another-room');
    provider.nextResponse!.complete(
      LivePlayUrl(urls: ['https://stale.example/live']),
    );
    await _settle();

    expect(room.roomId, 'another-room');
    expect(native.opens, hasLength(1));
    expect(native.stops, 1);
    expect(room.playUrls, isEmpty);
  });

  test('failure during replacement open is retried once after that open',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    final release = native.holdOpen = Completer<void>();
    room.mediaEnd();
    await _until(() => native.opens.length == 2);

    native.emitError('replacement failed');
    native.emitError('replacement failed');
    native.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    native.holdOpen = null;
    release.complete();
    await _until(() => native.opens.length == 3);
    await _settle();

    expect(provider.requests, 3);
    expect(native.opens, hasLength(3));
    expect(room.mediaErrorRetryCount, 2);
    expect(native.jumps, isEmpty);
  });

  test('failed replacement streams exhaust a bounded budget across lines',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    native.onOpen = () => native.emitError('bad live stream');
    room.mediaEnd();
    await _until(() => room.errorMsg.value.contains('请刷新'));

    expect(provider.requests, 5); // Initial open + two retries on each line.
    expect(native.opens, hasLength(5));
    expect(room.currentLineIndex, 1);
    expect(room.liveStatus.value, isTrue,
        reason:
            'a CDN failure alone does not prove the broadcaster is offline');
    native.emitError('another old error');
    await _settle();
    expect(native.opens, hasLength(5));
    expect(room.failureNotifications, 1);

    native.onOpen = null;
    room.changePlayLine(0);
    await _until(() => native.opens.length == 6);
    expect(room.errorMsg.value, isEmpty);
    expect(room.mediaErrorRetryCount, 0);
  });

  test('provider refresh failures also stop instead of retrying indefinitely',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    provider.failRefresh = true;
    room.mediaEnd();
    await _until(() => room.errorMsg.value.contains('请刷新'));

    expect(provider.detailRequests, 4);
    expect(native.opens, hasLength(1));
    expect(native.jumps, isEmpty);
  });

  test('only sustained advancing position replenishes the retry budget',
      () async {
    final native = _NativePlayer();
    final room = await _start(_Site(), native);
    room.mediaEnd();
    await _until(() => native.opens.length == 2);

    native.emitPlaying();
    native.emitPosition(const Duration(seconds: 1200));
    await Future<void>.delayed(Duration.zero);
    expect(room.mediaErrorRetryCount, 1);
    native.emitPosition(const Duration(seconds: 1205));
    await Future<void>.delayed(Duration.zero);
    expect(room.mediaErrorRetryCount, 1);
    native.emitPosition(const Duration(seconds: 1211));
    await Future<void>.delayed(Duration.zero);
    expect(room.mediaErrorRetryCount, 0);

    room.mediaEnd();
    await _until(() => native.opens.length == 3);
    expect(room.mediaErrorRetryCount, 1);
    expect(room.currentLineIndex, 0);
  });

  test('confirmed offline room stops playback without reopening the URL',
      () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    provider.offline = true;
    room.mediaEnd();
    await _until(() => native.stops == 1);

    expect(room.liveStatus.value, isFalse);
    expect(provider.requests, 1);
    expect(native.opens, hasLength(1));
  });

  test('close waits for replacement open and rejects further commands',
      () async {
    final native = _NativePlayer();
    final room = await _start(_Site(), native);
    final release = native.holdOpen = Completer<void>();
    room.changePlayLine(1);
    await _until(() => native.opens.length == 2);
    final closed = room.closePlayer();
    room.changePlayLine(0);
    expect(native.disposals, 0);

    release.complete();
    await closed;
    expect(native.disposals, 1);
    expect(native.opens, hasLength(2));
  });

  test('close during retry delay prevents even a provider request', () async {
    final provider = _Site();
    final native = _NativePlayer();
    final room = await _start(provider, native);
    room.mediaEnd();
    await room.closePlayer();
    await _settle();

    expect(provider.detailRequests, 0);
    expect(provider.requests, 1);
    expect(native.opens, hasLength(1));
  });
}
