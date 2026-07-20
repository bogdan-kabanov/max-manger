import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// MAX does not allow registration on web.max.ru — only via mobile/desktop app + QR login on web.
class RegistrationGuideDialog extends StatelessWidget {
  const RegistrationGuideDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => const RegistrationGuideDialog(),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Регистрация нового аккаунта MAX'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'MAX официально не даёт зарегистрироваться через web.max.ru. '
                'В браузере доступен только вход по QR-коду с телефона, где уже есть приложение MAX.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              _Step(
                number: 1,
                title: 'Зарегистрируйте номер в приложении MAX',
                body:
                    'Установите MAX на телефон (Android/iPhone) или официальный клиент MAX для Windows. '
                    'Введите номер → SMS-код → имя и фото профиля.',
                actions: [
                  TextButton(
                    onPressed: () => _openUrl('https://max.ru'),
                    child: const Text('Сайт max.ru'),
                  ),
                  TextButton(
                    onPressed: () => _openUrl('https://help.max.ru/help/about/kak-zaregistrirovatsya-v-max'),
                    child: const Text('Инструкция MAX'),
                  ),
                ],
              ),
              const _Step(
                number: 2,
                title: 'Создайте профиль в MAX Desktop',
                body:
                    'Нажмите «Добавить аккаунт» здесь — откроется web.max.ru с QR-кодом. '
                    'Каждый профиль изолирован (cookies, User-Agent, прокси).',
              ),
              const _Step(
                number: 3,
                title: 'Отсканируйте QR в приложении MAX',
                body:
                    'На телефоне: MAX → Настройки → Устройства / Вход по QR (или камера на экране входа). '
                    'Наведите на QR в центральной панели этого приложения.',
              ),
              const _Step(
                number: 4,
                title: 'Готово — сессия сохранится',
                body:
                    'После сканирования web.max.ru откроет аккаунт. Сессия сохранится в профиле MAX Desktop. '
                    'Для следующего входа снова понадобится QR с телефона.',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
                ),
                child: const Text(
                  'Обходного пути «зарегистрироваться только в браузере» у MAX нет — это ограничение самого сервиса, не нашего приложения. '
                  'Для нескольких аккаунтов: несколько SIM / номеров → регистрация в MAX на телефоне → отдельный профиль + QR для каждого.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Понятно'),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final int number;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            child: Text('$number', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(fontSize: 12, height: 1.4)),
                if (actions.isNotEmpty)
                  Wrap(spacing: 4, children: actions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
