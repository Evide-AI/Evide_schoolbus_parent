import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/parent_service.dart';
import '../theme.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _service = ParentService();
  List<AppNotification> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await _service.loadNotifications();
      setState(() { _items = items; _loading = false; });
    } catch (_) {
      setState(() { _error = 'Could not load notifications.'; _loading = false; });
    }
  }

  IconData _iconFor(String? category) {
    if (category == null) return Icons.notifications_rounded;
    if (category.startsWith('PROXIMITY')) return Icons.near_me_rounded;
    if (category.contains('SOS') || category.contains('EMERGENCY')) return Icons.warning_amber_rounded;
    if (category.contains('BUS_STARTED')) return Icons.play_circle_outline_rounded;
    if (category.contains('BUS_REACHED')) return Icons.check_circle_outline_rounded;
    return Icons.campaign_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.inkSoft)))
              : _items.isEmpty
                  ? const _EmptyInbox()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(14),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final n = _items[i];
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
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(
                                    color: AppColors.accentSoft,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(_iconFor(n.category), color: AppColors.accent, size: 20),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(n.title,
                                          style: const TextStyle(
                                              fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.ink)),
                                      if (n.body.isNotEmpty) ...[
                                        const SizedBox(height: 3),
                                        Text(n.body,
                                            style: const TextStyle(fontSize: 13.5, color: AppColors.inkSoft)),
                                      ],
                                      const SizedBox(height: 6),
                                      Text(DateFormat('d MMM, h:mm a').format(n.createdAt.toLocal()),
                                          style: const TextStyle(fontSize: 12, color: AppColors.inkFaint)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none_rounded, size: 48, color: AppColors.inkFaint),
          SizedBox(height: 12),
          Text('No notifications yet', style: TextStyle(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}
