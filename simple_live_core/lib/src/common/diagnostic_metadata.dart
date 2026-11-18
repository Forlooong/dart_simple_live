final _url = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
final _secretKey = RegExp(
  r'\b(cookie|set-cookie|authorization|token|access[_-]?token|refresh[_-]?token|password|passwd|kwebdavpassword|pairingkey|pairingcode|sessdata|bili_jct)\b\s*["\x27]?\s*[:=]|\bbearer\s+\S+',
  caseSensitive: false,
);

String sanitizeDiagnosticMessage(Object? value) {
  if (value is! String) return value?.runtimeType.toString() ?? 'null';
  return value
      .split('\n')
      .map((line) {
        if (_secretKey.hasMatch(line) || line.contains('simplelive://'))
          return '已省略敏感诊断内容';
        return line.replaceAllMapped(_url, (match) {
          final uri = Uri.tryParse(match[0]!);
          return uri == null || uri.host.isEmpty
              ? '[地址]'
              : '${uri.scheme}://${uri.host}';
        });
      })
      .join('\n');
}
