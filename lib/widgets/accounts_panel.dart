import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../models/profile_template.dart';
import '../providers/app_state.dart';
import '../services/desktop_file_picker.dart';
import '../services/proxy_support.dart';
import '../services/window_launcher.dart';
import 'parent_cluster_editor.dart';

/// Accounts table + profile editor, with reusable profile templates.
class AccountsPanel extends StatefulWidget {
  const AccountsPanel({super.key});

  @override
  State<AccountsPanel> createState() => _AccountsPanelState();
}

class _AccountsPanelState extends State<AccountsPanel> {
  int _tabIndex = 0;
  String? _openedAccountId;
  String? _selectedTemplateId;
  final _selectedAccountIds = <String>{};
  String _search = '';

  void _ensureSelectedTemplate(AppState state) {
    final templates = state.profileTemplates;
    if (templates.isEmpty) {
      if (_selectedTemplateId != null) _selectedTemplateId = null;
      return;
    }
    if (_selectedTemplateId == null ||
        !templates.any((t) => t.id == _selectedTemplateId)) {
      _selectedTemplateId = templates.first.id;
    }
  }

  Future<void> _addTemplate() async {
    final template = await context.read<AppState>().addProfileTemplate();
    if (!mounted) return;
    setState(() {
      _selectedTemplateId = template.id;
      _tabIndex = 1;
    });
  }

  Future<void> _deleteSelectedTemplate() async {
    final id = _selectedTemplateId;
    if (id == null) return;
    final state = context.read<AppState>();
    final template = state.profileTemplateById(id);
    if (template == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить шаблон профиля?'),
        content: Text('«${template.name}» будет снят с аккаунтов.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await state.removeProfileTemplate(id);
    if (!mounted) return;
    setState(() {
      _selectedTemplateId =
          state.profileTemplates.isNotEmpty ? state.profileTemplates.first.id : null;
      _selectedAccountIds.clear();
    });
  }

  bool _applyingTemplate = false;

  Future<void> _applyTemplateToSelected() async {
    final templateId = _selectedTemplateId;
    if (templateId == null || _selectedAccountIds.isEmpty || _applyingTemplate) {
      return;
    }
    setState(() => _applyingTemplate = true);
    try {
      final result = await context.read<AppState>().applyProfileTemplateToAccounts(
            templateId: templateId,
            accountIds: _selectedAccountIds,
          );
      if (!mounted) return;
      final buf = StringBuffer(
        'Локально ${result.local} · в MAX ${result.pushed}'
        '${result.failed > 0 ? ' · ошибок ${result.failed}' : ''}',
      );
      if (result.errors.isNotEmpty) {
        buf.write('\n${result.errors.take(3).join('\n')}');
        if (result.errors.length > 3) {
          buf.write('\n…ещё ${result.errors.length - 3}');
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(buf.toString()),
          duration: Duration(seconds: result.failed > 0 ? 6 : 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _applyingTemplate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureSelectedTemplate(state);

    final opened = _openedAccountId == null
        ? null
        : state.accountById(_openedAccountId!);
    if (_openedAccountId != null && opened == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _openedAccountId = null);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Аккаунты',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Профиль, шаблоны и назначение родительских / дочерних',
                      style: TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              if (_tabIndex == 1)
                FilledButton.tonalIcon(
                  onPressed: _addTemplate,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Шаблон'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('Аккаунты'),
                  icon: Icon(Icons.table_rows_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('Шаблоны'),
                  icon: Icon(Icons.style_outlined, size: 16),
                ),
              ],
              selected: {_tabIndex},
              onSelectionChanged: (v) {
                setState(() {
                  _tabIndex = v.first;
                  if (_tabIndex == 1) _openedAccountId = null;
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _tabIndex == 0
              ? (opened != null
                  ? _AccountProfileEditor(
                      account: opened,
                      onBack: () => setState(() => _openedAccountId = null),
                    )
                  : _AccountsTable(
                      search: _search,
                      onSearchChanged: (v) => setState(() => _search = v),
                      onOpen: (id) => setState(() => _openedAccountId = id),
                    ))
              : _ProfileTemplatesTab(
                  selectedTemplateId: _selectedTemplateId,
                  selectedAccountIds: _selectedAccountIds,
                  applying: _applyingTemplate,
                  onSelectTemplate: (id) => setState(() => _selectedTemplateId = id),
                  onToggleAccount: (id) {
                    setState(() {
                      if (_selectedAccountIds.contains(id)) {
                        _selectedAccountIds.remove(id);
                      } else {
                        _selectedAccountIds.add(id);
                      }
                    });
                  },
                  onSelectAllAccounts: (ids) {
                    setState(() {
                      _selectedAccountIds
                        ..clear()
                        ..addAll(ids);
                    });
                  },
                  onClearAccountSelection: () =>
                      setState(() => _selectedAccountIds.clear()),
                  onDeleteTemplate: _deleteSelectedTemplate,
                  onApply: _applyTemplateToSelected,
                ),
        ),
      ],
    );
  }
}

class _AccountsTable extends StatefulWidget {
  const _AccountsTable({
    required this.search,
    required this.onSearchChanged,
    required this.onOpen,
  });

  final String search;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onOpen;

  @override
  State<_AccountsTable> createState() => _AccountsTableState();
}

class _AccountsTableState extends State<_AccountsTable> {
  final _expandedParentIds = <String>{};

  static bool _hasProxy(MaxAccount account) {
    final proxy = account.isolation.proxyServer?.trim();
    return proxy != null && proxy.isNotEmpty;
  }

  static String _proxyShort(MaxAccount account) {
    final raw = account.isolation.proxyServer?.trim();
    if (raw == null || raw.isEmpty) return '—';
    return ParsedProxy.tryParse(raw)?.masked ?? raw;
  }

  bool _matches(MaxAccount a, String q) {
    if (q.isEmpty) return true;
    final hay = [
      a.label,
      a.profileDisplayName,
      a.phone ?? '',
      a.description ?? '',
      a.notes ?? '',
      a.healthStatus.shortLabel,
      a.isolation.proxyServer ?? '',
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  void _toggleExpand(String parentId) {
    setState(() {
      if (_expandedParentIds.contains(parentId)) {
        _expandedParentIds.remove(parentId);
      } else {
        _expandedParentIds.add(parentId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final q = widget.search.trim().toLowerCase();
    final filtered = state.accounts.where((a) => _matches(a, q)).toList();

    // Build parent → children groups; nest children under mothers.
    final claimedChildIds = <String>{};
    final groups = <({MaxAccount parent, List<MaxAccount> children})>[];
    final motherIdsToShow = <String>{};

    for (final a in filtered) {
      if (state.isMotherAccount(a.id)) motherIdsToShow.add(a.id);
      if (state.isChildAccount(a.id)) {
        final cluster = state.clusterContainingAccount(a.id);
        final mid = cluster?.motherAccountId;
        if (mid != null) motherIdsToShow.add(mid);
      }
    }

    for (final motherId in motherIdsToShow) {
      final mother = state.accountById(motherId);
      if (mother == null) continue;
      final cluster = state.accountMap.clusterForMother(motherId);
      final kids = <MaxAccount>[];
      for (final id in cluster?.childAccountIds ?? const <String>{}) {
        final child = state.accountById(id);
        if (child == null) continue;
        if (q.isEmpty || _matches(mother, q) || _matches(child, q)) {
          kids.add(child);
          claimedChildIds.add(child.id);
        }
      }
      kids.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (q.isEmpty || _matches(mother, q) || kids.isNotEmpty) {
        groups.add((parent: mother, children: kids));
      }
    }

    final singles = <MaxAccount>[
      for (final a in filtered)
        if (!claimedChildIds.contains(a.id) && !groups.any((g) => g.parent.id == a.id)) a,
    ];

    final roots = <({MaxAccount account, List<MaxAccount> children})>[
      ...groups.map((g) => (account: g.parent, children: g.children)),
      ...singles.map((a) => (account: a, children: const <MaxAccount>[])),
    ]..sort((a, b) => a.account.label.toLowerCase().compareTo(b.account.label.toLowerCase()));

    // While searching, treat parents with visible children as expanded.
    final expandedIds = <String>{..._expandedParentIds};
    if (q.isNotEmpty) {
      for (final root in roots) {
        if (root.children.isNotEmpty) expandedIds.add(root.account.id);
      }
    }

    final visibleCount = roots.fold<int>(
      0,
      (n, r) => n + 1 + (expandedIds.contains(r.account.id) ? r.children.length : 0),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            onChanged: widget.onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Поиск по имени, телефону, описанию…',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixText: '$visibleCount/${state.accounts.length}',
            ),
          ),
        ),
        Expanded(
          child: roots.isEmpty
              ? const Center(
                  child: Text(
                    'Нет аккаунтов',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
                        child: SingleChildScrollView(
                          child: DataTable(
                            showCheckboxColumn: false,
                            headingRowHeight: 40,
                            dataRowMinHeight: 52,
                            dataRowMaxHeight: 64,
                            columnSpacing: 16,
                            columns: const [
                              DataColumn(label: Text('Аккаунт')),
                              DataColumn(label: Text('Роль')),
                              DataColumn(label: Text('Имя профиля')),
                              DataColumn(label: Text('Описание')),
                              DataColumn(label: Text('Фото')),
                              DataColumn(label: Text('Телефон')),
                              DataColumn(label: Text('Прокси')),
                              DataColumn(label: Text('Статус')),
                              DataColumn(label: Text('Шаблон')),
                              DataColumn(label: Text('Действия')),
                            ],
                            rows: [
                              for (final root in roots) ...[
                                _accountDataRow(
                                  context: context,
                                  state: state,
                                  account: root.account,
                                  depth: 0,
                                  childCount: root.children.length,
                                  expanded: expandedIds.contains(root.account.id),
                                  onToggleExpand: root.children.isEmpty
                                      ? null
                                      : () => _toggleExpand(root.account.id),
                                  onOpen: widget.onOpen,
                                ),
                                if (expandedIds.contains(root.account.id))
                                  for (final child in root.children)
                                    _accountDataRow(
                                      context: context,
                                      state: state,
                                      account: child,
                                      depth: 1,
                                      childCount: 0,
                                      expanded: false,
                                      onToggleExpand: null,
                                      onOpen: widget.onOpen,
                                    ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  DataRow _accountDataRow({
    required BuildContext context,
    required AppState state,
    required MaxAccount account,
    required int depth,
    required int childCount,
    required bool expanded,
    required VoidCallback? onToggleExpand,
    required ValueChanged<String> onOpen,
  }) {
    final isChild = depth > 0;
    return DataRow(
      color: isChild
          ? WidgetStatePropertyAll(
              Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
            )
          : null,
      onSelectChanged: (_) => onOpen(account.id),
      cells: [
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: depth * 20.0),
              if (onToggleExpand != null)
                IconButton(
                  tooltip: expanded ? 'Свернуть' : 'Развернуть дочерние',
                  onPressed: onToggleExpand,
                  icon: Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 20,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                )
              else
                SizedBox(
                  width: 28,
                  child: isChild
                      ? Icon(
                          Icons.subdirectory_arrow_right,
                          size: 16,
                          color: Colors.white38,
                        )
                      : null,
                ),
              Flexible(
                child: Text(
                  account.label,
                  style: TextStyle(
                    fontWeight: isChild ? FontWeight.w500 : FontWeight.w600,
                    fontSize: isChild ? 13 : 14,
                  ),
                ),
              ),
              if (!isChild && childCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF90CAF9).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$childCount',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF90CAF9)),
                  ),
                ),
              ],
            ],
          ),
        ),
        DataCell(
          SizedBox(
            width: 130,
            child: Text(
              accountClusterRoleLabel(state, account.id),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: state.accountMap.isMotherAccount(account.id)
                    ? const Color(0xFF90CAF9)
                    : state.accountMap.isChildAccount(account.id)
                        ? Colors.white70
                        : Colors.white38,
              ),
            ),
          ),
        ),
        DataCell(
          Text(
            account.profileDisplayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DataCell(
          SizedBox(
            width: 140,
            child: Text(
              (account.description?.trim().isNotEmpty == true)
                  ? account.description!.trim()
                  : '—',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: account.description?.trim().isNotEmpty == true
                    ? null
                    : Colors.white38,
                fontSize: 12,
              ),
            ),
          ),
        ),
        DataCell(_PhotoThumb(path: account.profilePhotoPath)),
        DataCell(Text(
          account.phone?.trim().isNotEmpty == true ? account.phone!.trim() : '—',
        )),
        DataCell(
          SizedBox(
            width: 120,
            child: Text(
              _proxyShort(account),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _hasProxy(account) ? const Color(0xFFA5D6A7) : Colors.white38,
                fontFamily: 'Consolas',
              ),
            ),
          ),
        ),
        DataCell(
          Text(
            account.healthStatus.shortLabel,
            style: TextStyle(
              color: account.healthStatus.isProblem
                  ? Theme.of(context).colorScheme.error
                  : account.isHealthy
                      ? const Color(0xFFA5D6A7)
                      : Colors.white54,
              fontSize: 12,
            ),
          ),
        ),
        DataCell(
          Text(
            state.profileTemplateForAccount(account.id)?.name ?? '—',
            style: TextStyle(
              fontSize: 12,
              color: state.profileTemplateForAccount(account.id) == null
                  ? Colors.white38
                  : null,
            ),
          ),
        ),
        DataCell(
          _AccountRowActions(
            account: account,
            onEditProfile: () => onOpen(account.id),
          ),
        ),
      ],
    );
  }
}

class _AccountRowActions extends StatefulWidget {
  const _AccountRowActions({
    required this.account,
    required this.onEditProfile,
  });

  final MaxAccount account;
  final VoidCallback onEditProfile;

  @override
  State<_AccountRowActions> createState() => _AccountRowActionsState();
}

class _AccountRowActionsState extends State<_AccountRowActions> {
  bool _pushingProfile = false;

  Future<void> _onPushProfile() async {
    if (_pushingProfile || !widget.account.hasApiSession) return;
    setState(() => _pushingProfile = true);
    try {
      await _pushProfileToMax(context, widget.account);
    } finally {
      if (mounted) setState(() => _pushingProfile = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final account = widget.account;
    final isParent = context.watch<AppState>().accountMap.isMotherAccount(account.id);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RowIconBtn(
          tooltip: 'Профиль',
          icon: Icons.badge_outlined,
          onPressed: _pushingProfile ? null : widget.onEditProfile,
        ),
        _RowIconBtn(
          tooltip: isParent
              ? 'Родительский / дочерние'
              : 'Сделать родительским',
          icon: isParent ? Icons.account_tree : Icons.account_tree_outlined,
          color: isParent ? const Color(0xFF90CAF9) : null,
          onPressed: _pushingProfile
              ? null
              : () => showParentClusterEditor(
                    context,
                    parentAccountId: account.id,
                  ),
        ),
        _RowIconBtn(
          tooltip: _pushingProfile
              ? 'Установка профиля…'
              : 'Установить профиль в MAX',
          icon: Icons.cloud_upload_outlined,
          loading: _pushingProfile,
          onPressed: account.hasApiSession && !_pushingProfile
              ? _onPushProfile
              : null,
        ),
        _RowIconBtn(
          tooltip: 'Открыть Web',
          icon: Icons.language,
          onPressed: _pushingProfile
              ? null
              : () => WindowLauncher.instance.openWeb(account),
        ),
        _RowIconBtn(
          tooltip: 'Прокси / изоляция',
          icon: Icons.shield_outlined,
          onPressed: _pushingProfile
              ? null
              : () => _showProxyDialog(context, account),
        ),
        _RowIconBtn(
          tooltip: 'Автоматизация',
          icon: Icons.auto_awesome_outlined,
          onPressed: _pushingProfile
              ? null
              : () => WindowLauncher.instance.openAutomation(account),
        ),
        _RowIconBtn(
          tooltip: 'Эмулятор',
          icon: Icons.phone_android_outlined,
          onPressed: _pushingProfile
              ? null
              : () {
                  final state = context.read<AppState>();
                  state.selectAccount(account);
                  state.setEmulatorPanelVisible(true);
                  state.enableEmulatorRecordMode();
                },
        ),
        _RowIconBtn(
          tooltip: 'Удалить',
          icon: Icons.delete_outline,
          color: scheme.error,
          onPressed: _pushingProfile
              ? null
              : () => _confirmDeleteAccount(context, account),
        ),
      ],
    );
  }
}

class _RowIconBtn extends StatelessWidget {
  const _RowIconBtn({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
    this.loading = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18, color: onPressed == null ? Colors.white24 : color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}

Future<void> _pushProfileToMax(BuildContext context, MaxAccount account) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(content: Text('Установка профиля «${account.label}» в MAX…')),
  );
  final result = await context.read<AppState>().pushAccountProfileToMax(account);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        result.ok
            ? 'Профиль «${account.label}» установлен в MAX'
            : 'Не удалось: ${result.error ?? 'ошибка'}',
      ),
      duration: Duration(seconds: result.ok ? 3 : 5),
    ),
  );
}

Future<void> _showProxyDialog(BuildContext context, MaxAccount account) async {
  final proxyController = TextEditingController(text: account.isolation.proxyServer ?? '');
  final isolation = account.isolation;
  var applyToAll = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text('Прокси: ${account.label}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Экран: ${isolation.screenWidth}×${isolation.screenHeight} · '
                  'CPU: ${isolation.hardwareConcurrency} · '
                  'RAM: ${isolation.deviceMemory} GB',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: proxyController,
                  decoration: const InputDecoration(
                    labelText: 'Прокси (SOCKS5 / HTTP)',
                    hintText: 'http://user:pass@host:port  или  host:port:user:pass',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: applyToAll,
                  onChanged: (v) => setLocal(() => applyToAll = v == true),
                  title: const Text('Применить ко всем аккаунтам', style: TextStyle(fontSize: 12)),
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

class _AccountProfileEditor extends StatefulWidget {
  const _AccountProfileEditor({
    required this.account,
    required this.onBack,
  });

  final MaxAccount account;
  final VoidCallback onBack;

  @override
  State<_AccountProfileEditor> createState() => _AccountProfileEditorState();
}

class _AccountProfileEditorState extends State<_AccountProfileEditor> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _descCtrl;
  String? _photoPath;
  String? _templateId;
  bool _saving = false;
  bool _templateLoaded = false;
  int _detailTab = 0;
  bool _refreshingGroups = false;
  String _groupsSearch = '';

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    _labelCtrl = TextEditingController(text: account.label);
    _nameCtrl = TextEditingController(text: account.firstName ?? '');
    _lastNameCtrl = TextEditingController(text: account.lastName ?? '');
    _descCtrl = TextEditingController(text: account.description ?? '');
    _photoPath = account.profilePhotoPath;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_templateLoaded) {
      _templateId =
          context.read<AppState>().profileTemplateByAccountId[widget.account.id];
      _templateLoaded = true;
    }
  }

  @override
  void didUpdateWidget(covariant _AccountProfileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id) {
      final account = widget.account;
      _labelCtrl.text = account.label;
      _nameCtrl.text = account.firstName ?? '';
      _lastNameCtrl.text = account.lastName ?? '';
      _descCtrl.text = account.description ?? '';
      _photoPath = account.profilePhotoPath;
      _templateId =
          context.read<AppState>().profileTemplateByAccountId[account.id];
      _templateLoaded = true;
      _detailTab = 0;
      _groupsSearch = '';
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _nameCtrl.dispose();
    _lastNameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final path = await DesktopFilePicker.pickImage(title: 'Фото профиля');
      if (path == null || !mounted) return;
      setState(() => _photoPath = path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выбрать файл: $e')),
      );
    }
  }

  Future<void> _applyTemplate(String? templateId) async {
    if (templateId == null) {
      setState(() => _templateId = null);
      return;
    }
    final template = context.read<AppState>().profileTemplateById(templateId);
    if (template == null) return;
    setState(() {
      _templateId = templateId;
      _nameCtrl.text = template.firstName ?? '';
      _lastNameCtrl.text = template.lastName ?? '';
      _descCtrl.text = template.description ?? '';
      _photoPath = template.photoPath;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final name = _nameCtrl.text.trim();
    final last = _lastNameCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final photo = _photoPath?.trim() ?? '';
    final label = _labelCtrl.text.trim();

    final result = await context.read<AppState>().updateAccountProfile(
          accountId: widget.account.id,
          label: label.isEmpty ? widget.account.label : label,
          firstName: name.isEmpty ? null : name,
          lastName: last.isEmpty ? null : last,
          description: desc.isEmpty ? null : desc,
          profilePhotoPath: photo.isEmpty ? null : photo,
          clearFirstName: name.isEmpty,
          clearLastName: last.isEmpty,
          clearDescription: desc.isEmpty,
          clearProfilePhoto: photo.isEmpty,
          profileTemplateId: _templateId,
          clearProfileTemplate: _templateId == null,
          pushToMax: true,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    final msg = result == null
        ? 'Профиль сохранён'
        : result.ok
            ? 'Профиль установлен в MAX'
            : 'Локально сохранено. MAX: ${result.error ?? 'ошибка'}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: Duration(seconds: result?.ok == false ? 5 : 3),
      ),
    );
  }

  Future<void> _refreshGroups() async {
    if (!widget.account.hasApiSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет токена — нельзя обновить группы')),
      );
      return;
    }
    setState(() => _refreshingGroups = true);
    final result =
        await context.read<AppState>().refreshAccountMemberships(widget.account.id);
    if (!mounted) return;
    setState(() => _refreshingGroups = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Групп: ${result.groups.length}'
              : (result.message.isNotEmpty ? result.message : 'Не удалось обновить'),
        ),
        duration: Duration(seconds: result.ok ? 3 : 5),
      ),
    );
  }

  static String _fmtDt(DateTime? d) {
    if (d == null) return '—';
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.accountById(widget.account.id) ?? widget.account;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'К списку',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  account.label,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              if (_detailTab == 0)
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text(
                    account.hasApiSession ? 'Установить в MAX' : 'Сохранить',
                  ),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: _refreshingGroups || !account.hasApiSession
                      ? null
                      : _refreshGroups,
                  icon: _refreshingGroups
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('Обновить'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('Профиль'),
                  icon: Icon(Icons.badge_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('Группы'),
                  icon: Icon(Icons.groups_outlined, size: 16),
                ),
              ],
              selected: {_detailTab},
              onSelectionChanged: (v) => setState(() => _detailTab = v.first),
            ),
          ),
        ),
        Expanded(
          child: _detailTab == 0
              ? _buildProfileForm(state, account)
              : _buildGroupsTab(state, account),
        ),
      ],
    );
  }

  Widget _buildProfileForm(AppState state, MaxAccount account) {
    final templates = state.profileTemplates;
    final photoExists = _photoPath != null && File(_photoPath!).existsSync();

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const Text(
              'Имя, описание и фото будут отправлены в MAX по токену аккаунта. '
              'Можно заполнить вручную или взять из шаблона.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 14),
            if (templates.isNotEmpty) ...[
              DropdownButtonFormField<String?>(
                value: templates.any((t) => t.id == _templateId) ? _templateId : null,
                decoration: const InputDecoration(
                  labelText: 'Шаблон профиля',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Без шаблона (вручную)'),
                  ),
                  for (final t in templates)
                    DropdownMenuItem<String?>(
                      value: t.id,
                      child: Text(t.name),
                    ),
                ],
                onChanged: (v) => _applyTemplate(v),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Метка в приложении',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Имя',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _lastNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Фамилия',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Описание',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Фотография профиля',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 72,
                    height: 72,
                    color: Colors.white12,
                    child: photoExists
                        ? Image.file(File(_photoPath!), fit: BoxFit.cover)
                        : const Icon(Icons.person_outline, color: Colors.white38, size: 32),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _pickPhoto,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Выбрать фото'),
                ),
                if (_photoPath != null) ...[
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => setState(() => _photoPath = null),
                    child: const Text('Убрать'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 18),
            _ParentRoleCard(accountId: account.id),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Данные аккаунта',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    _InfoLine(label: 'Телефон', value: account.phone),
                    _InfoLine(label: 'Статус', value: account.healthStatus.longLabel),
                    _InfoLine(
                      label: 'Вход',
                      value: switch (account.authMethod) {
                        MaxAuthMethod.qr => 'QR',
                        MaxAuthMethod.sms => 'SMS',
                        MaxAuthMethod.token => 'Токен',
                      },
                    ),
                    _InfoLine(
                      label: 'Viewer ID',
                      value: account.viewerId?.toString(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsTab(AppState state, MaxAccount account) {
    final q = _groupsSearch.trim().toLowerCase();
    final groups = state.membershipsFor(account.id).where((m) {
      if (q.isEmpty) return true;
      return m.title.toLowerCase().contains(q) ||
          m.chatId.toLowerCase().contains(q);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  account.hasApiSession
                      ? 'Группы, в которые вступил аккаунт. «Обновить» подтягивает список из MAX.'
                      : 'Нет токена — можно смотреть сохранённый список, обновить нельзя.',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
              Text(
                '${groups.length}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _groupsSearch = v),
            decoration: const InputDecoration(
              hintText: 'Поиск по названию или chatId…',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: _refreshingGroups && groups.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : groups.isEmpty
                  ? Center(
                      child: Text(
                        account.hasApiSession
                            ? 'Групп пока нет.\nНажмите «Обновить», чтобы загрузить из MAX.'
                            : 'Нет сохранённых групп.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: groups.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final m = groups[i];
                        final title = m.title.trim().isNotEmpty
                            ? m.title.trim()
                            : 'Без названия';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.forum_outlined, size: 20),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            'id ${m.chatId}'
                            '${m.lastVerifiedAt != null ? ' · ${_fmtDt(m.lastVerifiedAt)}' : ''}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _ParentRoleCard extends StatelessWidget {
  const _ParentRoleCard({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isParent = state.accountMap.isMotherAccount(accountId);
    final isChild = state.accountMap.isChildAccount(accountId);
    final cluster = isParent
        ? state.accountMap.clusterForMother(accountId)
        : state.clusterContainingAccount(accountId);
    final childLabels = <String>[];
    if (isParent && cluster != null) {
      for (final id in cluster.childAccountIds) {
        final a = state.accountById(id);
        if (a != null) childLabels.add(a.label);
      }
      childLabels.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    String parentOfLabel = '';
    if (isChild && cluster?.motherAccountId != null) {
      parentOfLabel =
          state.accountById(cluster!.motherAccountId!)?.label ?? cluster.motherAccountId!;
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Родительский аккаунт',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              isParent
                  ? (childLabels.isEmpty
                      ? 'Родительский · работает один, без дочерних'
                      : 'Родительский · ${childLabels.length} дочерних')
                  : isChild
                      ? 'Сейчас дочерний у «$parentOfLabel». Можно сделать родительским — он переедет.'
                      : 'Не назначен. Сделайте родительским и сразу укажите дочерние (или оставьте пустым).',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            if (isParent && childLabels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final label in childLabels)
                    Chip(
                      label: Text(label, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => showParentClusterEditor(
                  context,
                  parentAccountId: accountId,
                ),
                icon: Icon(
                  isParent ? Icons.account_tree : Icons.account_tree_outlined,
                  size: 18,
                ),
                label: Text(
                  isParent ? 'Изменить дочерние' : 'Сделать родительским',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ),
          Expanded(
            child: Text(
              (value?.trim().isNotEmpty == true) ? value!.trim() : '—',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileTemplatesTab extends StatelessWidget {
  const _ProfileTemplatesTab({
    required this.selectedTemplateId,
    required this.selectedAccountIds,
    required this.applying,
    required this.onSelectTemplate,
    required this.onToggleAccount,
    required this.onSelectAllAccounts,
    required this.onClearAccountSelection,
    required this.onDeleteTemplate,
    required this.onApply,
  });

  final String? selectedTemplateId;
  final Set<String> selectedAccountIds;
  final bool applying;
  final ValueChanged<String> onSelectTemplate;
  final ValueChanged<String> onToggleAccount;
  final ValueChanged<Iterable<String>> onSelectAllAccounts;
  final VoidCallback onClearAccountSelection;
  final VoidCallback onDeleteTemplate;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final templates = state.profileTemplates;
    final selected = state.profileTemplateById(selectedTemplateId);
    final accounts = [...state.accounts]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    if (templates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Создайте шаблон профиля — имя, описание и фото —\nчтобы быстро проставить его на несколько аккаунтов.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: templates.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final t = templates[i];
              final selectedChip = t.id == selectedTemplateId;
              return ChoiceChip(
                label: Text(t.name),
                selected: selectedChip,
                onSelected: (_) => onSelectTemplate(t.id),
              );
            },
          ),
        ),
        if (selected != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Удалить',
                  onPressed: onDeleteTemplate,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ),
          _ProfileTemplateEditor(template: selected),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Применить к аккаунтам',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: applying || accounts.isEmpty
                      ? null
                      : () => onSelectAllAccounts(accounts.map((a) => a.id)),
                  child: const Text('Все'),
                ),
                TextButton(
                  onPressed: applying || selectedAccountIds.isEmpty
                      ? null
                      : onClearAccountSelection,
                  child: const Text('Сброс'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: applying || selectedAccountIds.isEmpty ? null : onApply,
                  icon: applying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: Text(
                    applying
                        ? 'Отправка…'
                        : 'В MAX (${selectedAccountIds.length})',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: accounts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final account = accounts[i];
                final checked = selectedAccountIds.contains(account.id);
                final assigned = state.profileTemplateForAccount(account.id);
                return CheckboxListTile(
                  dense: true,
                  value: checked,
                  onChanged: applying ? null : (_) => onToggleAccount(account.id),
                  title: Text(account.label),
                  subtitle: Text(
                    [
                      account.profileDisplayName,
                      if (assigned != null) 'шаблон: ${assigned.name}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  secondary: _PhotoThumb(path: account.profilePhotoPath, size: 36),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _ProfileTemplateEditor extends StatefulWidget {
  const _ProfileTemplateEditor({required this.template});

  final ProfileTemplate template;

  @override
  State<_ProfileTemplateEditor> createState() => _ProfileTemplateEditorState();
}

class _ProfileTemplateEditorState extends State<_ProfileTemplateEditor> {
  late TextEditingController _nameCtrl;
  late TextEditingController _firstCtrl;
  late TextEditingController _lastCtrl;
  late TextEditingController _descCtrl;
  String? _photoPath;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.template.name);
    _firstCtrl = TextEditingController(text: widget.template.firstName ?? '');
    _lastCtrl = TextEditingController(text: widget.template.lastName ?? '');
    _descCtrl = TextEditingController(text: widget.template.description ?? '');
    _photoPath = widget.template.photoPath;
  }

  @override
  void didUpdateWidget(covariant _ProfileTemplateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.template.id != widget.template.id) {
      _load(widget.template);
    } else if (!_dirty &&
        (oldWidget.template.name != widget.template.name ||
            oldWidget.template.firstName != widget.template.firstName ||
            oldWidget.template.lastName != widget.template.lastName ||
            oldWidget.template.description != widget.template.description ||
            oldWidget.template.photoPath != widget.template.photoPath)) {
      _load(widget.template);
    }
  }

  void _load(ProfileTemplate t) {
    _nameCtrl.text = t.name;
    _firstCtrl.text = t.firstName ?? '';
    _lastCtrl.text = t.lastName ?? '';
    _descCtrl.text = t.description ?? '';
    _photoPath = t.photoPath;
    _dirty = false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final path = await DesktopFilePicker.pickImage(title: 'Фото для шаблона');
      if (path == null || !mounted) return;
      setState(() {
        _photoPath = path;
        _dirty = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выбрать файл: $e')),
      );
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    final first = _firstCtrl.text.trim();
    final last = _lastCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final photo = _photoPath?.trim() ?? '';
    setState(() => _saving = true);
    try {
      await context.read<AppState>().updateProfileTemplate(
            widget.template.copyWith(
              name: name,
              firstName: first.isEmpty ? null : first,
              lastName: last.isEmpty ? null : last,
              description: desc.isEmpty ? null : desc,
              photoPath: photo.isEmpty ? null : photo,
              clearFirstName: first.isEmpty,
              clearLastName: last.isEmpty,
              clearDescription: desc.isEmpty,
              clearPhoto: photo.isEmpty,
            ),
          );
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Шаблон сохранён')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoExists = _photoPath != null && File(_photoPath!).existsSync();

    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                onChanged: (_) => setState(() => _dirty = true),
                decoration: const InputDecoration(
                  labelText: 'Название шаблона',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _firstCtrl,
                      onChanged: (_) => setState(() => _dirty = true),
                      decoration: const InputDecoration(
                        labelText: 'Имя',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _lastCtrl,
                      onChanged: (_) => setState(() => _dirty = true),
                      decoration: const InputDecoration(
                        labelText: 'Фамилия',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descCtrl,
                onChanged: (_) => setState(() => _dirty = true),
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Описание',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 64,
                      height: 64,
                      color: Colors.white12,
                      child: photoExists
                          ? Image.file(File(_photoPath!), fit: BoxFit.cover)
                          : const Icon(Icons.photo_outlined, color: Colors.white38),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _pickPhoto,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Фото'),
                  ),
                  if (_photoPath != null) ...[
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                                _photoPath = null;
                                _dirty = true;
                              }),
                      child: const Text('Убрать'),
                    ),
                  ],
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _dirty && !_saving ? _save : null,
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 16),
                    label: Text(_saving ? 'Сохранение…' : 'Сохранить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({this.path, this.size = 28});

  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final exists = path != null && path!.trim().isNotEmpty && File(path!).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: size,
        height: size,
        color: Colors.white12,
        child: exists
            ? Image.file(File(path!), fit: BoxFit.cover)
            : Icon(Icons.person_outline, size: size * 0.55, color: Colors.white38),
      ),
    );
  }
}
