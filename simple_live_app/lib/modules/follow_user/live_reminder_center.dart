import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/live_notification_service.dart';
import 'package:simple_live_app/services/live_notifications/notification_subscription.dart';

class LiveReminderCenter extends StatefulWidget {
  const LiveReminderCenter({super.key});

  @override
  State<LiveReminderCenter> createState() => _LiveReminderCenterState();
}

class _LiveReminderCenterState extends State<LiveReminderCenter> {
  final service = LiveNotificationService.instance;
  late var snapshot = service.reminderSnapshot();
  bool busy = false;

  Future<void> reload() async {
    if (!mounted) return;
    setState(() => snapshot = service.reminderSnapshot());
    try {
      await snapshot;
    } catch (_) {
      // FutureBuilder displays the retry action.
    }
  }

  Future<void> edit(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    try {
      await action();
      await reload();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存提醒设置，请重试')));
    } finally {
      busy = false;
    }
  }

  String timeOfDay(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

  Future<void> quietHours(QuietHours? current) async {
    final result = await showDialog<({QuietHours? hours})>(
      context: context,
      builder: (_) => _QuietHoursDialog(current: current),
    );
    if (result != null) await edit(() => service.setQuietHours(result.hours));
  }

  Future<void> roomAction(
    NotificationSubscription room,
    ReminderPreference current,
    String action,
  ) {
    if (action == 'disable') return edit(() => service.disableReminder(room));
    final now = DateTime.now();
    return edit(
      () => service.setReminderPreference(
        room,
        ReminderPreference(
          priority: action == 'priority' ? !current.priority : current.priority,
          snoozedUntil: switch (action) {
            'one' => now.add(const Duration(hours: 1)),
            'day' => now.add(const Duration(hours: 24)),
            'resume' => null,
            _ => current.snoozedUntil,
          },
        ),
      ),
    );
  }

  String describeStatus(Object? data) {
    if (data is! Map) return '暂无成功记录';
    final time = DateTime.tryParse(data['lastSuccess']?.toString() ?? '');
    final label = data['live'] == true ? '直播中' : '未开播';
    if (time == null) return '$label · 检查时间未知';
    final stamp = time.toLocal().toString().substring(0, 16);
    return '$label · $stamp${DateTime.now().difference(time) >= const Duration(hours: 1) ? '（已过期）' : ''}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('开播提醒中心'),
      actions: [
        IconButton(
          tooltip: '刷新提醒记录',
          onPressed: reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder(
      future: snapshot,
      builder: (context, result) {
        if (result.hasError)
          return Center(
            child: TextButton(onPressed: reload, child: const Text('读取失败，重试')),
          );
        final data = result.data;
        if (data == null)
          return const Center(
            child: CircularProgressIndicator(semanticsLabel: '正在读取提醒'),
          );
        final config = data.config;
        final hours = config.quietHours;
        final rooms = [...config.rooms]
          ..sort((a, b) {
            final priority =
                (config.preferenceFor(b).priority ? 1 : 0) -
                (config.preferenceFor(a).priority ? 1 : 0);
            return priority == 0 ? a.userName.compareTo(b.userName) : priority;
          });
        final states = data.state['rooms'] as Map? ?? {};
        final platforms = data.state['platforms'] as Map? ?? {};
        final history = data.state['history'] as List? ?? [];
        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        final recent = history.reversed
            .where(
              (entry) =>
                  entry is Map &&
                  (DateTime.tryParse(
                        entry['time']?.toString() ?? '',
                      )?.isAfter(cutoff) ??
                      false),
            )
            .take(200);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ListTile(
              title: const Text('免打扰'),
              subtitle: Text(
                hours == null
                    ? '关闭'
                    : '${timeOfDay(hours.start)}–${timeOfDay(hours.end)} · ${hours.summary ? '结束后汇总' : '丢弃提醒'}',
              ),
              onTap: () => quietHours(hours),
            ),
            const Divider(),
            if (rooms.isEmpty) const ListTile(title: Text('暂无已订阅的直播间')),
            for (final room in rooms)
              Builder(
                builder: (context) {
                  final preference = config.preferenceFor(room);
                  final status = states[room.id] as Map?;
                  final snoozed = preference.isSnoozed(DateTime.now());
                  final issue = LiveNotificationService.describePlatformIssue(
                    platforms[room.siteId] as Map?,
                  );
                  return ListTile(
                    key: ValueKey(room.id),
                    title: Text(
                      preference.priority
                          ? '${room.userName} · 重点关注'
                          : room.userName,
                    ),
                    subtitle: Text(
                      [
                        describeStatus(
                          status?['generation'] == room.generation
                              ? status
                              : null,
                        ),
                        if (issue != null) issue,
                        if (snoozed)
                          '暂缓至 ${preference.snoozedUntil!.toLocal().toString().substring(0, 16)}',
                      ].join('\n'),
                    ),
                    onTap: () => service.openReminderRoom(room),
                    trailing: PopupMenuButton<String>(
                      tooltip: '管理${room.userName}的提醒',
                      onSelected: (action) =>
                          roomAction(room, preference, action),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'priority',
                          child: Text(
                            preference.priority ? '取消重点关注' : '设为重点关注',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'one',
                          child: Text('暂缓 1 小时'),
                        ),
                        const PopupMenuItem(
                          value: 'day',
                          child: Text('暂缓 24 小时'),
                        ),
                        if (snoozed)
                          const PopupMenuItem(
                            value: 'resume',
                            child: Text('结束暂缓'),
                          ),
                        const PopupMenuItem(
                          value: 'disable',
                          child: Text('关闭提醒'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            const Divider(),
            const ListTile(title: Text('提醒记录')),
            if (recent.isEmpty) const ListTile(title: Text('暂无记录')),
            for (final raw in recent) _historyTile(raw as Map, config),
          ],
        );
      },
    ),
  );

  Widget _historyTile(Map event, NotificationConfig config) {
    final time = DateTime.parse(
      event['time'],
    ).toLocal().toString().substring(0, 16);
    if (event['result'] == 'summary') {
      return ListTile(
        title: Text('${event['count']} 个直播间的免打扰汇总'),
        subtitle: Text(time),
      );
    }
    final room = NotificationSubscription.fromJson(
      Map<String, dynamic>.from(event['room']),
    );
    final status = switch (event['result']) {
      'shown' => '已发送',
      'quiet' => '免打扰',
      'snoozed' => '暂缓',
      'failed' => '发送失败',
      _ => '已处理',
    };
    return ListTile(
      title: Text(room.userName),
      subtitle: Text('$status · $time'),
      onTap: () => service.openReminderRoom(room),
      trailing: config.contains(room)
          ? IconButton(
              tooltip: '关闭${room.userName}的提醒',
              icon: const Icon(Icons.notifications_off_outlined),
              onPressed: () => edit(() => service.disableReminder(room)),
            )
          : null,
    );
  }
}

class _QuietHoursDialog extends StatefulWidget {
  const _QuietHoursDialog({this.current});
  final QuietHours? current;
  @override
  State<_QuietHoursDialog> createState() => _QuietHoursDialogState();
}

class _QuietHoursDialogState extends State<_QuietHoursDialog> {
  late bool enabled = widget.current != null;
  late bool summary = widget.current?.summary ?? false;
  late TimeOfDay start = _time(widget.current?.start ?? 1320);
  late TimeOfDay end = _time(widget.current?.end ?? 480);

  TimeOfDay _time(int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  int _minutes(TimeOfDay time) => time.hour * 60 + time.minute;

  Future<void> pick({required bool starting}) async {
    final value = await showTimePicker(
      context: context,
      initialTime: starting ? start : end,
    );
    if (value == null || !mounted) return;
    setState(() {
      if (starting) {
        start = value;
      } else {
        end = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('免打扰时段'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: const Text('开启免打扰'),
            value: enabled,
            onChanged: (value) => setState(() => enabled = value),
          ),
          if (enabled) ...[
            ListTile(
              title: Text('开始 ${start.format(context)}'),
              onTap: () => pick(starting: true),
            ),
            ListTile(
              title: Text('结束 ${end.format(context)}'),
              onTap: () => pick(starting: false),
            ),
            SwitchListTile(
              title: const Text('结束后汇总'),
              subtitle: Text(summary ? '汇总仍在直播的房间' : '丢弃时段内的提醒'),
              value: summary,
              onChanged: (value) => setState(() => summary = value),
            ),
            if (start == end) const Text('开始和结束时间必须不同'),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Get.back(), child: const Text('取消')),
      FilledButton(
        onPressed: enabled && start == end
            ? null
            : () => Get.back(
                result: (
                  hours: enabled
                      ? QuietHours(
                          _minutes(start),
                          _minutes(end),
                          summary: summary,
                        )
                      : null,
                ),
              ),
        child: const Text('保存'),
      ),
    ],
  );
}
