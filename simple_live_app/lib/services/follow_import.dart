import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';

/// Imports a full batch without momentarily removing retained subscriptions.
/// All records are parsed before any write, so malformed input preserves the
/// current follows. Older backups retain each existing notification choice.
Future<void> importFollowUsers(
  Box<FollowUser> box,
  Iterable<dynamic> data, {
  required bool replace,
}) async {
  final existing = {for (final user in box.values) user.id: user};
  final imported = <String, FollowUser>{};
  for (final item in data) {
    final json = Map<String, dynamic>.from(item as Map);
    final user = FollowUser.fromJson(json, existing: existing[json['id']]);
    imported[user.id] = user;
  }
  await box.putAll(imported);
  if (replace) {
    await box.deleteAll(existing.keys.where((id) => !imported.containsKey(id)));
  }
}
