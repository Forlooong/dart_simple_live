import 'package:dio/dio.dart';

enum CoreErrorKind {
  unknown,
  cancelled,
  timeout,
  transport,
  authRequired,
  rateLimited,
  schemaChanged,
  noPlayableSource,
  offline,
}

class CoreError extends Error {
  /// 错误码
  final int statusCode;

  /// 错误信息
  final String message;
  final CoreErrorKind kind;
  final String? site;
  final List<CoreError> failures;

  bool get retriable =>
      kind == CoreErrorKind.timeout ||
      kind == CoreErrorKind.transport ||
      (kind == CoreErrorKind.noPlayableSource &&
          failures.isNotEmpty &&
          failures.every((failure) => failure.retriable));

  CoreError(
    this.message, {
    this.statusCode = 0,
    this.kind = CoreErrorKind.unknown,
    this.site,
    this.failures = const [],
  });

  factory CoreError.fromDio(DioException error, {String? site}) {
    if (error.type == DioExceptionType.cancel && error.error is CoreError) {
      return error.error as CoreError;
    }
    final status = error.response?.statusCode ?? 0;
    final kind = switch (error.type) {
      DioExceptionType.cancel => CoreErrorKind.cancelled,
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => CoreErrorKind.timeout,
      DioExceptionType.badResponse when status == 401 || status == 403 =>
        CoreErrorKind.authRequired,
      DioExceptionType.badResponse when status == 429 =>
        CoreErrorKind.rateLimited,
      _ when error.error is FormatException => CoreErrorKind.schemaChanged,
      _ => CoreErrorKind.transport,
    };
    return CoreError(
      switch (kind) {
        CoreErrorKind.cancelled => '请求已取消',
        CoreErrorKind.timeout => '请求超时',
        CoreErrorKind.authRequired => '需要登录或访问权限',
        CoreErrorKind.rateLimited => '请求过于频繁，请稍后重试',
        CoreErrorKind.schemaChanged => '平台响应格式异常',
        _ => '连接服务器失败，请稍后再试',
      },
      statusCode: status,
      kind: kind,
      site: site,
    );
  }
  @override
  String toString() {
    if (statusCode != 0) {
      return statusCodeToString(statusCode);
    }

    return message;
  }

  String statusCodeToString(int statusCode) {
    switch (statusCode) {
      case 400:
        return "错误的请求(400)";
      case 401:
        return "无权限访问资源(401)";
      case 403:
        return "无权限访问资源(403)";
      case 404:
        return "服务器找不到请求的资源(404)";
      case 429:
        return "请求过于频繁，请稍后重试(429)";
      case 500:
        return "服务器出现错误(500)";
      case 502:
        return "服务器出现错误(502)";
      case 503:
        return "服务器出现错误(503)";
      default:
        return "连接服务器失败，请稍后再试($statusCode)";
    }
  }
}
