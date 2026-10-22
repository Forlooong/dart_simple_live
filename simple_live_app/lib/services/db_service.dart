import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';

class DBService extends GetxService {
  DBService({
    // A narrow fault-injection seam for exercising interrupted Hive writes.
    FutureOr<void> Function(String operation, Object? key)? beforeTagWrite,
  }) : _beforeTagWrite = beforeTagWrite;

  static DBService get instance => Get.find<DBService>();
  final FutureOr<void> Function(String operation, Object? key)? _beforeTagWrite;
  Future<void> _tagMutations = Future<void>.value();
  Box<dynamic>? _tagOrderBox;
  Box<dynamic>? _tagBackupBox;
  bool _tagsReady = false;
  static const _tagRepairVersion = 1;
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  Future init() async {
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    tagBox = await Hive.openBox("FollowUserTag");
    await repairFollowTagStorage();
    await _recoverHistoryImport();
  }

  // Tag records always use their stable IDs. Ordering lives in a separate box.
  // Existing tests and secondary consumers can assign tagBox directly; metadata
  // is opened lazily on their first mutation instead of requiring new fixtures.
  Future<T> _serializeTagMutation<T>(Future<T> Function() action) {
    final result = _tagMutations.then((_) => action());
    _tagMutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _tagWrite(
    String operation,
    Object? key,
    Future<void> Function() write,
  ) async {
    await _beforeTagWrite?.call(operation, key);
    await write();
  }

  FollowUserTag _copyTag(FollowUserTag tag) =>
      tag.copyWith(userId: List<String>.from(tag.userId));

  Map<String, FollowUserTag> _canonicalTags() {
    final tags = <String, FollowUserTag>{};
    for (final key in tagBox.keys) {
      final tag = tagBox.get(key);
      if (tag == null || tag.id.isEmpty) continue;
      // A UUID-keyed record is the best available conflict heuristic. Both
      // versions are retained in the durable backup before repairing aliases.
      if (key == tag.id || !tags.containsKey(tag.id)) {
        tags[tag.id] = _copyTag(tag);
      }
    }
    return tags;
  }

  List<String> _orderedTagIds(
    Map<String, FollowUserTag> tags,
    dynamic savedOrder,
  ) {
    final ids = <String>{};
    if (savedOrder is List) {
      ids.addAll(savedOrder.whereType<String>().where(tags.containsKey));
    }
    ids.addAll(tags.keys);
    return ids.toList();
  }

  /// Idempotently repairs the integer/mismatched keys produced by old reorders.
  /// All tag mutations share this queue, so a repair cannot race a deletion.
  Future<void> repairFollowTagStorage() => _serializeTagMutation(() async {
    _tagsReady = false;
    await _ensureTagStorage();
  });

  Future<void> _ensureTagStorage() async {
    if (_tagsReady) return;
    _tagOrderBox ??= await Hive.openBox<dynamic>('${tagBox.name}_order');
    final metadata = _tagOrderBox!;
    await _recoverSnapshot();
    var pending = metadata.get('pendingRepair');
    if (pending == null) {
      final tags = _canonicalTags();
      final entries = tagBox.toMap();
      final aliases = entries.entries.where(
        (entry) => entry.value.id.isNotEmpty && entry.key != entry.value.id,
      );
      final order = _orderedTagIds(tags, metadata.get('ids'));
      if (aliases.isNotEmpty) {
        _tagBackupBox ??= await Hive.openBox<dynamic>(
          '${tagBox.name}_legacy_backup',
        );
        final backup = _tagBackupBox!;
        // Back up ALL original records, including canonical conflict winners
        // and malformed records. Typed keys distinguish 0 from the string "0".
        // Never replace a backup left by an interrupted earlier attempt.
        for (final entry in entries.entries) {
          final key = '${entry.key is int ? 'int' : 'string'}:${entry.key}';
          if (!backup.containsKey(key)) {
            final original = _copyTag(entry.value);
            await _tagWrite(
              'backup.put',
              key,
              () => backup.put(key, {
                'sourceKey': entry.key,
                'record': original.toJson(),
              }),
            );
          }
        }
        await _tagWrite('backup.flush', null, backup.flush);
        // Persist a replayable plan before touching source records. Re-reading
        // a half-repaired key chain could otherwise select a different winner.
        pending = {
          'records': tags.values.map((tag) => tag.toJson()).toList(),
          'ids': order,
          // A mismatched key can also be another tag's canonical destination.
          'aliases': aliases
              .map((entry) => entry.key)
              .where((key) => !tags.containsKey(key))
              .toList(),
        };
        await _tagWrite(
          'metadata.plan',
          'pendingRepair',
          () => metadata.put('pendingRepair', pending),
        );
        await _tagWrite('metadata.flush', null, metadata.flush);
      } else {
        await _saveTagOrder(order);
      }
    }
    if (pending != null) {
      final plan = Map<String, dynamic>.from(pending as Map);
      for (final rawTag in plan['records'] as List) {
        final tag = FollowUserTag.fromJson(Map<String, dynamic>.from(rawTag));
        await _tagWrite('tags.put', tag.id, () => tagBox.put(tag.id, tag));
      }
      await _tagWrite('tags.flush', null, tagBox.flush);
      await _saveTagOrder(List<String>.from(plan['ids']));
      // Only remove aliases once both canonical records and order are durable.
      for (final key in plan['aliases'] as List) {
        await _tagWrite('tags.deleteAlias', key, () => tagBox.delete(key));
      }
      await _tagWrite('tags.flush', null, tagBox.flush);
      await _tagWrite(
        'metadata.clearPlan',
        'pendingRepair',
        () => metadata.delete('pendingRepair'),
      );
      await _tagWrite('metadata.flush', null, metadata.flush);
    }
    // This marker is deliberately last; an error leaves repair retryable.
    await _tagWrite(
      'metadata.version',
      'repairVersion',
      () => metadata.put('repairVersion', _tagRepairVersion),
    );
    await _tagWrite('metadata.flush', null, metadata.flush);
    _tagsReady = true;
  }

  Future<void> _saveTagOrder(List<String> ids) async {
    final metadata = _tagOrderBox!;
    await _tagWrite('metadata.order', 'ids', () => metadata.put('ids', ids));
    await _tagWrite('metadata.flush', null, metadata.flush);
  }

  bool getFollowTagExist(String id) => _canonicalTags().containsKey(id);

  Future<void> deleteFollowTag(String id) => _serializeTagMutation(() async {
    await _ensureTagStorage();
    final tags = _canonicalTags();
    final removed = tags.remove(id);
    if (removed == null) return;
    final follows = {for (final follow in followBox.values) follow.id: follow};
    for (final follow in follows.values.toList()) {
      if (follow.tag == removed.tag || removed.userId.contains(follow.id)) {
        follows[follow.id] = _copyFollow(follow)..tag = '全部';
      }
    }
    await _commitSnapshot(
      follows,
      tags,
      _orderedTagIds(tags, _tagOrderBox!.get('ids')),
    );
  });

  FollowUserTag? getFollowTag(String tag) =>
      getFollowTagList().firstWhereOrNull((item) => item.tag == tag);

  bool getFollowTagExistByTag(String tag) =>
      getFollowTagList().any((item) => item.tag == tag);

  List<FollowUserTag> getFollowTagList() {
    final tags = _canonicalTags();
    return _orderedTagIds(
      tags,
      _tagOrderBox?.get('ids'),
    ).map((id) => tags[id]!).toList();
  }

  Future<void> updateFollowTag(FollowUserTag followTag) =>
      _updateFollowTag(followTag);

  Future<void> renameFollowTag(String id, String name) => _updateFollowTag(
    FollowUserTag(id: id, tag: name, userId: []),
    renameOnly: true,
  );

  Future<void> _updateFollowTag(
    FollowUserTag followTag, {
    bool renameOnly = false,
  }) {
    var snapshot = _copyTag(followTag);
    return _serializeTagMutation(() async {
      await _ensureTagStorage();
      // An older UI snapshot must not resurrect a tag deleted ahead of it.
      if (!tagBox.containsKey(snapshot.id)) return;
      if (renameOnly) {
        snapshot = snapshot.copyWith(
          userId: List<String>.from(tagBox.get(snapshot.id)!.userId),
        );
      }
      if (getFollowTagList().any(
        (tag) => tag.id != snapshot.id && tag.tag == snapshot.tag,
      )) {
        throw const FormatException('Duplicate tag name');
      }
      await _beforeTagWrite?.call('tags.update', snapshot.id);
      final tags = _canonicalTags();
      final old = tags[snapshot.id]!;
      tags[snapshot.id] = snapshot;
      final follows = {
        for (final follow in followBox.values) follow.id: follow,
      };
      for (final follow in follows.values.toList()) {
        if (snapshot.userId.contains(follow.id)) {
          follows[follow.id] = _copyFollow(follow)..tag = snapshot.tag;
          for (final tag in tags.values) {
            if (tag.id != snapshot.id) tag.userId.remove(follow.id);
          }
        } else if (follow.tag == old.tag || old.userId.contains(follow.id)) {
          follows[follow.id] = _copyFollow(follow)..tag = '全部';
        }
      }
      await _commitSnapshot(
        follows,
        tags,
        _orderedTagIds(tags, _tagOrderBox!.get('ids')),
      );
    });
  }

  Future<FollowUserTag> addFollowTag(String tag) =>
      _serializeTagMutation(() async {
        await _ensureTagStorage();
        final existing = getFollowTag(tag);
        if (existing != null) return existing;
        final uniqueId = uuid.v4();
        final item = FollowUserTag(id: uniqueId, tag: tag, userId: []);
        await _tagWrite('tags.add', uniqueId, () => tagBox.put(uniqueId, item));
        await _tagWrite('tags.flush', null, tagBox.flush);
        await _saveTagOrder(
          _orderedTagIds(_canonicalTags(), _tagOrderBox!.get('ids')),
        );
        return _copyTag(item);
      });

  Future<void> updateFollowTagOrder(List<FollowUserTag> userTagList) {
    final requestedIds = userTagList.map((tag) => tag.id).toList();
    return _serializeTagMutation(() async {
      await _ensureTagStorage();
      final tags = _canonicalTags();
      final existingOrder = _orderedTagIds(tags, _tagOrderBox!.get('ids'));
      // Keep stored tags omitted by stale/partial lists, and never write stale
      // tag objects over a rename or recreate a deleted tag during reordering.
      await _saveTagOrder(
        _orderedTagIds(tags, [...requestedIds, ...existingOrder]),
      );
    });
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future<void> addFollow(FollowUser follow) => _serializeTagMutation(() async {
    await _ensureTagStorage();
    await followBox.put(follow.id, follow);
  });

  Future<({FollowUser saved, bool previous})> setFollowNotification(
    String id,
    bool enabled,
  ) => _serializeTagMutation(() async {
    await _ensureTagStorage();
    final current = followBox.get(id);
    if (current == null) throw Exception('直播间已取消关注');
    final previous = current.notifyLive;
    final saved = _copyFollow(current)..notifyLive = enabled;
    await followBox.put(id, saved);
    return (saved: saved, previous: previous);
  });

  Future<void> rollbackFollowNotification(
    FollowUser saved,
    bool previous,
  ) => _serializeTagMutation(() async {
    await _ensureTagStorage();
    final current = followBox.get(saved.id);
    // Scheduling may fail after a later import, unfollow or toggle. Undo only
    // our own unchanged write, never that newer decision or replacement room.
    if (!identical(current, saved) || current!.notifyLive == previous) return;
    await followBox.put(saved.id, _copyFollow(current)..notifyLive = previous);
  });

  Future<void> deleteFollow(String id) => _serializeTagMutation(() async {
    await _ensureTagStorage();
    final follows = {for (final follow in followBox.values) follow.id: follow}
      ..remove(id);
    final tags = _canonicalTags();
    for (final tag in tags.values) {
      tag.userId.remove(id);
    }
    await _commitSnapshot(
      follows,
      tags,
      _orderedTagIds(tags, _tagOrderBox!.get('ids')),
    );
  });

  Future<void> moveFollow(String id, String? tagId) =>
      _serializeTagMutation(() async {
        await _ensureTagStorage();
        final tags = _canonicalTags();
        if (tagId != null && !tags.containsKey(tagId)) return;
        final current = followBox.get(id);
        if (current == null) return;
        final follows = {
          for (final follow in followBox.values) follow.id: follow,
        };
        follows[id] = _copyFollow(current)..tag = tags[tagId]?.tag ?? '全部';
        for (final tag in tags.values) {
          tag.userId.remove(id);
          if (tag.id == tagId) tag.userId.add(id);
        }
        await _commitSnapshot(
          follows,
          tags,
          _orderedTagIds(tags, _tagOrderBox!.get('ids')),
        );
      });

  FollowUser _copyFollow(FollowUser user) => FollowUser.fromJson(user.toJson())
    ..liveStatus = user.liveStatus
    ..liveStartTime = user.liveStartTime;

  Future<void> importTags(Iterable<dynamic> data, {required bool replace}) =>
      importSnapshot(tags: data, replace: replace);

  Future<void> importFollows(Iterable<dynamic> data, {required bool replace}) =>
      importSnapshot(follows: data, replace: replace);

  Future<Map<String, Object>> exportSnapshot() =>
      _serializeTagMutation(() async {
        await _ensureTagStorage();
        return {
          'follows': getFollowList().map((user) => user.toJson()).toList(),
          'tags': getFollowTagList().map((tag) => tag.toJson()).toList(),
        };
      });

  static void validateSnapshot({
    Iterable<dynamic>? follows,
    Iterable<dynamic>? tags,
  }) {
    _parseSnapshot(follows: follows, tags: tags);
  }

  static ({
    List<Map<String, dynamic>>? follows,
    Map<String, FollowUserTag> tags,
  })
  _parseSnapshot({Iterable<dynamic>? follows, Iterable<dynamic>? tags}) {
    final followIds = <String>{};
    final rawFollows = follows?.map((raw) {
      final json = Map<String, dynamic>.from(raw as Map);
      final user = FollowUser.fromJson(json);
      if (!followIds.add(user.id) ||
          user.id.isEmpty ||
          !Sites.allSites.containsKey(user.siteId) ||
          user.roomId.isEmpty ||
          user.id != '${user.siteId}_${user.roomId}' ||
          (json.containsKey('notifyLive') && json['notifyLive'] is! bool)) {
        throw const FormatException('Invalid follow');
      }
      return json;
    }).toList();
    final importedTags = <String, FollowUserTag>{};
    final names = <String>{};
    final members = <String>{};
    for (final raw in tags ?? const []) {
      final tag = FollowUserTag.fromJson(Map<String, dynamic>.from(raw as Map));
      if (tag.id.isEmpty ||
          tag.tag.trim().isEmpty ||
          const ['全部', '直播中', '未开播'].contains(tag.tag) ||
          importedTags.containsKey(tag.id) ||
          !names.add(tag.tag) ||
          tag.userId.toSet().length != tag.userId.length) {
        throw const FormatException('Invalid or duplicate tag');
      }
      for (final id in tag.userId) {
        if (id.isEmpty || !members.add(id)) {
          throw const FormatException('Invalid or repeated tag membership');
        }
      }
      importedTags[tag.id] = tag;
    }
    return (follows: rawFollows, tags: importedTags);
  }

  /// Validate the whole input before joining the same queue as local edits.
  /// The journal contains the pre-import state until every box is durable.
  Future<void> importSnapshot({
    Iterable<dynamic>? follows,
    Iterable<dynamic>? tags,
    required bool replace,
  }) async {
    final input = _parseSnapshot(follows: follows, tags: tags);
    final rawFollows = input.follows;
    final importedTags = input.tags;
    await _serializeTagMutation(() async {
      await _ensureTagStorage();
      final stored = {for (final user in followBox.values) user.id: user};
      final nextFollows = <String, FollowUser>{
        if (rawFollows == null || !replace) ...stored,
      };
      final seen = <String>{};
      for (final raw in rawFollows ?? const <Map<String, dynamic>>[]) {
        final user = FollowUser.fromJson(raw, existing: stored[raw['id']]);
        if (!seen.add(user.id)) throw const FormatException('Duplicate follow');
        nextFollows[user.id] = user;
      }
      final nextTags = <String, FollowUserTag>{
        if (tags == null || !replace) ..._canonicalTags(),
        ...importedTags,
      };
      // A legacy follows-only file carries names instead of a tags document.
      // Preserve those categories by creating each missing name once.
      if (tags == null && rawFollows != null) {
        for (final user in nextFollows.values) {
          if (user.tag != '全部' &&
              !nextTags.values.any((tag) => tag.tag == user.tag)) {
            final id = uuid.v4();
            nextTags[id] = FollowUserTag(id: id, tag: user.tag, userId: []);
          }
        }
      }
      if (nextTags.values.map((tag) => tag.tag).toSet().length !=
          nextTags.length) {
        throw const FormatException('Conflicting tag names');
      }
      final memberships = <String, FollowUserTag>{};
      if (tags != null) {
        for (final tag in nextTags.values) {
          for (final id in tag.userId) {
            if (memberships.containsKey(id)) {
              throw const FormatException('Follow belongs to multiple tags');
            }
            memberships[id] = tag;
          }
        }
      }
      final byName = {for (final tag in nextTags.values) tag.tag: tag};
      for (final tag in nextTags.values) {
        tag.userId = [];
      }
      for (final current in nextFollows.values.toList()) {
        final tag = tags == null
            ? byName[current.tag]
            : memberships[current.id];
        nextFollows[current.id] = _copyFollow(current)..tag = tag?.tag ?? '全部';
        tag?.userId.add(current.id);
      }
      final order = tags != null && replace
          ? nextTags.keys.toList()
          : _orderedTagIds(nextTags, _tagOrderBox!.get('ids'));
      await _commitSnapshot(nextFollows, nextTags, order);
    });
  }

  Future<void> _writeSnapshot(
    Map<String, FollowUser> follows,
    Map<dynamic, FollowUserTag> tags,
    List<String> order,
  ) async {
    // Remove only obsolete IDs first: a removal must not emit an earlier
    // update event for an unchanged retained room. Retained IDs are never
    // cleared, so notification subscriptions do not momentarily disappear.
    await _tagWrite(
      'snapshot.removeFollows',
      null,
      () => followBox.deleteAll(
        followBox.keys.where((key) => !follows.containsKey(key)).toList(),
      ),
    );
    await _tagWrite(
      'snapshot.follows',
      null,
      () => followBox.putAll({
        for (final entry in follows.entries)
          if (!identical(followBox.get(entry.key), entry.value))
            entry.key: entry.value,
      }),
    );
    await _tagWrite('snapshot.tags', null, () => tagBox.putAll(tags));
    await _tagWrite(
      'snapshot.removeTags',
      null,
      () => tagBox.deleteAll(
        tagBox.keys.where((key) => !tags.containsKey(key)).toList(),
      ),
    );
    await _tagWrite('snapshot.flushFollows', null, followBox.flush);
    await _tagWrite('snapshot.flushTags', null, tagBox.flush);
    await _saveTagOrder(order);
  }

  Future<void> _recoverSnapshot() async {
    final pending = _tagOrderBox!.get('pendingSnapshot');
    if (pending == null) return;
    final follows = <String, FollowUser>{};
    for (final raw in pending['follows'] as List) {
      final follow = FollowUser.fromJson(Map<String, dynamic>.from(raw));
      follows[follow.id] = follow;
    }
    final tags = <dynamic, FollowUserTag>{};
    for (final raw in pending['tags'] as List) {
      tags[raw['key']] = FollowUserTag.fromJson(
        Map<String, dynamic>.from(raw['record']),
      );
    }
    await _writeSnapshot(follows, tags, List<String>.from(pending['ids']));
    await _tagOrderBox!.delete('pendingSnapshot');
    await _tagOrderBox!.flush();
  }

  Future<void> _commitSnapshot(
    Map<String, FollowUser> follows,
    Map<String, FollowUserTag> tags,
    List<String> order,
  ) async {
    final metadata = _tagOrderBox!;
    final previous = {
      'follows': followBox.values.map((user) => user.toJson()).toList(),
      'tags': tagBox
          .toMap()
          .entries
          .map((entry) => {'key': entry.key, 'record': entry.value.toJson()})
          .toList(),
      'ids': _orderedTagIds(_canonicalTags(), metadata.get('ids')),
    };
    await metadata.put('pendingSnapshot', previous);
    await metadata.flush();
    try {
      await _writeSnapshot(follows, tags, order);
      await _tagWrite(
        'snapshot.commit',
        null,
        () => metadata.delete('pendingSnapshot'),
      );
      await _tagWrite('snapshot.finish', null, metadata.flush);
    } catch (_) {
      _tagsReady = false;
      // A flush may fail after deleting the marker in memory. Restore the
      // durable undo record before attempting rollback in that case as well.
      await metadata.put('pendingSnapshot', previous);
      await metadata.flush();
      await _recoverSnapshot();
      rethrow;
    }
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await _serializeTagMutation(() async {
      await _recoverHistoryImport();
      await historyBox.put(history.id, history);
    });
  }

  Box<dynamic>? _historyImportBox;

  Future<void> _replaceHistories(Map<String, History> records) async {
    await historyBox.putAll(records);
    await historyBox.deleteAll(
      historyBox.keys.where((key) => !records.containsKey(key)).toList(),
    );
    await historyBox.flush();
  }

  Future<void> _recoverHistoryImport() async {
    _historyImportBox ??= await Hive.openBox<dynamic>(
      '${historyBox.name}_restore',
    );
    final pending = _historyImportBox!.get('previous');
    if (pending == null) return;
    final records = <String, History>{};
    for (final raw in pending as List) {
      final history = History.fromJson(Map<String, dynamic>.from(raw));
      records[history.id] = history;
    }
    await _replaceHistories(records);
    await _historyImportBox!.delete('previous');
    await _historyImportBox!.flush();
  }

  static Map<String, History> parseHistories(Iterable<dynamic> data) {
    final imported = <String, History>{};
    for (final raw in data) {
      final history = History.fromJson(Map<String, dynamic>.from(raw as Map));
      if (history.id.isEmpty ||
          history.roomId.isEmpty ||
          !Sites.allSites.containsKey(history.siteId) ||
          history.id != '${history.siteId}_${history.roomId}' ||
          imported.containsKey(history.id)) {
        throw const FormatException('Invalid or duplicate history');
      }
      imported[history.id] = history;
    }
    return imported;
  }

  Future<void> deleteHistory(String id) => _serializeTagMutation(() async {
    await _recoverHistoryImport();
    await historyBox.delete(id);
  });

  Future<void> clearHistories() => _serializeTagMutation(() async {
    await _recoverHistoryImport();
    await historyBox.clear();
  });

  Future<void> importHistories(
    Iterable<dynamic> data, {
    required bool replace,
  }) async {
    final imported = parseHistories(data);
    await _serializeTagMutation(() async {
      await _recoverHistoryImport();
      final existing = {for (final item in historyBox.values) item.id: item};
      final next = <String, History>{if (!replace) ...existing};
      for (final entry in imported.entries) {
        final old = existing[entry.key];
        next[entry.key] =
            old != null && old.updateTime.isAfter(entry.value.updateTime)
            ? old
            : entry.value;
      }
      final previous = existing.values.map((item) => item.toJson()).toList();
      await _historyImportBox!.put('previous', previous);
      await _historyImportBox!.flush();
      try {
        await _replaceHistories(next);
        await _historyImportBox!.delete('previous');
        await _historyImportBox!.flush();
      } catch (_) {
        await _historyImportBox!.put('previous', previous);
        await _historyImportBox!.flush();
        await _recoverHistoryImport();
        rethrow;
      }
    });
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
