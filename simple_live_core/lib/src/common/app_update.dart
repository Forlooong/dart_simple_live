import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

const updateRepository = 'Forlooong/dart_simple_live';
const updateReleasePage = 'https://github.com/$updateRepository/releases';
const updateManifestUrl =
    '$updateReleasePage/latest/download/update.json';

class UpdatePackage {
  final String platform, arch, url, sha256, packageId, certificate;
  final int build, size, minSdk;
  UpdatePackage(Map<String, dynamic> value)
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
    if (uri.scheme != 'https' || uri.host != 'github.com' ||
        !uri.path.startsWith('/$updateRepository/releases/download/') ||
        uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        size <= 0 || size > 2147483648 || build <= 0) {
      throw const FormatException('无效的更新安装包');
    }
  }
}

class AppUpdate {
  final String version, notes;
  final List<UpdatePackage> packages;
  AppUpdate(Map<String, dynamic> value)
      : version = value['version'] as String,
        notes = value['notes'] as String,
        packages = (value['packages'] as List)
            .map((item) => UpdatePackage(Map<String, dynamic>.from(item as Map)))
            .toList();

  UpdatePackage? select({required String platform, required String arch,
    required int installedBuild, String packageId = '', String certificate = '',
    int sdk = 0}) {
    final matches = packages.where((p) => p.platform == platform &&
        (p.arch == arch || p.arch == 'universal') && p.build > installedBuild &&
        (platform != 'android' || (p.packageId == packageId &&
          p.certificate == certificate.toLowerCase() && p.minSdk <= sdk))).toList();
    if (matches.length > 1) throw const FormatException('更新安装包不唯一');
    return matches.isEmpty ? null : matches.single;
  }
}

class AppUpdateClient {
  final Dio dio;
  AppUpdateClient({Dio? client}) : dio = client ?? Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  Future<AppUpdate?> check(String app) async {
    try {
      final response = await dio.get<String>(updateManifestUrl,
          options: Options(responseType: ResponseType.plain));
      final body = response.data!;
      if (body.length > 262144) throw const FormatException('更新信息过大');
      final value = jsonDecode(body) as Map<String, dynamic>;
      if (value['schemaVersion'] != 1 || value['repository'] != updateRepository) {
        throw const FormatException('不支持的更新来源');
      }
      return AppUpdate(Map<String, dynamic>.from(value[app] as Map));
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<File> download(UpdatePackage package, Directory directory,
      {required CancelToken cancel, required void Function(int, int) progress}) async {
    await directory.create(recursive: true);
    final name = Uri.parse(package.url).pathSegments.last;
    if (!RegExp(r'^[A-Za-z0-9_.+\-]+$').hasMatch(name)) {
      throw const FormatException('无效的安装包名称');
    }
    final target = File('${directory.path}/$name');
    final partial = File('${target.path}.part');
    // Keep only this download; older installers are temporary artifacts.
    await for (final entry in directory.list()) {
      if (entry is File && entry.path != target.path && entry.path != partial.path) {
        await entry.delete();
      }
    }
    try {
      await dio.download(package.url, partial.path, cancelToken: cancel,
          onReceiveProgress: (received, total) {
            if (received > package.size) cancel.cancel('安装包大小不符');
            progress(received, package.size);
          });
      if (cancel.isCancelled || await partial.length() != package.size ||
          (await sha256.bind(partial.openRead()).first).toString() != package.sha256) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}
