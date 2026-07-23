import 'dart:convert';

import '../models/automation_rule.dart';
import '../models/macro_scenario.dart';

/// JavaScript injected into web.max.ru for automation on the official site.
class AutomationBridge {
  static String documentCreatedScript() {
    return _bridgeScript();
  }

  static String ensureInstalledScript() => _bridgeScript();

  static String _bridgeScript() {
    return '''
(function () {
  if (window.__maxDesktop && window.__maxDesktop.__version === 5) return;
  if (window.__maxDesktopObserver) {
    try { window.__maxDesktopObserver.disconnect(); } catch (_) {}
  }

  const state = {
    rules: [],
    repliedKeys: new Set(),
    aiSeenKeys: new Set(),
    enabled: true,
    aiEnabled: false,
    aiTargetChats: [],
    picking: false,
    pickOverlay: null,
    pickHandler: null,
    scanTimer: null,
    joinConfirmTimer: null,
    joinConfirmCooldownUntil: 0,
  };

  function post(type, payload) {
    try {
      window.chrome.webview.postMessage(JSON.stringify({ type, payload }));
    } catch (_) {}
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function normalize(text) {
    return (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  }

  function matchRule(text, rule) {
    const value = normalize(text);
    if (!value) return false;
    if (rule.type === 'autoReply') return true;
    const keywords = rule.keywords || [];
    return keywords.some((keyword) => {
      const k = normalize(keyword);
      if (!k) return false;
      return rule.matchContains ? value.includes(k) : value === k;
    });
  }

  function matchRuleOnRaw(rawText, rule) {
    const value = normalize(rawText);
    return matchRule(value, rule);
  }

  function cssPath(el) {
    if (!el || el.nodeType !== 1) return '';
    if (el.id) return '#' + CSS.escape(el.id);
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && parts.length < 6) {
      let part = node.tagName.toLowerCase();
      if (node.classList && node.classList.length) {
        part += '.' + Array.from(node.classList).slice(0, 2).map((c) => CSS.escape(c)).join('.');
      }
      const parent = node.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter((c) => c.tagName === node.tagName);
        if (siblings.length > 1) {
          part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
        }
      }
      parts.unshift(part);
      if (node.id) break;
      node = node.parentElement;
    }
    return parts.join(' > ');
  }

  function findComposerInput() {
    const selectors = [
      'div[contenteditable="true"]',
      'textarea',
      '[role="textbox"]',
      'input[type="text"]',
    ];
    for (const selector of selectors) {
      const nodes = document.querySelectorAll(selector);
      for (const node of nodes) {
        if (!node.offsetParent && node !== document.activeElement) continue;
        const rect = node.getBoundingClientRect();
        if (rect.width > 80 && rect.height > 20) return node;
      }
    }
    return document.querySelector('div[contenteditable="true"], textarea, [role="textbox"]');
  }

  function readInputText(el) {
    if (!el) return '';
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') return String(el.value || '');
    return String(el.innerText || el.textContent || '').replace(/\\u00a0/g, ' ').trim();
  }

  function setNativeValue(el, text) {
    const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, text);
    else el.value = text;
  }

  function setInputValue(el, text) {
    if (!el) return false;
    const want = String(text || '');
    el.focus();
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
      setNativeValue(el, want);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return readInputText(el) === want;
    }

    // contenteditable (MAX web / React): selectAll + insertText is most reliable
    try {
      const sel = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(el);
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (_) {}

    let ok = false;
    try {
      ok = document.execCommand('insertText', false, want);
    } catch (_) {
      ok = false;
    }

    if (!ok || !readInputText(el)) {
      try {
        el.textContent = '';
        el.dispatchEvent(new InputEvent('beforeinput', {
          bubbles: true, cancelable: true, inputType: 'deleteContentBackward', data: null,
        }));
        el.textContent = want;
        el.dispatchEvent(new InputEvent('beforeinput', {
          bubbles: true, cancelable: true, inputType: 'insertText', data: want,
        }));
        el.dispatchEvent(new InputEvent('input', {
          bubbles: true, inputType: 'insertText', data: want,
        }));
      } catch (_) {
        el.textContent = want;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }

    const got = readInputText(el);
    if (!want) return got.length === 0;
    if (got === want) return true;
    // Soft match: UI may normalize whitespace / add zero-width chars
    const norm = (s) => s.replace(/\\s+/g, ' ').trim();
    return norm(got) === norm(want) || norm(got).includes(norm(want).slice(0, Math.min(24, want.length)));
  }

  function clickSendButton() {
    const composer = findComposerInput();

    // 1) Explicit text / aria / title / test id
    const allButtons = [
      ...document.querySelectorAll('button, [role="button"], [type="submit"]'),
    ];
    for (const btn of allButtons) {
      if (!isVisible(btn)) continue;
      const label = normalize(
        [
          btn.innerText,
          btn.getAttribute('aria-label'),
          btn.getAttribute('title'),
          btn.getAttribute('data-testid'),
          btn.getAttribute('data-qa'),
          btn.getAttribute('name'),
        ]
          .filter(Boolean)
          .join(' '),
      );
      if (
        label.includes('отправ') ||
        label.includes('send') ||
        label.includes('paper-plane') ||
        label.includes('paperplane') ||
        label.includes('submit')
      ) {
        btn.click();
        return true;
      }
    }

    // 2) Buttons near the composer (icon-only send is common in MAX web)
    if (composer) {
      const near = findSendNearComposer(composer);
      if (near) {
        near.click();
        return true;
      }
    }

    // 3) Fallback: Enter in the composer (most reliable for chat UIs)
    if (composer) {
      composer.focus();
      if (pressEnterOn(composer)) return true;
    }
    return pressEnterOnActive();
  }

  function isVisible(el) {
    if (!el) return false;
    if (!el.offsetParent && el !== document.activeElement) {
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
        return false;
      }
    }
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function findSendNearComposer(composer) {
    let root = composer.parentElement;
    for (let depth = 0; depth < 6 && root; depth++) {
      const buttons = root.querySelectorAll('button, [role="button"]');
      let best = null;
      let bestScore = -1;
      const cRect = composer.getBoundingClientRect();
      for (const btn of buttons) {
        if (!isVisible(btn)) continue;
        const rect = btn.getBoundingClientRect();
        // Prefer compact square-ish controls to the right of the input
        const toTheRight = rect.left >= cRect.right - 8;
        const sameRow = Math.abs(rect.top + rect.height / 2 - (cRect.top + cRect.height / 2)) < 48;
        if (!sameRow && !toTheRight) continue;
        const area = rect.width * rect.height;
        if (area < 200 || area > 20000) continue;
        const hasSvg = !!btn.querySelector('svg');
        const disabled =
          btn.disabled === true ||
          btn.getAttribute('aria-disabled') === 'true' ||
          btn.getAttribute('data-disabled') === 'true';
        if (disabled) continue;
        let score = 0;
        if (toTheRight) score += 5;
        if (sameRow) score += 3;
        if (hasSvg) score += 2;
        if (rect.width <= 64 && rect.height <= 64) score += 2;
        if (score > bestScore) {
          bestScore = score;
          best = btn;
        }
      }
      if (best && bestScore >= 5) return best;
      root = root.parentElement;
    }
    return null;
  }

  function pressEnterOn(el) {
    if (!el) return false;
    el.focus();
    const opts = {
      key: 'Enter',
      code: 'Enter',
      keyCode: 13,
      which: 13,
      bubbles: true,
      cancelable: true,
    };
    el.dispatchEvent(new KeyboardEvent('keydown', opts));
    el.dispatchEvent(new KeyboardEvent('keypress', opts));
    el.dispatchEvent(new KeyboardEvent('keyup', opts));
    return true;
  }

  function pressEnterOnActive() {
    const el = document.activeElement || findComposerInput();
    return pressEnterOn(el);
  }

  function clickByText(text) {
    return clickByTextIn(document, text);
  }

  function clickByTextIn(root, text) {
    const target = normalize(text);
    if (!target || !root) return false;
    const nodes = root.querySelectorAll('button, a, [role="button"], [role="listitem"], span, div');
    for (const node of nodes) {
      if (!node.offsetParent && node !== document.activeElement) continue;
      const label = normalize(node.innerText || node.textContent || node.getAttribute('aria-label') || '');
      if (!label) continue;
      if (label === target || label.includes(target)) {
        node.click();
        return true;
      }
    }
    return false;
  }

  function isJoinLikePage() {
    const href = location.href || '';
    if (/max\\.ru\\/join\\//i.test(href)) return true;
    if (/web\\.max\\.ru/i.test(href) && /join/i.test(href)) return true;
    const body = normalize(document.body?.innerText || '');
    if (!body) return false;
    const hasAction = ['вступить', 'подписаться', 'присоединиться', 'отправить заявку', 'join', 'subscribe']
      .some((word) => body.includes(word));
    const hasRules = body.includes('правил') || body.includes('соглас') || body.includes('услов');
    return hasAction && (hasRules || /join/i.test(href));
  }

  function findJoinDialogRoot() {
    const selectors = '[role="dialog"], [class*="modal"], [class*="Modal"], [class*="dialog"], [class*="Dialog"], [class*="popup"], [class*="Popup"]';
    const dialogs = document.querySelectorAll(selectors);
    for (const dialog of dialogs) {
      const style = window.getComputedStyle(dialog);
      if (style.display === 'none' || style.visibility === 'hidden') continue;
      const text = normalize(dialog.innerText || '');
      if (!text) continue;
      if (text.includes('вступить') || text.includes('подписаться') || text.includes('правил') || text.includes('соглас')) {
        return dialog;
      }
    }
    return isJoinLikePage() ? document.body : null;
  }

  function confirmJoinDialogs(verbose) {
    const now = Date.now();
    if (now < state.joinConfirmCooldownUntil) return false;

    const root = findJoinDialogRoot();
    if (!root) return false;

    let acted = false;

    const boxes = root.querySelectorAll('input[type="checkbox"], [role="checkbox"]');
    for (const box of boxes) {
      const checked = box.checked === true || box.getAttribute('aria-checked') === 'true';
      if (checked) continue;
      try {
        box.click();
        acted = true;
      } catch (_) {}
    }

    const confirmTexts = [
      'принимаю правила',
      'согласиться и вступить',
      'согласен и вступить',
      'отправить заявку',
      'присоединиться',
      'подписаться',
      'подтвердить',
      'согласиться',
      'согласен',
      'принять',
      'продолжить',
      'вступить',
      'accept',
      'subscribe',
      'join',
    ];

    for (const text of confirmTexts) {
      if (clickByTextIn(root, text)) {
        acted = true;
        break;
      }
    }

    if (acted) {
      state.joinConfirmCooldownUntil = now + 2500;
      post('automation.log', { message: 'Авто-подтверждение вступления в канал/группу' });
      if (verbose) post('automation.joinConfirmed', { href: location.href });
    }
    return acted;
  }

  function startJoinConfirmTimer() {
    if (state.joinConfirmTimer) return;
    state.joinConfirmTimer = setInterval(() => {
      if (isJoinLikePage() || findJoinDialogRoot()) {
        confirmJoinDialogs(false);
      }
    }, 1500);
  }

  function clickAt(x, y) {
    const el = document.elementFromPoint(x, y);
    if (!el) return false;
    el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: x, clientY: y }));
    el.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: x, clientY: y }));
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: x, clientY: y }));
    return true;
  }

  async function executeMacroStep(step) {
    const type = step.type;
    try {
      if (type === 'wait') {
        await sleep(Math.max(100, step.waitMs || 1000));
        return { ok: true };
      }
      if (type === 'clickSelector') {
        const el = step.selector ? document.querySelector(step.selector) : null;
        if (!el) return { ok: false, error: 'Элемент не найден: ' + step.selector };
        el.click();
        return { ok: true };
      }
      if (type === 'clickText') {
        const ok = clickByText(step.text || '');
        return ok ? { ok: true } : { ok: false, error: 'Текст не найден: ' + step.text };
      }
      if (type === 'clickCoordinates') {
        const ok = clickAt(step.x || 0, step.y || 0);
        return ok ? { ok: true } : { ok: false, error: 'Клик по координатам не удался' };
      }
      if (type === 'typeText') {
        const el = step.selector ? document.querySelector(step.selector) : findComposerInput();
        if (!el) return { ok: false, error: 'Поле ввода не найдено' };
        const want = step.text || '';
        const ok = setInputValue(el, want);
        if (!ok) {
          return {
            ok: false,
            error: 'Текст не попал в поле ввода (contenteditable) — сообщение не будет отправлено',
          };
        }
        return { ok: true };
      }
      if (type === 'focusInput') {
        const el = findComposerInput();
        if (!el) return { ok: false, error: 'Поле ввода не найдено' };
        el.focus();
        return { ok: true };
      }
      if (type === 'pressEnter') {
        const composer = findComposerInput();
        if (composer && !readInputText(composer).trim()) {
          return { ok: false, error: 'Поле пустое — Enter не отправлен' };
        }
        return pressEnterOnActive() ? { ok: true } : { ok: false, error: 'Enter не отправлен' };
      }
      if (type === 'clickSend') {
        const composer = findComposerInput();
        const beforeText = readInputText(composer);
        if (!beforeText.trim()) {
          return {
            ok: false,
            error: 'Поле пустое — нечего отправлять (шаг typeText не сработал?)',
          };
        }
        const outBefore = countOutgoingMessages(document.body);
        const clicked = clickSendButton();
        if (!clicked) {
          return { ok: false, error: 'Кнопка отправки не найдена (и Enter не сработал)' };
        }
        await sleep(450);
        const afterText = readInputText(findComposerInput());
        const outAfter = countOutgoingMessages(document.body);
        if (afterText.trim() === beforeText.trim() && outAfter <= outBefore) {
          return {
            ok: false,
            error: 'Сообщение не ушло: поле не очистилось после отправки',
          };
        }
        return { ok: true };
      }
      return { ok: false, error: 'Неизвестный шаг: ' + type };
    } catch (err) {
      return { ok: false, error: String(err) };
    }
  }

  async function runMacroSteps(steps) {
    const results = [];
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      const result = await executeMacroStep(step);
      results.push({ index: i, type: step.type, ...result });
      post('macro.stepDone', { index: i, type: step.type, ...result });
      if (!result.ok) break;
    }
    const ok = results.length > 0 && results.every((r) => r.ok);
    const failed = results.filter((r) => !r.ok).length;
    post('macro.done', { results, ok, failed, total: results.length });
    return results;
  }

  function disablePicker() {
    state.picking = false;
    if (state.pickOverlay) {
      state.pickOverlay.remove();
      state.pickOverlay = null;
    }
    if (state.pickHandler) {
      document.removeEventListener('click', state.pickHandler, true);
      state.pickHandler = null;
    }
  }

  function enablePicker() {
    disablePicker();
    state.picking = true;
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483646;cursor:crosshair;background:rgba(91,141,239,0.08);';
    document.body.appendChild(overlay);
    state.pickOverlay = overlay;

    state.pickHandler = (event) => {
      event.preventDefault();
      event.stopPropagation();
      disablePicker();
      const target = document.elementFromPoint(event.clientX, event.clientY);
      if (!target) {
        post('macro.picked', { ok: false, error: 'Элемент не найден' });
        return;
      }
      post('macro.picked', {
        ok: true,
        selector: cssPath(target),
        text: (target.innerText || target.textContent || '').trim().slice(0, 120),
        x: Math.round(event.clientX),
        y: Math.round(event.clientY),
        tag: target.tagName,
      });
    };

    document.addEventListener('click', state.pickHandler, true);
    post('macro.pickerEnabled', { ok: true });
  }

  function isInChatListSidebar(node) {
    const rect = node.getBoundingClientRect();
    if (!rect.width || !rect.height) return false;
    // Узкий левый столбец со списком чатов (не область переписки)
    return rect.left < window.innerWidth * 0.30
      && rect.width < window.innerWidth * 0.32
      && rect.height < 100;
  }

  function getMessageRaw(node) {
    return (node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim();
  }

  function isLikelyOutgoing(node) {
    const raw = getMessageRaw(node);
    // MAX: «Богдан Кабанов владелец привет»
    if (/\\bвладелец\\b/i.test(raw)) return true;

    let el = node;
    for (let i = 0; i < 10 && el; i++) {
      const blob = (
        String(el.className || '') + ' ' +
        (el.getAttribute('class') || '') + ' ' +
        (el.getAttribute('data-testid') || '') + ' ' +
        (el.getAttribute('aria-label') || '') + ' ' +
        (el.getAttribute('role') || '')
      ).toLowerCase();
      if (/outgoing|outbound|self|own|sent|mine|my-message|my_message|is-out|is-mine|message-out|msg-out|from-me|by-me/.test(blob)) {
        return true;
      }
      if (/incoming|inbound|message-in|msg-in|from-other/.test(blob)) return false;
      try {
        const st = window.getComputedStyle(el);
        if (st.alignSelf === 'flex-end' || st.marginLeft === 'auto') return true;
        if (st.flexDirection === 'row-reverse') return true;
      } catch (_) {}
      el = el.parentElement;
    }

    const rect = node.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    if (rect.width > 20 && centerX > window.innerWidth * 0.52) return true;
    return false;
  }

  function cleanMessagePreview(text) {
    const cleaned = text.replace(/^[^\\n]+?\\bвладелец\\b\\s*/i, '').trim();
    return cleaned || text;
  }

  function collectMessageNodes(root) {
    const seen = new Set();
    const nodes = [];
    root.querySelectorAll(
      '[data-message-id], [class*="message"], [class*="Message"], [class*="bubble"], [class*="Bubble"], [role="listitem"]'
    ).forEach((node, index) => {
      if (isInChatListSidebar(node)) return;
      const rect = node.getBoundingClientRect();
      if (!rect.height || rect.height < 8) return;

      const raw = getMessageRaw(node);
      if (raw.length < 2 || raw.length > 2000) return;
      if (/^[0-9]{1,2}:[0-9]{2}\$/.test(raw)) return;

      const key = node.getAttribute('data-message-id') || raw.slice(0, 80) + ':' + index;
      if (seen.has(key)) return;
      seen.add(key);

      const outgoing = isLikelyOutgoing(node);
      nodes.push({ key, text: raw, preview: cleanMessagePreview(raw), node, outgoing });
    });
    return nodes;
  }

  function extractIncomingMessages(root) {
    return collectMessageNodes(root)
      .filter((m) => !m.outgoing)
      .map(({ key, text, node }) => ({ key, text, node }));
  }

  function getActiveChatTitle() {
    const docTitle = (document.title || '').trim();
    const match = docTitle.match(/чат\\s+с\\s+(.+)/i);
    if (match) return match[1].trim();

    const headerSelectors = [
      'header h1', 'header h2', 'header h3',
      '[class*="ChatHeader"]', '[class*="chatHeader"]',
      '[class*="header"][class*="title"]',
      '[class*="conversation"] [class*="title"]',
    ];
    for (const selector of headerSelectors) {
      const el = document.querySelector(selector);
      if (!el) continue;
      const line = (el.innerText || el.textContent || '').trim().split('\\n')[0].trim();
      if (line && line.length > 0 && line.length < 80) return line;
    }

    const main = document.querySelector('main') || document.body;
    const headings = main.querySelectorAll('h1, h2, h3, [role="heading"]');
    for (const el of headings) {
      if (isInChatListSidebar(el)) continue;
      const line = (el.innerText || el.textContent || '').trim().split('\\n')[0].trim();
      if (line && line.length > 0 && line.length < 80) return line;
    }

    const active = document.querySelector('[aria-selected="true"]');
    if (active) {
      const line = (active.innerText || active.textContent || '').trim().split('\\n')[0].trim();
      if (line) return line;
    }

    const title = (document.title || '').trim();
    if (title) return title.split(/[-|]/)[0].trim();
    return 'Чат';
  }

  function normalizeChatTitle(text) {
    let t = normalize(text);
    for (const prefix of ['окно чата с ', 'чат с ', 'chat with ']) {
      if (t.startsWith(prefix)) {
        t = t.slice(prefix.length).trim();
        break;
      }
    }
    return t;
  }

  function matchesTargetChat() {
    if (!state.aiTargetChats || state.aiTargetChats.length === 0) return true;
    const title = normalizeChatTitle(getActiveChatTitle());
    return state.aiTargetChats.some((target) => {
      const t = normalizeChatTitle(target);
      return t && (title.includes(t) || t.includes(title));
    });
  }

  function tryAiNotify(message, verbose) {
    if (!state.aiEnabled) {
      if (verbose) post('automation.log', { message: 'DOM: ИИ выключен в браузере' });
      return;
    }
    if (state.aiSeenKeys.has(message.key)) return;
    if (!matchesTargetChat()) {
      if (verbose) {
        post('automation.log', {
          level: 'warn',
          message: 'DOM: чат «' + getActiveChatTitle() + '» не в целях [' + state.aiTargetChats.join(', ') + ']',
        });
      }
      return;
    }
    state.aiSeenKeys.add(message.key);
    const preview = message.text.length > 60 ? message.text.slice(0, 60) + '…' : message.text;
    post('automation.log', { message: 'DOM: новое входящее → «' + preview + '»' });
    post('automation.incomingMessage', {
      key: message.key,
      text: message.text,
      chatTitle: getActiveChatTitle(),
      href: location.href,
    });
  }

  function tryAutoReply(message) {
    if (!state.enabled) return;
    for (const rule of state.rules) {
      if (!rule.enabled) continue;
      if (!matchRuleOnRaw(message.text, rule)) continue;
      if (state.repliedKeys.has(message.key)) continue;
      const input = findComposerInput();
      if (!input) {
        post('automation.log', { level: 'warn', message: 'Поле ввода не найдено' });
        return;
      }
      if (!setInputValue(input, rule.replyText || '')) return;
      const sent = clickSendButton();
      state.repliedKeys.add(message.key);
      post('automation.reply', { text: message.text, reply: rule.replyText, sent });
      return;
    }
  }

  function countOutgoingMessages(root) {
    return collectMessageNodes(root).filter((m) => m.outgoing).length;
  }

  function scanMessages(logScan) {
    const all = collectMessageNodes(document.body);
    const incoming = all.filter((m) => !m.outgoing);
    const outgoing = all.filter((m) => m.outgoing);
    const recent = incoming.slice(-20);
    let newNotified = 0;
    recent.forEach((message) => {
      const wasSeen = state.aiSeenKeys.has(message.key);
      tryAiNotify(message, logScan);
      if (!wasSeen && state.aiSeenKeys.has(message.key)) newNotified++;
      tryAutoReply(message);
    });
    if (logScan && state.aiEnabled) {
      const lastIn = incoming.length ? incoming[incoming.length - 1] : null;
      const lastOut = outgoing.length ? outgoing[outgoing.length - 1] : null;
      post('automation.aiScan', {
        found: incoming.length,
        newNotified: newNotified,
        outgoingSkipped: outgoing.length,
        lastIncoming: lastIn ? lastIn.preview.slice(0, 80) : null,
        lastOutgoing: lastOut ? lastOut.preview.slice(0, 80) : null,
        chat: getActiveChatTitle(),
        chatNormalized: normalizeChatTitle(getActiveChatTitle()),
        targets: state.aiTargetChats,
        matchesTarget: matchesTargetChat(),
        seenKeys: state.aiSeenKeys.size,
        hasComposer: !!findComposerInput(),
      });
    }
  }

  function startAiScanTimer() {
    if (state.scanTimer) return;
    state.scanTimer = setInterval(() => {
      if (state.aiEnabled) scanMessages(false);
    }, 5000);
  }

  const observer = new MutationObserver(() => {
    window.requestAnimationFrame(() => {
      scanMessages(false);
      confirmJoinDialogs(false);
    });
  });

  window.__maxDesktop = {
    __version: 5,
    setRules(rules) {
      state.rules = Array.isArray(rules) ? rules : [];
      post('automation.rulesUpdated', { count: state.rules.length });
    },
    setEnabled(enabled) {
      state.enabled = !!enabled;
    },
    setAiConfig(config) {
      const wasEnabled = state.aiEnabled;
      state.aiEnabled = !!config?.enabled;
      state.aiTargetChats = Array.isArray(config?.targetChats) ? config.targetChats : [];
      if (config?.enabled && !wasEnabled) {
        state.aiSeenKeys = new Set();
      }
      if (config?.resetSeen) {
        state.aiSeenKeys = new Set();
      }
      if (state.aiEnabled) {
        startAiScanTimer();
        setTimeout(() => scanMessages(false), 200);
      }
    },
    scanNow(force) {
      if (force) state.aiSeenKeys = new Set();
      scanMessages(true);
      post('automation.scan', { ok: true, forced: !!force });
    },
    sendMessage(text) {
      const input = findComposerInput();
      if (!input) {
        post('automation.log', { level: 'error', message: 'ИИ отправка: поле ввода не найдено' });
        return false;
      }
      if (!setInputValue(input, text || '')) {
        post('automation.log', { level: 'error', message: 'ИИ отправка: не удалось ввести текст' });
        return false;
      }
      const sent = clickSendButton();
      post('automation.log', {
        level: sent ? 'info' : 'error',
        message: sent ? 'ИИ отправка: кнопка нажата, сообщение ушло' : 'ИИ отправка: кнопка отправки не найдена',
      });
      return sent;
    },
    diagnose() {
      const messages = extractIncomingMessages(document.body);
      const title = getActiveChatTitle();
      const diag = {
        aiEnabled: state.aiEnabled,
        targets: state.aiTargetChats,
        chatTitle: title,
        chatNormalized: normalizeChatTitle(title),
        matchesTarget: matchesTargetChat(),
        incomingFound: messages.length,
        seenKeys: state.aiSeenKeys.size,
        hasComposer: !!findComposerInput(),
        href: location.href,
      };
      post('automation.aiDiag', diag);
      return diag;
    },
    ping() {
      post('automation.pong', { href: location.href, title: document.title });
    },
    runMacro(steps) {
      return runMacroSteps(Array.isArray(steps) ? steps : []);
    },
    confirmJoin(verbose) {
      return confirmJoinDialogs(!!verbose);
    },
    enablePicker() {
      enablePicker();
    },
    disablePicker() {
      disablePicker();
      post('macro.pickerDisabled', { ok: true });
    },
  };

  window.__maxDesktopObserver = observer;
  observer.observe(document.body, { childList: true, subtree: true, characterData: true });
  startAiScanTimer();
  startJoinConfirmTimer();
  post('automation.ready', { href: location.href, version: 4 });
})();
''';
  }

  static String runMacro(MacroScenario scenario) {
    final steps = scenario.steps.map((s) => s.toScriptJson()).toList();
    return 'window.__maxDesktop && window.__maxDesktop.runMacro(${jsonEncode(steps)});';
  }

  static String enablePicker() {
    return 'window.__maxDesktop && window.__maxDesktop.enablePicker();';
  }

  static String disablePicker() {
    return 'window.__maxDesktop && window.__maxDesktop.disablePicker();';
  }

  static String syncRules(List<AutomationRule> rules) {
    final payload = rules
        .where((r) => r.enabled)
        .map(
          (r) => {
            'type': r.type == AutomationRuleType.autoReply ? 'autoReply' : 'keywordReply',
            'enabled': r.enabled,
            'keywords': r.keywords,
            'replyText': r.replyText,
            'matchContains': r.matchContains,
          },
        )
        .toList();

    return 'window.__maxDesktop && window.__maxDesktop.setRules(${jsonEncode(payload)});';
  }

  static String setEnabled(bool enabled) {
    return 'window.__maxDesktop && window.__maxDesktop.setEnabled($enabled);';
  }

  static String ping() {
    return 'window.__maxDesktop && window.__maxDesktop.ping();';
  }

  static String syncAiConfig({
    required bool enabled,
    required List<String> targetChats,
    bool resetSeen = false,
  }) {
    final payload = jsonEncode({
      'enabled': enabled,
      'targetChats': targetChats,
      'resetSeen': resetSeen,
    });
    return 'window.__maxDesktop && window.__maxDesktop.setAiConfig($payload);';
  }

  static String scanNow({bool force = false}) {
    return 'window.__maxDesktop && window.__maxDesktop.scanNow($force);';
  }

  static String diagnoseScript() {
    return 'window.__maxDesktop && window.__maxDesktop.diagnose();';
  }

  static String sendMessage(String text) {
    return 'window.__maxDesktop && window.__maxDesktop.sendMessage(${jsonEncode(text)});';
  }

  static String confirmJoin({bool verbose = false}) {
    return 'window.__maxDesktop && window.__maxDesktop.confirmJoin($verbose);';
  }
}
