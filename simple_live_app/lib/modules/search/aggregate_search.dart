import 'package:flutter/foundation.dart';
import 'package:simple_live_core/simple_live_core.dart';

typedef AggregateSearchResult = ({
  String roomId,
  String author,
  String? title,
  bool? live,
  String? source,
});

class PlatformSearchResults {
  final results = <String, AggregateSearchResult>{};
  int nextPage = 1;
  bool hasMore = true;
  bool loading = false;
  CoreErrorKind? failure;
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

  bool supportsRemote(String id) => !anchors || id != 'douyin';

  bool _visible(String id) =>
      selectedPlatform == null || selectedPlatform == id;

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
    final roomId = item.roomId;
    if (roomId.isEmpty || roomId == 'null') return;
    final results = platforms[id]!.results;
    if (!results.containsKey(roomId)) ordered.add((id, roomId));
    results[roomId] = item;
  }

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

  void _start() {
    if (!active || keyword.isEmpty) return;
    for (final id in sites.keys) {
      final state = platforms[id];
      if (!_visible(id) ||
          state == null ||
          state.nextPage != 1 ||
          state.failure != null ||
          state.loading) {
        continue;
      }
      if (id == 'douyin' && state.results.isEmpty) {
        for (final item
            in localDouyinResults?.call(keyword) ??
                const <AggregateSearchResult>[]) {
          _store(id, item);
        }
      }
      if (supportsRemote(id)) load(id);
    }
    notifyListeners();
  }

  void _cancel() {
    for (final entry in _requests.entries) {
      entry.value.cancel();
      platforms[entry.key]?.loading = false;
    }
    _requests.clear();
  }

  Future<void> load(String id) async {
    final state = platforms[id];
    final site = sites[id];
    if (_disposed ||
        !active ||
        keyword.isEmpty ||
        state == null ||
        site == null ||
        !_visible(id) ||
        !supportsRemote(id) ||
        !state.hasMore ||
        state.loading) {
      return;
    }
    final version = site.statusConfigurationVersion;
    final block = _recovery.blocked(id, version);
    if (block != null) {
      state.failure = block;
      notifyListeners();
      return;
    }
    const timeout = Duration(seconds: 20);
    final context = RequestContext(timeout: timeout);
    _requests[id] = context;
    state.loading = true;
    state.failure = null;
    notifyListeners();
    final term = keyword;
    final page = state.nextPage;
    final searchAnchors = anchors;
    bool current() => !_disposed && identical(_requests[id], context);
    try {
      final (items, more) = await context
          .run(() async {
            if (searchAnchors) {
              final result = await site.searchAnchors(term, page: page);
              return (
                result.items.map<AggregateSearchResult>(
                  (item) => (
                    roomId: item.roomId,
                    source: null,
                    author: item.userName,
                    title: item.roomTitle,
                    live: item.statusKnown
                        ? item.liveStatus
                        : site.peekRoomStatus(item.roomId)?.live,
                  ),
                ),
                result.hasMore,
              );
            }
            final result = await site.searchRooms(term, page: page);
            return (
              result.items.map<AggregateSearchResult>(
                (item) => (
                  roomId: item.roomId,
                  source: null,
                  author: item.userName,
                  title: item.title,
                  live:
                      item.liveStatus ?? site.peekRoomStatus(item.roomId)?.live,
                ),
              ),
              result.hasMore,
            );
          })
          .timeout(timeout);
      if (!current()) return;
      if (site.statusConfigurationVersion != version) {
        state.failure = CoreErrorKind.authRequired;
        return;
      }
      for (final item in items) {
        _store(id, item);
      }
      state.hasMore = more;
      state.nextPage++;
      _recovery.succeeded(id);
    } catch (error) {
      context.cancel();
      if (!current()) return;
      _recovery.failed(id, version, error);
      state.failure = PlatformRecovery.classify(error);
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
