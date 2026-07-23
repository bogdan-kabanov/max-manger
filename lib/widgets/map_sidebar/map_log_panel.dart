import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/browser_session_manager.dart';

class MapLogPanel extends StatelessWidget {
  const MapLogPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserSessionManager>();

    return SizedBox(
      height: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Журнал', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: browser.logs.isEmpty
                      ? null
                      : () {
                          final text = browser.logs
                              .map((e) =>
                                  '${e.time.hour}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')} ${e.message}')
                              .join('\n');
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Журнал скопирован')),
                          );
                        },
                  child: const Text('Копировать', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              itemCount: browser.logs.length,
              itemBuilder: (context, index) {
                final entry = browser.logs[index];
                final color = entry.level == 'error'
                    ? Colors.redAccent
                    : entry.level == 'warn'
                        ? Colors.orangeAccent
                        : entry.message.contains('🔍')
                            ? Colors.blueGrey
                            : null;
                final time =
                    '${entry.time.hour}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$time  ',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).hintColor,
                            fontFamily: 'Consolas',
                          ),
                        ),
                        TextSpan(
                          text: entry.message,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.35,
                            color: color,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
