/// Validates the status fields used for live-room polling.
///
/// A malformed response must remain an error, rather than looking like an
/// offline room and creating a false offline-to-live notification transition.
class LiveStatusParser {
  static bool bilibili(Object? response) {
    final data = _field(response, 'data');
    return _statusCode(_field(data, 'live_status'), 'bilibili.live_status') ==
        1;
  }

  static bool douyu(Object? room) {
    final status = _statusCode(
      _field(room, 'show_status'),
      'douyu.show_status',
    );
    if (status != 1) {
      return false;
    }
    // Offline responses need not contain playback metadata. For an online
    // room, however, a missing flag cannot establish that this is not a replay.
    final videoLoop = _statusCode(_field(room, 'videoLoop'), 'douyu.videoLoop');
    if (videoLoop != 0 && videoLoop != 1) {
      throw const FormatException('Invalid live status: douyu.videoLoop');
    }
    return videoLoop == 0;
  }

  static bool huya(Object? response) {
    final room = _field(response, 'roomInfo');
    return _statusCode(_field(room, 'eLiveStatus'), 'huya.eLiveStatus') == 2;
  }

  // The caller also needs code 4 to follow an expired session room ID to the
  // anchor's stable web room ID. Validate before that fallback is considered.
  static int douyinStatusCode(Object? room) {
    return _statusCode(_field(room, 'status'), 'douyin.status');
  }

  static Object? _field(Object? object, String name) {
    return object is Map ? object[name] : null;
  }

  static int _statusCode(Object? value, String field) {
    if (value is! int || value < 0) {
      throw FormatException('Invalid live status: $field');
    }
    // Preserve each site's existing non-live integer states. The undocumented
    // APIs can add states, so do not impose a guessed platform-wide enum.
    return value;
  }
}
