import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show CoreErrorKind, sanitizeDiagnosticMessage;

class Log {
  static LogFileWriter? logFileWriter;
  static void initWriter() {
    logFileWriter = LogFileWriter();
  }

  static void disposeWriter() {
    logFileWriter?.close();
    logFileWriter = null;
  }

  static void writeLog(content, [Level level = Level.info]) {
    logFileWriter?.write(
      "[${level.name.toUpperCase()}] $_currentTime：${sanitizeDiagnosticMessage(content)}",
    );
  }

  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static void addDebugLog(String content, Color? color) {
    if (kReleaseMode) {
      return;
    }
    if (content.contains("请求响应")) {
      content = content.split("\n").join('\n💡 ');
    }
    try {
      debugLogs.insert(
        0,
        DebugLogModel(
          DateTime.now(),
          sanitizeDiagnosticMessage(content),
          color: color,
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
  }

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

  static void d(String message, [bool writeFile = true]) {
    message = sanitizeDiagnosticMessage(message);
    addDebugLog(message, Colors.orange);
    logger.d("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.debug);
    }
  }

  static void i(String message, [bool writeFile = true]) {
    message = sanitizeDiagnosticMessage(message);
    addDebugLog(message, Colors.blue);
    logger.i("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.info);
    }
  }

  static void e(
    String message,
    StackTrace stackTrace, [
    bool writeFile = true,
  ]) {
    message = sanitizeDiagnosticMessage(message);
    stackTrace = StackTrace.fromString(
      sanitizeDiagnosticMessage(stackTrace.toString()),
    );
    addDebugLog('$message\r\n\r\n$stackTrace', Colors.red);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
    if (writeFile) {
      writeLog("$message\n$stackTrace", Level.error);
    }
  }

  static void w(String message, [bool writeFile = true]) {
    message = sanitizeDiagnosticMessage(message);
    addDebugLog(message, Colors.pink);
    logger.w("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.warning);
    }
  }

  static void logPrint(dynamic obj, [bool writeFile = true]) {
    final message = sanitizeDiagnosticMessage(obj);
    addDebugLog(message, Colors.red);
    if (writeFile) {
      writeLog(message, Level.info);
    }
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(message);
    }
  }

  static String get _currentTime => Utils.timeFormat.format(DateTime.now());

  static void platformFailure(CoreErrorKind kind) {
    logFileWriter?.write('[PLATFORM] ${kind.name}');
  }

  static String diagnosticSummary(
    Iterable<String> lines, {
    required String version,
    required String platform,
    DateTime? now,
  }) {
    const levels = ['TRACE', 'DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'];
    final counts = {for (final level in levels) level: 0};
    final errors = {for (final kind in CoreErrorKind.values) kind.name: 0};
    for (final line in lines) {
      if (line.startsWith('[PLATFORM] ')) {
        final name = line.substring('[PLATFORM] '.length).trim();
        if (errors.containsKey(name)) errors[name] = errors[name]! + 1;
        continue;
      }
      for (final level in levels) {
        if (line.startsWith('[$level] ')) {
          counts[level] = counts[level]! + 1;
          break;
        }
      }
    }
    return [
      'Simple Live $version',
      'Platform: $platform',
      'Generated: ${(now ?? DateTime.now()).toUtc().toIso8601String()}',
      for (final level in levels) '$level: ${counts[level]}',
      for (final entry in errors.entries)
        if (entry.value > 0) '${entry.key}: ${entry.value}',
    ].join('\n');
  }
}

class LogFileWriter {
  late String fileName;
  LogFileWriter() {
    var dt = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    fileName = "$dt.log";
    initFile();
  }
  IOSink? fileWriter;
  void initFile() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    var logFile = File("${logDir.path}/$fileName");
    fileWriter = logFile.openWrite(mode: FileMode.append);
    writeSystemInfo();
  }

  void write(String content) {
    fileWriter?.write(content);
    fileWriter?.write("\r\n");
  }

  Future close() async {
    await fileWriter?.close();
  }

  void writeSystemInfo() async {
    write("System Info:");
    write("Current Time: ${DateTime.now()}");
    write("Platform: ${Platform.operatingSystem}");
    write("Version: ${Platform.operatingSystemVersion}");
    write(
      "App Version: ${Utils.packageInfo.version}+${Utils.packageInfo.buildNumber}",
    );
    write("End System Info");
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
