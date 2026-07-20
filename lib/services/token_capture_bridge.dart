/// Hooks WebSocket on web.max.ru — token capture + incoming messages.
class TokenCaptureBridge {
  static String documentScript() {
    return '''
(function () {
  if (window.__maxTokenCapture && window.__maxTokenCaptureVersion === 3) return;
  window.__maxTokenCapture = true;
  window.__maxTokenCaptureVersion = 3;

  function post(type, payload) {
    try {
      window.chrome.webview.postMessage(JSON.stringify({ type, payload }));
    } catch (_) {}
  }

  function extractToken(payload) {
    if (!payload || typeof payload !== 'object') return null;
    if (payload.tokenAttrs && typeof payload.tokenAttrs.token === 'string') {
      return payload.tokenAttrs.token;
    }
    if (typeof payload.token === 'string' && payload.token.length > 24) {
      return payload.token;
    }
    return null;
  }

  function extractPhone(payload) {
    const contact = payload?.profile?.contact || payload?.contact;
    return contact?.phone || null;
  }

  function inspectMessage(raw, direction) {
    try {
      const msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!msg || typeof msg !== 'object') return;

      const token = extractToken(msg.payload);
      if (token) {
        post('auth.tokenCaptured', {
          token,
          phone: extractPhone(msg.payload),
          opcode: msg.opcode,
        });
      }

      if (msg.opcode === 128 && msg.payload && msg.payload.message && direction === 'in') {
        const m = msg.payload.message;
        const text = (m.text || '').trim();
        if (text.length < 1) return;
        const preview = text.length > 50 ? text.slice(0, 50) + '…' : text;
        post('automation.log', { message: 'WS: opcode 128 → «' + preview + '»' });
        post('ws.chatMessage', {
          text,
          sender: m.sender,
          chatId: msg.payload.chatId,
          messageId: m.id,
        });
      }
    } catch (_) {}
  }

  const OrigWS = window.WebSocket;
  function PatchedWebSocket(url, protocols) {
    const ws = protocols !== undefined ? new OrigWS(url, protocols) : new OrigWS(url);
    ws.addEventListener('message', (ev) => inspectMessage(ev.data, 'in'));
    const origSend = ws.send.bind(ws);
    ws.send = function (data) {
      inspectMessage(data, 'out');
      return origSend(data);
    };
    return ws;
  }
  PatchedWebSocket.prototype = OrigWS.prototype;
  ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (key) {
    PatchedWebSocket[key] = OrigWS[key];
  });
  window.WebSocket = PatchedWebSocket;
  post('ws.hookReady', { ok: true });
})();
''';
  }
}
