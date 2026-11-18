import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show validateShieldRules;
import 'package:uuid/uuid.dart';

enum RestoreGroup {
  follows('关注和标签'),
  history('观看历史'),
  shield('屏蔽词'),
  settings('设置');

  const RestoreGroup(this.label);
  final String label;
}

enum RestoreMode {
  skip('跳过'),
  merge('合并'),
  replace('替换');

  const RestoreMode(this.label);
  final String label;
}

class WebDavBackup {
  static const followsFile = 'SimpleLive_follows.json';
  static const tagsFile = 'SimpleLive_Tags.json';
  static const historyFile = 'SimpleLive_histories.json';
  static const shieldFile = 'SimpleLive_blocked_word.json';
  static const settingsFile = 'SimpleLive_Settings.json';
  static const accountFile = 'SimpleLive_bilibili_account.json';
  static const maxSize = 32 * 1024 * 1024;

  WebDavBackup._(this.documents);
  final Map<String, dynamic> documents;

  static Set<String> _selectedFiles(bool accountOnly) => accountOnly
      ? {accountFile}
      : {followsFile, tagsFile, historyFile, shieldFile, settingsFile};

  static WebDavBackup decode(List<int> bytes, {bool accountOnly = false}) {
    if (bytes.length > maxSize) throw const FormatException('备份文件过大');
    final selected = _selectedFiles(accountOnly);
    final names = <String>{};
    final archive = ZipDecoder().decodeBytes(
      bytes,
      callback: (entry) {
        if (entry.isFile &&
            selected.contains(entry.name) &&
            !names.add(entry.name)) {
          throw const FormatException('备份中有重复文件');
        }
      },
    );
    return read(archive, accountOnly: accountOnly);
  }

  static WebDavBackup read(Archive archive, {bool accountOnly = false}) {
    final selected = _selectedFiles(accountOnly);
    final documents = <String, dynamic>{};
    var size = 0;
    for (final file in archive) {
      if (!file.isFile || !selected.contains(file.name)) continue;
      size += file.size;
      if (size > maxSize || documents.containsKey(file.name)) {
        throw const FormatException('备份文件大小或目录异常');
      }
      final content = file.content;
      final crc = file.crc32;
      if (content.length != file.size ||
          (crc != null && getCrc32(content) != crc)) {
        throw const FormatException('备份校验失败');
      }
      final data = jsonDecode(utf8.decode(content));
      if (data is! Map ||
          (data['version'] != null && data['version'] != 2) ||
          !data.containsKey('data')) {
        throw const FormatException('无法识别备份格式');
      }
      final value = data['data'];
      if (const {
            followsFile,
            tagsFile,
            historyFile,
            shieldFile,
          }.contains(file.name)
          ? value is! List
          : value is! Map) {
        throw const FormatException('备份数据格式异常');
      }
      documents[file.name] = value;
    }
    if (documents.containsKey(followsFile) || documents.containsKey(tagsFile)) {
      DBService.validateSnapshot(
        follows: documents[followsFile] as List?,
        tags: documents[tagsFile] as List?,
      );
    }
    if (documents.containsKey(historyFile)) {
      documents[historyFile] = DBService.parseHistories(documents[historyFile]);
    }
    if (documents.containsKey(shieldFile)) {
      documents[shieldFile] = validateShieldRules(documents[shieldFile]);
    }
    if (documents.containsKey(settingsFile)) {
      documents[settingsFile] = LocalStorageService.validateSettings(
        documents[settingsFile],
      );
    }
    return WebDavBackup._(documents);
  }

  bool has(RestoreGroup group) => switch (group) {
    RestoreGroup.follows =>
      documents.containsKey(followsFile) || documents.containsKey(tagsFile),
    RestoreGroup.history => documents.containsKey(historyFile),
    RestoreGroup.shield => documents.containsKey(shieldFile),
    RestoreGroup.settings => documents.containsKey(settingsFile),
  };

  String? get legacyCookie {
    final value = (documents[accountFile] as Map?)?['cookie'];
    return value is String && value.isNotEmpty && value.length <= 65536
        ? value
        : null;
  }
}

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

class RestoreDiff {
  RestoreDiff(Map before, Map after)
    : added = after.keys.where((key) => !before.containsKey(key)).length,
      removed = before.keys.where((key) => !after.containsKey(key)).length,
      updated = after.keys
          .where(
            (key) =>
                before.containsKey(key) &&
                jsonEncode(before[key]) != jsonEncode(after[key]),
          )
          .length;

  final int added;
  final int removed;
  final int updated;
  String get label => '新增 $added，更新 $updated，移除 $removed';
}

Map<String, Map> _records(List values) => {
  for (final record in values.cast<Map>()) record['id'] as String: record,
};

class RestoreChange {
  RestoreChange(this.group, this.before, this.after);
  final RestoreGroup group;
  final Object before;
  final Object after;
  bool get changed => _digest(before) != _digest(after);

  Map<String, RestoreDiff> get differences {
    if (group == RestoreGroup.follows) {
      final current = before as Map;
      final next = after as Map;
      return {
        '关注': RestoreDiff(
          _records(current['follows']),
          _records(next['follows']),
        ),
        '标签': RestoreDiff(_records(current['tags']), _records(next['tags'])),
      };
    }
    final (oldRecords, newRecords) = switch (group) {
      RestoreGroup.history => (
        _records(before as List),
        _records(after as List),
      ),
      RestoreGroup.shield => (
        {for (final word in before as List) word: true},
        {for (final word in after as List) word: true},
      ),
      _ => (before as Map, after as Map),
    };
    return {group.label: RestoreDiff(oldRecords, newRecords)};
  }
}

class WebDavRestorePreview {
  WebDavRestorePreview(this.backup, this.current);
  final WebDavBackup backup;
  final Map<RestoreGroup, Object> current;
  final _legacyTagIds = <String, String>{};

  RestoreChange change(
    RestoreGroup group,
    RestoreMode mode, {
    bool restoreBells = false,
  }) {
    final before = current[group]!;
    final replace = mode == RestoreMode.replace;
    final docs = backup.documents;
    final after = switch (group) {
      RestoreGroup.follows => _follows(before as Map, replace, restoreBells),
      RestoreGroup.history => _histories(before as List, replace),
      RestoreGroup.shield => validateShieldRules({
        if (!replace) ...(before as List<String>),
        ...docs[WebDavBackup.shieldFile] as List<String>,
      })..sort(),
      RestoreGroup.settings => _settings(before as Map, replace),
    };
    return RestoreChange(group, before, after);
  }

  List<Map> _histories(List before, bool replace) {
    final current = _records(before);
    final next = <String, Map>{if (!replace) ...current};
    for (final item
        in (backup.documents[WebDavBackup.historyFile] as Map<String, History>)
            .values) {
      final old = current[item.id];
      next[item.id] =
          !replace &&
              old != null &&
              DateTime.parse(old['updateTime']).isAfter(item.updateTime)
          ? old
          : item.toJson();
    }
    return (next.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((entry) => entry.value)
        .toList();
  }

  Map<String, dynamic> _settings(Map before, bool replace) {
    final next = {
      if (!replace) ...before,
      ...backup.documents[WebDavBackup.settingsFile] as Map,
    };
    return {
      for (final key in LocalStorageService.backupKeys.keys)
        if (next.containsKey(key)) key: next[key],
    };
  }

  Map<String, Object> _follows(Map before, bool replace, bool restoreBells) {
    final docs = backup.documents;
    final incoming = docs[WebDavBackup.followsFile] as List?;
    final incomingTags = docs[WebDavBackup.tagsFile] as List?;
    final oldFollows = _records(before['follows']);
    final oldTags = _records(before['tags']);
    final follows = <String, Map>{
      if (!replace || incoming == null) ...oldFollows,
    };
    for (final raw in incoming ?? const []) {
      final json = Map<String, dynamic>.of(raw as Map<String, dynamic>);
      if (!restoreBells) json.remove('notifyLive');
      final old = oldFollows[json['id']];
      final user = FollowUser.fromJson(
        json,
        existing: old == null
            ? null
            : FollowUser.fromJson(Map<String, dynamic>.from(old)),
      );
      follows[user.id] = user.toJson();
    }
    final tags = <String, Map>{
      if (!replace || incomingTags == null) ...oldTags,
    };
    final memberships = <String, String>{
      for (final tag in tags.values)
        for (final room in tag['userId'] as List)
          room as String: tag['id'] as String,
    };
    final names = <String, String>{
      for (final tag in tags.values) tag['tag'] as String: tag['id'] as String,
    };
    final originalNames = Map.of(names);
    final targetIds = <String>{};
    for (final raw in incomingTags ?? const []) {
      final id = raw['id'] as String;
      final name = raw['tag'] as String;
      final sameName = names[name];
      final originalNameId = originalNames[name];
      if (tags.containsKey(id) &&
          ((sameName != null && sameName != id) ||
              (originalNameId != null && originalNameId != id))) {
        throw const FormatException('标签 ID 和名称指向两个本机标签');
      }
      final target = sameName ?? id;
      if (!targetIds.add(target))
        throw const FormatException('备份中的多个标签合并到同一标签');
      names.remove(tags[target]?['tag']);
      names[name] = target;
      tags[target] = {'id': target, 'tag': name, 'userId': <String>[]};
      for (final room in raw['userId'] as List) {
        memberships[room as String] = target;
      }
    }
    if (incomingTags == null) {
      for (final raw in incoming ?? const []) {
        final id = raw['id'] as String;
        final name = raw['tag'] as String?;
        if (name == '全部') memberships.remove(id);
        if (name == null ||
            name == '全部' ||
            name.trim().isEmpty ||
            name == '直播中' ||
            name == '未开播')
          continue;
        final tagId = names.putIfAbsent(
          name,
          () => _legacyTagIds.putIfAbsent(name, const Uuid().v4),
        );
        tags.putIfAbsent(
          tagId,
          () => {'id': tagId, 'tag': name, 'userId': <String>[]},
        );
        memberships[id] = tagId;
      }
    }
    final members = {for (final id in tags.keys) id: <String>[]};
    final orderedFollows = follows.keys.toList()..sort();
    final nextFollows = <Map>[];
    for (final id in orderedFollows) {
      final tag = memberships[id];
      members[tag]?.add(id);
      nextFollows.add({...follows[id]!, 'tag': tags[tag]?['tag'] ?? '全部'});
    }
    return {
      'follows': nextFollows,
      'tags': [
        for (final tag in tags.entries)
          {...tag.value, 'userId': members[tag.key]!},
      ],
    };
  }
}

class WebDavRestoreResult {
  final List<String> succeeded = [];
  final List<String> failed = [];
  final List<String> skipped = [];
  final List<String> unchanged = [];
}

class WebDavRestore {
  static const _checkpointKey = 'rollback';
  static Future<void> _operations = Future<void>.value();
  final _db = DBService.instance;
  final _storage = LocalStorageService.instance;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Box<dynamic>> _journal() => Hive.openBox('WebDavRestore');

  Future<Object> _read(RestoreGroup group) async => switch (group) {
    RestoreGroup.follows => await _db.exportSnapshot(),
    RestoreGroup.history => await _db.exportHistorySnapshot(),
    RestoreGroup.shield => _storage.shieldBox.values.toSet().toList()..sort(),
    RestoreGroup.settings => _storage.exportSettings(),
  };

  Future<WebDavRestorePreview> preview(WebDavBackup backup) async =>
      WebDavRestorePreview(backup, {
        for (final group in RestoreGroup.values)
          if (backup.has(group)) group: await _read(group),
      });

  Future<bool> _write(RestoreGroup group, Object expected, Object after) async {
    switch (group) {
      case RestoreGroup.follows:
        if (!await _db.replaceSnapshotIfCurrent(expected as Map, after as Map))
          return false;
        EventBus.instance.emit(Constant.kUpdateFollow, 0);
      case RestoreGroup.history:
        if (!await _db.replaceHistoriesIfCurrent(
          expected as List,
          after as List,
        ))
          return false;
        EventBus.instance.emit(Constant.kUpdateHistory, 0);
      case RestoreGroup.shield:
        try {
          final next = await _storage.updateShieldRules(
            after as List,
            replace: true,
            expected: Set<String>.from(expected as List),
          );
          AppSettingsController.instance.shieldList.assignAll(next);
        } on ShieldRulesChanged {
          return false;
        }
      case RestoreGroup.settings:
        if (!await _storage.restoreSettings(
          after as Map,
          replace: true,
          expected: expected as Map,
        ))
          return false;
        AppSettingsController.instance.reloadSettings();
    }
    return true;
  }

  Future<void> _save(Box box, Map current, [Map? pending]) async {
    await box.put(_checkpointKey, {'current': current, 'pending': ?pending});
    await box.flush();
  }

  Future<Map<String, dynamic>> _recover(Box box) async {
    final saved = box.get(_checkpointKey) as Map?;
    final current = Map<String, dynamic>.from(saved?['current'] as Map? ?? {});
    final pending = saved?['pending'] as Map?;
    if (pending == null) return current;
    final committed = <String, dynamic>{};
    for (final group in RestoreGroup.values) {
      final entry = pending[group.name] as Map?;
      if (entry != null &&
          _digest(await _read(group)) != _digest(entry['before'])) {
        committed[group.name] = entry;
      }
    }
    final checkpoint = committed.isEmpty ? current : committed;
    await _save(box, checkpoint);
    return checkpoint;
  }

  Future<WebDavRestoreResult> apply(List<RestoreChange> changes) =>
      _serialize(() => _apply(changes));

  Future<WebDavRestoreResult> _apply(List<RestoreChange> changes) async {
    final result = WebDavRestoreResult();
    final pending = {
      for (final change in changes)
        if (change.changed)
          change.group.name: {
            'before': change.before,
            'after': _digest(change.after),
          },
    };
    final journal = await _journal();
    final current = await _recover(journal);
    if (pending.isNotEmpty) await _save(journal, current, pending);
    final committed = <String, dynamic>{};
    for (final change in changes) {
      final group = change.group;
      try {
        if (!change.changed) {
          if (_digest(await _read(group)) == _digest(change.before)) {
            result.unchanged.add(group.label);
          } else {
            result.skipped.add(group.label);
          }
        } else if (await _write(group, change.before, change.after)) {
          result.succeeded.add(group.label);
          committed[group.name] = pending[group.name];
        } else {
          result.skipped.add(group.label);
        }
      } catch (_, stack) {
        result.failed.add(group.label);
        Log.e('恢复${group.label}失败', stack);
      }
    }
    if (result.failed.isEmpty) {
      if (pending.isNotEmpty)
        await _save(journal, committed.isEmpty ? current : committed);
    } else {
      // Leave the checkpoint available if a box committed before a refresh
      // failed; the same reconciliation also covers a process interruption.
      await _recover(journal);
    }
    return result;
  }

  Future<bool> hasRollback() =>
      _serialize(() async => (await _recover(await _journal())).isNotEmpty);

  Future<WebDavRestoreResult> rollback() => _serialize(_rollback);

  Future<WebDavRestoreResult> _rollback() async {
    final journal = await _journal();
    final checkpoint = await _recover(journal);
    final result = WebDavRestoreResult();
    for (final group in RestoreGroup.values) {
      final entry = checkpoint[group.name] as Map?;
      if (entry == null) continue;
      try {
        final current = await _read(group);
        final before = entry['before'] as Object;
        if (_digest(current) == _digest(before)) {
          result.unchanged.add(group.label);
        } else if (_digest(current) != entry['after'] ||
            !await _write(group, current, before)) {
          result.skipped.add(group.label);
          continue;
        } else {
          result.succeeded.add(group.label);
        }
        checkpoint.remove(group.name);
      } catch (_, stack) {
        result.failed.add(group.label);
        Log.e('回滚${group.label}失败', stack);
      }
    }
    await _save(journal, checkpoint);
    return result;
  }
}
