import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_nav_page.dart';
import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/max_auth_service.dart';
import '../services/proxy_support.dart';
import '../services/window_launcher.dart';
import 'bulk_token_import_dialog.dart';
import 'emulator_panel_dialog.dart';
import 'map_sidebar/account_chats_tab.dart';
import 'map_sidebar/map_log_panel.dart';
import 'map_sidebar/workflow_groups_tab.dart';
import 'automation_panel.dart';
import 'channel_catalog_panel.dart';
import 'funnels_panel.dart';
import 'join_templates_panel.dart';
import 'mother_panel.dart';
import 'pipeline_assign_panel.dart';
import 'pipeline_journal_panel.dart';
import 'pipeline_launch_panel.dart';
import 'registration_guide_dialog.dart';
import 'sms_account_dialog.dart';
import 'token_account_dialog.dart';

export '../models/app_nav_page.dart';

/// Adaptive left navigation: slim rail + dedicated pages (no cramped sidebar).
class AppNavShell extends StatefulWidget {
  const AppNavShell({
    super.key,
    this.expandContent = false,
    this.onCheckUpdates,
    this.onInstallUpdate,
    this.checkingUpdates = false,
    this.updateAvailable = false,
    this.localVersionLabel = '',
    this.updateStatus,
  });

  /// When the center map is hidden, grow the page column into that space.
  final bool expandContent;
  final VoidCallback? onCheckUpdates;
  final VoidCallback? onInstallUpdate;
  final bool checkingUpdates;
  final bool updateAvailable;
  final String localVersionLabel;
  final String? updateStatus;

  @override
  State<AppNavShell> createState() => _AppNavShellState();
}

class _AppNavShellState extends State<AppNavShell> {
  /// Primary rail destinations (index → page). Secondary pages open from «Ещё».
  static const _railPages = <AppNavPage>[
    AppNavPage.parse,
    AppNavPage.assign,
    AppNavPage.templates,
    AppNavPage.funnels,
    AppNavPage.launch,
    AppNavPage.journal,
    AppNavPage.profiles,
    AppNavPage.addAccount,
    AppNavPage.more,
  ];

  int _railIndexFor(AppNavPage page) {
    final i = _railPages.indexOf(page);
    if (i >= 0) return i;
    // Secondary tools highlight «Ещё».
    return _railPages.indexOf(AppNavPage.more);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final page = state.navPage;

    final shell = LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final wideWorkPage = page.isWideWorkPage;
        // Pipeline / work pages need room for lists + actions; keep map-rail pages compact.
        final contentWidth = wideWorkPage
            ? (totalWidth < 1200 ? 520.0 : (totalWidth < 1600 ? 640.0 : 720.0))
            : (totalWidth < 1100
                ? 260.0
                : (totalWidth < 1400 ? 300.0 : 340.0));
        final extended = totalWidth >= 1500;

        final pageBody = AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          child: KeyedSubtree(
            key: ValueKey(page),
            child: switch (page) {
              AppNavPage.parse => const _ParsePage(),
              AppNavPage.assign => const _AssignPage(),
              AppNavPage.templates => const _TemplatesPage(),
              AppNavPage.funnels => const _FunnelsPage(),
              AppNavPage.launch => const _LaunchPage(),
              AppNavPage.journal => const _JournalPage(),
              AppNavPage.profiles => const _ProfilesPage(),
              AppNavPage.addAccount => _AddAccountPage(
                  onCreated: () => context.read<AppState>().setNavPage(AppNavPage.profiles),
                ),
              AppNavPage.more => const _MorePage(),
              AppNavPage.groups => const _GroupsPage(),
              AppNavPage.chats => const _ChatsPage(),
              AppNavPage.mother => const _MotherPage(),
              AppNavPage.automation => const _AutomationPage(),
              AppNavPage.emulator => const _EmulatorPage(),
              AppNavPage.help => const _HelpPage(),
              AppNavPage.about => _AboutPage(
                  onCheckUpdates: widget.onCheckUpdates,
                  onInstallUpdate: widget.onInstallUpdate,
                  checkingUpdates: widget.checkingUpdates,
                  updateAvailable: widget.updateAvailable,
                  localVersionLabel: widget.localVersionLabel,
                  updateStatus: widget.updateStatus,
                ),
            },
          ),
        );

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
                selectedIndex: _railIndexFor(page),
                onDestinationSelected: (i) =>
                    context.read<AppState>().setNavPage(_railPages[i]),
                labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.selected,
                backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                leading: Padding(
                  padding: EdgeInsets.only(top: 12, bottom: extended ? 8 : 4),
                  child: _BrandMark(compact: !extended),
                ),
                destinations: [
                  const NavigationRailDestination(
                    icon: Icon(Icons.travel_explore_outlined),
                    selectedIcon: Icon(Icons.travel_explore),
                    label: Text('Парсинг'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.bookmark_border),
                    selectedIcon: Icon(Icons.bookmark),
                    label: Text('Раздача'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.description_outlined),
                    selectedIcon: Icon(Icons.description),
                    label: Text('Шаблоны'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.filter_alt_outlined),
                    selectedIcon: Icon(Icons.filter_alt),
                    label: Text('Воронки'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.play_circle_outline),
                    selectedIcon: Icon(Icons.play_circle),
                    label: Text('Запуск'),
                  ),
                  NavigationRailDestination(
                    icon: Badge(
                      isLabelVisible: state.runningActionsCount > 0,
                      label: Text('${state.runningActionsCount}'),
                      child: const Icon(Icons.history_outlined),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: state.runningActionsCount > 0,
                      label: Text('${state.runningActionsCount}'),
                      child: const Icon(Icons.history),
                    ),
                    label: const Text('Журнал'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.people_outline),
                    selectedIcon: Icon(Icons.people),
                    label: Text('Профили'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.person_add_alt_outlined),
                    selectedIcon: Icon(Icons.person_add_alt_1),
                    label: Text('Вход'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.more_horiz),
                    selectedIcon: Icon(Icons.more_horiz),
                    label: Text('Ещё'),
                  ),
                ],
              ),
              VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
              if (widget.expandContent)
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: contentWidth,
                      child: pageBody,
                    ),
                  ),
                )
              else
                SizedBox(width: contentWidth, child: pageBody),
            ],
          ),
        );
      },
    );

    return shell;
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
      mainAxisSize: MainAxisSize.min,
      children: [
        badge,
        const SizedBox(width: 10),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('MAX Desktop', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text('web.max.ru', style: TextStyle(fontSize: 11, color: Colors.white60)),
          ],
        ),
      ],
    );
  }
}

// ─── Profiles ───────────────────────────────────────────────────────────────

class _GroupsPage extends StatelessWidget {
  const _GroupsPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.selectedAccount;
    if (account == null) {
      return const _EmptyHint(
        icon: Icons.folder_outlined,
        text: 'Выберите аккаунт на вкладке «Профили»,\nзатем откройте «Группы».',
      );
    }
    return WorkflowGroupsTab(
      key: ValueKey('nav-groups-${account.id}'),
      accountId: account.id,
    );
  }
}

class _ParsePage extends StatelessWidget {
  const _ParsePage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            'Парсинг',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(child: ChannelCatalogPanel(key: ValueKey('nav-parse'))),
      ],
    );
  }
}

class _AssignPage extends StatelessWidget {
  const _AssignPage();

  @override
  Widget build(BuildContext context) {
    return const PipelineAssignPanel(key: ValueKey('nav-assign'));
  }
}

class _LaunchPage extends StatelessWidget {
  const _LaunchPage();

  @override
  Widget build(BuildContext context) {
    return const PipelineLaunchPanel(key: ValueKey('nav-launch'));
  }
}

class _JournalPage extends StatelessWidget {
  const _JournalPage();

  @override
  Widget build(BuildContext context) {
    return const PipelineJournalPanel(key: ValueKey('nav-journal'));
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String title, String subtitle, AppNavPage page) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        onTap: () => context.read<AppState>().setNavPage(page),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Text('Ещё', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        tile(Icons.hive_outlined, 'Матка (расширенно)', 'Старые режимы join/invite/forward', AppNavPage.mother),
        tile(Icons.folder_outlined, 'Группы на карте', 'Workflow-группы выбранного аккаунта', AppNavPage.groups),
        tile(Icons.chat_bubble_outline, 'Чаты', 'Каталог чатов MAX по маткам', AppNavPage.chats),
        tile(Icons.smart_toy_outlined, 'Авто', 'Автоответы, ИИ, сценарии', AppNavPage.automation),
        tile(Icons.phone_android_outlined, 'Эмулятор', 'AVD / зеркало', AppNavPage.emulator),
        tile(Icons.help_outline, 'Справка', 'Регистрация и QR', AppNavPage.help),
        tile(Icons.info_outline, 'О приложении', 'Версия и обновления', AppNavPage.about),
      ],
    );
  }
}

class _ChatsPage extends StatelessWidget {
  const _ChatsPage();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return AccountChatsTab(
      key: ValueKey('nav-chats-${state.selectedAccount?.id ?? 'all'}'),
      focusAccountId: state.selectedAccount?.id,
    );
  }
}

class _MotherPage extends StatelessWidget {
  const _MotherPage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Матка (расширенно)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        Expanded(child: MotherPanel(embedded: false)),
        MapLogPanel(),
      ],
    );
  }
}

class _TemplatesPage extends StatelessWidget {
  const _TemplatesPage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: JoinTemplatesPanel(key: ValueKey('nav-templates'))),
        MapLogPanel(),
      ],
    );
  }
}

class _FunnelsPage extends StatelessWidget {
  const _FunnelsPage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: FunnelsPanel(key: ValueKey('nav-funnels'))),
        MapLogPanel(),
      ],
    );
  }
}

class _AutomationPage extends StatelessWidget {
  const _AutomationPage();

  @override
  Widget build(BuildContext context) {
    return const AutomationPanel(fullWidth: true);
  }
}

class _ProfilesPage extends StatefulWidget {
  const _ProfilesPage();

  @override
  State<_ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<_ProfilesPage> {
  bool _checking = false;
  String? _checkProgress;

  Future<void> _checkAll() async {
    final state = context.read<AppState>();
    final total = state.accountsWithToken().length;
    if (total == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет аккаунтов с токеном для проверки')),
      );
      return;
    }

    setState(() {
      _checking = true;
      _checkProgress = '0/$total';
    });

    final counts = await state.checkAllAccountHealth(
      onProgress: (done, all, account) {
        if (!mounted) return;
        setState(() => _checkProgress = '$done/$all · ${account.label}');
      },
    );

    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkProgress = null;
    });

    final ok = counts[AccountHealthStatus.ok] ?? 0;
    final banned = counts[AccountHealthStatus.banned] ?? 0;
    final dead = counts[AccountHealthStatus.authFailed] ?? 0;
    final net = counts[AccountHealthStatus.networkError] ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Проверено: активны $ok · бан $banned · токен мёртв $dead'
          '${net > 0 ? ' · сеть $net' : ''}',
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final accounts = state.accounts;
    final selected = state.selectedAccount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Профили', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                    SizedBox(height: 2),
                    Text(
                      'Имя, фамилия, телефон — после «Инфо» или «Проверить статусы». '
                      'При выборе непроверенного аккаунта подтянется само.',
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _checking || accounts.isEmpty ? null : _checkAll,
                icon: _checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.health_and_safety_outlined, size: 16),
                label: Text(
                  _checking ? (_checkProgress ?? 'Проверка…') : 'Проверить статусы',
                  style: const TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
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
                      account.profileDisplayName,
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
                        _HealthBadge(status: account.healthStatus),
                        _StatusBadge(
                          label: account.hasApiSession ? 'токен' : 'нет токена',
                          ok: account.hasApiSession,
                        ),
                        _StatusBadge(
                          label: _hasProxy(account) ? 'прокси' : 'без прокси',
                          ok: _hasProxy(account),
                        ),
                        if (account.phone?.trim().isNotEmpty == true)
                          _StatusBadge(
                            label: account.phone!.trim(),
                            ok: true,
                            neutral: true,
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
    if (account.phone != null && account.phone!.trim().isNotEmpty) {
      parts.add(account.phone!.trim());
    }
    if (account.viewerId != null) {
      parts.add('id ${account.viewerId}');
    }
    parts.add(_authMethodLabel(account.authMethod));
    if (account.lastOpenedAt != null) {
      parts.add('открыт ${_formatDate(account.lastOpenedAt!)}');
    }
    if (account.hasEmulator) {
      parts.add('AVD ${account.emulator.avdName}');
    }
    if (parts.isEmpty) return 'Изолированный профиль';
    return parts.join(' · ');
  }

  static String _authMethodLabel(MaxAuthMethod method) {
    return switch (method) {
      MaxAuthMethod.qr => 'QR',
      MaxAuthMethod.sms => 'SMS',
      MaxAuthMethod.token => 'токен',
    };
  }
}

class _SelectedAccountActions extends StatefulWidget {
  const _SelectedAccountActions({required this.account});

  final MaxAccount account;

  @override
  State<_SelectedAccountActions> createState() => _SelectedAccountActionsState();
}

class _SelectedAccountActionsState extends State<_SelectedAccountActions> {
  bool _refreshing = false;

  MaxAccount get account => widget.account;

  Future<void> _refreshProfile() async {
    setState(() => _refreshing = true);
    final result = await context.read<AppState>().refreshAccountProfile(account);
    if (!mounted) return;
    setState(() => _refreshing = false);
    final status = context.read<AppState>().accountById(account.id)?.healthStatus;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Инфо обновлено'
                  '${result.profileName != null ? ': ${result.profileName}' : ''}'
                  '${result.profilePhone != null ? ' · ${result.profilePhone}' : ''}'
                  '${status != null ? ' · ${status.shortLabel}' : ''}'
              : '${status?.longLabel ?? 'Не удалось обновить'}: ${result.error ?? ''}',
        ),
      ),
    );
  }

  Future<void> _checkHealth() async {
    setState(() => _refreshing = true);
    final result = await context.read<AppState>().checkAccountHealth(account);
    if (!mounted) return;
    setState(() => _refreshing = false);
    final fresh = context.read<AppState>().accountById(account.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fresh != null
              ? '${fresh.healthStatus.longLabel}'
                  '${result.error != null && !result.ok ? ': ${result.error}' : ''}'
              : (result.error ?? 'Готово'),
        ),
      ),
    );
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label скопирован'), duration: const Duration(seconds: 2)),
    );
  }

  String _proxyLabel() {
    final raw = account.isolation.proxyServer?.trim();
    if (raw == null || raw.isEmpty) return 'нет';
    return ParsedProxy.tryParse(raw)?.masked ?? raw;
  }

  String _authLabel() {
    return switch (account.authMethod) {
      MaxAuthMethod.qr => 'QR',
      MaxAuthMethod.sms => 'SMS',
      MaxAuthMethod.token => 'токен',
    };
  }

  static String _fmt(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final token = account.apiToken;
    final proxyRaw = account.isolation.proxyServer?.trim();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  account.profileDisplayName,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (account.hasApiSession) ...[
                TextButton.icon(
                  onPressed: _refreshing ? null : _checkHealth,
                  icon: const Icon(Icons.health_and_safety_outlined, size: 16),
                  label: const Text('Статус', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: _refreshing ? null : _refreshProfile,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync, size: 16),
                  label: const Text('Инфо', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _InfoGrid(
            rows: [
              _InfoRow(
                label: 'имя',
                value: (account.firstName?.trim().isNotEmpty == true)
                    ? account.firstName!.trim()
                    : '—',
                onCopy: account.firstName?.trim().isNotEmpty == true
                    ? () => _copy('Имя', account.firstName!.trim())
                    : null,
              ),
              _InfoRow(
                label: 'фамилия',
                value: (account.lastName?.trim().isNotEmpty == true)
                    ? account.lastName!.trim()
                    : '—',
                onCopy: account.lastName?.trim().isNotEmpty == true
                    ? () => _copy('Фамилия', account.lastName!.trim())
                    : null,
              ),
              _InfoRow(
                label: 'описание',
                value: (account.description?.trim().isNotEmpty == true)
                    ? account.description!.trim()
                    : '—',
                onCopy: account.description?.trim().isNotEmpty == true
                    ? () => _copy('Описание', account.description!.trim())
                    : null,
              ),
              _InfoRow(
                label: 'телефон',
                value: (account.phone?.trim().isNotEmpty == true) ? account.phone!.trim() : '—',
                onCopy: account.phone?.trim().isNotEmpty == true
                    ? () => _copy('Телефон', account.phone!.trim())
                    : null,
              ),
              _InfoRow(
                label: 'статус',
                value: account.healthStatus.longLabel +
                    (account.lastCheckedAt != null
                        ? ' · ${_fmt(account.lastCheckedAt!)}'
                        : ''),
              ),
              if (account.lastError != null && account.lastError!.trim().isNotEmpty)
                _InfoRow(label: 'ошибка', value: account.lastError!.trim()),
              _InfoRow(
                label: 'viewerId',
                value: account.viewerId?.toString() ?? '—',
                onCopy: account.viewerId != null
                    ? () => _copy('viewerId', '${account.viewerId}')
                    : null,
              ),
              _InfoRow(label: 'вход', value: _authLabel()),
              _InfoRow(
                label: 'токен',
                value: token != null && token.isNotEmpty
                    ? MaxAuthService.tokenPreview(token)
                    : 'нет',
                onCopy: token != null && token.isNotEmpty
                    ? () => _copy('Токен', token)
                    : null,
              ),
              _InfoRow(
                label: 'прокси',
                value: _proxyLabel(),
                onCopy: proxyRaw != null && proxyRaw.isNotEmpty
                    ? () => _copy('Прокси', proxyRaw)
                    : null,
              ),
              _InfoRow(
                label: 'deviceId',
                value: account.webDeviceId,
                onCopy: () => _copy('deviceId', account.webDeviceId),
              ),
              _InfoRow(label: 'создан', value: _fmt(account.createdAt)),
              _InfoRow(
                label: 'открыт',
                value: account.lastOpenedAt != null ? _fmt(account.lastOpenedAt!) : '—',
              ),
              if (account.isUzbek) const _InfoRow(label: 'регион', value: 'UZ (+998 / метка)'),
              if (account.hasEmulator)
                _InfoRow(label: 'AVD', value: account.emulator.avdName ?? '—'),
              if (account.notes?.trim().isNotEmpty == true)
                _InfoRow(label: 'заметки', value: account.notes!.trim()),
            ],
          ),
          const SizedBox(height: 10),
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

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.rows});

  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in rows) ...[
          row,
          if (row != rows.last) const SizedBox(height: 3),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', height: 1.25),
          ),
        ),
        if (onCopy != null)
          InkWell(
            onTap: onCopy,
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.copy, size: 13, color: Colors.white54),
            ),
          ),
      ],
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

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.status});

  final AccountHealthStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (status) {
      AccountHealthStatus.ok => (
          const Color(0xFF1B5E20).withValues(alpha: 0.55),
          const Color(0xFFA5D6A7),
        ),
      AccountHealthStatus.banned => (
          const Color(0xFFB71C1C).withValues(alpha: 0.55),
          const Color(0xFFFFCDD2),
        ),
      AccountHealthStatus.authFailed => (
          const Color(0xFFE65100).withValues(alpha: 0.45),
          const Color(0xFFFFCC80),
        ),
      AccountHealthStatus.networkError => (
          const Color(0xFF37474F).withValues(alpha: 0.55),
          const Color(0xFFB0BEC5),
        ),
      AccountHealthStatus.unknown => (
          Colors.white12,
          Colors.white70,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.shortLabel,
        style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600),
      ),
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
    this.onInstallUpdate,
    this.checkingUpdates = false,
    this.updateAvailable = false,
    this.localVersionLabel = '',
    this.updateStatus,
  });

  final VoidCallback? onCheckUpdates;
  final VoidCallback? onInstallUpdate;
  final bool checkingUpdates;
  final bool updateAvailable;
  final String localVersionLabel;
  final String? updateStatus;

  @override
  Widget build(BuildContext context) {
    final primaryAction = updateAvailable && onInstallUpdate != null
        ? onInstallUpdate
        : onCheckUpdates;

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
                onPressed: checkingUpdates || primaryAction == null ? null : primaryAction,
                icon: checkingUpdates
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(updateAvailable ? Icons.system_update : Icons.refresh, size: 18),
                label: Text(updateAvailable ? 'Установить обновление' : 'Проверить обновления'),
              ),
              if (updateAvailable && onCheckUpdates != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: checkingUpdates ? null : onCheckUpdates,
                  child: const Text('Проверить ещё раз'),
                ),
              ],
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
                    hintText: 'http://user:pass@host:port  или  host:port:user:pass',
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
