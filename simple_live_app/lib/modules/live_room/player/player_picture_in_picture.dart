import 'package:floating/floating.dart';
import 'package:flutter/widgets.dart';

/// Both layouts use the same keyed video player. Mount only one layout at a
/// time so Flutter can move the player between the room and PiP.
class PlayerPictureInPicture extends StatelessWidget {
  const PlayerPictureInPicture({
    super.key,
    required this.status,
    required this.room,
    required this.playerBuilder,
  });

  final Stream<PiPStatus> status;
  final Widget room;
  final WidgetBuilder playerBuilder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PiPStatus>(
      stream: status,
      builder: (context, snapshot) {
        return snapshot.data == PiPStatus.enabled
            ? playerBuilder(context)
            : room;
      },
    );
  }
}
