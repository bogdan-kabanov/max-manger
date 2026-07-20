import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/window_launcher.dart';
import 'emulator_panel_dialog.dart';
import 'registration_guide_dialog.dart';
import 'sms_account_dialog.dart';
import 'bulk_token_import_dialog.dart';
import 'token_account_dialog.dart';

enum AppNavPage { profiles, addAccount, emulator, help, about }

/// Adaptive left navigation: slim rail + dedicated pages (no cramped sidebar).
class AppNavShell extends StatefulWidget {
  const AppNavShell({
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

  @override
  State<AppNavShell> createState() => _AppNavShellState();
}

class _AppNavShellState extends State<AppNavShell> {
  AppNavPage _page = AppNavPage.profiles;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        // Prefer a readable content column; shrink only when the window is tight.
        final contentWidth = totalWidth < 1100
            ? 260.0
            : (totalWidth < 1400 ? 300.0 : 340.0);
        final extended = totalWidth >= 1500;

        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NavigationRail(
                extended: extended,
                minWidth: 64,
                minExtendedWidth: 148,
                selectedIndex: _page.index,
                onDestinationSelected: (i) => setState(() => _page = AppNavPage.values[i]),
                labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                leading: Padding(
                  padding: EdgeInsets.only(top: 12, bottom: extended ? 8 : 4),
                  child: _BrandMark(compact: !extended),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.people_outline),
                    selectedIcon: Icon(Icons.people),
                    label: Text('Профили'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_add_alt_outlined),
                    selectedIcon: Icon(Icons.person_add_alt_1),
                    label: Text('Вход'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.phone_android_outlined),
                    selectedIcon: Icon(Icons.phone_android),
                    label: Text('Эмулятор'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.help_outline),
                    selectedIcon: Icon(Icons.help),
                    label: Text('Справка'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.info_outline),
                    selectedIcon: Icon(Icons.info),
                    label: Text('О приложении'),
                  ),
                ],
              ),
              VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
              SizedBox(
                width: contentWidth,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: KeyedSubtree(
                    key: ValueKey(_page),
                    child: switch (_page) {
                      AppNavPage.profiles => const _ProfilesPage(),
                      AppNavPage.addAccount => _AddAccountPage(
                          onCreated: () => setState(() => _page = AppNavPage.profiles),
                        ),
                      AppNavPage.emulator => const _EmulatorPage(),
                      AppNavPage.help => const _HelpPage(),
                      AppNavPage.about => _AboutPage(
                          onCheckUpdates: widget.onCheckUpdates,
                          checkingUpdates: widget.checkingUpdates,
                          updateAvailable: widget.updateAvailable,
                          localVersionLabel: widget.localVersionLabel,
                          updateStatus: widget.updateStatus,
                        ),
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(colors: [Color(0xFF5B8DEF), Color(0xFF7C5CFF)]),
      ),
      child: const Text('M', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    );

    if (compact) return badge;

    return Row(
      children: [
        badge,
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MAX Desktop', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              Text('web.max.ru', style: TextStyle(fontSize: 11, color: Colors.white60)),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Profiles ───────────────────────────────────────────────────────────────

class _ProfilesPage extends StatelessWidget {
  const _ProfilesPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;
    final selected = state.selectedAccount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PageHeader(
          title: 'Профили',
          subtitle: 'Изолированные сессии web.max.ru',
        ),
        Expanded(
          child: accounts.isEmpty
              ? const _EmptyHint(
                  icon: Icons.people_outline,
                  text: 'Пока нет профилей.\nОткройте вкладку «Вход», чтобы добавить аккаунт.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: accounts.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isSelected = selected?.id == account.id;
                    return _ProfileCard(
                      account: account,
                      selected: isSelected,
                      onTap: () => context.read<AppState>().selectAccount(account),
                    );
                  },
                ),
        ),
        if (selected != null) _SelectedAccountActions(account: selected),
      ],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.account,
    required this.selected,
    required this.onTap,
  });

  final MaxAccount account;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = account.label.trim().isEmpty
        ? '?'
        : account.label.characters.first.toUpperCase();

    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.45) : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(radius: 18, child: Text(initial)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.label,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _accountSubtitle(account),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      softWrap: true,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _StatusBadge(
                          label: account.hasApiSession ? 'токен' : 'нет токена',
                          ok: account.hasApiSession,
                        ),
                        _StatusBadge(
                          label: _hasProxy(account) ? 'прокси' : 'без прокси',
                          ok: _hasProxy(account),
                        ),
                        if (account.viewerId != null)
                          _StatusBadge(
                            label: 'id ${account.viewerId}',
                            ok: true,
                            neutral: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  static bool _hasProxy(MaxAccount account) {
    final proxy = account.isolation.proxyServer?.trim();
    return proxy != null && proxy.isNotEmpty;
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  static String _accountSubtitle(MaxAccount account) {
    final parts = <String>[];
    if (account.lastOpenedAt != null) {
      parts.add('Открыт ${_formatDate(account.lastOpenedAt!)}');
    }
    if (account.hasApiSession && account.phone != null) {
      parts.add('SMS ${account.phone}');
    }
    if (account.hasEmulator) {
      parts.add('AVD ${account.emulator.avdName}');
    }
    if (parts.isEmpty) return 'Изолированный профиль';
    return parts.join(' · ');
  }
}

class _SelectedAccountActions extends StatelessWidget {
  const _SelectedAccountActions({required this.account});

  final MaxAccount account;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            account.label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ActionChip(
                icon: Icons.language,
                label: 'Web',
                onPressed: () => WindowLauncher.instance.openWeb(account),
              ),
              _ActionChip(
                icon: Icons.auto_awesome_outlined,
                label: 'Авто',
                onPressed: () => WindowLauncher.instance.openAutomation(account),
              ),
              _ActionChip(
                icon: Icons.phone_android_outlined,
                label: 'Эмулятор',
                onPressed: () {
                  final state = context.read<AppState>();
                  state.setEmulatorPanelVisible(true);
                  state.enableEmulatorRecordMode();
                },
              ),
              _ActionChip(
                icon: Icons.shield_outlined,
                label: 'Изоляция',
                onPressed: () => _showIsolationDialog(context, account),
              ),
              _ActionChip(
                icon: Icons.delete_outline,
                label: 'Удалить',
                danger: true,
                onPressed: () => _confirmDeleteAccount(context, account),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(icon, size: 16, color: danger ? scheme.error : null),
      label: Text(label, style: TextStyle(fontSize: 12, color: danger ? scheme.error : null)),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.ok,
    this.neutral = false,
  });

  final String label;
  final bool ok;
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (neutral) {
      bg = Colors.white12;
      fg = Colors.white70;
    } else if (ok) {
      bg = const Color(0xFF1B5E20).withValues(alpha: 0.55);
      fg = const Color(0xFFA5D6A7);
    } else {
      bg = const Color(0xFF4E342E).withValues(alpha: 0.55);
      fg = const Color(0xFFFFAB91);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

// ─── Add account ────────────────────────────────────────────────────────────

class _AddAccountPage extends StatelessWidget {
  const _AddAccountPage({required this.onCreated});

  final VoidCallback onCreated;

  Future<void> _showAddQrDialog(BuildContext context) async {
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
    onCreated();
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const _PageHeader(
          title: 'Вход',
          subtitle: 'Выберите способ добавления профиля',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            children: [
              _MethodCard(
                icon: Icons.qr_code_2,
                title: 'Профиль + QR',
                body: 'Рекомендуется. Официальный вход через web.max.ru и QR с телефона.',
                primary: true,
                onTap: () => _showAddQrDialog(context),
              ),
              const SizedBox(height: 10),
              _MethodCard(
                icon: Icons.sms_outlined,
                title: 'SMS',
                body: 'Вход по номеру. Часто блокируется captcha — может не работать.',
                onTap: () => SmsAccountDialog.show(context),
              ),
              const SizedBox(height: 10),
              _MethodCard(
                icon: Icons.key_outlined,
                title: 'Токен',
                body: 'Вставьте уже полученный API-токен сессии.',
                onTap: () => TokenAccountDialog.show(context),
              ),
              const SizedBox(height: 10),
              _MethodCard(
                icon: Icons.upload_file_outlined,
                title: 'Файлы с токенами',
                body: 'Выберите сразу много .txt — парсер заберёт An_… из localStorage.setItem и создаст аккаунты.',
                onTap: () async {
                  final ok = await BulkTokenImportDialog.show(context);
                  if (ok == true && context.mounted) onCreated();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: primary
          ? scheme.primaryContainer.withValues(alpha: 0.55)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: primary ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(body, style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.35)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: Colors.white54),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Emulator ───────────────────────────────────────────────────────────────

class _EmulatorPage extends StatelessWidget {
  const _EmulatorPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.selectedAccount;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const _PageHeader(
          title: 'Эмулятор',
          subtitle: 'Android AVD для выбранного профиля',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: account == null
              ? const _EmptyHint(
                  icon: Icons.phone_android_outlined,
                  text: 'Сначала выберите профиль на вкладке «Профили».',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _InfoBanner(
                      title: account.label,
                      body: account.hasEmulator
                          ? 'AVD: ${account.emulator.avdName}'
                          : 'AVD ещё не настроен для этого профиля',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () {
                        state.setEmulatorPanelVisible(true);
                        state.enableEmulatorRecordMode();
                      },
                      icon: const Icon(Icons.phone_android),
                      label: const Text('Показать эмулятор'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => EmulatorPanelDialog.show(context, account),
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Настройки AVD'),
                    ),
                    if (state.emulatorPanelVisible) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => state.setEmulatorPanelVisible(false),
                        icon: const Icon(Icons.visibility_off_outlined, size: 18),
                        label: const Text('Скрыть панель эмулятора'),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

// ─── Help ───────────────────────────────────────────────────────────────────

class _HelpPage extends StatelessWidget {
  const _HelpPage();

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const _PageHeader(
          title: 'Справка',
          subtitle: 'Как зарегистрировать и войти в MAX',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _HelpStep(
                number: 1,
                title: 'Зарегистрируйте номер в MAX',
                body:
                    'Установите MAX на телефон или официальный клиент для Windows. '
                    'Номер → SMS → имя и фото.',
              ),
              const SizedBox(height: 10),
              const _HelpStep(
                number: 2,
                title: 'Создайте профиль здесь',
                body: 'Вкладка «Вход» → «Профиль + QR». Каждый профиль изолирован.',
              ),
              const SizedBox(height: 10),
              const _HelpStep(
                number: 3,
                title: 'Отсканируйте QR',
                body: 'В телефоне: MAX → устройства / вход по QR. Наведите на QR в центре окна.',
              ),
              const SizedBox(height: 10),
              const _HelpStep(
                number: 4,
                title: 'Сессия сохранится',
                body: 'После входа cookies останутся в профиле MAX Desktop.',
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _openUrl('https://max.ru'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Сайт max.ru'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => RegistrationGuideDialog.show(context),
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: const Text('Подробная инструкция'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep({
    required this.number,
    required this.title,
    required this.body,
  });

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: scheme.primary.withValues(alpha: 0.25),
          child: Text('$number', style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── About ──────────────────────────────────────────────────────────────────

class _AboutPage extends StatelessWidget {
  const _AboutPage({
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const _PageHeader(
          title: 'О приложении',
          subtitle: 'Версия и обновления',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InfoBanner(
                title: localVersionLabel.isEmpty ? 'Версия…' : 'Версия $localVersionLabel',
                body: updateStatus?.isNotEmpty == true
                    ? updateStatus!
                    : 'Официальный клиент для работы с web.max.ru',
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: checkingUpdates || onCheckUpdates == null ? null : onCheckUpdates,
                icon: checkingUpdates
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(updateAvailable ? Icons.system_update : Icons.refresh, size: 18),
                label: Text(updateAvailable ? 'Есть обновление' : 'Проверить обновления'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Shared chrome ──────────────────────────────────────────────────────────

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white60)),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 36, color: Colors.white38),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4)),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.35)),
        ],
      ),
    );
  }
}

// ─── Dialogs (shared) ───────────────────────────────────────────────────────

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
                Text(isolation.userAgent, style: const TextStyle(fontSize: 11, color: Colors.white70)),
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

Future<void> _confirmDeleteAccount(BuildContext context, MaxAccount account) async {
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
