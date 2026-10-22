import 'package:logger/logger.dart';

import 'core_error.dart';

enum RequestLogType {
  /// 输出安全的请求元数据；不记录请求或响应载荷。
  all,

  /// 简洁的输出
  /// 仅输出请求的源站、响应状态和耗时
  short,

  /// 不输出请求信息
  none,
}

class CoreLog {
  /// 是否启用日志
  static bool enableLog = true;

  /// 请求日志模式
  static RequestLogType requestLogType = RequestLogType.short;

  static Function(Level, String)? onPrintLog;
  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
    ),
  );

  static void d(String message) {
    if (!enableLog) {
      return;
    }
    onPrintLog?.call(Level.debug, message);
    if (onPrintLog == null) {
      logger.d("${DateTime.now().toString()}\n$message");
    }
  }

  static void i(String message) {
    if (!enableLog) {
      return;
    }
    onPrintLog?.call(Level.info, message);
    if (onPrintLog == null) {
      logger.i("${DateTime.now().toString()}\n$message");
    }
  }

  static void e(String message, StackTrace stackTrace) {
    if (!enableLog) {
      return;
    }
    onPrintLog?.call(Level.error, message);
    if (onPrintLog == null) {
      logger.e("${DateTime.now().toString()}\n$message",
          stackTrace: stackTrace);
    }
  }

  static void error(e) {
    if (!enableLog) {
      return;
    }
    final message = e is CoreError ? e.toString() : 'Core operation failed (${e.runtimeType})';
    onPrintLog?.call(Level.error, message);
    if (onPrintLog == null) {
      logger.e(
        "${DateTime.now().toString()}\n$message",
        stackTrace: (e is Error) ? e.stackTrace : StackTrace.current,
      );
    }
  }

  static void w(String message) {
    if (!enableLog) {
      return;
    }
    onPrintLog?.call(Level.warning, message);
    if (onPrintLog == null) {
      logger.w("${DateTime.now().toString()}\n$message");
    }
  }
}
