import 'core_error.dart';
import 'request_context.dart';

Never invalidPlayback(String site) => throw CoreError(
  '平台播放响应格式异常',
  kind: CoreErrorKind.schemaChanged,
  site: site,
);

Map playbackMap(dynamic value, String site) =>
    value is Map ? value : invalidPlayback(site);

List playbackList(dynamic value, String site) =>
    value is List ? value : invalidPlayback(site);

Map playbackData(dynamic response, String site, {String codeKey = 'code'}) {
  final root = playbackMap(response, site);
  final code = root[codeKey];
  if (code is! int) invalidPlayback(site);
  if (code != 0) {
    throw CoreError(
      '平台拒绝播放请求',
      site: site,
      kind: switch (code) {
        -101 || 401 || 403 => CoreErrorKind.authRequired,
        -412 || 429 => CoreErrorKind.rateLimited,
        _ => CoreErrorKind.noPlayableSource,
      },
    );
  }
  return playbackMap(root['data'], site);
}

String playbackUrl(dynamic value, String site) {
  if (value is! String) invalidPlayback(site);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    invalidPlayback(site);
  }
  return value;
}

/// Limit provider pressure, retain server ordering, and keep usable candidates
/// when another CDN fails. Cancellation still belongs to the whole attempt.
Future<List<String>> collectPlaybackUrls<T>(
  List<T> candidates,
  Future<String> Function(T) load,
  String site,
) async {
  Future<List<String>> collect() async {
    final results = List<String?>.filled(candidates.length, null);
    final failures = <CoreError>[];
    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length) {
        RequestContext.current?.check();
        final index = next++;
        try {
          results[index] = playbackUrl(await load(candidates[index]), site);
        } on CoreError catch (error) {
          if (error.kind == CoreErrorKind.cancelled) rethrow;
          failures.add(error);
        } catch (_) {
          failures.add(
            CoreError(
              '平台播放响应格式异常',
              kind: CoreErrorKind.schemaChanged,
              site: site,
            ),
          );
        }
      }
    }

    await Future.wait(
      List.generate(candidates.length > 1 ? 2 : 1, (_) => worker()),
    );
    final urls = results.whereType<String>().toSet().toList();
    if (urls.isEmpty) {
      throw CoreError(
        '没有可用播放线路',
        kind: CoreErrorKind.noPlayableSource,
        site: site,
        failures: List.unmodifiable(failures),
      );
    }
    return urls;
  }

  return RequestContext.current == null
      ? RequestContext().run(collect)
      : collect();
}
