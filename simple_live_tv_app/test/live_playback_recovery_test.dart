import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';

class _Settings extends AppSettingsController {
  @override
  // Keep plugin-backed settings initialization out of the fixture.
  // ignore: must_call_super
  void onInit() {}
}

LiveRoomDetail _detail({bool live = true, String room = 'a'}) => LiveRoomDetail(
  roomId: room,
  title: '',
  cover: '',
  userName: '',
  userAvatar: '',
  online: 0,
  status: live,
  url: '',
  data: room,
);

class _Site extends LiveSite {
  final requests = <String>[];
  int details = 0;
  bool offline = false;
  Completer<LivePlayUrl>? urls;
  Completer<List<LivePlayQuality>>? qualities;
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    details++;
    return _detail(live: !offline, room: '$roomId-$details');
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async => qualities == null
      ? [LivePlayQuality(quality: 'high', data: detail.data)]
      : await qualities!.future;
  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    requests.add(quality.data.toString());
    return urls == null
        ? LivePlayUrl(urls: ['https://example.test/${requests.length}'])
        : await urls!.future;
  }
}

class _Native extends PlatformPlayer {
  _Native() : super(configuration: const PlayerConfiguration());
  final opens = <Playable>[];
  Completer<void>? holdOpen;
  void Function()? onOpen;
  int disposals = 0;
  int stops = 0;
  void fail() {
    errorController.add('synthetic error');
    completedController.add(true);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens.add(playable);
    onOpen?.call();
    await holdOpen?.future;
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
  _Room(_Site site, this.native)
    : super(
        pSite: Site(id: 'test', name: '', logo: '', index: 0, liveSite: site),
        pRoomId: 'a',
      );
  final _Native native;
  late final _player = Player(platformPlayer: native);
  int failures = 0;
  @override
  Player get player => _player;
  @override
  void showPlaybackFailure() {
    failures++;
  }

  @override
  Future<void> resetSystem() async {}
  @override
  Future<void> loadData() async {}
  @override
  Future<int> getQualityLevel() async => 2;
}

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Site site;
  late _Native native;
  late _Room room;
  setUp(() {
    Get.put<AppSettingsController>(_Settings());
    site = _Site();
    native = _Native();
    room = _Room(site, native);
    room.detail.value = _detail();
    room.liveStatus.value = true;
    room.qualites.value = [LivePlayQuality(quality: 'high', data: 'old')];
    room.currentQuality = 0;
    room.initStream();
  });
  tearDown(() async {
    native.holdOpen?.complete();
    await room.closePlayer();
    room.focusNode.dispose();
    Get.reset();
  });

  test('old URL response cannot replace the newer quality selection', () async {
    final old = site.urls = Completer<LivePlayUrl>();
    final first = room.getPlayUrl();
    site.urls = null;
    room.qualites.value = [LivePlayQuality(quality: 'new', data: 'new')];
    await room.getPlayUrl();
    old.complete(LivePlayUrl(urls: ['https://obsolete.test/']));
    await first;
    expect(room.currentQualityInfo.value, 'new');
    expect(native.opens, hasLength(1));
    expect(room.playUrls.single, 'https://example.test/2');
  });

  test('changing rooms during quality lookup rejects the old result', () async {
    final old = site.qualities = Completer<List<LivePlayQuality>>();
    final first = room.getPlayQualites();
    await room.resetRoom(room.site, 'b');
    old.complete([LivePlayQuality(quality: 'stale', data: 'stale')]);
    await first;
    expect(room.qualites, isEmpty);
    expect(native.opens, isEmpty);
  });

  test('closing during URL lookup cannot open after dispose', () async {
    final response = site.urls = Completer<LivePlayUrl>();
    final pending = room.getPlayUrl();
    await room.closePlayer();
    response.complete(LivePlayUrl(urls: ['https://obsolete.test/']));
    await pending;
    expect(native.opens, isEmpty);
    expect(native.disposals, 1);
  });

  test(
    'close drains active open and discards queued commands exactly once',
    () async {
      final gate = native.holdOpen = Completer<void>();
      final opening = room.getPlayUrl();
      await _until(() => native.opens.isNotEmpty);
      room.changePlayLine(0);
      final closed = room.closePlayer();
      expect(identical(closed, room.closePlayer()), isTrue);
      expect(native.disposals, 0);
      gate.complete();
      native.holdOpen = null;
      await opening;
      await closed;
      expect(native.opens, hasLength(1));
      expect(native.disposals, 1);
    },
  );

  test(
    'error plus EOF owns one recovery and obtains a fresh full source',
    () async {
      await room.getPlayUrl();
      native.fail();
      await _until(() => native.opens.length == 2);
      expect(site.details, 1);
      expect(site.requests, ['old', 'a-1']);
      expect(room.mediaErrorRetryCount, 1);
      expect(room.liveStatus.value, isTrue);
    },
  );

  test(
    'recovery preserves provider quality identity when labels change',
    () async {
      room.qualites.value = [
        LivePlayQuality(quality: 'high', data: 'old', id: 'selected'),
      ];
      await room.getPlayUrl();
      site.qualities = Completer<List<LivePlayQuality>>()
        ..complete([
          LivePlayQuality(quality: 'high', data: 'wrong', id: 'other'),
          LivePlayQuality(quality: 'renamed', data: 'right', id: 'selected'),
        ]);
      native.fail();
      await _until(() => native.opens.length == 2);
      expect(room.currentQualityInfo.value, 'renamed');
      expect(site.requests.last, 'right');
    },
  );

  test('closing during recovery delay cancels further source work', () async {
    await room.getPlayUrl();
    native.fail();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await room.closePlayer();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(site.details, 0);
    expect(native.opens, hasLength(1));
  });

  test(
    'repeated terminal events stop at budget without declaring offline',
    () async {
      native.onOpen = native.fail;
      await room.getPlayUrl();
      await _until(() => room.failures > 0);
      expect(native.opens, hasLength(3));
      expect(room.failures, 1);
      expect(room.liveStatus.value, isTrue);
    },
  );

  test('only a fresh offline room response stops recovery', () async {
    await room.getPlayUrl();
    site.offline = true;
    native.fail();
    await _until(() => native.stops == 1);
    expect(room.liveStatus.value, isFalse);
    expect(native.opens, hasLength(1));
  });
}
