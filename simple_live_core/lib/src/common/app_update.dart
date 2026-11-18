import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

const updateRepository = 'Forlooong/dart_simple_live';
const updateReleasePage = 'https://github.com/$updateRepository/releases';
const updateManifestUrl = '$updateReleasePage/latest/download/update.json';
const _releaseApi = 'https://api.github.com/repos/$updateRepository/releases';
const _assetPrefix = '/$updateRepository/releases/download/';
const _manifestLimit = 262144;

Uri updateReleaseUri(String? tag) => tag == null
    ? Uri.parse(updateReleasePage)
    : Uri.parse('$updateReleasePage/tag/${Uri.encodeComponent(tag)}');

int? installedUpdateBuild(String value, {required String platform}) {
  final number = int.tryParse(value);
  if (number != null && number > 0) return number;
  if (platform == 'ios' || platform == 'macos') {
    final appleBuild = RegExp(r'^\d+\.\d+\.\d+\.(\d+)$').firstMatch(value);
    if (appleBuild != null) return int.tryParse(appleBuild[1]!);
  }
  return null;
}

class UpdatePackage {
  final String platform, arch, url, sha256, packageId, certificate;
  final int build, size, minSdk;
  final int? assetId;
  UpdatePackage(Map<String, dynamic> value, {this.assetId})
    : platform = value['platform'] as String,
      arch = value['arch'] as String,
      url = value['url'] as String,
      sha256 = value['sha256'] as String,
      packageId = value['packageId'] as String? ?? '',
      certificate = value['certificate'] as String? ?? '',
      build = value['build'] as int,
      size = value['size'] as int,
      minSdk = value['minSdk'] as int? ?? 0 {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.port != 443 ||
        !uri.path.startsWith(_assetPrefix) ||
        uri.pathSegments.length != 6 ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        size <= 0 ||
        size > 2147483648 ||
        build <= 0) {
      throw const FormatException('无效的更新安装包');
    }
  }

  String get releaseTag => Uri.parse(url).pathSegments[4];
}

class AppUpdate {
  final String version, notes;
  final List<UpdatePackage> packages;
  final String? tag;
  final DateTime? publishedAt;

  AppUpdate(
    Map<String, dynamic> value, {
    String? releaseNotes,
    this.tag,
    this.publishedAt,
    Map<String, int> assetIds = const {},
  }) : version = value['version'] as String,
       notes = releaseNotes ?? (value['notes'] as String? ?? ''),
       packages = (value['packages'] as List)
           .map(
             (item) => UpdatePackage(
               Map<String, dynamic>.from(item as Map),
               assetId:
                   assetIds[Uri.parse(item['url'] as String).pathSegments.last],
             ),
           )
           .toList() {
    if (tag != null && packages.any((package) => package.releaseTag != tag)) {
      throw const FormatException('更新清单与发布版本不一致');
    }
  }

  Uri get releaseUri =>
      updateReleaseUri(tag ?? packages.firstOrNull?.releaseTag);

  UpdatePackage? select({
    required String platform,
    required String arch,
    required int installedBuild,
    String packageId = '',
    String certificate = '',
    int sdk = 0,
  }) {
    final matches = packages
        .where(
          (p) =>
              p.platform == platform &&
              (p.arch == arch || p.arch == 'universal') &&
              p.build > installedBuild &&
              (platform != 'android' ||
                  (p.packageId == packageId &&
                      p.certificate == certificate.toLowerCase() &&
                      p.minSdk <= sdk)),
        )
        .toList();
    if (matches.length > 1) throw const FormatException('更新安装包不唯一');
    return matches.isEmpty ? null : matches.single;
  }
}

class AppUpdateClient {
  final Dio dio;
  AppUpdateClient({Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'User-Agent': 'Simple-Live-Updater'},
            ),
          );

  static final _embedded = RegExp(
    r'<!-- simple-live-update-manifest:v1\s+([A-Za-z0-9+/=]+)\s*-->',
  );
  static Options _metadata(String accept) => Options(
    responseType: ResponseType.plain,
    headers: {'Accept': accept},
    receiveTimeout: const Duration(seconds: 12),
  );

  Future<AppUpdate?> check(String app) async {
    Object? apiFailure;
    try {
      final release = await _checkApi(app);
      if (release != null) return release;
    } on DioException catch (error) {
      apiFailure = error;
    } on FormatException catch (error) {
      apiFailure = error;
    }
    try {
      final result = await dio.get<String>(
        updateManifestUrl,
        options: _metadata('application/octet-stream'),
      );
      return _manifest(app, result.data);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        if (apiFailure != null) throw apiFailure;
        return null;
      }
      if (apiFailure is FormatException) throw apiFailure;
      rethrow;
    }
  }

  Future<AppUpdate?> _checkApi(String app) async {
    final Response<String> response;
    try {
      response = await dio.get<String>(
        '$_releaseApi/latest',
        options: _metadata('application/vnd.github+json'),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
    final release = _object(response.data, 'GitHub 发布信息');
    final tag = release['tag_name'];
    final assets = release['assets'];
    if (tag is! String || tag.isEmpty || assets is! List) {
      throw const FormatException('GitHub 发布信息缺少版本或附件');
    }
    final ids = <String, int>{};
    String? digest;
    for (final item in assets.whereType<Map>()) {
      final name = item['name'], id = item['id'];
      if (name is! String || id is! int || id <= 0) continue;
      ids[name] = id;
      if (name == 'update.json' && item['digest'] is String) {
        digest = item['digest'] as String;
      }
    }
    final manifestId = ids['update.json'];
    if (manifestId == null) {
      throw const FormatException('此版本缺少更新清单');
    }
    final body = release['body'] is String ? release['body'] as String : '';
    final marker = _embedded.firstMatch(body);
    String? manifest;
    if (marker != null && digest != null) {
      try {
        final bytes = base64Decode(marker[1]!);
        if (bytes.length <= _manifestLimit &&
            'sha256:${sha256.convert(bytes)}' == digest) {
          manifest = utf8.decode(bytes);
        }
      } on FormatException {
        // The attached manifest remains available for legacy releases.
      }
    }
    if (manifest == null) {
      final asset = await dio.get<String>(
        '$_releaseApi/assets/$manifestId',
        options: _metadata('application/octet-stream'),
      );
      manifest = asset.data;
      if (manifest != null &&
          digest != null &&
          'sha256:${sha256.convert(utf8.encode(manifest))}' != digest) {
        throw const FormatException('更新清单校验失败');
      }
    }
    final published = release['published_at'];
    return _manifest(
      app,
      manifest,
      tag: tag,
      assetIds: ids,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      releaseNotes: body.replaceAll(_embedded, '').trim(),
    );
  }

  Map<String, dynamic> _object(String? body, String label) {
    if (body == null || body.length > _manifestLimit) {
      throw FormatException('$label为空或过大');
    }
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw FormatException('$label格式无效');
    }
    return value;
  }

  AppUpdate _manifest(
    String app,
    String? body, {
    String? tag,
    String? releaseNotes,
    DateTime? publishedAt,
    Map<String, int> assetIds = const {},
  }) {
    final value = _object(body, '更新清单');
    if (value['schemaVersion'] != 1 ||
        value['repository'] != updateRepository) {
      throw const FormatException('不支持的更新来源');
    }
    final section = value[app];
    if (section is! Map<String, dynamic>) {
      throw const FormatException('缺少当前应用的更新信息');
    }
    final notes = section['notes'];
    try {
      return AppUpdate(
        section,
        tag: tag,
        publishedAt: publishedAt,
        assetIds: assetIds,
        releaseNotes:
            releaseNotes?.isNotEmpty == true &&
                (notes is! String ||
                    notes.trim().isEmpty ||
                    notes.startsWith('非官方个人维护版本。源码：'))
            ? releaseNotes
            : null,
      );
    } on TypeError {
      throw const FormatException('更新清单字段格式不正确');
    } on StateError {
      throw const FormatException('更新安装包地址不完整');
    }
  }

  Future<File> download(
    UpdatePackage package,
    Directory directory, {
    required CancelToken cancel,
    required void Function(int, int) progress,
  }) async {
    await directory.create(recursive: true);
    final name = Uri.parse(package.url).pathSegments.last;
    if (!RegExp(r'^[A-Za-z0-9_.+\-]+$').hasMatch(name)) {
      throw const FormatException('无效的安装包名称');
    }
    final target = File.fromUri(
      directory.uri.resolve(Uri.encodeComponent(name)),
    );
    final partial = File('${target.path}.part');
    if (cancel.isCancelled) throw cancel.cancelError!;
    if (await target.exists() &&
        await target.length() == package.size &&
        (await sha256.bind(target.openRead()).first).toString() ==
            package.sha256) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      progress(package.size, package.size);
      return target;
    }
    // This app-owned cache holds only temporary update downloads.
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          !{name, '$name.part'}.contains(entry.uri.pathSegments.last)) {
        await entry.delete();
      }
    }
    var oversized = false;
    Future<void> transfer(String url, {Options? options}) => dio.download(
      url,
      partial.path,
      options: options,
      cancelToken: cancel,
      onReceiveProgress: (received, _) {
        if (received > package.size) {
          oversized = true;
          cancel.cancel();
        } else {
          progress(received, package.size);
        }
      },
    );
    try {
      try {
        await transfer(package.url);
      } on DioException {
        if (oversized || cancel.isCancelled || package.assetId == null) rethrow;
        // A new request starts from byte zero and uses the same size and hash.
        progress(0, package.size);
        await transfer(
          '$_releaseApi/assets/${package.assetId}',
          options: Options(headers: {'Accept': 'application/octet-stream'}),
        );
      }
      if (cancel.isCancelled ||
          await partial.length() != package.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              package.sha256) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } on DioException {
      if (oversized) throw const FormatException('安装包大小与更新清单不符');
      rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}
