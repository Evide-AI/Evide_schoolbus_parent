import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/parent_service.dart';
import '../theme.dart';

/// The parent's inbox: messages from the school office and bus staff, plus an
/// entry each time their child boards or gets off the bus.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _Filter { all, messages, attendance }

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _service = ParentService();
  List<AppNotification> _items = [];
  bool _loading = true;
  String? _error;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _service.loadNotifications();
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not load your messages. Pull down to try again.';
        _loading = false;
      });
    }
  }

  List<AppNotification> get _visible {
    switch (_filter) {
      case _Filter.messages:
        return _items.where((n) => !n.isAttendance).toList();
      case _Filter.attendance:
        return _items.where((n) => n.isAttendance).toList();
      case _Filter.all:
        return _items;
    }
  }

  /// Groups into Today / Yesterday / date, so a busy day reads cleanly.
  Map<String, List<AppNotification>> _grouped(List<AppNotification> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final out = <String, List<AppNotification>>{};
    for (final n in items) {
      final d = DateTime(n.createdAt.year, n.createdAt.month, n.createdAt.day);
      final diff = today.difference(d).inDays;
      final key = diff == 0
          ? 'Today'
          : diff == 1
              ? 'Yesterday'
              : DateFormat('d MMMM').format(n.createdAt);
      (out[key] ??= []).add(n);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped(_visible);

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: Column(
        children: [
          _FilterBar(
            filter: _filter,
            messageCount: _items.where((n) => !n.isAttendance).length,
            attendanceCount: _items.where((n) => n.isAttendance).length,
            onChanged: (f) => setState(() => _filter = f),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _Message(text: _error!, onRetry: _load)
                    : _visible.isEmpty
                        ? RefreshIndicator(
                            onRefresh: _load,
                            child: ListView(children: const [SizedBox(height: 90), _EmptyInbox()]),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                              itemCount: grouped.length,
                              itemBuilder: (context, i) {
                                final key = grouped.keys.elementAt(i);
                                final entries = grouped[key]!;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                                      child: Text(
                                        key,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.inkFaint,
                                        ),
                                      ),
                                    ),
                                    ...entries.map((n) => Padding(
                                          padding: const EdgeInsets.only(bottom: 10),
                                          child: _NotificationCard(item: n),
                                        )),
                                  ],
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final _Filter filter;
  final int messageCount;
  final int attendanceCount;
  final ValueChanged<_Filter> onChanged;
  const _FilterBar({
    required this.filter,
    required this.messageCount,
    required this.attendanceCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(_Filter value, String label, int? count) {
      final on = filter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => onChanged(value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: on ? AppColors.accentSoft : AppColors.paper,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? AppColors.accent : AppColors.line),
            ),
            child: Text(
              count == null || count == 0 ? label : '$label ($count)',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: on ? AppColors.accent : AppColors.inkSoft,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          chip(_Filter.all, 'All', null),
          chip(_Filter.messages, 'Messages', messageCount),
          chip(_Filter.attendance, 'Attendance', attendanceCount),
        ],
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  final AppNotification item;
  const _NotificationCard({required this.item});

  ({IconData icon, Color color, Color background}) get _style {
    final category = item.category ?? '';
    if (item.isAttendance) {
      final gotOff = item.title.toLowerCase().contains('got off');
      final absent = item.title.toLowerCase().contains('absent');
      if (absent) {
        return (icon: Icons.person_off_rounded, color: AppColors.stop, background: AppColors.stopSoft);
      }
      return (
        icon: gotOff ? Icons.logout_rounded : Icons.login_rounded,
        color: AppColors.go,
        background: AppColors.goSoft,
      );
    }
    if (category.startsWith('PROXIMITY')) {
      return (icon: Icons.near_me_rounded, color: AppColors.amber, background: AppColors.amberSoft);
    }
    if (category.contains('SOS') || category.contains('EMERGENCY')) {
      return (icon: Icons.warning_amber_rounded, color: AppColors.stop, background: AppColors.stopSoft);
    }
    if (category.contains('BUS_STARTED')) {
      return (icon: Icons.play_circle_outline_rounded, color: AppColors.accent, background: AppColors.accentSoft);
    }
    if (category.contains('BUS_REACHED') || category.contains('TRIP_ENDED')) {
      return (icon: Icons.check_circle_outline_rounded, color: AppColors.go, background: AppColors.goSoft);
    }
    // A message from the office or the bus staff.
    return (
      icon: item.senderType == 'driver' ? Icons.directions_bus_rounded : Icons.campaign_rounded,
      color: AppColors.accent,
      background: AppColors.accentSoft,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = _style;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: style.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(style.icon, color: style.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                    height: 1.3,
                  ),
                ),
                if (item.body.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.body,
                    style: const TextStyle(fontSize: 13.5, color: AppColors.inkSoft, height: 1.45),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (!item.isAttendance) ...[
                      Text(
                        item.fromLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.inkFaint,
                        ),
                      ),
                      const Text('  ·  ', style: TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                    ],
                    Text(
                      DateFormat('h:mm a').format(item.createdAt),
                      style: const TextStyle(fontSize: 12, color: AppColors.inkFaint),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const _Message({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.inkSoft)),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_email_read_outlined, size: 44, color: AppColors.inkFaint),
            SizedBox(height: 14),
            Text(
              'Nothing yet',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.ink),
            ),
            SizedBox(height: 6),
            Text(
              'Messages from your school and bus staff will appear here, along with '
              'a note each time your child boards or gets off the bus.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkSoft, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
