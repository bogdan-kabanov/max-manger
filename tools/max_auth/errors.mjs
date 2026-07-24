const MESSAGES = {
  'captcha.validation-failed':
    'MAX блокирует SMS через неофициальный API (защита от ботов). Это не связано с VPN или регионом. '
    + 'Используйте «Профиль + QR» или «Вход по токену» — они работают через официальный web.max.ru.',
  'phone.region.unsupported':
    'Номер не поддерживается для SMS через API. Зарегистрируйте номер в приложении MAX на телефоне, '
    + 'затем войдите через QR в «Профиль + QR».',
  'service.unavailable': 'Сервис MAX временно недоступен. Попробуйте позже.',
  'session.invalid.state': 'Ошибка сессии MAX. Запросите код заново.',
  'login.token':
    'Токен сессии протух (FAIL_LOGIN_TOKEN). Откройте аккаунт → войдите заново через QR/web.max.ru и обновите токен.',
  FAIL_LOGIN_TOKEN:
    'Токен сессии протух (FAIL_LOGIN_TOKEN). Откройте аккаунт → войдите заново через QR/web.max.ru и обновите токен.',
  no_token: 'MAX не отправил SMS-код через API.',
};

export function mapMaxAuthError(payload, fallbackCode) {
  const code = String(payload?.error ?? payload?.message ?? fallbackCode ?? 'unknown');

  if (MESSAGES[code]) return MESSAGES[code];

  const localized = payload?.localizedMessage ?? payload?.title;
  if (typeof localized === 'string' && localized.trim()) {
    const lower = localized.toLowerCase();
    if (lower.includes('регион') || lower.includes('region') || lower.includes('captcha')) {
      return `${localized.trim()}. SMS через API недоступен — используйте QR или токен из web.max.ru.`;
    }
    return localized.trim();
  }

  return `Ошибка MAX: ${code}`;
}

export function reply(data) {
  process.stdout.write(`${JSON.stringify(data)}\n`);
}

export function ok(data) {
  reply({ ok: true, ...data });
  process.exit(0);
}

export function fail(message, extra = {}) {
  reply({ ok: false, error: message, ...extra });
  process.exit(1);
}
