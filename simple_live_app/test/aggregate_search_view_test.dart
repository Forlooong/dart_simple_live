import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/aggregate_search.dart';
import 'package:simple_live_app/modules/search/aggregate_search_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Site extends LiveSite {
  final requests = <Completer<LiveSearchRoomResult>>[];

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    final request = Completer<LiveSearchRoomResult>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  testWidgets('mobile layout keeps filters usable with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final site = _Site();
    final search = AggregateSearch({'douyin': site})..setActive(true);
    addTearDown(search.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppStyle.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(body: AggregateSearchView(search)),
      ),
    );
    expect(find.text('搜索直播间或主播'), findsOneWidget);
    search.reset('主播', searchAnchors: false);
    await tester.pump();
    expect(find.text('正在搜索…'), findsOneWidget);

    site.requests.single.complete(
      LiveSearchRoomResult(
        hasMore: false,
        items: [
          LiveRoomItem(
            roomId: '123',
            title: '一条标题较长的直播搜索结果',
            cover: '',
            userName: '主播',
            liveStatus: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未开播'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选平台'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '抖音直播'));
    await tester.pumpAndSettle();
    expect(find.text('不限平台'), findsNothing);
    await tester.tap(find.text('仅直播中'));
    await tester.pumpAndSettle();
    expect(find.text('暂无已确认开播的结果'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('未开播'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop retains results while showing failure and retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final site = _Site();
    final search = AggregateSearch({'douyin': site})..setActive(true);
    addTearDown(search.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppStyle.lightTheme,
        home: Scaffold(body: AggregateSearchView(search)),
      ),
    );
    search.reset('主播', searchAnchors: false);
    site.requests.single.complete(
      LiveSearchRoomResult(
        hasMore: false,
        partialFailure: CoreError('需要登录', kind: CoreErrorKind.authRequired),
        items: [
          LiveRoomItem(
            roomId: '123',
            title: '保留已取得的房间',
            cover: '',
            userName: '主播',
            liveStatus: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('抖音直播结果可能不完整'), findsOneWidget);
    expect(find.text('保留已取得的房间'), findsOneWidget);
    expect(find.text('去抖音搜索'), findsOneWidget);
    expect(tester.getTopLeft(find.text('搜索结果')).dx, greaterThan(180));
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(site.requests, hasLength(2));
    expect(find.text('保留已取得的房间'), findsOneWidget);
    site.requests.last.complete(
      LiveSearchRoomResult(hasMore: false, items: []),
    );
    await tester.pumpAndSettle();
    expect(find.text('抖音直播结果可能不完整'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
