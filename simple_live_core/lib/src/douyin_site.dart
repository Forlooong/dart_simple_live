import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/live_status_parser.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

typedef DouyinPartitionLoader =
    Future<LiveCategoryResult> Function(
      String partitionId,
      String partitionType, {
      required int count,
      int offset,
    });
typedef DouyinCategoryLoader = Future<List<LiveCategory>> Function();

class _PartitionBatch {
  final List<LiveRoomItem>? items;
  final CoreError? error;
  const _PartitionBatch({this.items, this.error});
}

class DouyinSite extends LiveSite {
  DouyinSite({
    DouyinPartitionLoader? partitionLoader,
    DouyinCategoryLoader? categoryLoader,
  }) : _partitionLoader = partitionLoader,
       _categoryLoader = categoryLoader;

  final DouyinPartitionLoader? _partitionLoader;
  final DouyinCategoryLoader? _categoryLoader;

  static const int kRecommendPageSize = 15;
  static const int kHomeCategoryLimit = 8;
  static const int kHomeCategoryRoomCount = 5;
  static const int kHomeRequestConcurrency = 4;

  List<LiveRoomItem>? _recommendSnapshot;
  Future<List<LiveRoomItem>>? _recommendBuild;

  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400";

  static const String kDefaultReferer = "https://live.douyin.com";

  static const String kDefaultAuthority = "live.douyin.com";

  /// Legacy guest-session compatibility value; user credentials always win.
  /// Its continued validity is platform-dependent and must not be assumed.
  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 用户设置的 cookie
  String _cookie = "";
  String get cookie => _cookie;
  set cookie(String value) {
    if (_cookie == value) return;
    _cookie = value;
    invalidateStatusCache();
  }

  void _logDebug(String msg) {
    // 同时使用 print 和 CoreLog 确保日志输出
    print("[Douyin] $msg");
    CoreLog.d("[Douyin] $msg");
  }

  final Map<String, dynamic> headers = const {
    "Authority": kDefaultAuthority,
    "Referer": kDefaultReferer,
    "User-Agent": kDefaultUserAgent,
  };

  Future<Map<String, dynamic>> getRequestHeaders() async => {
    ...headers,
    'cookie': cookie.isNotEmpty ? cookie : kDefaultCookie,
  };

  @override
  Future<List<LiveCategory>> getCategores() async {
    final result = await HttpClient.instance.getText(
      "https://live.douyin.com/",
      queryParameters: {},
      header: await getRequestHeaders(),
    );
    return parseCategories(result);
  }

  static List<LiveCategory> parseCategories(String html) {
    final categories = <LiveCategory>[];
    final data = _extractCategoryData(html);
    for (final raw in data) {
      final item = _searchMap(raw);
      final partition = _searchMap(item?["partition"]);
      if (item == null || partition == null) continue;
      final id =
          "${_searchText(partition["id_str"])},${_searchText(partition["type"])}";
      if (id == ",") continue;

      final subs = <LiveSubCategory>[];
      final subList = item["sub_partition"];
      if (subList is List) {
        for (final subRaw in subList) {
          final subPartition = _searchMap(_searchMap(subRaw)?["partition"]);
          if (subPartition == null) continue;
          subs.add(
            LiveSubCategory(
              id: "${_searchText(subPartition["id_str"])},${_searchText(subPartition["type"])}",
              name: _searchText(subPartition["title"]),
              parentId: id,
              pic: "",
            ),
          );
        }
      }

      final category = LiveCategory(
        children: subs,
        id: id,
        name: _searchText(partition["title"]),
      );
      subs.insert(
        0,
        LiveSubCategory(
          id: category.id,
          name: category.name,
          parentId: category.id,
          pic: "",
        ),
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    final ids = category.id.split(',');
    if (ids.length < 2) throw _invalidSearchResponse();
    final result = await _loadPartition(
      ids[0],
      ids[1],
      count: kRecommendPageSize,
      offset: (page - 1) * kRecommendPageSize,
    );
    return LiveCategoryResult(hasMore: result.hasMore, items: result.items);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    final requestedPage = page < 1 ? 1 : page;
    if (requestedPage == 1) {
      _recommendSnapshot = null;
    }

    var all = _recommendSnapshot;
    if (all == null) {
      final build = _recommendBuild ??= _buildRecommendSnapshot();
      try {
        all = await build;
        if (identical(_recommendBuild, build)) {
          _recommendSnapshot = all;
          _recommendBuild = null;
        }
      } catch (error) {
        if (identical(_recommendBuild, build)) _recommendBuild = null;
        rethrow;
      }
    }

    final start = (requestedPage - 1) * kRecommendPageSize;
    if (start >= all.length) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    final end = min(start + kRecommendPageSize, all.length);
    return LiveCategoryResult(
      hasMore: end < all.length,
      items: all.sublist(start, end),
    );
  }

  Future<List<LiveRoomItem>> _buildRecommendSnapshot() async {
    final categories = <LiveCategory>[];
    CoreError? categoryError;
    try {
      final loaded = await (_categoryLoader?.call() ?? getCategores());
      categories.addAll(loaded.take(kHomeCategoryLimit));
    } on CoreError catch (error) {
      if (error.kind == CoreErrorKind.cancelled) rethrow;
      categoryError = error;
    } catch (error) {
      categoryError = CoreError(
        '抖音热门分区读取失败',
        site: 'douyin',
        kind: CoreErrorKind.schemaChanged,
      );
      CoreLog.error(error);
    }

    final requests = <Future<_PartitionBatch> Function()>[
      () => _loadPartitionBatch('720', '1', kRecommendPageSize),
      for (final category in categories)
        () {
          final ids = category.id.split(',');
          if (ids.length < 2) {
            return Future.value(
              _PartitionBatch(
                error: CoreError(
                  '抖音热门分区响应异常',
                  site: 'douyin',
                  kind: CoreErrorKind.schemaChanged,
                ),
              ),
            );
          }
          return _loadPartitionBatch(ids[0], ids[1], kHomeCategoryRoomCount);
        },
    ];

    final outcomes = await _runPartitionBatches(
      requests,
      kHomeRequestConcurrency,
    );
    final batches = <List<LiveRoomItem>>[];
    final failures = <CoreError>[];
    for (final outcome in outcomes) {
      final items = outcome.items;
      if (items != null) batches.add(items);
      final error = outcome.error;
      if (error != null) {
        if (error.kind == CoreErrorKind.cancelled) throw error;
        failures.add(error);
      }
    }
    if (batches.isEmpty) throw _recommendFailure(failures, categoryError);
    return _mergeRooms(batches);
  }

  Future<_PartitionBatch> _loadPartitionBatch(
    String partitionId,
    String partitionType,
    int count,
  ) async {
    try {
      final result = await _loadPartition(
        partitionId,
        partitionType,
        count: count,
      );
      return _PartitionBatch(items: result.items);
    } on CoreError catch (error) {
      return _PartitionBatch(error: error);
    } catch (error) {
      CoreLog.error(error);
      return _PartitionBatch(
        error: CoreError(
          '抖音热门分区响应异常',
          site: 'douyin',
          kind: CoreErrorKind.schemaChanged,
        ),
      );
    }
  }

  Future<List<_PartitionBatch>> _runPartitionBatches(
    List<Future<_PartitionBatch> Function()> tasks,
    int limit,
  ) async {
    final outcomes = List<_PartitionBatch?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tasks.length) return;
        try {
          outcomes[index] = await tasks[index]();
        } catch (error) {
          outcomes[index] = _PartitionBatch(
            error: error is CoreError
                ? error
                : CoreError(
                    '抖音热门分区响应异常',
                    site: 'douyin',
                    kind: CoreErrorKind.schemaChanged,
                  ),
          );
        }
      }
    }

    await Future.wait(List.generate(min(limit, tasks.length), (_) => worker()));
    return [for (final outcome in outcomes) outcome!];
  }

  CoreError _recommendFailure(
    List<CoreError> failures,
    CoreError? categoryError,
  ) {
    final all = <CoreError>[
      ...failures,
      if (categoryError != null) categoryError,
    ];
    final rateLimited =
        all.isNotEmpty &&
        all.every((error) => error.kind == CoreErrorKind.rateLimited);
    final authRequired = all.any(
      (error) => error.kind == CoreErrorKind.authRequired,
    );
    var retryAfter = failures.isEmpty ? null : failures.first.retryAfter;
    return CoreError(
      '抖音热门直播加载失败',
      site: 'douyin',
      kind: rateLimited
          ? CoreErrorKind.rateLimited
          : authRequired
          ? CoreErrorKind.authRequired
          : CoreErrorKind.transport,
      failures: all,
      retryAfter: retryAfter,
    );
  }

  Future<LiveCategoryResult> _loadPartition(
    String partitionId,
    String partitionType, {
    required int count,
    int offset = 0,
  }) {
    final loader = _partitionLoader;
    if (loader != null) {
      return loader(partitionId, partitionType, count: count, offset: offset);
    }
    return _fetchPartitionRooms(
      partitionId,
      partitionType,
      count: count,
      offset: offset,
    );
  }

  Future<LiveCategoryResult> _fetchPartitionRooms(
    String partitionId,
    String partitionType, {
    required int count,
    int offset = 0,
  }) async {
    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": count.toString(),
        "offset": offset.toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var response = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );
    return parsePartitionRooms(response, count: count);
  }

  static LiveCategoryResult parsePartitionRooms(
    Object? response, {
    required int count,
  }) {
    final data = _searchMap(response)?["data"];
    final list = _searchMap(data)?["data"];
    if (list is! List) throw _invalidSearchResponse();

    final items = <LiveRoomItem>[];
    for (final raw in list) {
      final item = _searchMap(raw);
      final room = _searchMap(item?["room"]);
      if (item == null || room == null) continue;
      final owner = _searchMap(room["owner"]);
      final id = _stableSearchRoomId(item["web_rid"] ?? owner?["web_rid"]);
      if (id.isEmpty) continue;
      final online = _roomOnline(room);
      items.add(
        LiveRoomItem(
          roomId: id,
          title: _searchText(room["title"]),
          cover: _searchImage(room["cover"]),
          userName: _searchText(owner?["nickname"]),
          online: online.value,
          onlineKnown: online.known,
        ),
      );
    }
    return LiveCategoryResult(hasMore: list.length >= count, items: items);
  }

  static List<LiveRoomItem> _mergeRooms(Iterable<List<LiveRoomItem>> batches) {
    final order = <String>[];
    final merged = <String, LiveRoomItem>{};
    for (final batch in batches) {
      for (final item in batch) {
        if (item.roomId.isEmpty) continue;
        final existing = merged[item.roomId];
        if (existing == null) {
          order.add(item.roomId);
          merged[item.roomId] = item;
          continue;
        }
        merged[item.roomId] = LiveRoomItem(
          roomId: existing.roomId,
          title: existing.title.isNotEmpty ? existing.title : item.title,
          cover: existing.cover.isNotEmpty ? existing.cover : item.cover,
          userName: existing.userName.isNotEmpty
              ? existing.userName
              : item.userName,
          online: existing.onlineKnown ? existing.online : item.online,
          onlineKnown: existing.onlineKnown || item.onlineKnown,
          liveStatus: existing.liveStatus ?? item.liveStatus,
          profile: existing.profile ?? item.profile,
          accountId: existing.accountId ?? item.accountId,
        );
      }
    }

    final entries = <(int, LiveRoomItem)>[
      for (var index = 0; index < order.length; index++)
        (index, merged[order[index]]!),
    ];
    entries.sort((a, b) {
      final aKnown = a.$2.onlineKnown;
      final bKnown = b.$2.onlineKnown;
      if (aKnown != bKnown) return aKnown ? -1 : 1;
      if (aKnown) {
        final byOnline = b.$2.online.compareTo(a.$2.online);
        if (byOnline != 0) return byOnline;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in entries) entry.$2];
  }

  static ({int value, bool known}) _roomOnline(Map room) {
    final stats = _searchMap(room['room_view_stats']);
    final roomStats = _searchMap(room['stats']);
    final label = _searchText(stats?['display_long']);
    final displayShowsOnline = label.contains('在线') && !label.contains('累计');
    final online =
        _parseOnline(room['user_count']) ??
        _parseOnline(roomStats?['user_count']) ??
        _parseOnline(room['user_count_str']) ??
        (displayShowsOnline
            ? _parseOnline(stats?['display_value']) ??
                  _parseOnline(stats?['display_short'])
            : null);
    return (value: online ?? 0, known: online != null);
  }

  static int? _parseOnline(Object? value) {
    if (value is int) return value < 0 ? null : value;
    if (value is num) {
      if (!value.isFinite || value < 0) return null;
      final parsed = value.toInt();
      return parsed;
    }
    final text = _searchText(value).replaceAll(',', '').replaceAll('+', '');
    if (text.isEmpty) return null;
    final direct = int.tryParse(text);
    if (direct != null) return direct < 0 ? null : direct;
    final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)(万|亿)?$').firstMatch(text);
    if (match == null) return null;
    final base = double.tryParse(match.group(1)!);
    if (base == null) return null;
    final unit = switch (match.group(2)) {
      '万' => 10000.0,
      '亿' => 100000000.0,
      _ => 1.0,
    };
    final scaled = base * unit;
    return scaled.isFinite ? scaled.round() : null;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 有两种roomId，一种是webRid，一种是roomId
    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // roomId一般长度为19位，例如：7376429659866598196
    // webRid是固定的，用户每次开播都是同一个webRid
    // webRid一般长度为11-12位，例如：416144012050
    // 这里简单进行判断，如果roomId长度小于15，则认为是webRid
    if (roomId.length <= 16) {
      var webRid = roomId;
      return await getRoomDetailByWebRid(webRid);
    }

    return await getRoomDetailByRoomId(roomId);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByRoomId(String roomId) async {
    // 读取房间信息
    var roomData = await _getRoomDataByRoomId(roomId);

    // 通过房间信息获取WebRid
    var webRid = roomData["data"]["room"]["owner"]["web_rid"].toString();

    var room = roomData["data"]["room"];
    var owner = room["owner"];

    var status = LiveStatusParser.douyinStatusCode(room);

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid);
      return result;
    }

    var roomStatus = status == 2;
    final chat = roomStatus
        ? await _getChatSession(webRid, roomId)
        : _chatArgs(webRid, roomId, const {}, '');

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: owner["nickname"].toString(),
      userAvatar: owner["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner["signature"].toString(),
      notice: "",
      showTime: roomStatus ? _startTime(room) : null,
      danmakuData: chat,
      data: room["stream_url"],
    );
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByWebRid(String webRid) async {
    try {
      var result = await _getRoomDetailByWebRidApi(webRid);
      return result;
    } catch (e) {
      CoreLog.error(e);
    }
    return await _getRoomDetailByWebRidHtml(webRid);
  }

  /// 通过WebRid访问直播间API，从API中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidApi(String webRid) async {
    // 读取房间信息
    var data = await _getRoomDataByApi(webRid);

    final rooms = data['data'];
    final account = _searchMap(data['user']);
    if (rooms is List &&
        rooms.isEmpty &&
        account != null &&
        _searchText(account['nickname']).isNotEmpty &&
        _searchLiveStatus(account['live_status']) != true) {
      // The room endpoint has confirmed the owner but returned no active room.
      return LiveRoomDetail(
        roomId: webRid,
        title: '',
        cover: '',
        userName: _searchText(account['nickname']),
        userAvatar: _searchImage(account['avatar_thumb']),
        online: 0,
        status: false,
        url: 'https://live.douyin.com/$webRid',
        introduction: _searchText(account['signature']),
      );
    }
    var roomData = data["data"][0];
    var userData = data["user"];
    final roomId = _searchText(roomData['id_str'] ?? roomData['id']);

    var owner = roomData["owner"];

    var roomStatus = LiveStatusParser.douyinStatusCode(roomData) == 2;

    final (showTime, chat) = roomStatus
        ? await (
            _resolveStartTime(roomData, roomId),
            _getChatSession(webRid, roomId),
          ).wait
        : (null, _chatArgs(webRid, roomId, const {}, ''));
    return LiveRoomDetail(
      roomId: webRid,
      title: roomData["title"].toString(),
      cover: roomStatus ? roomData["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : userData["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : userData["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(roomData["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      showTime: showTime,
      danmakuData: chat,
      data: roomStatus ? roomData["stream_url"] : {},
    );
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidHtml(String webRid) async {
    final (roomData, sessionCookie) = await _getRoomDataByHtml(webRid);

    var room = roomData["roomStore"]["roomInfo"]["room"];
    final roomId = _searchText(room['id_str'] ?? room['id']);
    var owner = room["owner"];
    var anchor = roomData["roomStore"]["roomInfo"]["anchor"];
    var roomStatus = LiveStatusParser.douyinStatusCode(room) == 2;

    final showTime = roomStatus ? await _resolveStartTime(room, roomId) : null;

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : anchor["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : anchor["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      showTime: showTime,
      danmakuData: _chatArgs(webRid, roomId, roomData, sessionCookie),
      data: roomStatus ? room["stream_url"] : {},
    );
  }

  static String? _startTime(Object? value) {
    if (value is! Map) return null;
    for (final field in ['start_time', 'live_start_time']) {
      final raw = int.tryParse(_searchText(value[field]));
      if (raw == null || raw <= 0) continue;
      final seconds = raw >= 100000000000 ? raw ~/ 1000 : raw;
      if (seconds <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        return seconds.toString();
      }
    }
    return null;
  }

  Future<String?> _resolveStartTime(Map room, String roomId) async {
    final startTime = _startTime(room);
    if (startTime != null || !RegExp(r'^\d{17,20}$').hasMatch(roomId)) {
      return startTime;
    }
    // Reflow gives the start time for the exact broadcast, which is often
    // absent from web room metadata.
    final parent = RequestContext.current;
    final context = RequestContext(timeout: const Duration(seconds: 4));
    try {
      final data = await context.run(() => _getRoomDataByRoomId(roomId));
      return _startTime(_searchMap(data['data'])?['room']);
    } catch (_) {
      parent?.check();
      return null;
    }
  }

  Future<DouyinDanmakuArgs> _getChatSession(
    String webRid,
    String roomId,
  ) async {
    final parent = RequestContext.current;
    final context = RequestContext(timeout: const Duration(seconds: 4));
    try {
      final (html, sessionCookie) = await context.run(
        () => _getRoomPage(webRid),
      );
      return _chatArgs(
        webRid,
        roomId,
        _parseRoomState(html) ?? const {},
        sessionCookie,
      );
    } catch (_) {
      parent?.check();
      return _chatArgs(webRid, roomId, const {}, '');
    }
  }

  DouyinDanmakuArgs _chatArgs(
    String webRid,
    String roomId,
    Map state,
    String sessionCookie,
  ) {
    final user = _searchMap(state['userStore']);
    final visitor = _searchText(_searchMap(user?['odin'])?['user_unique_id']);
    return DouyinDanmakuArgs(
      webRid: webRid,
      roomId: roomId,
      userId: visitor.isEmpty ? generateRandomNumber(12).toString() : visitor,
      cookie: sessionCookie.isNotEmpty
          ? sessionCookie
          : cookie.isNotEmpty
          ? cookie
          : kDefaultCookie,
    );
  }

  Future<(String, String)> _getRoomPage(String webRid) async {
    final supplied = cookie;
    final response = await HttpClient.instance.getTextResponse(
      'https://live.douyin.com/$webRid',
      header: {...headers, if (supplied.isNotEmpty) 'Cookie': supplied},
    );
    final session = <String, String>{};
    void addCookie(String pair) {
      final separator = pair.indexOf('=');
      if (separator <= 0) return;
      session[pair.substring(0, separator).trim()] = pair;
    }

    for (final pair in supplied.split(';')) {
      addCookie(pair.trim());
    }
    // A browser uses the new visitor cookies returned with this page. The
    // account's login cookies continue to come from the configured session.
    for (final line in response.headers['set-cookie'] ?? const <String>[]) {
      final pair = line.split(';').first.trim();
      if (RegExp(
        r'^(ttwid|__ac_nonce|__ac_signature|msToken|UIFID_TEMP)=',
      ).hasMatch(pair)) {
        addCookie(pair);
      }
    }
    return (response.data ?? '', session.values.join('; '));
  }

  Future<String> _getWebCookie(String webRid) async =>
      (await _getRoomPage(webRid)).$2;

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<(Map, String)> _getRoomDataByHtml(String webRid) async {
    final (html, sessionCookie) = await _getRoomPage(webRid);
    final state = _parseRoomState(html);
    if (state == null) throw const FormatException('抖音页面缺少房间状态');
    return (state, sessionCookie);
  }

  static Map? _parseRoomState(String html) {
    final renderData = RegExp(
      r'(\{\\"state\\":\{\\"appStore.*?)\]\\n',
    ).firstMatch(html)?.group(1);
    if (renderData == null) return null;
    try {
      final data = _searchMap(json.decode(json.decode('"$renderData"')));
      return _searchMap(data?['state']);
    } on FormatException {
      return null;
    }
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByApi(String webRid) async {
    String serverUrl = "https://live.douyin.com/webcast/room/web/enter/";

    // 提前获取 headers
    var requestHeader = await getRequestHeaders();

    // 使用动态 Referer（包含房间号，参考 DouyinLiveRecorder）
    requestHeader["Referer"] = "https://live.douyin.com/$webRid";

    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "web_rid": webRid,
        "msToken": "",
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: requestHeader,
    );

    if (result is! Map) {
      throw Exception("抖音接口返回格式异常");
    }

    return result["data"];
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    var result = await HttpClient.instance.getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: await getRequestHeaders(),
    );
    return result;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    List<LivePlayQuality> qualities = [];

    try {
      var liveCoreData = detail.data["live_core_sdk_data"];

      if (liveCoreData == null) {
        return qualities;
      }

      var pullData = liveCoreData["pull_data"];

      if (pullData == null) {
        return qualities;
      }

      var options = pullData["options"];

      var qulityList = options?["qualities"];

      var streamData = pullData["stream_data"]?.toString() ?? "";

      if (!streamData.startsWith('{')) {
        var flvList = (detail.data["flv_pull_url"] as Map).values
            .cast<String>()
            .toList();
        var hlsList = (detail.data["hls_pull_url_map"] as Map).values
            .cast<String>()
            .toList();
        for (var quality in qulityList) {
          int level = quality["level"];
          List<String> urls = [];
          var flvIndex = flvList.length - level;
          if (flvIndex >= 0 && flvIndex < flvList.length) {
            urls.add(flvList[flvIndex]);
          }
          var hlsIndex = hlsList.length - level;
          if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
            urls.add(hlsList[hlsIndex]);
          }
          var qualityItem = LivePlayQuality(
            id:
                quality['sdk_key'] is String &&
                    (quality['sdk_key'] as String).isNotEmpty
                ? quality['sdk_key'] as String
                : null,
            quality: quality["name"],
            sort: level,
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      } else {
        var qualityData = json.decode(streamData)["data"] as Map;

        for (var quality in qulityList) {
          List<String> urls = [];

          var flvUrl = qualityData[quality["sdk_key"]]?["main"]?["flv"]
              ?.toString();

          if (flvUrl != null && flvUrl.isNotEmpty) {
            urls.add(flvUrl);
          }
          var hlsUrl = qualityData[quality["sdk_key"]]?["main"]?["hls"]
              ?.toString();

          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            urls.add(hlsUrl);
          }

          var qualityItem = LivePlayQuality(
            id:
                quality['sdk_key'] is String &&
                    (quality['sdk_key'] as String).isNotEmpty
                ? quality['sdk_key'] as String
                : null,
            quality: quality["name"],
            sort: quality["level"],
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      }
    } catch (e, stackTrace) {
      CoreLog.error(e);
      CoreLog.error(stackTrace);
    }
    // var qualityData = json.decode(
    //     detail.data["live_core_sdk_data"]["pull_data"]["stream_data"])["data"];

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    _logDebug("获取到的画质列表: ${qualities.map((q) => q.quality).toList()}");
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 返回列表的副本，防止外部 clear() 影响原始数据
    return LivePlayUrl(urls: List<String>.from(quality.data));
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    final id = directSearchRoomId(keyword);
    if (id != null) {
      if (page != 1) return LiveSearchRoomResult(hasMore: false, items: []);
      final detail = await getRoomDetail(roomId: id);
      return LiveSearchRoomResult(
        hasMore: false,
        items: [
          LiveRoomItem(
            roomId: id,
            title: detail.title,
            cover: detail.cover,
            userName: detail.userName,
            liveStatus: detail.status,
          ),
        ],
      );
    }

    // Merge the two sources, retaining usable results if one is unavailable.
    final (live, users) = await (
      _searchSource(() => _searchLiveRooms(keyword, page)),
      _searchSource(() => searchAnchors(keyword, page: page)),
    ).wait;
    RequestContext.current?.check();
    if (live.$1 == null && users.$1 == null) throw users.$2!;
    final items = <LiveRoomItem>[...?live.$1?.items];
    final byRoom = {for (final item in items) item.roomId: item};
    for (final user in users.$1?.items ?? const <LiveAnchorItem>[]) {
      if (user.roomId.isNotEmpty && byRoom.containsKey(user.roomId)) {
        final previous = byRoom[user.roomId]!;
        items[items.indexOf(previous)] = LiveRoomItem(
          roomId: previous.roomId,
          title: previous.title,
          cover: previous.cover,
          userName: previous.userName,
          online: previous.online,
          onlineKnown: previous.onlineKnown,
          liveStatus:
              previous.liveStatus ??
              (user.statusKnown ? user.liveStatus : null),
          profile: user.profile,
          accountId: user.accountId,
        );
        continue;
      }
      items.add(
        LiveRoomItem(
          roomId: user.roomId,
          title: user.roomTitle ?? '',
          cover: user.avatar,
          userName: user.userName,
          onlineKnown: false,
          liveStatus: user.statusKnown ? user.liveStatus : null,
          profile: user.profile,
          accountId: user.accountId,
        ),
      );
    }
    return LiveSearchRoomResult(
      items: items,
      hasMore: live.$1?.hasMore == true || users.$1?.hasMore == true,
      partialFailure: users.$2 ?? live.$2,
    );
  }

  static String? directSearchRoomId(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'live.douyin.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.pathSegments.length != 1) {
      return null;
    }
    final id = _stableSearchRoomId(uri.pathSegments.single);
    return id.isEmpty ? null : id;
  }

  Future<(T?, CoreError?)> _searchSource<T>(Future<T> Function() load) async {
    try {
      return (await load(), null);
    } on CoreError catch (error) {
      if (error.kind == CoreErrorKind.cancelled) rethrow;
      return (null, error);
    } on FormatException {
      return (null, _invalidSearchResponse());
    }
  }

  Future<LiveSearchRoomResult> _searchLiveRooms(
    String keyword,
    int page,
  ) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    final result = await _searchResponse(uri, keyword, 'live', 'data');
    final items = <LiveRoomItem>[];
    final seen = <String>{};
    for (final item in result['data'] as List) {
      final raw = _searchMap(_searchMap(item)?['lives'])?['rawdata'];
      if (raw is! String || raw.isEmpty) continue;
      Map? room;
      try {
        room = _searchMap(jsonDecode(raw));
      } on FormatException {
        continue;
      }
      final owner = _searchMap(room?['owner']);
      final id = _stableSearchRoomId(owner?['web_rid']);
      if (id.isEmpty || room == null || owner == null || !seen.add(id))
        continue;
      final online = _roomOnline(room);
      items.add(
        LiveRoomItem(
          roomId: id,
          title: _searchText(room['title']),
          cover: _searchImage(room['cover']),
          userName: _searchText(owner['nickname']),
          profile: _searchProfile(owner),
          accountId: _searchText(owner['unique_id']),
          online: online.value,
          onlineKnown: online.known,
          liveStatus: _searchLiveStatus(room['status']),
        ),
      );
    }
    if (items.isEmpty && (result['data'] as List).isNotEmpty) {
      throw _invalidSearchResponse();
    }
    return LiveSearchRoomResult(
      hasMore: _searchMore(result, result['data'] as List),
      items: items,
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    final uri = Uri.https('www.douyin.com', '/aweme/v1/web/discover/search/', {
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'search_channel': 'aweme_user',
      'keyword': keyword.trim().replaceFirst(RegExp(r'^@'), ''),
      'search_source': 'switch_tab',
      'offset': ((page - 1) * 10).toString(),
      'count': '10',
    });
    final result = await _searchResponse(uri, keyword, 'user', 'user_list');
    return parseUserSearch(result);
  }

  static LiveSearchAnchorResult parseUserSearch(Map result) {
    final data = result['user_list'];
    if (data is! List) throw _invalidSearchResponse();
    final items = <LiveAnchorItem>[];
    final seen = <String>{};
    for (final raw in data) {
      final entry = _searchMap(raw);
      final user = _searchMap(entry?['user_info']);
      if (user == null) continue;
      final profile = _searchProfile(user);
      final room =
          _searchMap(entry?['room_data']) ?? _searchMap(user['room_data']);
      final id = _stableSearchRoomId(user['web_rid'] ?? room?['web_rid']);
      final name = _searchText(user['nickname']);
      if (name.isEmpty || (id.isEmpty && profile == null)) continue;
      if (!seen.add(id.isEmpty ? profile!.path : id)) continue;
      final status = _searchLiveStatus(room?['status'] ?? user['live_status']);
      items.add(
        LiveAnchorItem(
          roomId: id,
          profile: profile,
          accountId: _searchText(user['unique_id']).isEmpty
              ? _searchText(user['short_id'])
              : _searchText(user['unique_id']),
          avatar: _searchImage(user['avatar_thumb']),
          userName: name,
          roomTitle: _searchText(room?['title']),
          liveStatus: status == true,
          statusKnown: status != null,
        ),
      );
    }
    if (items.isEmpty && data.isNotEmpty) throw _invalidSearchResponse();
    return LiveSearchAnchorResult(
      hasMore: _searchMore(result, data),
      items: items,
    );
  }

  Future<Map> _searchResponse(
    Uri uri,
    String keyword,
    String type,
    String field,
  ) async {
    final session = cookie;
    final searchCookie = session.isNotEmpty
        ? session
        : type == 'live'
        ? await _getWebCookie('')
        : '';
    final result = await HttpClient.instance.getJson(
      uri.toString(),
      header: {
        'accept': 'application/json',
        'referer': Uri.https('www.douyin.com', '/search/$keyword', {
          'type': type,
        }).toString(),
        'user-agent': kDefaultUserAgent,
        if (searchCookie.isNotEmpty) 'cookie': searchCookie,
      },
    );
    if (result == null || result == '' || result == 'blocked') {
      throw CoreError(
        '抖音搜索访问受限，请稍后重试',
        site: 'douyin',
        kind: CoreErrorKind.rateLimited,
      );
    }
    if (result is! Map) throw _invalidSearchResponse();
    final statusCode = _searchText(result['status_code']);
    if (statusCode.isNotEmpty && statusCode != '0') {
      final statusMessage = _searchText(result['status_msg']).toLowerCase();
      final loginRequired =
          statusCode == '2483' ||
          statusMessage.contains('登录') ||
          statusMessage.contains('login');
      final rateLimited =
          statusMessage.contains('频繁') ||
          statusMessage.contains('限流') ||
          statusMessage.contains('稍后') ||
          statusMessage.contains('too many');
      final kind = loginRequired
          ? CoreErrorKind.authRequired
          : rateLimited
          ? CoreErrorKind.rateLimited
          : CoreErrorKind.unknown;
      throw CoreError(
        loginRequired
            ? '抖音搜索需要登录'
            : rateLimited
            ? '抖音搜索请求过于频繁'
            : '抖音搜索暂不可用',
        site: 'douyin',
        kind: kind,
      );
    }
    if (result[field] is! List) throw _invalidSearchResponse();
    return result;
  }

  static CoreError _invalidSearchResponse() => CoreError(
    '抖音搜索响应格式异常',
    site: 'douyin',
    kind: CoreErrorKind.schemaChanged,
  );

  static List<dynamic> _extractCategoryData(String html) {
    final normalized = html.replaceAll('\\"', '"').replaceAll('\\\\', '\\');
    for (final source in <String>[normalized, html]) {
      final marker = source.indexOf('"categoryData"');
      if (marker < 0) continue;
      final start = source.indexOf("[", marker);
      if (start < 0) continue;
      final end = _matchingBracket(source, start);
      if (end < 0) continue;
      try {
        final decoded = json.decode(source.substring(start, end + 1));
        if (decoded is List) return decoded;
      } on FormatException {
        continue;
      }
    }
    throw CoreError(
      "抖音分区数据缺失",
      site: "douyin",
      kind: CoreErrorKind.schemaChanged,
    );
  }

  static int _matchingBracket(String source, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < source.length; index++) {
      final code = source.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          inString = false;
        }
      } else if (code == 0x22) {
        inString = true;
      } else if (code == 0x5b) {
        depth++;
      } else if (code == 0x5d) {
        depth--;
        if (depth == 0) return index;
      }
    }
    return -1;
  }

  static Map? _searchMap(Object? value) => value is Map ? value : null;
  static String _searchText(Object? value) =>
      value is String || value is int ? value.toString().trim() : '';
  static String _stableSearchRoomId(Object? value) {
    final id = _searchText(value);
    return RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(id) ? id : '';
  }

  static Uri? _searchProfile(Map user) {
    final id = _searchText(user['sec_uid']);
    return RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id)
        ? Uri.https('www.douyin.com', '/user/$id')
        : null;
  }

  static String _searchImage(Object? value) {
    final urls = _searchMap(value)?['url_list'];
    return urls is List && urls.isNotEmpty ? _searchText(urls.first) : '';
  }

  static bool? _searchLiveStatus(Object? value) => switch (_searchText(value)) {
    '2' => true,
    '4' => false,
    _ => null,
  };

  static bool _searchMore(Map value, List items) => switch (value['has_more']) {
    null => items.length >= 10,
    final more => more == true || _searchText(more) == '1',
  };

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    return (await getRoomStatusSnapshot(roomId: roomId)).live;
  }

  @override
  Future<LiveRoomStatus> getRoomStatusSnapshot({required String roomId}) async {
    var webRid = roomId;
    if (roomId.length > 16) {
      final data = await _getRoomDataByRoomId(roomId);
      final room = data['data']['room'];
      final status = LiveStatusParser.douyinStatusCode(room);
      if (status != 4) {
        return LiveRoomStatus(
          live: status == 2,
          showTime: status == 2 ? _startTime(room) : null,
        );
      }
      webRid = room['owner']['web_rid'].toString();
    }
    try {
      final data = await _getRoomDataByApi(webRid);
      final room = data['data'][0];
      final live = LiveStatusParser.douyinStatusCode(room) == 2;
      return LiveRoomStatus(
        live: live,
        showTime: live ? _startTime(room) : null,
      );
    } catch (error) {
      RequestContext.current?.check();
      if (error is CoreError &&
          (error.kind == CoreErrorKind.rateLimited ||
              error.kind == CoreErrorKind.authRequired))
        rethrow;
      final (data, _) = await _getRoomDataByHtml(webRid);
      final room = data['roomStore']['roomInfo']['room'];
      final live = LiveStatusParser.douyinStatusCode(room) == 2;
      return LiveRoomStatus(
        live: live,
        showTime: live ? _startTime(room) : null,
      );
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  int generateRandomNumber(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ??
        Random().nextInt(1000000000);
  }
}
