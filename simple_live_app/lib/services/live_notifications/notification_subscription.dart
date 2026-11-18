/// A UI-owned snapshot. Background isolates never open the UI's Hive boxes.
class NotificationSubscription {
  const NotificationSubscription({
    required this.id,
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.generation,
  });

  final String id;
  final String siteId;
  final String roomId;
  final String userName;
  // Changes after opt-out/re-subscribe, even for the same room.
  final String generation;

  factory NotificationSubscription.fromJson(Map<String, dynamic> json) =>
      NotificationSubscription(
        id: json['id'] as String,
        siteId: json['siteId'] as String,
        roomId: json['roomId'] as String,
        userName: json['userName'] as String,
        generation: json['generation'] as String,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'siteId': siteId,
    'roomId': roomId,
    'userName': userName,
    'generation': generation,
  };
}

class NotificationConfig {
  const NotificationConfig({
    this.rooms = const [],
    this.quietHours,
    this.preferences = const {},
    this.credentialRevisions = const {},
  });

  final List<NotificationSubscription> rooms;
  final QuietHours? quietHours;
  final Map<String, ReminderPreference> preferences;
  final Map<String, int> credentialRevisions;

  int credentialRevision(String site) => credentialRevisions[site] ?? 0;

  ReminderPreference preferenceFor(NotificationSubscription room) =>
      preferences[room.generation] ?? const ReminderPreference();

  bool contains(NotificationSubscription room) => rooms.any(
    (current) => current.id == room.id && current.generation == room.generation,
  );

  factory NotificationConfig.fromJson(Map<String, dynamic> json) =>
      NotificationConfig(
        rooms: (json['rooms'] as List)
            .map(
              (room) => NotificationSubscription.fromJson(
                Map<String, dynamic>.from(room as Map),
              ),
            )
            .toList(),
        quietHours: QuietHours.fromJson(json['quietHours']),
        credentialRevisions: {
          for (final entry
              in (json['credentialRevisions'] as Map? ?? {}).entries)
            if (entry.key is String && entry.value is int)
              entry.key as String: entry.value as int,
        },
        preferences: {
          for (final entry in (json['preferences'] as Map? ?? {}).entries)
            if (entry.key is String && entry.value is Map)
              entry.key as String: ReminderPreference.fromJson(entry.value),
        },
      );

  Map<String, dynamic> toJson() => {
    'version': 2,
    'rooms': rooms.map((room) => room.toJson()).toList(),
    if (quietHours != null) 'quietHours': quietHours!.toJson(),
    if (credentialRevisions.isNotEmpty)
      'credentialRevisions': credentialRevisions,
    if (preferences.isNotEmpty)
      'preferences': {
        for (final entry in preferences.entries)
          entry.key: entry.value.toJson(),
      },
  };
}

class ReminderPreference {
  const ReminderPreference({this.priority = false, this.snoozedUntil});

  final bool priority;
  final DateTime? snoozedUntil;
  bool isSnoozed(DateTime now) => snoozedUntil?.isAfter(now) ?? false;

  factory ReminderPreference.fromJson(Map json) => ReminderPreference(
    priority: json['priority'] == true,
    snoozedUntil: DateTime.tryParse(json['snoozedUntil']?.toString() ?? ''),
  );

  Map<String, dynamic> toJson() => {
    'priority': priority,
    if (snoozedUntil != null)
      'snoozedUntil': snoozedUntil!.toUtc().toIso8601String(),
  };
}

class QuietHours {
  const QuietHours(this.start, this.end, {this.summary = false});
  final int start;
  final int end;
  final bool summary;

  DateTime? activeUntil(DateTime time) {
    final local = time.toLocal();
    final minute = local.hour * 60 + local.minute;
    final overnight = start > end;
    final active = overnight
        ? minute >= start || minute < end
        : minute >= start && minute < end;
    if (!active) return null;
    return DateTime(
      local.year,
      local.month,
      local.day + (overnight && minute >= start ? 1 : 0),
      end ~/ 60,
      end % 60,
    );
  }

  static QuietHours? fromJson(Object? json) {
    if (json is! Map) return null;
    final start = json['start'];
    final end = json['end'];
    if (start is! int ||
        end is! int ||
        start < 0 ||
        start >= 1440 ||
        end < 0 ||
        end >= 1440 ||
        start == end)
      return null;
    return QuietHours(start, end, summary: json['summary'] == true);
  }

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'summary': summary,
  };
}
