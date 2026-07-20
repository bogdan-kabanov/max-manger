import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../extensions/window_controller_ext.dart';
import '../models/max_account.dart';
import '../models/window_arguments.dart';

class WindowLauncher {
  WindowLauncher._();

  static final WindowLauncher instance = WindowLauncher._();

  Future<void> openWeb(MaxAccount account) =>
      _open(WindowArguments(type: WindowType.web, accountId: account.id));

  Future<void> openEmulator(MaxAccount account) =>
      _open(WindowArguments(type: WindowType.emulator, accountId: account.id));

  Future<void> openAutomation(MaxAccount account) =>
      _open(WindowArguments(type: WindowType.automation, accountId: account.id));

  Future<void> _open(WindowArguments args) async {
    final encoded = args.encode();
    final existing = await WindowController.getAll();
    for (final controller in existing) {
      if (controller.arguments == encoded) {
        await controller.focusShow();
        return;
      }
    }

    final controller = await WindowController.create(
      WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: encoded,
      ),
    );
    await controller.focusShow();
  }
}
