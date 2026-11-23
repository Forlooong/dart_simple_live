import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';

void main() {
  testWidgets('follow row refreshes duration while the room remains live', (
    tester,
  ) async {
    final user = FollowUser(
      id: 'douyin_123',
      roomId: '123',
      siteId: 'douyin',
      userName: '主播',
      face: '',
      addTime: DateTime.now(),
    )..liveStatus.value = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FollowUserItem(item: user)),
      ),
    );
    expect(find.textContaining('开播了'), findsNothing);

    user.liveStartTime =
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600}';
    await tester.pump();
    expect(find.textContaining('开播了'), findsOneWidget);

    user.liveStatus.value = 1;
    await tester.pump();
    expect(find.textContaining('开播了'), findsNothing);
  });
}
