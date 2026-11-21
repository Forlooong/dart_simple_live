import 'package:floating/floating.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/player_picture_in_picture.dart';

void main() {
  testWidgets('picture in picture keeps a single keyed player', (tester) async {
    final key = GlobalKey();
    var inPictureInPicture = false;
    final floating = Floating();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('floating');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pipAvailable') return true;
      return inPictureInPicture;
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerPictureInPicture(
          status: floating.pipStatusStream,
          room: Center(child: SizedBox(key: key)),
          playerBuilder: (_) => SizedBox(key: key),
        ),
      ),
    );
    try {
      await tester.pump(const Duration(milliseconds: 20));
      inPictureInPicture = true;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(key), findsOneWidget);
      expect(find.byType(Center), findsNothing);

      inPictureInPicture = false;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(key), findsOneWidget);
      expect(find.byType(Center), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      floating.reset();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
