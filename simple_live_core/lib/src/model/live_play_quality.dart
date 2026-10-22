import 'dart:convert';

class LivePlayQuality {
  /// 清晰度
  final String quality;

  /// Stable provider quality/rate identity; display labels can change.
  final String? id;

  /// 清晰度信息
  final dynamic data;

  final int sort;

  LivePlayQuality({
    required this.quality,
    this.id,
    required this.data,
    this.sort = 0,
  });

  @override
  String toString() {
    return json.encode({"quality": quality, "data": data.toString()});
  }
}
