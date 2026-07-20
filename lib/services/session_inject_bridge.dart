import 'dart:convert';

/// Injects saved API session into web.max.ru localStorage before the app boots.
class SessionInjectBridge {
  static String documentScript({
    required String token,
    required String deviceId,
    int? viewerId,
  }) {
    final auth = <String, dynamic>{'token': token};
    if (viewerId != null) auth['viewerId'] = viewerId;

    final authJson = jsonEncode(auth);
    return '''
(function () {
  if (window.__maxSessionInject) return;
  window.__maxSessionInject = true;
  try {
    var auth = $authJson;
    localStorage.setItem('__oneme_device_id', ${jsonEncode(deviceId)});
    localStorage.setItem('__oneme_auth', JSON.stringify(auth));
    if (!sessionStorage.getItem('__max_desktop_session_reload')) {
      sessionStorage.setItem('__max_desktop_session_reload', '1');
      location.reload();
    }
  } catch (_) {}
})();
''';
  }
}
