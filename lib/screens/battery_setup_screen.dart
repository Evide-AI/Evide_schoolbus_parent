import 'package:flutter/material.dart';
import '../services/battery_service.dart';
import '../theme.dart';

/// Walks the parent through the phone settings that let the "bus is near"
/// alarm ring even when the app hasn't been opened for days.
class BatterySetupScreen extends StatefulWidget {
  /// Called when the parent finishes or skips.
  final VoidCallback onDone;
  const BatterySetupScreen({super.key, required this.onDone});

  @override
  State<BatterySetupScreen> createState() => _BatterySetupScreenState();
}

class _BatterySetupScreenState extends State<BatterySetupScreen> with WidgetsBindingObserver {
  AlarmReadiness? _r;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The parent leaves for system settings and comes back — re-check then.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final r = await BatteryService.instance.check();
    if (!mounted) return;
    setState(() => _r = r);
  }

  Future<void> _skip() async {
    await BatteryService.instance.markSkipped();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Keep bus alarms working')),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Some phones switch off apps you haven\'t opened for a day or two. '
                  'When that happens the bus alarm can\'t reach you. '
                  'Turn on the settings below once and alarms will ring even if '
                  'you don\'t open the app.',
                  style: TextStyle(color: AppColors.inkSoft, height: 1.45),
                ),
                const SizedBox(height: 20),
                _Step(
                  done: r.notificationsOn,
                  title: 'Allow notifications',
                  body: 'Without this, nothing can be shown.',
                  action: 'Allow',
                  onTap: () async {
                    await BatteryService.instance.openNotificationSettings();
                    _refresh();
                  },
                ),
                _Step(
                  done: r.alarmChannelOn,
                  title: 'Keep "Bus approaching alerts" loud',
                  body: 'Set it to make sound and pop on screen, not "Silent".',
                  action: 'Open alert settings',
                  onTap: BatteryService.instance.openAlarmChannelSettings,
                ),
                _Step(
                  done: r.batteryUnrestricted,
                  title: 'Remove battery restriction',
                  body: 'Find "Evide Parent" in the list and choose "Don\'t optimise" '
                      '(or "Unrestricted" / "No restrictions").',
                  action: 'Open battery settings',
                  onTap: BatteryService.instance.openBatterySettings,
                ),
                if (r.needsAutostartStep)
                  _Step(
                    done: false,
                    title: 'Allow Autostart / background running',
                    body: 'Your phone (${_pretty(r.manufacturer)}) has its own app manager. '
                        'Turn on Autostart for Evide Parent, and set battery to '
                        '"No restrictions" if you see it.',
                    action: 'Open autostart settings',
                    onTap: BatteryService.instance.openAutostartSettings,
                    cannotVerify: true,
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: widget.onDone,
                  child: Text(r.allGood ? 'Done' : 'I\'ve done these'),
                ),
                TextButton(onPressed: _skip, child: const Text('Skip for now')),
              ],
            ),
    );
  }

  String _pretty(String m) => m.isEmpty ? 'phone' : m[0].toUpperCase() + m.substring(1);
}

class _Step extends StatelessWidget {
  final bool done;
  final bool cannotVerify;
  final String title;
  final String body;
  final String action;
  final VoidCallback onTap;

  const _Step({
    required this.done,
    required this.title,
    required this.body,
    required this.action,
    required this.onTap,
    this.cannotVerify = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? AppColors.goSoft : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: done ? AppColors.go : AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(done ? Icons.check_circle : Icons.error_outline,
                color: done ? AppColors.go : AppColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(color: AppColors.inkSoft, height: 1.4)),
          if (!done) ...[
            const SizedBox(height: 10),
            OutlinedButton(onPressed: onTap, child: Text(action)),
          ],
        ],
      ),
    );
  }
}
