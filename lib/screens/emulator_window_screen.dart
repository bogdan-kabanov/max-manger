import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../extensions/window_controller_ext.dart';
import '../providers/app_state.dart';
import '../widgets/emulator_clicker_panel.dart';
import '../widgets/emulator_mirror_widget.dart';

class EmulatorWindowScreen extends StatefulWidget {
  const EmulatorWindowScreen({super.key, required this.accountId});

  final String accountId;

  @override
  State<EmulatorWindowScreen> createState() => _EmulatorWindowScreenState();
}

class _EmulatorWindowScreenState extends State<EmulatorWindowScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<AppState>();
      await state.selectAccountById(widget.accountId, openBrowser: false);
      state.enableEmulatorRecordMode();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.selectedAccount;

    if (account == null) {
      return const Scaffold(body: Center(child: Text('Аккаунт не найден')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Эмулятор — ${account.label}'),
        actions: [
          IconButton(
            tooltip: 'Закрыть окно',
            onPressed: () async {
              final controller = await WindowController.fromCurrentEngine();
              await controller.close();
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: EmulatorMirrorWidget(account: account),
          ),
          const SizedBox(
            width: 360,
            child: EmulatorClickerPanel(),
          ),
        ],
      ),
    );
  }
}

Future<void> setupEmulatorWindow(String accountLabel) async {
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(1180, 860),
      center: true,
      title: 'MAX Эмулятор — $accountLabel',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
