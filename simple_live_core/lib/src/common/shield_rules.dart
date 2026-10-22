/// Shared import limits match the native filter's UTF-16 rule budgets.
List<String> validateShieldRules(Iterable<dynamic> data) {
  final rules = <String>{};
  var bytes = 0;
  for (final raw in data) {
    if (raw is! String || raw.trim().isEmpty) {
      throw const FormatException('屏蔽规则必须为非空字符串');
    }
    if (!rules.add(raw)) continue;
    final regex = raw.length > 2 && raw.startsWith('/') && raw.endsWith('/');
    final units = raw.length - (regex ? 2 : 0);
    bytes += units * 2;
    if (rules.length > 2000 || units > 4096 || bytes > 1024 * 1024) {
      throw const FormatException('屏蔽规则超过数量、单条长度或总长度限制');
    }
  }
  return rules.toList();
}
