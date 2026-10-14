import 'dart:isolate';

/// Validate manual additions off the UI isolate. Existing/imported rules remain
/// stored so their original text and native compatibility diagnostics are kept.
Future<String?> validateDanmakuRule(String value) async {
  if (value.trim().isEmpty) return '请输入关键词';
  final regex =
      value.length > 2 && value.startsWith('/') && value.endsWith('/');
  final pattern = regex ? value.substring(1, value.length - 1) : value;
  if (pattern.length > 4096) return '屏蔽词过长，最多支持 4096 个字符单元';
  if (!regex) return null;
  return Isolate.run(() {
    try {
      RegExp(pattern);
      return null;
    } on FormatException catch (error) {
      return '正则表达式无效：${error.message}';
    }
  });
}
