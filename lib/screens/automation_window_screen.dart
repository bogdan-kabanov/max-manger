import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../extensions/window_controller_ext.dart';
import '../providers/app_state.dart';
import '../widgets/automation_panel.dart';

class AutomationWindowScreen extends StatefulWidget {
  const AutomationWindowScreen({super.key, required this.accountId});

  final String accountId;

  @override
  State<AutomationWindowScreen> createState() => _AutomationWindowScreenState();
}

class _AutomationWindowScreenState extends State<AutomationWindowScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<AppState>().selectAccountById(widget.accountId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AppState>().selectedAccount;

    return Scaffold(
      appBar: AppBar(
        title: Text('Автоматизация — ${account?.label ?? ''}'),
        actions: [
          IconButton(
            tooltip: 'Закрыть',
            onPressed: () async {
              final controller = await WindowController.fromCurrentEngine();
              await controller.close();
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: const AutomationPanel(fullWidth: true),
    );
  }
}

Future<void> setupAutomationWindow(String accountLabel) async {
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(480, 900),
      center: true,
      title: 'MAX Автоматизация — $accountLabel',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
