import 'dart:convert';
import 'dart:io';

import 'notification_subscription.dart';

abstract class NotificationStore {
  Future<NotificationConfig> readConfig();
  Future<Map<String, dynamic>> readState();
  Future<void> writeState(Map<String, dynamic> state);
}

/// Each file has exactly one writer: the UI writes config, the unique periodic
/// worker writes state. Rename on Android keeps readers from seeing partial JSON.
/// Do not add foreground checks or a second worker that writes the same state.
class FileNotificationStore implements NotificationStore {
  FileNotificationStore(this.directory);

  final Directory directory;

  Future<Map<String, dynamic>> _read(String name) async {
    final file = File('${directory.path}/$name.json');
    if (!await file.exists()) return {};
    return Map<String, dynamic>.from(jsonDecode(await file.readAsString()));
  }

  Future<void> _write(String name, Map<String, dynamic> value) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/$name.json');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<NotificationConfig> readConfig() async {
    final json = await _read('subscriptions');
    return json.isEmpty
        ? const NotificationConfig()
        : NotificationConfig.fromJson(json);
  }

  Future<void> writeConfig(NotificationConfig config) =>
      _write('subscriptions', config.toJson());

  @override
  Future<Map<String, dynamic>> readState() => _read('state');

  @override
  Future<void> writeState(Map<String, dynamic> state) => _write('state', state);
}
