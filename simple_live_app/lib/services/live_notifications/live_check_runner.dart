import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';

import 'notification_store.dart';
import 'notification_subscription.dart';

typedef LiveStatusCheck = Future<bool> Function(NotificationSubscription room);
typedef LiveAlert = Future<void> Function(NotificationSubscription room);

/// Runs inside the unique Android worker. Platform requests overlap, while
/// state commits and delivery share one ordered queue.
class LiveCheckRunner {
  LiveCheckRunner({
    required this.store,
    required this.check,
    required this.show,
    required this.cancel,
    this.showSummary,
    this.roomTimeout = const Duration(seconds: 20),
    this.budget = const Duration(minutes: 7),
    this.platformSpacing = const Duration(milliseconds: 250),
    Stopwatch Function()? createStopwatch,
    DateTime Function()? now,
  }) : _createStopwatch = createStopwatch ?? Stopwatch.new,
       _now = now ?? DateTime.now;

  final NotificationStore store;
  final LiveStatusCheck check;
  final LiveAlert show;
  final LiveAlert cancel;
  final Future<void> Function(int count)? showSummary;
  final Duration roomTimeout;
  final Duration budget;
  final Duration platformSpacing;
  final Stopwatch Function() _createStopwatch;
  final DateTime Function() _now;
  static const supportedSites = {'bilibili', 'douyu', 'huya', 'douyin'};

  Future<void> run() async {
    final clock = _createStopwatch()..start();
    var deadline = false;
    final requests = <RequestContext>{};
    final budgetTimer = Timer(budget, () {
      deadline = true;
      for (final request in requests) {
        request.cancel();
      }
    });
    bool expired() => deadline || clock.elapsed >= budget;
    Timer? flushTimer;
    var dirty = 0;
    var writes = Future<void>.value();
    try {
      final config = await store.readConfig();
      final state = await store.readState();
      final subscriptions = {
        for (final room in config.rooms) room.id: room.generation,
      };
      final statuses = Map<String, dynamic>.from(state['rooms'] as Map? ?? {});
      statuses.removeWhere(
        (key, value) =>
            value is! Map ||
            subscriptions[key] == null ||
            subscriptions[key] != value['generation'],
      );
      state['rooms'] = statuses;
      final cursors = Map<String, dynamic>.from(state['cursors'] as Map? ?? {});
      state['cursors'] = cursors;
      final platforms = Map<String, dynamic>.from(
        state['platforms'] as Map? ?? {},
      );
      state['platforms'] = platforms;
      platforms.removeWhere(
        (site, _) => !config.rooms.any((room) => room.siteId == site),
      );
      final recovery = PlatformRecovery(now: _now);
      final deferred = Map<String, dynamic>.from(
        state['deferred'] as Map? ?? {},
      );
      state['deferred'] = deferred;
      final history = List<dynamic>.from(state['history'] as List? ?? []);
      state['history'] = history;
      final confirmed = <String, int>{};

      void trimHistory() {
        final oldest = _now().subtract(const Duration(days: 30));
        history.removeWhere(
          (entry) =>
              entry is! Map ||
              !(DateTime.tryParse(
                    entry['time']?.toString() ?? '',
                  )?.isAfter(oldest) ??
                  false),
        );
        if (history.length > 200) history.removeRange(0, history.length - 200);
      }

      trimHistory();

      Future<void> flush() async {
        flushTimer?.cancel();
        flushTimer = null;
        await store.writeState(state);
        dirty = 0;
      }

      Future<void> serialize(Future<void> Function() action) {
        writes = writes.then((_) => action());
        return writes;
      }

      Future<void> recordWithoutAlert() async {
        if (++dirty >= 10) {
          await flush();
        } else {
          flushTimer ??= Timer(const Duration(seconds: 1), () {
            // The queue retains failures so the worker can retry safely.
            unawaited(
              serialize(() async {
                if (dirty > 0) await flush();
              }).catchError((Object _) {}),
            );
          });
        }
      }

      Future<void> poll(
        String site,
        List<NotificationSubscription> rooms,
      ) async {
        final prior = platforms[site] as Map? ?? {};
        final revision = config.credentialRevision(site);
        final savedBackoff = prior['backoff'];
        if (savedBackoff is Map)
          recovery.restore(site, savedBackoff, version: revision);
        final platform = <String, dynamic>{
          'selected': rooms.length,
          'checked': 0,
          'succeeded': 0,
          'lastSuccess': prior['lastSuccess'],
        };
        platforms[site] = platform;
        final cursor = rooms.indexWhere(
          (room) => room.id == (cursors[site] ?? state['cursor']),
        );
        if (cursor >= 0) {
          rooms.addAll(rooms.take(cursor + 1).toList());
          rooms.removeRange(0, cursor + 1);
        }
        Duration? lastStart;
        for (final room in rooms) {
          if (expired()) break;
          final gate = recovery.blocked(site, revision);
          if (gate != null) {
            platform['error'] = gate.name;
            platform['backoff'] = recovery.snapshot(site);
            if (platform['checked'] == 0 ||
                gate == CoreErrorKind.rateLimited ||
                gate == CoreErrorKind.authRequired)
              break;
          }
          if (lastStart != null) {
            final delay = platformSpacing - (clock.elapsed - lastStart);
            final remaining = budget - clock.elapsed;
            if (delay >= remaining) break;
            if (delay > Duration.zero) await Future<void>.delayed(delay);
          }
          if (expired()) break;
          final selection = await store.readConfig();
          if (selection.credentialRevision(site) != revision || expired())
            break;
          if (!selection.contains(room)) continue;
          final remaining = budget - clock.elapsed;
          final timeout = remaining < roomTimeout ? remaining : roomTimeout;
          if (timeout <= Duration.zero) break;
          lastStart = clock.elapsed;
          cursors[site] = room.id;
          // Keep legacy readers and the first post-upgrade round compatible.
          state['cursor'] = room.id;
          platform['checked'] = (platform['checked'] as int) + 1;
          final context = RequestContext(timeout: timeout);
          requests.add(context);
          bool live;
          try {
            live = await context.run(() => check(room)).timeout(timeout);
          } catch (error) {
            context.cancel();
            if (timeout == remaining &&
                (error is TimeoutException ||
                    error is CoreError &&
                        error.kind == CoreErrorKind.timeout)) {
              deadline = true;
            }
            final kind = PlatformRecovery.classify(error);
            if (!expired() || kind == CoreErrorKind.timeout) {
              platform['error'] = kind.name;
              if (timeout != remaining) recovery.failed(site, revision, error);
              platform['backoff'] = recovery.snapshot(site);
            }
            continue;
          } finally {
            requests.remove(context);
          }
          if (expired()) break;
          recovery.succeeded(site);
          platform.remove('backoff');
          await serialize(() async {
            if (expired()) return;
            final latest = await store.readConfig();
            if (!latest.contains(room) ||
                latest.credentialRevision(site) != revision ||
                expired())
              return;
            final previous = statuses[room.id] as Map?;
            final time = _now().toUtc().toIso8601String();
            final notify =
                previous?['generation'] == room.generation &&
                previous?['live'] == false &&
                live;
            statuses[room.id] = {
              'generation': room.generation,
              'live': live,
              'lastSuccess': time,
            };
            confirmed[room.id] = revision;
            state['lastCheck'] = time;
            platform['lastSuccess'] = time;
            platform['succeeded'] = (platform['succeeded'] as int) + 1;
            if (!notify) {
              await recordWithoutAlert();
              return;
            }
            final now = _now();
            final quiet = latest.quietHours;
            final activeUntil = quiet?.activeUntil(now);
            final snoozed = latest.preferenceFor(room).isSnoozed(now);
            final event = <String, dynamic>{
              'room': room.toJson(),
              'time': time,
              'result': snoozed
                  ? 'snoozed'
                  : activeUntil == null
                  ? 'attempted'
                  : 'quiet',
            };
            history.add(event);
            trimHistory();
            if (snoozed || activeUntil != null) {
              if (!snoozed && quiet!.summary) {
                deferred[room.id] = {
                  'generation': room.generation,
                  'until': activeUntil!.toUtc().toIso8601String(),
                };
              }
              await recordWithoutAlert();
              return;
            }
            // Commit before asking Android to display: a failure before this
            // commit can be retried. An interruption after it may drop the
            // alert, but must not replay a possibly displayed notification.
            await flush();
            if (expired()) return;
            final delivery = await store.readConfig();
            if (!delivery.contains(room) ||
                delivery.credentialRevision(site) != revision ||
                expired() ||
                delivery.preferenceFor(room).isSnoozed(_now()) ||
                delivery.quietHours?.activeUntil(_now()) != null)
              return;
            try {
              await show(room);
              event['result'] = 'shown';
            } catch (_) {
              event['result'] = 'failed';
              return;
            } finally {
              if (!(await store.readConfig()).contains(room))
                await cancel(room);
            }
          });
        }
      }

      await Future.wait([
        for (final site in supportedSites)
          if (config.rooms.any((room) => room.siteId == site))
            poll(
              site,
              config.rooms.where((room) => room.siteId == site).toList(),
            ),
      ]);
      if (deferred.isNotEmpty) {
        await serialize(() async {
          final now = _now();
          final latest = await store.readConfig();
          final rooms = {for (final room in latest.rooms) room.id: room};
          final summary = <NotificationSubscription>[];
          deferred.removeWhere((id, raw) {
            final room = rooms[id];
            final entry = raw as Map;
            final until = DateTime.tryParse(entry['until']?.toString() ?? '');
            if (room == null ||
                room.generation != entry['generation'] ||
                until == null ||
                now.difference(until) > const Duration(hours: 24) ||
                latest.preferenceFor(room).isSnoozed(now))
              return true;
            if (now.isBefore(until) ||
                confirmed[id] != latest.credentialRevision(room.siteId) ||
                expired() ||
                latest.quietHours?.activeUntil(now) != null)
              return false;
            if ((statuses[id] as Map?)?['live'] == true) {
              summary.add(room);
            }
            return true;
          });
          if (summary.isEmpty ||
              latest.quietHours?.summary != true ||
              showSummary == null)
            return;
          history.add({
            'result': 'summary',
            'count': summary.length,
            'time': now.toUtc().toIso8601String(),
          });
          trimHistory();
          // Use the same commit-before-display contract as a room alert.
          await flush();
          if (expired()) return;
          final delivery = await store.readConfig();
          final count = summary
              .where(
                (room) =>
                    delivery.contains(room) &&
                    confirmed[room.id] ==
                        delivery.credentialRevision(room.siteId) &&
                    !delivery.preferenceFor(room).isSnoozed(_now()),
              )
              .length;
          if (count > 0 &&
              !expired() &&
              delivery.quietHours?.activeUntil(_now()) == null &&
              delivery.quietHours?.summary == true) {
            try {
              await showSummary!(count);
            } catch (_) {
              // The same summary will not replay after a failed delivery.
            }
          }
        });
      }
      await serialize(flush);
    } finally {
      budgetTimer.cancel();
      flushTimer?.cancel();
      for (final request in requests) {
        request.cancel();
      }
    }
  }
}
