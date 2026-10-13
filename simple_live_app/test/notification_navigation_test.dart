import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/live_notifications/notification_navigation.dart';

class _RoomController extends GetxController {
  bool disposed = false;

  @override
  void onClose() {
    disposed = true;
    super.onClose();
  }
}

Widget _app(NotificationNavigationObserver observer) => GetMaterialApp(
      initialRoute: '/home',
      defaultTransition: Transition.fade,
      transitionDuration: const Duration(milliseconds: 300),
      navigatorObservers: [observer],
      getPages: [
        GetPage(
          name: '/home',
          page: () => const Scaffold(body: Text('home')),
        ),
        GetPage(
          name: RoutePath.kLiveRoomDetail,
          page: () {
            Get.find<_RoomController>();
            return const Scaffold(body: Text('live'));
          },
          binding: BindingsBuilder.put(() => _RoomController()),
        ),
        GetPage(
          name: '/settings',
          page: () => const Scaffold(body: Text('settings')),
        ),
      ],
    );

void main() {
  tearDown(() => Get.reset());

  testWidgets('reveals a live room with real GetX query parameters',
      (tester) async {
    final observer = NotificationNavigationObserver();
    await tester.pumpWidget(_app(observer));
    await tester.pumpAndSettle();
    Get.toNamed(RoutePath.kLiveRoomDetail, parameters: {'roomId': '123'});
    await tester.pumpAndSettle();
    final room = observer.liveRoomRoute!;
    final controller = Get.find<_RoomController>();
    expect(room.settings.name, '${RoutePath.kLiveRoomDetail}?roomId=123');

    Get.toNamed('/settings');
    await tester.pumpAndSettle();
    expect(observer.revealLiveRoom(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('live'), findsOneWidget);
    expect(find.text('settings'), findsNothing);
    expect(observer.liveRoomRoute, same(room));
    expect(Get.find<_RoomController>(), same(controller));
    expect(controller.disposed, isFalse);
  });

  testWidgets('waits for a popped live route to dispose its GetX controller',
      (tester) async {
    final observer = NotificationNavigationObserver();
    await tester.pumpWidget(_app(observer));
    await tester.pumpAndSettle();
    Get.toNamed(RoutePath.kLiveRoomDetail, parameters: {'roomId': '123'});
    await tester.pumpAndSettle();
    final controller = Get.find<_RoomController>();

    Get.back();
    await tester.pump();
    expect(observer.revealLiveRoom(), isFalse);
    expect(controller.disposed, isFalse);
    var ready = false;
    final disposal = observer.waitForRetiringLiveRooms().then((_) {
      ready = true;
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(ready, isFalse);
    await tester.pumpAndSettle();
    await disposal;

    expect(ready, isTrue);
    expect(controller.disposed, isTrue);
    expect(Get.isRegistered<_RoomController>(), isFalse);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('removing a closing live route waits for controller disposal',
      (tester) async {
    final observer = NotificationNavigationObserver();
    await tester.pumpWidget(_app(observer));
    await tester.pumpAndSettle();
    Get.toNamed(RoutePath.kLiveRoomDetail, parameters: {'roomId': '123'});
    await tester.pumpAndSettle();
    final controller = Get.find<_RoomController>();

    final removal = observer.removeLiveRoom();
    await tester.pumpAndSettle();
    await removal;

    expect(observer.liveRoomRoute, isNull);
    expect(controller.disposed, isTrue);
    expect(Get.isRegistered<_RoomController>(), isFalse);
    expect(find.text('home'), findsOneWidget);
  });
}
