import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:simple_live_core/simple_live_core.dart';

typedef AggregateSearchResult = ({
  String roomId,
  String author,
  String? title,
  bool? live,
  Uri? profile,
  String? source,
  String? accountId,
});

Uri douyinWebSearchUri(String keyword, {required bool anchors}) => Uri.https(
  'www.douyin.com',
  '/search/$keyword',
  {'type': anchors ? 'user' : 'live'},
);

class PlatformSearchResults {
  final results = <String, AggregateSearchResult>{};
  int nextPage = 1;
  bool hasMore = true;
  bool loading = false;
  final _failedPages = SplayTreeMap<int, CoreErrorKind>();
  int? get retryPage => _failedPages.firstKey();
  CoreErrorKind? get failure => _failedPages[retryPage];
}

class AggregateSearch extends ChangeNotifier {
  AggregateSearch(
    this.sites, {
    PlatformRecovery? recovery,
    this.localDouyinResults,
  }) : _recovery = recovery ?? PlatformRecovery();

  final Map<String, LiveSite> sites;
  final PlatformRecovery _recovery;
  final Iterable<AggregateSearchResult> Function(String)? localDouyinResults;
  final ordered = <(String, String)>[];
  String? selectedPlatform;
  final platforms = <String, PlatformSearchResults>{};
  final _requests = <String, RequestContext>{};
  String keyword = '';
  bool anchors = false;
  bool active = false;
  bool _disposed = false;

  bool _visible(String id) =>
      selectedPlatform == null || selectedPlatform == id;

  void reset(String value, {required bool searchAnchors}) {
    _cancel();
    keyword = value.trim();
    ordered.clear();
    anchors = searchAnchors;
    platforms
      ..clear()
      ..addEntries(
        sites.keys.map((id) => MapEntry(id, PlatformSearchResults())),
      );
    notifyListeners();
    if (active) _start();
  }

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    if (active) {
      _start();
    } else {
      _cancel();
    }
  }

  void selectPlatform(String? id) {
    if (selectedPlatform == id) return;
    selectedPlatform = id;
    for (final entry in _requests.entries.toList()) {
      if (_visible(entry.key)) continue;
      _requests.remove(entry.key);
      entry.value.cancel();
      platforms[entry.key]?.loading = false;
    }
    _start();
    notifyListeners();
  }

  void _store(String id, AggregateSearchResult item) {
    final state = platforms[id]!;
    if (item.roomId == 'null') return;
    final key = item.roomId.isNotEmpty ? item.roomId : item.profile?.path;
    if (key == null) return;
    final roomMatch = state.results.containsKey(key)
        ? key
        : item.roomId.isEmpty
        ? null
        : state.results.entries
              .where((entry) => entry.value.roomId == item.roomId)
              .firstOrNull
              ?.key;
    final profileMatch = item.profile == null
        ? null
        : state.results.entries
              .where(
                (entry) =>
                    entry.value.profile == item.profile &&
                    (item.roomId.isEmpty || entry.value.roomId.isEmpty),
              )
              .firstOrNull
              ?.key;
    final target = roomMatch ?? profileMatch ?? key;
    final previous = state.results[target];
    if (profileMatch != null &&
        profileMatch != target &&
        state.results[profileMatch]!.roomId.isEmpty) {
      state.results.remove(profileMatch);
      ordered.remove((id, profileMatch));
    }
    if (previous == null) ordered.add((id, target));
    state.results[target] = (
      roomId: item.roomId.isEmpty ? previous?.roomId ?? '' : item.roomId,
      author: item.author.isEmpty ? previous?.author ?? '' : item.author,
      title: item.title ?? previous?.title,
      live: item.live ?? previous?.live,
      profile: item.profile ?? previous?.profile,
      source: item.source,
      accountId: item.accountId ?? previous?.accountId,
    );
  }

  void _start() {
    if (!active || keyword.isEmpty) return;
    for (final id in sites.keys) {
      final state = platforms[id];
      if (_visible(id) && state?.nextPage == 1 && state?.failure == null) {
        if (id == 'douyin' && state!.results.isEmpty) {
          for (final item
              in localDouyinResults?.call(keyword) ??
                  const <AggregateSearchResult>[]) {
            _store(id, item);
          }
        }
        load(id);
      }
    }
  }

  void _cancel() {
    for (final entry in _requests.entries) {
      entry.value.cancel();
      platforms[entry.key]?.loading = false;
    }
    _requests.clear();
  }

  Future<void> load(String id, {bool retry = false}) async {
    final state = platforms[id];
    final site = sites[id];
    if (_disposed ||
        !active ||
        keyword.isEmpty ||
        state == null ||
        site == null ||
        !_visible(id) ||
        (!state.hasMore && !(retry && state.retryPage != null)) ||
        state.loading) {
      return;
    }
    final version = site.statusConfigurationVersion;
    final recoveryKey = id != 'douyin'
        ? id
        : anchors
        ? 'douyin:anchors'
        : DouyinSite.directSearchRoomId(keyword) != null
        ? 'douyin:direct'
        : 'douyin:rooms';
    final block = _recovery.blocked(recoveryKey, version);
    final page = retry ? state.retryPage ?? state.nextPage : state.nextPage;
    if (block != null) {
      state._failedPages[page] = block;
      notifyListeners();
      return;
    }
    const timeout = Duration(seconds: 20);
    final context = RequestContext(timeout: timeout);
    _requests[id] = context;
    state.loading = true;
    notifyListeners();
    final term = keyword;
    final searchAnchors = anchors;
    bool current() => !_disposed && identical(_requests[id], context);
    try {
      final (items, more, partial) = await context
          .run(() async {
            if (searchAnchors) {
              final result = await site.searchAnchors(term, page: page);
              return (
                result.items.map<AggregateSearchResult>(
                  (item) => (
                    roomId: item.roomId,
                    profile: item.profile,
                    source: null,
                    accountId: item.accountId,
                    author: item.userName,
                    title: item.roomTitle,
                    live: item.statusKnown
                        ? item.liveStatus
                        : site.peekRoomStatus(item.roomId)?.live,
                  ),
                ),
                result.hasMore,
                null as CoreError?,
              );
            }
            final result = await site.searchRooms(term, page: page);
            return (
              result.items.map<AggregateSearchResult>(
                (item) => (
                  roomId: item.roomId,
                  profile: item.profile,
                  source: null,
                  accountId: item.accountId,
                  author: item.userName,
                  title: item.title,
                  live:
                      item.liveStatus ?? site.peekRoomStatus(item.roomId)?.live,
                ),
              ),
              result.hasMore,
              result.partialFailure,
            );
          })
          .timeout(timeout);
      if (!current()) return;
      if (site.statusConfigurationVersion != version) {
        state._failedPages[page] = CoreErrorKind.authRequired;
        return;
      }
      for (final item in items) {
        _store(id, item);
      }
      if (page == state.nextPage) {
        state.hasMore = more;
        if (partial == null || more) state.nextPage++;
      }
      if (partial == null) {
        state._failedPages.remove(page);
        _recovery.succeeded(recoveryKey);
      } else {
        state._failedPages[page] = partial.kind;
      }
    } catch (error) {
      context.cancel();
      if (!current()) return;
      _recovery.failed(recoveryKey, version, error);
      state._failedPages[page] = PlatformRecovery.classify(error);
    } finally {
      if (current()) {
        _requests.remove(id);
        state.loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }
}
