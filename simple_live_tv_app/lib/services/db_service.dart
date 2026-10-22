import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';

import 'package:simple_live_tv_app/models/db/history.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  Future<void> _mutations = Future.value();

  Future<void> _serialize(Future<void> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future init() async {
    historyBox = await Hive.openBox("TVHostiry");
    followBox = await Hive.openBox("TVFollowUser");
    await _recover(followBox, FollowUser.fromJson);
    await _recover(historyBox, History.fromJson);
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future<void> addFollow(FollowUser follow) => _serialize(() async {
    await _recover(followBox, FollowUser.fromJson);
    await followBox.put(follow.id, follow);
  });

  Future<void> deleteFollow(String id) => _serialize(() async {
    await _recover(followBox, FollowUser.fromJson);
    await followBox.delete(id);
  });

  Future<void> _replace<T>(Box<T> box, Map<String, T> records) async {
    await box.putAll(records);
    await box.deleteAll(
      box.keys.where((key) => !records.containsKey(key)).toList(),
    );
    await box.flush();
  }

  Future<void> _recover<T>(
    Box<T> box,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final journal = await Hive.openBox<dynamic>('${box.name}_restore');
    final previous = journal.get('previous');
    if (previous == null) return;
    final records = <String, T>{};
    for (final raw in previous as List) {
      final json = Map<String, dynamic>.from(raw);
      records[json['id'] as String] = parse(json);
    }
    await _replace(box, records);
    await journal.delete('previous');
    await journal.flush();
  }

  Future<void> _commit<T>(
    Box<T> box,
    Map<String, T> records,
    T Function(Map<String, dynamic>) parse,
    Map<String, dynamic> Function(T) encode,
  ) async {
    final journal = await Hive.openBox<dynamic>('${box.name}_restore');
    final previous = box.values.map(encode).toList();
    await journal.put('previous', previous);
    await journal.flush();
    try {
      await _replace(box, records);
      await journal.delete('previous');
      await journal.flush();
    } catch (_) {
      await journal.put('previous', previous);
      await journal.flush();
      await _recover(box, parse);
      rethrow;
    }
  }

  Future<void> importFollows(
    Iterable<dynamic> data, {
    required bool replace,
  }) async {
    final imported = <String, FollowUser>{};
    for (final raw in data) {
      final user = FollowUser.fromJson(Map<String, dynamic>.from(raw as Map));
      if (!Sites.allSites.containsKey(user.siteId) ||
          user.roomId.isEmpty ||
          user.id != '${user.siteId}_${user.roomId}' ||
          imported.containsKey(user.id)) {
        throw const FormatException('Invalid or duplicate follow');
      }
      imported[user.id] = user;
    }
    await _serialize(() async {
      await _recover(followBox, FollowUser.fromJson);
      await _commit(
        followBox,
        {
          if (!replace)
            for (final user in followBox.values) user.id: user,
          ...imported,
        },
        FollowUser.fromJson,
        (user) => user.toJson(),
      );
    });
  }

  Future<void> importHistories(
    Iterable<dynamic> data, {
    required bool replace,
  }) async {
    final imported = <String, History>{};
    for (final raw in data) {
      final item = History.fromJson(Map<String, dynamic>.from(raw as Map));
      if (!Sites.allSites.containsKey(item.siteId) ||
          item.roomId.isEmpty ||
          item.id != '${item.siteId}_${item.roomId}' ||
          imported.containsKey(item.id)) {
        throw const FormatException('Invalid or duplicate history');
      }
      imported[item.id] = item;
    }
    await _serialize(() async {
      await _recover(historyBox, History.fromJson);
      final existing = {for (final item in historyBox.values) item.id: item};
      final next = <String, History>{if (!replace) ...existing};
      for (final entry in imported.entries) {
        final old = existing[entry.key];
        next[entry.key] =
            old != null && old.updateTime.isAfter(entry.value.updateTime)
            ? old
            : entry.value;
      }
      await _commit(
        historyBox,
        next,
        History.fromJson,
        (item) => item.toJson(),
      );
    });
  }

  Future<void> deleteHistory(String id) => _serialize(() async {
    await _recover(historyBox, History.fromJson);
    await historyBox.delete(id);
  });

  Future<void> clearHistories() => _serialize(() async {
    await _recover(historyBox, History.fromJson);
    await historyBox.clear();
  });

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future<void> addOrUpdateHistory(History history) => _serialize(() async {
    await _recover(historyBox, History.fromJson);
    await historyBox.put(history.id, history);
  });

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
