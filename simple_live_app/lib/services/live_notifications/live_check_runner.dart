import 'notification_store.dart';
import 'notification_subscription.dart';

typedef LiveStatusCheck = Future<bool> Function(NotificationSubscription room);
typedef LiveAlert = Future<void> Function(NotificationSubscription room);

/// No UI, Hive, GetX or platform dependencies: also runs in a headless engine.
class LiveCheckRunner {
  LiveCheckRunner({
    required this.store,
    required this.check,
    required this.show,
    required this.cancel,
    this.roomTimeout = const Duration(seconds: 20),
    this.budget = const Duration(minutes: 7),
  });

  final NotificationStore store;
  final LiveStatusCheck check;
  final LiveAlert show;
  final LiveAlert cancel;
  final Duration roomTimeout;
  final Duration budget;

  Future<void> run() async {
    final config = await store.readConfig();
    final state = await store.readState();
    final statuses = Map<String, dynamic>.from(state['rooms'] as Map? ?? {});
    statuses.removeWhere((key, value) => !config.rooms.any((room) =>
        room.id == key && (value as Map)['generation'] == room.generation));
    state['rooms'] = statuses;
    final rooms = [...config.rooms];
    final cursor = rooms.indexWhere((room) => room.id == state['cursor']);
    // Rotate so a large list or consistently slow room cannot starve its tail.
    if (cursor >= 0) {
      rooms.addAll(rooms.take(cursor + 1).toList());
      rooms.removeRange(0, cursor + 1);
    }
    final stopwatch = Stopwatch()..start();
    for (final room in rooms) {
      if (stopwatch.elapsed >= budget) break;
      if (!(await store.readConfig()).contains(room)) continue;
      try {
        final remaining = budget - stopwatch.elapsed;
        final live = await check(room)
            .timeout(remaining < roomTimeout ? remaining : roomTimeout);
        if (!(await store.readConfig()).contains(room)) continue;
        final previous = statuses[room.id] as Map?;
        final shouldNotify = previous?['generation'] == room.generation &&
            previous?['live'] == false &&
            live;
        statuses[room.id] = {'generation': room.generation, 'live': live};
        state['cursor'] = room.id;
        state['lastCheck'] = DateTime.now().toUtc().toIso8601String();
        // Persist before showing: process death must not replay a batch of alerts.
        // Delivery is best-effort; a kill at this boundary can lose one alert.
        await store.writeState(state);
        if (shouldNotify && (await store.readConfig()).contains(room)) {
          await show(room);
          // Covers a concurrent opt-out while the native show call was pending.
          if (!(await store.readConfig()).contains(room)) await cancel(room);
        }
      } catch (_) {
        // Unknown is not offline. Keep the last successful state for this room
        // and allow remaining rooms to be checked even if one platform fails.
        state['cursor'] = room.id;
      }
    }
    await store.writeState(state);
  }
}
