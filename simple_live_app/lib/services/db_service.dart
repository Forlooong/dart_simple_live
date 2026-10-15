import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
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
    await _tagWrite('tags.delete', id, () => tagBox.delete(id));
    await _tagWrite('tags.flush', null, tagBox.flush);
    await _saveTagOrder(
      _orderedTagIds(_canonicalTags(), _tagOrderBox!.get('ids')),
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

  Future<void> updateFollowTag(FollowUserTag followTag) {
    final snapshot = _copyTag(followTag);
    return _serializeTagMutation(() async {
      await _ensureTagStorage();
      // An older UI snapshot must not resurrect a tag deleted ahead of it.
      if (!tagBox.containsKey(snapshot.id)) return;
      await _tagWrite(
        'tags.update',
        snapshot.id,
        () => tagBox.put(snapshot.id, snapshot),
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

  Future addFollow(FollowUser follow) async {
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
