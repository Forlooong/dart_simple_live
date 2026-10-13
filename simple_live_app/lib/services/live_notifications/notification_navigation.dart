import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:simple_live_app/routes/route_path.dart';

final liveNotificationNavigationObserver = NotificationNavigationObserver();

/// Tracks actual route objects, including live rooms finishing their exit
/// animation. A GetX controller can outlive a pop until that animation ends.
class NotificationNavigationObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];
  final Map<Route<dynamic>, Future<void>> _retiringLiveRooms = {};

  bool _isLiveRoom(Route<dynamic> route) =>
      Uri.tryParse(route.settings.name ?? '')?.path ==
      RoutePath.kLiveRoomDetail;

  Route<dynamic>? get liveRoomRoute {
    for (final route in _routes.reversed) {
      if (_isLiveRoom(route)) return route;
    }
    return null;
  }

  /// Returns false without changing the stack if its live room was already
  /// popped. Query parameters in the route name do not affect the match.
  bool revealLiveRoom() {
    final route = liveRoomRoute;
    if (route == null || navigator == null) return false;
    navigator!.popUntil((candidate) => identical(candidate, route));
    return true;
  }

  Future<void> removeLiveRoom() async {
    final route = liveRoomRoute;
    if (route != null) navigator?.removeRoute(route);
    await waitForRetiringLiveRooms();
  }

  Future<void> waitForRetiringLiveRooms() async {
    while (_retiringLiveRooms.isNotEmpty) {
      await Future.wait(_retiringLiveRooms.values.toList());
    }
  }

  void _retire(Route<dynamic> route) {
    if (!_isLiveRoom(route) || route is! TransitionRoute<dynamic>) return;
    final completed = route.completed.then<void>((_) {});
    _retiringLiveRooms[route] = completed;
    unawaited(completed.then((_) {
      _retiringLiveRooms.remove(route);
    }));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _retire(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _retire(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) _routes.removeAt(index);
    if (newRoute != null) {
      _routes.insert(index < 0 ? _routes.length : index, newRoute);
    }
    if (oldRoute != null) _retire(oldRoute);
  }
}
