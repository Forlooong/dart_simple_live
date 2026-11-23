import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/search/room/search_room_controller.dart';

class _Site extends LiveSite {
  late LiveSearchRoomResult result;

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async => result;
}

void main() {
  final unavailable = CoreError('搜索需要登录', kind: CoreErrorKind.authRequired);
  final room = LiveRoomItem(
    roomId: '123',
    title: '直播间',
    cover: '',
    userName: '主播',
  );
  late _Site site;
  late SearchRoomController controller;

  setUp(() {
    site = _Site();
    controller = SearchRoomController('主播')
      ..site = Site(
        id: 'douyin',
        name: '抖音',
        logo: '',
        liveSite: site,
        index: 0,
      );
  });

  tearDown(() {
    controller.onClose();
    controller.scrollController.dispose();
  });

  test('empty partial response shows an error and can be retried', () async {
    site.result = LiveSearchRoomResult(
      hasMore: false,
      items: [],
      partialFailure: unavailable,
    );
    await controller.refreshData();
    expect(controller.pageError.value, isTrue);
    expect(controller.pageEmpty.value, isFalse);
    expect(controller.errorMsg.value, contains('搜索需要登录'));

    site.result = LiveSearchRoomResult(hasMore: false, items: []);
    await controller.refreshData();
    expect(controller.pageError.value, isFalse);
    expect(controller.pageEmpty.value, isTrue);
  });

  test(
    'keeps received rooms and the warning until a new search succeeds',
    () async {
      site.result = LiveSearchRoomResult(
        hasMore: true,
        items: [room],
        partialFailure: unavailable,
      );
      await controller.refreshData();
      expect(controller.list.single.roomId, '123');
      expect(controller.partialFailure.value, same(unavailable));

      site.result = LiveSearchRoomResult(hasMore: false, items: []);
      await controller.loadData();
      expect(controller.partialFailure.value, same(unavailable));

      site.result = LiveSearchRoomResult(hasMore: false, items: [room]);
      await controller.refreshData();
      expect(controller.list.single.roomId, '123');
      expect(controller.partialFailure.value, isNull);
    },
  );
}
