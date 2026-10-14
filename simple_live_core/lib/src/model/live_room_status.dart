/// Follow-list status without playback URLs, signing or danmaku credentials.
class LiveRoomStatus {
  const LiveRoomStatus({required this.live, this.showTime});

  final bool live;
  final String? showTime;
}
