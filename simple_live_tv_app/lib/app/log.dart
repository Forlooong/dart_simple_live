import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show sanitizeDiagnosticMessage;

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  static void d(String message) {
    logger.d(
      "${DateTime.now().toString()}\n${sanitizeDiagnosticMessage(message)}",
    );
  }

  static void i(String message) {
    logger.i(
      "${DateTime.now().toString()}\n${sanitizeDiagnosticMessage(message)}",
    );
  }

  static void e(String message, StackTrace stackTrace) {
    logger.e(
      "${DateTime.now().toString()}\n${sanitizeDiagnosticMessage(message)}",
      stackTrace: StackTrace.fromString(
        sanitizeDiagnosticMessage(stackTrace.toString()),
      ),
    );
  }

  static void w(String message) {
    logger.w(
      "${DateTime.now().toString()}\n${sanitizeDiagnosticMessage(message)}",
    );
  }

  static void logPrint(dynamic obj) {
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(sanitizeDiagnosticMessage(obj));
    }
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
