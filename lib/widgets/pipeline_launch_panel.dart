import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/active_action.dart';
import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import '../services/pipeline_group_planner.dart';

/// Main launch hub: join assigned groups + post-join templates.
class PipelineLaunchPanel extends StatefulWidget {
  const PipelineLaunchPanel({super.key});

  @override
  State<PipelineLaunchPanel> createState() => _PipelineLaunchPanelState();
}

class _PipelineLaunchPanelState extends State<PipelineLaunchPanel> {
  bool _inviteById = false;
  bool _running = false;
  final _log = <String>[];
  late final TextEditingController _delaySec;

  @override
  void initState() {
    super.initState();
    _delaySec = TextEditingController(text: '2.5');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ms = context.read<AppState>().rateSettings.motherJoinDelayMs;
      _delaySec.text = _msToSecText(ms);
    });
  }

  @override
  void dispose() {
    _delaySec.dispose();
    super.dispose();
  }

  static String _msToSecText(int ms) {
    final s = ms / 1000;
    if (s == s.roundToDouble()) return s.round().toString();
    return s.toStringAsFixed(1);
  }

  int _delayMsFromField(int fallback) {
    final raw = _delaySec.text.trim().replaceAll(',', '.');
    final sec = double.tryParse(raw);
    if (sec == null || sec < 0) return fallback;
    return (sec * 1000).round().clamp(0, 600000);
  }

  Future<void> _persistDelay(AppState state) async {
    final next = state.rateSettings.copyWith(
      motherJoinDelayMs: _delayMsFromField(state.rateSettings.motherJoinDelayMs),
    );
    await state.updateRateSettings(next);
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 200) _log.removeLast();
    });
  }

  PipelineLaunchPlan _plan(AppState state) {
    return state.buildPipelineLaunchPlan(
      alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
    );
  }

  Future<void> _run(AppState state) async {
    if (_running) return;
    await _persistDelay(state);
    final plan = _plan(state);
    if (!plan.ok) {
      _append(plan.error ?? 'План пуст');
      return;
    }

    final useInviteById = _inviteById && !plan.isSoloWorkers;

    setState(() {
      _running = true;
      _log.clear();
    });

    await state.addPipelineJournal(
      kind: PipelineJournalKind.launchPlan,
      message: plan.summaryLine,
      detail: useInviteById ? 'режим: по ID' : 'режим: по ссылкам',
    );

    final action = state.beginAction(
      kind: useInviteById ? ActiveActionKind.inviteChildren : ActiveActionKind.childrenJoin,
      title: useInviteById ? 'Запуск: по ID' : 'Запуск: вступление + шаблон',
      subtitle: plan.summaryLine,
    );

    void track(String msg) {
      _append(msg);
      state.updateActionProgress(action.id, message: msg);
    }

    try {
      if (useInviteById) {
        final result = await state.runPipelineChildrenJoinById(
          cancel: action.cancelToken,
          actionId: action.id,
          onLog: track,
        );
        if (action.cancelToken.isCancelled) {
          state.finishAction(
            action.id,
            status: ActiveActionStatus.cancelled,
            message: result.message,
          );
        } else {
          state.finishAction(action.id, message: result.message);
        }
      } else {
        final result = await state.runPipelineChildrenJoinByLinks(
          cancel: action.cancelToken,
          actionId: action.id,
          onLog: track,
        );
        if (action.cancelToken.isCancelled) {
          state.finishAction(action.id, status: ActiveActionStatus.cancelled, message: result.message);
        } else {
          state.finishAction(action.id, message: result.message);
        }
      }
    } catch (e) {
      track('✗ $e');
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      await state.addPipelineJournal(
        kind: PipelineJournalKind.error,
        message: 'Запуск упал: $e',
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final plan = _plan(state);
    final scheme = Theme.of(context).colorScheme;
    final solo = plan.isSoloWorkers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Запуск',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                solo
                    ? 'Основной сценарий: аккаунт сам входит по ссылкам и шлёт шаблон '
                        '(если назначен во вкладке «Шаблоны»). Группы — из «Раздачи».'
                    : 'Основной сценарий: воркеры входят в назначенные группы и шлют шаблон. '
                        'Статусы вступлений — во вкладке «Раздача».',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plan.summaryLine,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (plan.totalWithoutLink > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Без ссылки: ${plan.totalWithoutLink} — будут пропущены',
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: _delaySec,
                    enabled: !_running,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Пауза между группами (сек)',
                      isDense: true,
                      border: OutlineInputBorder(),
                      helperText: 'Между вступлениями / invite / выходами',
                    ),
                    onEditingComplete: () => _persistDelay(state),
                  ),
                  if (!solo)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _inviteById,
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _inviteById = v ?? false),
                      title: const Text(
                        'Добавлять по ID (каскад)',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        'Выкл. — воркеры сами по ссылкам. '
                        'Вкл. — матка inviteUsers, при фейле ссылка + вход.',
                        style: TextStyle(fontSize: 11),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Режим: аккаунт сам по ссылкам (+ шаблон после входа)',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: plan.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      plan.error ??
                          'Сначала назначьте группы в «Раздаче» на аккаунт '
                          '(кластер на карте профилей можно без дочек).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final summary in plan.motherSummaries) ...[
                      ListTile(
                        dense: true,
                        leading: Icon(
                          solo ? Icons.person_outline : Icons.hive_outlined,
                          size: 20,
                        ),
                        title: Text(
                          solo
                              ? '«${summary.mother.label}» · сам'
                              : 'Матка «${summary.mother.label}» · ${summary.clusterName}',
                        ),
                        subtitle: Text(
                          solo
                              ? '${summary.groupCount} групп'
                              : '${summary.groupCount} групп → ${summary.children.length} воркеров'
                                  '${summary.withoutLinkCount > 0 ? ' · без ссылки: ${summary.withoutLinkCount}' : ''}',
                        ),
                      ),
                      if (!solo)
                        for (final slot in plan.slots.where((s) => s.mother.id == summary.mother.id))
                          Padding(
                            padding: const EdgeInsets.only(left: 40, bottom: 4),
                            child: Text(
                              '· ${slot.child.label}: ${slot.groupCount} групп'
                              '${slot.withoutLinkCount > 0 ? ' (−${slot.withoutLinkCount} без ссылки)' : ''}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      const Divider(height: 16),
                    ],
                    if (_log.isNotEmpty) ...[
                      const Text('Журнал запуска', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      for (final line in _log.take(40))
                        Text(line, style: const TextStyle(fontSize: 11, fontFamily: 'Consolas')),
                    ],
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            onPressed: _running || !plan.ok ? null : () => _run(state),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(
              _running
                  ? 'Работает…'
                  : solo
                      ? 'Запустить: вступление + шаблон'
                      : (_inviteById ? 'Запустить (по ID)' : 'Запустить по ссылкам'),
            ),
          ),
        ),
      ],
    );
  }
}
