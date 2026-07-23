import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/active_action.dart';
import '../models/pipeline_journal_event.dart';
import '../providers/app_state.dart';
import '../services/pipeline_group_planner.dart';

/// Preview unique group distribution and run children join by invite links.
class PipelineLaunchPanel extends StatefulWidget {
  const PipelineLaunchPanel({super.key});

  @override
  State<PipelineLaunchPanel> createState() => _PipelineLaunchPanelState();
}

class _PipelineLaunchPanelState extends State<PipelineLaunchPanel> {
  bool _inviteById = false;
  bool _running = false;
  final _log = <String>[];

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
    final plan = _plan(state);
    if (!plan.ok) {
      _append(plan.error ?? 'План пуст');
      return;
    }

    setState(() {
      _running = true;
      _log.clear();
    });

    await state.addPipelineJournal(
      kind: PipelineJournalKind.launchPlan,
      message: plan.summaryLine,
      detail: _inviteById ? 'режим: по ID' : 'режим: по ссылкам',
    );

    final action = state.beginAction(
      kind: _inviteById ? ActiveActionKind.inviteChildren : ActiveActionKind.childrenJoin,
      title: _inviteById ? 'Запуск: по ID' : 'Запуск: по ссылкам',
      subtitle: plan.summaryLine,
    );

    void track(String msg) {
      _append(msg);
      state.updateActionProgress(action.id, message: msg);
    }

    try {
      if (_inviteById) {
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
                'Можно запускать и с вкладки «Раздача» — там же видно, кто уже вступил. '
                'Дочки делят назначенные группы и входят по invite-ссылкам.',
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
                      'Без ссылки: ${plan.totalWithoutLink} — в link-режиме будут пропущены',
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ],
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _inviteById,
                    onChanged: _running
                        ? null
                        : (v) => setState(() => _inviteById = v ?? false),
                    title: const Text('Добавлять по ID (матка вступит)', style: TextStyle(fontSize: 13)),
                    subtitle: const Text(
                      'Выкл. по умолчанию. Вкл. — матка входит и inviteUsers.',
                      style: TextStyle(fontSize: 11),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
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
                  child: Text(
                    plan.error ?? 'Сначала назначьте группы на шаге «Раздача»',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final summary in plan.motherSummaries) ...[
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.hive_outlined, size: 20),
                        title: Text('Матка «${summary.mother.label}» · ${summary.clusterName}'),
                        subtitle: Text(
                          '${summary.groupCount} групп → ${summary.children.length} дочек'
                          '${summary.withoutLinkCount > 0 ? ' · без ссылки: ${summary.withoutLinkCount}' : ''}',
                        ),
                      ),
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
            label: Text(_running
                ? 'Работает…'
                : (_inviteById ? 'Запустить (по ID)' : 'Запустить по ссылкам')),
          ),
        ),
      ],
    );
  }
}
