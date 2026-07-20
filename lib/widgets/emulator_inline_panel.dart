import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/window_launcher.dart';
import 'emulator_clicker_panel.dart';
import 'emulator_mirror_widget.dart';

/// Встроенная панель эмулятора: зеркало экрана + кликер сценариев.
class EmulatorInlinePanel extends StatelessWidget {
  const EmulatorInlinePanel({super.key, required this.account});

  final MaxAccount account;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final clickerVisible = appState.emulatorClickerVisible;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.phone_android, size: 16),
                      const SizedBox(width: 6),
                      const Text('Эмулятор', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => WindowLauncher.instance.openEmulator(account),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('В окне'),
                      ),
                      IconButton(
                        tooltip: clickerVisible ? 'Скрыть кликер' : 'Кликер сценариев',
                        onPressed: () => appState.setEmulatorClickerVisible(!clickerVisible),
                        icon: Icon(clickerVisible ? Icons.chevron_right : Icons.list_alt),
                      ),
                      IconButton(
                        tooltip: 'Скрыть панель',
                        onPressed: () => appState.setEmulatorPanelVisible(false),
                        icon: const Icon(Icons.expand_more, size: 20),
                      ),
                    ],
                  ),
                ),
                Expanded(child: EmulatorMirrorWidget(account: account)),
              ],
            ),
          ),
          if (clickerVisible)
            SizedBox(
              width: 280,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: const EmulatorClickerPanel(),
              ),
            ),
        ],
      ),
    );
  }
}
