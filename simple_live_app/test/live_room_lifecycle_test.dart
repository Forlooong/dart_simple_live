import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

// Keep HTTP and native media outside these tests while exercising the real
// request-generation and selection guards in LiveRoomController.
class _FakeSite extends LiveSite {
  final urls = <Completer<LivePlayUrl>>[];
  final qualities = <Completer<List<LivePlayQuality>>>[];

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    final request = Completer<LivePlayUrl>();
    urls.add(request);
    return request.future;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    final request = Completer<List<LivePlayQuality>>();
    qualities.add(request);
    return request.future;
  }
}

class _Controller extends LiveRoomController {
  _Controller(Site site) : super(pSite: site, pRoomId: 'first');

  bool closing = false;
  final opened = <List<String>>[];
  Completer<int>? qualityPreference;

  @override
  bool get playerClosing => closing;

  @override
  Future<void> initPlaylist() async {
    opened.add(playUrls.toList());
  }

  @override
  Future<int> getQualityLevel() =>
      qualityPreference?.future ?? Future<int>.value(2);

  // resetRoom must still execute its real invalidation, but must not start
  // plugin-backed loading or native stop commands in this focused fixture.
  @override
  Future<void> loadData() async {}

  @override
  Future<void> runPlayerCommand(Future<void> Function() command) async {}
}

LiveRoomDetail _detail(String room) => LiveRoomDetail(
      roomId: room,
      title: room,
      cover: '',
      userName: '',
      userAvatar: '',
      online: 0,
      status: true,
      url: '',
    );

Site _site(String id, _FakeSite provider) =>
    Site(id: id, liveSite: provider, logo: '', name: id);

void _selectQuality(_Controller controller) {
  controller.detail.value = _detail(controller.roomId);
  controller.qualites.value = [
    LivePlayQuality(quality: 'high', data: 1),
    LivePlayQuality(quality: 'low', data: 2),
  ];
  controller.currentQuality = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a slower old quality response cannot replace the latest playlist',
    () async {
      final provider = _FakeSite();
      final controller = _Controller(_site('first', provider));
      _selectQuality(controller);
      final first = controller.getPlayUrl();
      controller.currentQuality = 1;
      final second = controller.getPlayUrl();

      provider.urls[1].complete(
        LivePlayUrl(urls: ['https://new.example/live']),
      );
      await second;
      provider.urls[0].complete(
        LivePlayUrl(urls: ['https://old.example/live']),
      );
      await first;

      expect(controller.playUrls, ['https://new.example/live']);
      expect(controller.opened, [
        ['https://new.example/live'],
      ]);
      expect(controller.currentQualityInfo.value, 'low');
    },
  );

  test('URL response arriving after close never opens a playlist', () async {
    final provider = _FakeSite();
    final controller = _Controller(_site('first', provider));
    _selectQuality(controller);
    final request = controller.getPlayUrl();
    controller.closing = true;
    provider.urls.single.complete(
      LivePlayUrl(urls: ['https://old.example/live']),
    );
    await request;

    expect(controller.opened, isEmpty);
    expect(controller.playUrls, isEmpty);
  });

  test(
    'room switch clears old quality and ignores old in-flight URLs',
    () async {
      final oldProvider = _FakeSite();
      final newProvider = _FakeSite();
      final controller = _Controller(_site('first', oldProvider));
      _selectQuality(controller);
      final oldRequest = controller.getPlayUrl();

      controller.resetRoom(_site('second', newProvider), 'second');
      expect(controller.qualites, isEmpty);
      expect(controller.currentQuality, -1);
      await controller.getPlayUrl();
      expect(newProvider.urls, isEmpty);

      oldProvider.urls.single.complete(
        LivePlayUrl(urls: ['https://old.example/live']),
      );
      await oldRequest;
      expect(controller.opened, isEmpty);
      expect(controller.playUrls, isEmpty);
    },
  );

  test(
    'close during quality preference lookup does not request playback',
    () async {
      final provider = _FakeSite();
      final controller = _Controller(_site('first', provider));
      controller.detail.value = _detail('first');
      controller.qualityPreference = Completer<int>();
      final request = controller.getPlayQualites();
      provider.qualities.single.complete([
        LivePlayQuality(quality: 'high', data: 1),
      ]);
      // Let getPlayQualites reach its second await before closing.
      await Future<void>.delayed(Duration.zero);
      controller.closing = true;
      controller.qualityPreference!.complete(2);
      await request;

      expect(provider.urls, isEmpty);
      expect(controller.qualites, isEmpty);
      expect(controller.opened, isEmpty);
    },
  );

  test('invalid quality selections cannot issue provider requests', () async {
    final provider = _FakeSite();
    final controller = _Controller(_site('first', provider));
    _selectQuality(controller);
    controller.currentQuality = -1;
    await controller.getPlayUrl();
    controller.currentQuality = controller.qualites.length;
    await controller.getPlayUrl();
    expect(provider.urls, isEmpty);
  });
}
