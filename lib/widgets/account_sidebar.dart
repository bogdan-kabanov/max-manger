import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/window_launcher.dart';
import 'registration_guide_dialog.dart';
import 'sms_account_dialog.dart';
import 'token_account_dialog.dart';
import 'emulator_panel_dialog.dart';

class AccountSidebar extends StatelessWidget {
  const AccountSidebar({
    super.key,
    this.onCheckUpdates,
    this.checkingUpdates = false,
    this.updateAvailable = false,
    this.localVersionLabel = '',
    this.updateStatus,
  });

  final VoidCallback? onCheckUpdates;
  final bool checkingUpdates;
  final bool updateAvailable;
  final String localVersionLabel;
  final String? updateStatus;

  Future<void> _showAddDialog(BuildContext context) async {
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новый аккаунт'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Рабочий, личный...',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Создать'),
          ),
        ],
      ),
    );

    if (label == null || !context.mounted) return;
    await context.read<AppState>().addAccount(label);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Откройте web.max.ru и отсканируйте QR. Токен сессии сохранится автоматически.'),
        action: SnackBarAction(
          label: 'Как?',
          onPressed: () => RegistrationGuideDialog.show(context),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;
    final selected = state.selectedAccount;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF5B8DEF), Color(0xFF7C5CFF)],
                    ),
                  ),
                  child: const Text('M', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MAX Desktop', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text('Официальный web.max.ru', style: TextStyle(fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                FilledButton.icon(
                  onPressed: () => _showAddDialog(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Профиль + QR'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => SmsAccountDialog.show(context),
                  icon: const Icon(Icons.sms_outlined, size: 18),
                  label: const Text('SMS (может не работать)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => TokenAccountDialog.show(context),
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: const Text('Вход по токену'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    final state = context.read<AppState>();
                    state.setEmulatorPanelVisible(true);
                  },
                  icon: const Icon(Icons.phone_android_outlined, size: 18),
                  label: const Text('Показать эмулятор'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    final account = context.read<AppState>().selectedAccount;
                    if (account == null) return;
                    EmulatorPanelDialog.show(context, account);
                  },
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Настройки AVD'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => RegistrationGuideDialog.show(context),
                  icon: const Icon(Icons.help_outline, size: 18),
                  label: const Text('Справка'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: accounts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Рекомендуется: «Профиль + QR» — официальный вход.\n'
                        'SMS через API часто блокируется MAX (captcha).',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: accounts.length,
                    itemBuilder: (context, index) {
                      final account = accounts[index];
                      final isSelected = selected?.id == account.id;
                      return _AccountTile(
                        account: account,
                        selected: isSelected,
                        onTap: () => context.read<AppState>().selectAccount(account),
                        onSettings: () => _showIsolationDialog(context, account),
                        onEmulator: () {
                          final state = context.read<AppState>();
                          state.setEmulatorPanelVisible(true);
                          state.enableEmulatorRecordMode();
                        },
                        onOpenWeb: () => WindowLauncher.instance.openWeb(account),
                        onDelete: () => _confirmDelete(context, account),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  localVersionLabel.isEmpty ? 'Версия…' : 'Версия $localVersionLabel',
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
                if (updateStatus != null && updateStatus!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    updateStatus!,
                    style: TextStyle(
                      fontSize: 11,
                      color: updateAvailable ? Colors.lightGreenAccent : Colors.white70,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: checkingUpdates || onCheckUpdates == null ? null : onCheckUpdates,
                  icon: checkingUpdates
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(updateAvailable ? Icons.system_update : Icons.refresh, size: 18),
                  label: Text(updateAvailable ? 'Есть обновление' : 'Проверить обновления'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showIsolationDialog(BuildContext context, MaxAccount account) async {
    final proxyController = TextEditingController(text: account.isolation.proxyServer ?? '');
    final isolation = account.isolation;
    var applyToAll = false;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Изоляция: ${account.label}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Каждый аккаунт получает уникальный профиль браузера. '
                    'Сайт не видит cookies и сессии других аккаунтов.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Text('Экран: ${isolation.screenWidth}×${isolation.screenHeight}', style: const TextStyle(fontSize: 12)),
                  Text('CPU ядер: ${isolation.hardwareConcurrency}', style: const TextStyle(fontSize: 12)),
                  Text('Память: ${isolation.deviceMemory} GB', style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  Text(
                    isolation.userAgent,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: proxyController,
                    decoration: const InputDecoration(
                      labelText: 'Прокси (SOCKS5 / HTTP)',
                      hintText: 'socks5://user:pass@host:port',
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: applyToAll,
                    onChanged: (v) => setLocal(() => applyToAll = v == true),
                    title: const Text('Применить ко всем аккаунтам', style: TextStyle(fontSize: 12)),
                    subtitle: const Text(
                      'Матка, дочерние, API и браузер — один прокси',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                  const Text(
                    'Без прокси все аккаунты ходят с одного IP. '
                    'SOCKS5 с логином поддерживается для API/матки и WS.',
                    style: TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await context.read<AppState>().regenerateFingerprint(account);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Новый отпечаток'),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final state = context.read<AppState>();
                if (applyToAll) {
                  await state.applyProxyToAllAccounts(proxyController.text);
                } else {
                  await state.updateAccountIsolation(
                    account,
                    proxyServer: proxyController.text,
                  );
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    proxyController.dispose();
  }

  Future<void> _confirmDelete(BuildContext context, MaxAccount account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить аккаунт?'),
        content: Text('Будут удалены профиль браузера и правила для «${account.label}».'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().removeAccount(account);
    }
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.selected,
    required this.onTap,
    required this.onSettings,
    required this.onEmulator,
    required this.onOpenWeb,
    required this.onDelete,
  });

  final MaxAccount account;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSettings;
  final VoidCallback onEmulator;
  final VoidCallback onOpenWeb;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: selected ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.45) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  child: Text(account.label.characters.first.toUpperCase()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _accountSubtitle(account),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                  tooltip: 'Автоматизация',
                  onPressed: () => WindowLauncher.instance.openAutomation(account),
                ),
                IconButton(
                  icon: const Icon(Icons.language, size: 20),
                  tooltip: 'Окно Web',
                  onPressed: onOpenWeb,
                ),
                IconButton(
                  icon: Icon(
                    Icons.phone_android_outlined,
                    size: 20,
                    color: account.hasEmulator ? Colors.greenAccent : null,
                  ),
                  tooltip: 'Показать эмулятор внизу',
                  onPressed: onEmulator,
                ),
                IconButton(
                  icon: const Icon(Icons.shield_outlined, size: 20),
                  tooltip: 'Изоляция профиля',
                  onPressed: onSettings,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _accountSubtitle(MaxAccount account) {
    if (account.lastOpenedAt != null) {
      return 'Открыт: ${_formatDate(account.lastOpenedAt!)}';
    }
    if (account.hasApiSession && account.phone != null) {
      return 'SMS: ${account.phone}';
    }
    if (account.hasEmulator) {
      return 'Эмулятор: ${account.emulator.avdName}';
    }
    return 'Изолированный профиль';
  }
}
