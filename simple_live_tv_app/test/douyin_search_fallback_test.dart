import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/search/anchor/search_anchor_controller.dart';
import 'package:simple_live_tv_app/modules/search/room/search_room_controller.dart';

void main() {
  test('TV offers a web fallback after empty in-app searches', () async {
    final site = _SearchSpy();
    _useDouyin(site);
    final rooms = SearchRoomController('主播');
    final anchors = SearchAnchorController('主播');

    rooms.setSite(Constant.kDouyin);
    anchors.setSite(Constant.kDouyin);
    await Future<void>.delayed(Duration.zero);

    expect(rooms.showDouyinWebSearch, isTrue);
    expect(anchors.showDouyinWebSearch, isTrue);
    expect(rooms.list, isEmpty);
    expect(anchors.list, isEmpty);
    expect(site.roomQueries, ['主播']);
    expect(site.anchorQueries, ['主播']);
  });

  test('TV room search routes Douyin direct links to Douyin', () async {
    final site = _SearchSpy();
    _useDouyin(site);
    const link = 'https://live.douyin.com/1234';
    final rooms = SearchRoomController(link);

    expect(rooms.siteId.value, Constant.kDouyin);
    await rooms.refreshData();
    expect(rooms.showDouyinWebSearch, isFalse);
    expect(site.roomQueries, [link]);
    expect(rooms.list.single.roomId, '1234');
  });
}

void _useDouyin(LiveSite site) {
  final original = Sites.allSites[Constant.kDouyin]!;
  Sites.allSites[Constant.kDouyin] = Site(
    id: original.id,
    liveSite: site,
    logo: original.logo,
    name: original.name,
    index: original.index,
  );
  addTearDown(() => Sites.allSites[Constant.kDouyin] = original);
}

class _SearchSpy extends LiveSite {
  final roomQueries = <String>[];
  final anchorQueries = <String>[];

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    roomQueries.add(keyword);
    return LiveSearchRoomResult(
      hasMore: false,
      items: [
        if (DouyinSite.directSearchRoomId(keyword) != null)
          LiveRoomItem(roomId: '1234', title: '直链', cover: '', userName: '主播'),
      ],
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    anchorQueries.add(keyword);
    return LiveSearchAnchorResult(hasMore: false, items: []);
  }
}
