import { MaxClient, inviteUsers, resolveGroupByLink, addContact, createChannel, OPCODES, generateRandomId } from '@mqpanda/vkmax-node';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fail, ok, mapMaxAuthError } from './errors.mjs';
import {
  progress,
  initMotherLog,
  summarizeArgs,
  summarizeRpc,
  getMotherLogPath,
  maskToken,
} from './mother_logger.mjs';
import { applyProxy, maskProxy, withProxy, currentProxyUrl } from './proxy.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sessionsDir = path.join(__dirname, 'sessions');

function sessionPath(phone) {
  const safe = phone.replace(/[^0-9+]/g, '');
  return path.join(sessionsDir, `${safe}.json`);
}

async function saveSession(phone, data) {
  await mkdir(sessionsDir, { recursive: true });
  await writeFile(sessionPath(phone), JSON.stringify(data, null, 2), 'utf-8');
}

async function loadSession(phone) {
  try {
    const raw = await readFile(sessionPath(phone), 'utf-8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function extractToken(payload) {
  if (typeof payload?.tokenAttrs?.token === 'string') return payload.tokenAttrs.token;
  if (typeof payload?.token === 'string') return payload.token;
  return undefined;
}

function asString(value) {
  if (value == null) return undefined;
  const text = String(value).trim();
  return text.length > 0 ? text : undefined;
}

function pickNameEntry(names) {
  if (!Array.isArray(names) || names.length === 0) return null;
  return names.find((n) => n && (n.type === 'ONEME' || n.type === 'CUSTOM')) ?? names[0];
}

function extractProfile(payload) {
  const profile = payload?.profile ?? {};
  const contact = profile.contact ?? profile;
  const entry = pickNameEntry(contact.names);
  let firstName = asString(entry?.firstName ?? contact.firstName);
  let lastName = asString(entry?.lastName ?? contact.lastName);
  const displayName = asString(entry?.name ?? contact.name);
  // MAX often returns only `name` (e.g. «Илья») without firstName/lastName split.
  if (!firstName && displayName) {
    const parts = displayName.split(/\s+/).filter(Boolean);
    if (parts.length >= 2) {
      firstName = parts[0];
      lastName = lastName ?? parts.slice(1).join(' ');
    } else {
      firstName = displayName;
    }
  }
  const composed = [firstName, lastName].filter(Boolean).join(' ');
  const name = displayName ?? (composed || undefined);
  const phoneRaw = contact.phone ?? profile.phone ?? payload?.phone;
  const phone = asString(phoneRaw);
  const description = asString(
    contact.description ??
      profile.description ??
      contact.about ??
      profile.about ??
      entry?.description,
  );
  return {
    name: name ?? phone,
    firstName,
    lastName,
    description,
    phone,
    id: contact.id ?? profile.id,
  };
}

async function cmdSendCode(phone) {
  const client = new MaxClient();
  try {
    await client.connect();
    await client._sendHelloPacket();
    const start = await client.invokeMethod(17, {
      phone,
      type: 'START_AUTH',
      language: 'ru',
    });
    const payload = start.payload ?? {};
    if (payload.error) {
      fail(mapMaxAuthError(payload), { code: payload.error });
    }
    if (!payload.token) {
      fail(mapMaxAuthError({}, 'no_token'), { code: 'no_token' });
    }
    await saveSession(phone, { smsToken: payload.token, phone });
    ok({ smsSent: true, phone, message: 'Код отправлен на номер (SMS или приложение MAX)' });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdVerifyCode(phone, code) {
  const session = await loadSession(phone);
  if (!session?.smsToken) fail('Сначала запросите SMS-код');

  const client = new MaxClient();
  try {
    await client.connect();
    const response = await client.signIn(session.smsToken, code);
    const payload = response.payload ?? {};
    if (payload.error) fail(mapMaxAuthError(payload), { code: payload.error });

    if (payload.passwordChallenge) {
      await saveSession(phone, {
        ...session,
        trackId: payload.passwordChallenge.trackId,
        hint: payload.passwordChallenge.hint,
      });
      ok({
        requires2FA: true,
        hint: payload.passwordChallenge.hint,
        phone,
      });
      return;
    }

    const token = extractToken(payload);
    const profile = extractProfile(payload);
    if (!token) fail('Вход выполнен, но токен не получен');

    await saveSession(phone, { phone, token, profile });
    ok({ requires2FA: false, token, profile, phone });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdVerify2FA(phone, password) {
  const session = await loadSession(phone);
  if (!session?.trackId) fail('2FA сессия не найдена');

  const client = new MaxClient();
  try {
    await client.connect();
    const response = await client.verifyPassword(session.trackId, password);
    const payload = response.payload ?? {};
    if (payload.error) fail(mapMaxAuthError(payload), { code: payload.error });

    const token = extractToken(payload);
    const profile = extractProfile(payload);
    if (!token) fail('2FA пройдена, но токен не получен');

    await saveSession(phone, { phone, token, profile });
    ok({ token, profile, phone });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function enrichProfileFromContacts(client, profile) {
  if (!profile?.id) return profile;
  try {
    const response = await client.invokeMethod(32, { contactIds: [profile.id] });
    const payload = response?.payload ?? {};
    const contacts = payload.contacts ?? payload.contact ?? null;
    let contact = null;
    if (Array.isArray(contacts) && contacts.length > 0) contact = contacts[0];
    else if (contacts && typeof contacts === 'object' && !Array.isArray(contacts)) contact = contacts;
    else if (payload.contact) contact = payload.contact;
    if (!contact) return profile;
    const enriched = extractProfile({ profile: { contact } });
    return {
      ...profile,
      name: enriched.name ?? profile.name,
      firstName: enriched.firstName ?? profile.firstName,
      lastName: enriched.lastName ?? profile.lastName,
      description: enriched.description ?? profile.description,
      phone: enriched.phone ?? profile.phone,
      id: enriched.id ?? profile.id,
    };
  } catch (_) {
    return profile;
  }
}

async function cmdLoginToken(token, proxy) {
  try {
    const used = applyProxy(proxy);
    if (used) progress(`[Прокси] ${maskProxy(used)}`);
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }

  const client = new MaxClient();
  try {
    await client.connect();
    const response = await client.loginByToken(token);
    const payload = response.payload ?? {};
    if (payload.error) fail(mapMaxAuthError(payload), { code: payload.error });

    let profile = extractProfile(payload);
    profile = await enrichProfileFromContacts(client, profile);
    ok({ token, profile, phone: profile.phone });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseJoinHash(linkOrHash) {
  if (linkOrHash == null) return null;
  const raw = String(linkOrHash).trim();
  if (!raw || raw === 'undefined' || raw === 'null') return null;
  const match = raw.match(/max\.ru\/join\/([A-Za-z0-9_-]+)/i);
  if (match) return isValidJoinHash(match[1]) ? match[1] : null;
  if (/^[A-Za-z0-9_-]+$/.test(raw)) return isValidJoinHash(raw) ? raw : null;
  return null;
}

function isValidJoinHash(hash) {
  if (hash == null) return false;
  const raw = String(hash).trim();
  if (!raw || raw === 'undefined' || raw === 'null') return false;
  return /^[A-Za-z0-9_-]{8,}$/.test(raw);
}

function sanitizeHashes(hashes) {
  return [...new Set((hashes ?? []).map((h) => parseJoinHash(h) ?? (isValidJoinHash(h) ? String(h).trim() : null)).filter(Boolean))];
}

function groupHash(group) {
  const hash = group?.hash ?? parseJoinHash(group?.inviteUrl);
  return isValidJoinHash(hash) ? String(hash).trim() : null;
}

async function connectWithToken(token, proxy = undefined) {
  const run = async () => {
    progress('[API] connect + loginByToken…', 'debug', {
      token: maskToken(token),
      proxy: currentProxyUrl() ? maskProxy(currentProxyUrl()) : null,
    });
    const client = new MaxClient();
    await client.connect();
    const response = await client.loginByToken(token);
    const payload = response.payload ?? {};
    progress('[API] loginByToken ответ', 'debug', summarizeRpc(response));
    if (payload.error) {
      await client.disconnect().catch(() => undefined);
      fail(mapMaxAuthError(payload), { code: payload.error });
    }
    const profile = extractProfile(payload);
    const loginChats = Array.isArray(payload.chats) ? payload.chats : [];
    progress(
      `[API] аккаунт: id=${profile.id}, name=${profile.name ?? '?'}, phone=${profile.phone ?? '?'}`
      + `, чатов в login: ${loginChats.length}`,
      'info',
    );
    return {
      client,
      profileId: profile.id,
      token,
      loginChats,
      chatMarker: payload.chatMarker ?? null,
    };
  };

  if (proxy != null && String(proxy).trim()) {
    return withProxy(proxy, run);
  }
  // Ensure MaxClient is patched even without proxy (idempotent).
  applyProxy(currentProxyUrl());
  return run();
}

async function ensureConnected(client, token) {
  if (client.isConnected) return;

  // Server-side disconnect leaves keepalive running — clear before reconnect.
  if (client._keepaliveTask) {
    clearInterval(client._keepaliveTask);
    client._keepaliveTask = null;
  }

  await client.connect();
  const response = await client.loginByToken(token);
  const payload = response.payload ?? {};
  if (payload.error) {
    fail(mapMaxAuthError(payload), { code: payload.error });
  }
}

async function safeDisconnect(client) {
  if (!client?.isConnected) return;
  await client.disconnect().catch(() => undefined);
}

function normalizeUserIds(userIds = []) {
  return [...new Set((userIds ?? []).map((id) => {
    const raw = String(id).trim();
    if (!raw) return null;
    const num = Number(raw);
    return Number.isNaN(num) ? raw : num;
  }).filter((id) => id != null))];
}

function assertRpcOk(response, context = 'MAX API') {
  const payload = response?.payload ?? response ?? {};
  if (payload?.error) {
    const details = payload.localizedMessage ?? payload.message ?? payload.title ?? payload.error;
    throw new Error(`${context}: ${details}`);
  }
  return payload;
}

async function isUserInChat(client, chatId, userId) {
  try {
    const chat = await getChatInfo(client, chatId);
    const participants = chat?.participants ?? {};
    return Object.keys(participants).some((id) => String(id) === String(userId));
  } catch (_) {
    return false;
  }
}

async function inviteUsersToChat(client, chatId, userIds, showHistory = true) {
  const id = normalizeChatId(chatId);
  const participants = normalizeUserIds(userIds);
  return inviteUsers(client, id, participants, showHistory);
}

function rpcPayload(response, context = 'MAX API') {
  return assertRpcOk(response, context);
}

function extractMessageId(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const candidates = [
    payload.messageId,
    payload.id,
    payload.message?.id,
    payload.message?.messageId,
    payload.messages?.[0]?.id,
    payload.messages?.[0]?.messageId,
  ];
  for (const c of candidates) {
    if (c == null) continue;
    const s = String(c).trim();
    if (s) return s;
  }
  return null;
}

function extractHashesFromText(text) {
  const hashes = [];
  const regex = /max\.ru\/join\/([A-Za-z0-9_-]+)/gi;
  let match;
  while ((match = regex.exec(String(text))) !== null) {
    if (isValidJoinHash(match[1])) hashes.push(match[1]);
  }
  return hashes;
}

function extractHashFromChatObject(chat) {
  if (!chat || typeof chat !== 'object') return null;
  const candidates = [
    chat.link,
    chat.inviteLink,
    chat.joinLink,
    chat.baseLink,
    chat.invite,
    chat.options?.inviteLink,
    chat.options?.link,
    chat.data?.inviteLink,
  ];
  for (const candidate of candidates) {
    const hash = parseJoinHash(candidate);
    if (hash) return hash;
  }
  return null;
}

function decodeHtmlEntities(text) {
  return String(text ?? '')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ');
}

/** External public chat directory (max-catalog.com WP REST). Group chats are invite-only in MAX. */
async function fetchMaxCatalogChatPage({ page = 1, perPage = 100, search = '' } = {}) {
  const params = new URLSearchParams({
    per_page: String(Math.max(1, Math.min(Number(perPage) || 100, 100))),
    page: String(Math.max(1, Number(page) || 1)),
    _fields: 'id,slug,title,acf',
  });
  const q = String(search ?? '').trim();
  if (q) params.set('search', q);

  const url = `https://max-catalog.com/wp-json/wp/v2/chat?${params.toString()}`;
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json',
      'User-Agent': 'MAX-Desktop/1.0 (catalog-import)',
    },
  });
  if (!response.ok) {
    throw new Error(`max-catalog HTTP ${response.status}`);
  }
  const items = await response.json();
  if (!Array.isArray(items)) {
    throw new Error('max-catalog: неожиданный ответ');
  }
  const candidates = [];
  for (const item of items) {
    const link = item?.acf?.chat_link ?? item?.acf?.link ?? '';
    const hash = parseJoinHash(link);
    if (!hash) continue;
    candidates.push({
      hash,
      title: decodeHtmlEntities(item?.title?.rendered ?? item?.slug ?? hash),
      type: null,
      chatId: null,
      source: 'max-catalog',
    });
  }
  return {
    candidates,
    total: Number(response.headers.get('x-wp-total') || 0),
    totalPages: Number(response.headers.get('x-wp-totalpages') || 1),
  };
}

async function collectMaxCatalogChatCandidates({
  topics = [],
  target = 30,
  excludeHashes = new Set(),
  onProgress = () => undefined,
} = {}) {
  const want = Math.max(target * 4, 40);
  const collected = [];
  const seen = new Set();

  function pushAll(list) {
    for (const c of list) {
      if (!c?.hash || seen.has(c.hash) || excludeHashes.has(c.hash)) continue;
      seen.add(c.hash);
      collected.push(c);
    }
  }

  const queries = topics.length > 0 ? topics : [''];
  for (const query of queries) {
    if (collected.length >= want) break;
    try {
      const first = await fetchMaxCatalogChatPage({ page: 1, perPage: 100, search: query });
      onProgress(
        query
          ? `[Каталог web] «${query}»: ${first.total || first.candidates.length} чатов на max-catalog.com`
          : `[Каталог web] на max-catalog.com: ${first.total || first.candidates.length} чатов`,
      );
      pushAll(first.candidates);

      const totalPages = Math.max(1, first.totalPages || 1);
      if (query) {
        // Keyword: take a couple more pages of search hits.
        for (let page = 2; page <= Math.min(totalPages, 3) && collected.length < want; page++) {
          const next = await fetchMaxCatalogChatPage({ page, perPage: 100, search: query });
          pushAll(next.candidates);
          await sleep(120);
        }
      } else {
        // Open: random pages so repeats don't always start from the same chats.
        const pagePool = [];
        for (let p = 2; p <= totalPages; p++) pagePool.push(p);
        pagePool.sort(() => Math.random() - 0.5);
        const extra = Math.min(pagePool.length, Math.max(2, Math.ceil(want / 100)));
        for (let i = 0; i < extra && collected.length < want; i++) {
          const next = await fetchMaxCatalogChatPage({ page: pagePool[i], perPage: 100 });
          pushAll(next.candidates);
          onProgress(`[Каталог web] страница ${pagePool[i]}/${totalPages} → кандидатов: ${collected.length}`);
          await sleep(120);
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      onProgress(`[Каталог web] ошибка загрузки: ${message}`, 'warn');
    }
  }

  collected.sort(() => Math.random() - 0.5);
  return collected;
}

function normalizeChatId(chatId) {
  const raw = String(chatId).trim();
  const asNum = Number(raw);
  if (!Number.isNaN(asNum) && String(asNum) === raw) return asNum;
  return chatId;
}

function chatFromInfoPayload(payload) {
  if (!payload || typeof payload !== 'object') return null;
  if (payload.chat?.id != null) return payload.chat;
  if (Array.isArray(payload.chats) && payload.chats.length > 0) return payload.chats[0];
  if (payload.id != null) return payload;
  return null;
}

async function getChatInfo(client, chatId) {
  const id = normalizeChatId(chatId);

  try {
    const response = await client.invokeMethod(61, { chatId: id });
    const chat = chatFromInfoPayload(rpcPayload(response, 'GET_CHAT_INFO'));
    if (chat?.id != null) return chat;
  } catch (_) {
    // try bulk below
  }

  try {
    const response = await client.invokeMethod(48, { chatIds: [id] });
    const payload = rpcPayload(response, 'GET_CHATS');
    const chats = payload.chats ?? [];
    const found = chats.find((c) => String(c.id) === String(id));
    if (found) return found;
  } catch (_) {
    // try full list below
  }

  try {
    const chats = await getAllChats(client);
    return chats.find((c) => String(c.id) === String(id)) ?? null;
  } catch (_) {
    return null;
  }
}

async function reworkInviteLink(client, chatId, revokePrivateLink = false) {
  const id = normalizeChatId(chatId);
  const response = await client.invokeMethod(OPCODES.CHANGE_GROUP_SETTINGS, {
    chatId: id,
    revokePrivateLink: Boolean(revokePrivateLink),
  });
  const payload = rpcPayload(response, 'CHAT_UPDATE');
  return chatFromInfoPayload(payload) ?? chatFromPayload(payload);
}

async function fetchInviteLinkFromProfile(client, chatId, title = chatId, progress) {
  progress?.(`[Профиль] «${title}» — читаем invite-ссылку`);
  let chat = await getChatInfo(client, chatId);
  let hash = extractHashFromChatObject(chat);
  let source = hash ? 'profile' : null;

  if (!hash) {
    try {
      chat = await reworkInviteLink(client, chatId, false);
      hash = extractHashFromChatObject(chat);
      if (hash) source = 'profile_link';
    } catch (_) {
      // ignore
    }
  }

  if (!hash) {
    try {
      chat = await reworkInviteLink(client, chatId, true);
      hash = extractHashFromChatObject(chat);
      if (hash) source = 'profile_link_refresh';
    } catch (_) {
      // ignore
    }
  }

  const resolvedTitle = chat?.title ?? chat?.name ?? title;
  return {
    chatId: String(chatId),
    title: resolvedTitle,
    type: chat?.type ?? 'CHAT',
    hash: hash ?? null,
    inviteUrl: hash ? joinUrl(hash) : null,
    source,
    rawLink: typeof chat?.link === 'string' ? chat.link : null,
  };
}

async function fetchInviteLinksForChatIds(client, chatIds, progress, titleHints = []) {
  let chatTitleById = new Map();
  for (const group of titleHints ?? []) {
    if (!group?.chatId) continue;
    const title = group.title ?? group.name;
    if (title) chatTitleById.set(String(group.chatId), String(title));
  }
  try {
    const chats = await getAllChats(client);
    for (const chat of chats ?? []) {
      if (chat?.id == null) continue;
      chatTitleById.set(String(chat.id), chat.title ?? chat.name ?? String(chat.id));
    }
  } catch (_) {
    // titles optional
  }

  const groups = [];
  for (let i = 0; i < chatIds.length; i++) {
    const chatId = String(chatIds[i]);
    const title = chatTitleById.get(chatId) ?? chatId;
    try {
      const entry = await fetchInviteLinkFromProfile(client, chatId, title, progress);
      groups.push(entry);
      if (entry.hash) {
        progress?.(`[Профиль] ✓ «${entry.title}» → ${entry.inviteUrl}`);
      } else {
        progress?.(`[Профиль] ✗ «${entry.title}» — ссылка не получена`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      groups.push({
        chatId,
        title: chatId,
        type: 'CHAT',
        hash: null,
        inviteUrl: null,
        error: message,
      });
      progress?.(`[Профиль] ✗ ${chatId}: ${message}`);
    }
    if (i < chatIds.length - 1) await sleep(400);
  }
  return groups;
}

async function resolveForwardGroups(client, { groups = [], chatIds = [], links = [] }, progress) {
  const byId = new Map();

  for (const group of groups ?? []) {
    if (!group?.chatId) continue;
    byId.set(String(group.chatId), group);
  }

  const idsToFetch = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];
  for (const chatId of idsToFetch) {
    const existing = byId.get(chatId);
    if (groupHash(existing)) continue;
    const fetched = await fetchInviteLinkFromProfile(
      client,
      chatId,
      existing?.title ?? chatId,
      progress,
    );
    byId.set(chatId, { ...(existing ?? {}), ...fetched });
  }

  const all = [...byId.values()].map((g) => {
    const hash = groupHash(g);
    return {
      ...g,
      chatId: String(g.chatId),
      hash,
      inviteUrl: hash ? joinUrl(hash) : null,
      inviteMethod: hash ? 'link' : 'add_member',
    };
  });

  if (idsToFetch.length > 0) {
    return idsToFetch.map((chatId) => all.find((g) => g.chatId === chatId) ?? {
      chatId,
      title: chatId,
      type: 'CHAT',
      hash: null,
      inviteUrl: null,
      inviteMethod: 'add_member',
    });
  }

  const withLink = all.filter((g) => g.hash);
  if (withLink.length > 0) {
    return withLink;
  }

  // Fallback only when no chatIds were provided (legacy paste flow).
  const pasted = parseHashes(links);
  return pasted.map((hash) => ({
    hash,
    inviteUrl: joinUrl(hash),
    title: hash.slice(0, 12),
    chatId: null,
    type: 'CHAT',
    source: 'manual',
  }));
}

function isGroupLikeChat(chat) {
  const type = String(chat?.type ?? '').toUpperCase();
  if (!type || type === 'DIALOG') return false;
  return type.includes('CHAT') || type.includes('GROUP') || type.includes('CHANNEL');
}

/** kind: 'chats' | 'channels' | 'all' — CHAT = можно писать, CHANNEL = лента для подписчиков */
function matchesDiscoverKind(type, kind = 'all') {
  const t = String(type ?? '').toUpperCase();
  if (!t || t === 'DIALOG') return false;
  const isChannel = t.includes('CHANNEL');
  const isChat = t.includes('CHAT') || t.includes('GROUP');
  if (kind === 'chats') return isChat && !isChannel;
  if (kind === 'channels') return isChannel;
  return isChat || isChannel;
}

async function findInviteHashInChat(client, chatId, backward = 160) {
  const response = await client.invokeMethod(OPCODES.GET_MESSAGES, {
    chatId,
    forward: 0,
    backward,
    getMessages: true,
  });
  const payload = rpcPayload(response, 'GET_MESSAGES');
  const messages = payload.messages ?? [];
  for (const msg of messages) {
    const fromElements = (msg.elements ?? [])
      .map((el) => el?.attributes?.url ?? el?.url ?? '')
      .join(' ');
    const text = `${msg.text ?? ''} ${fromElements}`;
    const hashes = extractHashesFromText(text);
    if (hashes.length > 0) return hashes[0];
  }
  return null;
}

async function buildGroupCatalog(client, { chatIds = null, seedChats = [], chatMarker = null } = {}, progress) {
  const chats = await getAllChats(client, { seedChats, chatMarker });
  const wanted = chatIds ? new Set(chatIds.map((id) => String(id))) : null;
  const groups = [];

  for (const chat of chats ?? []) {
    if (!isGroupLikeChat(chat)) continue;
    const chatId = String(chat.id);
    if (wanted && !wanted.has(chatId)) continue;

    const title = chat.title ?? chat.name ?? chatId;
    let entry = {
      chatId,
      title,
      type: chat.type ?? 'CHAT',
      hash: extractHashFromChatObject(chat),
      inviteUrl: null,
      source: extractHashFromChatObject(chat) ? 'chat_list' : null,
    };
    if (entry.hash) entry.inviteUrl = joinUrl(entry.hash);

    if (!entry.hash) {
      entry = await fetchInviteLinkFromProfile(client, chatId, title, progress);
    }

    groups.push(entry);
  }

  groups.sort((a, b) => String(a.title).localeCompare(String(b.title), 'ru'));
  return groups;
}

function mergeHashesFromLinksAndGroups(links, groups = []) {
  const hashes = new Set(parseHashes(links));
  for (const group of groups ?? []) {
    const hash = groupHash(group);
    if (hash) hashes.add(hash);
  }
  return [...hashes];
}

function groupsFromJoinResults(results = []) {
  const groups = [];
  for (const row of results) {
    if (!row?.ok || !row?.chatId) continue;
    if (row.phase && row.phase !== 'join' && row.phase !== 'resolve' && row.phase !== 'child_join') {
      continue;
    }
    groups.push({
      chatId: String(row.chatId),
      title: row.title ?? row.chatId,
      type: 'CHAT',
      hash: row.hash ?? null,
      inviteUrl: row.hash ? joinUrl(row.hash) : null,
    });
  }
  return groups;
}

function withTimeout(promise, ms, label = 'timeout') {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timeout ${ms}ms`)), ms);
    }),
  ]);
}

async function getAllChats(client, { seedChats = [], chatMarker = null } = {}) {
  const all = [];
  const seen = new Set();
  const pushAll = (chats) => {
    for (const chat of chats ?? []) {
      if (chat?.id == null) continue;
      const key = String(chat.id);
      if (seen.has(key)) continue;
      seen.add(key);
      all.push(chat);
    }
  };

  // loginByToken already returns a chat page — use it first (avoids hung RPC on SOCKS).
  pushAll(seedChats);
  if (all.length > 0) {
    progress(`[Каналы] из login: ${all.length}`);
  }

  // Bulk [0] — often empty, but usually returns quickly.
  try {
    const response = await withTimeout(
      client.invokeMethod(48, { chatIds: [0] }),
      12000,
      'GET_CHATS_BULK',
    );
    const payload = rpcPayload(response, 'GET_CHATS_BULK');
    const before = all.length;
    pushAll(payload.chats);
    if (all.length > before) {
      progress(`[Каналы] +bulk: ${all.length - before}`);
    }
  } catch (error) {
    progress(`[Каналы] bulk пропуск: ${error instanceof Error ? error.message : error}`, 'warn');
  }

  // Enough from login — do not risk GET_CHATS(53) hang on SOCKS proxies.
  if (all.length > 0) return all;

  // Last resort only when login had no chats.
  let marker =
    typeof chatMarker === 'number' && chatMarker > 0 ? chatMarker : Date.now();
  for (let page = 0; page < 10; page++) {
    try {
      const response = await withTimeout(
        client.invokeMethod(53, { count: 100, marker }),
        8000,
        'GET_CHATS',
      );
      const payload = rpcPayload(response, 'GET_CHATS');
      const batch = payload.chats ?? [];
      if (!Array.isArray(batch) || batch.length === 0) break;
      pushAll(batch);
      const next = payload.marker;
      if (next == null || next === marker) break;
      marker = next;
      if (batch.length < 100) break;
    } catch (error) {
      progress(
        `[Каналы] GET_CHATS пропуск: ${error instanceof Error ? error.message : error}`,
        'warn',
      );
      break;
    }
  }

  return all;
}

function findDialogWithUser(chats, userId) {
  const uid = String(userId);
  for (const chat of chats ?? []) {
    if (chat.type !== 'DIALOG') continue;
    const participants = chat.participants ?? {};
    if (Object.keys(participants).some((id) => String(id) === uid)) {
      return chat.id;
    }
  }
  return null;
}

async function readJoinHashesFromDialog(client, chatId, fromUserId, backward = 80) {
  const response = await client.invokeMethod(OPCODES.GET_MESSAGES, {
    chatId,
    forward: 0,
    backward,
    getMessages: true,
  });
  const payload = rpcPayload(response, 'GET_MESSAGES');
  const messages = payload.messages ?? [];
  const hashes = new Set();
  for (const msg of messages) {
    if (fromUserId != null && String(msg.sender ?? '') !== String(fromUserId)) continue;
    for (const hash of extractHashesFromText(msg.text ?? '')) {
      hashes.add(hash);
    }
  }
  return [...hashes];
}

function parseHashes(links) {
  return [...new Set((links ?? []).map(parseJoinHash).filter(Boolean))];
}

function joinUrl(hash) {
  return `https://max.ru/join/${hash}`;
}

/** Markdown-style links: `[label](https://…)` → plain text + LINK elements. */
function parseMessageWithLinks(raw) {
  const input = String(raw ?? '');
  if (!input || !input.includes('](')) {
    return { text: input, elements: [] };
  }
  const linkRe = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
  let text = '';
  const elements = [];
  let last = 0;
  let match;
  while ((match = linkRe.exec(input)) !== null) {
    text += input.slice(last, match.index);
    const label = match[1];
    const url = match[2];
    const from = text.length;
    text += label;
    elements.push({
      type: 'LINK',
      from,
      length: label.length,
      attributes: { url },
    });
    last = match.index + match[0].length;
  }
  text += input.slice(last);
  return { text, elements };
}

function buildTextMessagePayload(rawText) {
  const parsed = parseMessageWithLinks(rawText);
  const message = {
    text: parsed.text,
    cid: generateRandomId(),
    attaches: [],
  };
  if (parsed.elements.length > 0) {
    message.elements = parsed.elements;
  }
  return message;
}

async function sendInviteLinkToUser(client, userId, hash) {
  if (!isValidJoinHash(hash)) {
    throw new Error('Некорректная invite-ссылка');
  }
  const id = typeof userId === 'string' ? parseInt(userId, 10) : userId;
  try {
    await addContact(client, id);
  } catch (_) {
    // already in contacts
  }

  const url = joinUrl(hash);
  const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
    userId: id,
    message: {
      text: url,
      cid: generateRandomId(),
      elements: [
        {
          type: 'LINK',
          from: 0,
          length: url.length,
          attributes: { url },
        },
      ],
      attaches: [],
    },
    notify: true,
  });
  return rpcPayload(response, 'SEND_MESSAGE');
}

async function runForwardLinks(client, token, hashes, childUserIds, delayMs, results, progress) {
  const validHashes = sanitizeHashes(hashes);
  if (validHashes.length === 0) {
    throw new Error('Нет валидных invite-ссылок для пересылки');
  }
  for (let c = 0; c < childUserIds.length; c++) {
    const userId = childUserIds[c];
    progress(`[Пересылка] дочерний ${c + 1}/${childUserIds.length} (id ${userId})`);
    for (let i = 0; i < validHashes.length; i++) {
      const hash = validHashes[i];
      const url = joinUrl(hash);
      try {
        await ensureConnected(client, token);
        await sendInviteLinkToUser(client, userId, hash);
        results.push({ hash, ok: true, phase: 'forward', childUserId: userId });
        progress(`[Пересылка] ✓ ${url.slice(0, 40)}… → id ${userId}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        results.push({
          hash,
          ok: false,
          phase: 'forward',
          childUserId: userId,
          error: message,
        });
        progress(`[Пересылка] ✗ id ${userId}: ${message}`);
      }
      if (i < validHashes.length - 1) await sleep(delayMs);
    }
    if (c < childUserIds.length - 1) await sleep(delayMs);
  }
}

function buildChannelDeliveryPlan(channels = []) {
  const linkChannels = [];
  const inviteChannels = [];
  for (const channel of channels ?? []) {
    if (!channel?.chatId) continue;
    const entry = {
      chatId: String(channel.chatId),
      title: channel.title ?? channel.chatId,
      hash: groupHash(channel),
      type: channel.type ?? 'CHAT',
    };
    if (entry.hash) {
      linkChannels.push(entry);
    } else {
      inviteChannels.push(entry);
    }
  }
  return { linkChannels, inviteChannels };
}

function isRussianPhone(phone) {
  if (!phone) return false;
  const digits = String(phone).replace(/\D/g, '');
  if (digits.length === 11 && (digits.startsWith('79') || digits.startsWith('89'))) return true;
  if (digits.length === 10 && digits.startsWith('9')) return true;
  return false;
}

function splitChildrenByDelivery(childTargets = [], legacy = {}) {
  const linkChildren = [];
  const addMemberUserIds = [];

  if ((childTargets ?? []).length > 0) {
    for (const target of childTargets) {
      const userId = String(target?.userId ?? '').trim();
      if (!userId) continue;
      const joinByLink = target.joinByLink === true
        || (target.joinByLink !== false && isRussianPhone(target.phone));
      if (joinByLink && target.token) {
        linkChildren.push({ userId, token: String(target.token) });
      } else {
        addMemberUserIds.push(userId);
      }
    }
    progress('[План] разделение дочерних', 'debug', {
      linkChildren: linkChildren.map((c) => c.userId),
      addMemberUserIds,
    });
    return { linkChildren, addMemberUserIds };
  }

  const userIds = legacy.forwardUserIds ?? [];
  for (let i = 0; i < userIds.length; i++) {
    addMemberUserIds.push(String(userIds[i]));
  }
  progress('[План] legacy: все дочерние → добавление по ID', 'debug', { addMemberUserIds });
  return { linkChildren, addMemberUserIds };
}

async function joinIfNotMember(client, hash, userId, progress) {
  const rawHash = parseJoinHash(hash) ?? (isValidJoinHash(hash) ? String(hash).trim() : null);
  if (!rawHash) throw new Error('Некорректная invite-ссылка');

  let chatId = null;
  let title = rawHash;
  try {
    const resolved = await resolveGroupByLink(client, rawHash);
    const chat = chatFromPayload(resolved?.payload) ?? chatFromInfoPayload(resolved?.payload);
    if (chat?.id != null) {
      chatId = String(chat.id);
      title = chat.title ?? chat.name ?? title;
    }
  } catch (_) {
    // optional pre-check
  }

  if (userId != null && chatId && await isUserInChat(client, chatId, userId)) {
    progress?.(`[Пропуск] id ${userId} уже в «${title}»`);
    return {
      hash: rawHash,
      chatId,
      title,
      alreadyMember: true,
      skipped: true,
    };
  }

  return safeJoinGroupByLink(client, rawHash);
}

async function inviteUsersToChannel(client, token, channel, userIds, progress, results = null) {
  const users = [...new Set((userIds ?? []).map((id) => String(id)).filter(Boolean))];
  const title = channel.title ?? channel.chatId;
  if (users.length === 0) return { ok: true, skipped: true };

  const pending = [];
  for (const userId of users) {
    if (await isUserInChat(client, channel.chatId, userId)) {
      progress?.(`[Пропуск] id ${userId} уже в «${title}»`);
      if (results) {
        results.push({
          ok: true,
          phase: 'invite',
          method: 'already_member',
          chatId: channel.chatId,
          title,
          childUserId: userId,
          alreadyMember: true,
        });
      }
    } else {
      pending.push(userId);
    }
  }
  if (pending.length === 0) return { ok: true, skipped: true, alreadyMember: true };

  progress(`[Добавить] «${title}» — выбрано ${pending.length} чел.`);
  try {
    await ensureConnected(client, token);
    progress('[API] inviteUsers…', 'debug', {
      chatId: channel.chatId,
      title,
      userIds: users,
    });
    const apiResponse = await inviteUsersToChat(client, channel.chatId, pending, true);
    assertRpcOk(apiResponse, 'inviteUsers');
    progress('[API] inviteUsers ответ', 'debug', summarizeRpc(apiResponse));
    await sleep(800);
    for (const userId of pending) {
      const inChat = await isUserInChat(client, channel.chatId, userId);
      progress(`[Проверка] id ${userId} в канале: ${inChat ? 'да' : 'нет'}`, inChat ? 'info' : 'warn');
      if (!inChat) {
        throw new Error(`Участник ${userId} не появился в канале после inviteUsers`);
      }
    }
    progress(`[Добавить] ✓ «${title}» — участники добавлены маткой`);
    return { ok: true, method: 'add_member', users: pending, title };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    progress(`[Добавить] ✗ «${title}»: ${message}`, 'warn');
    return { ok: false, error: message, method: 'add_member', title };
  }
}

async function runInviteUsersToGroups(client, token, channels, userIds, delayMs, results, progress) {
  const users = [...new Set((userIds ?? []).map((id) => String(id)).filter(Boolean))];
  if (users.length === 0) return;

  for (let i = 0; i < channels.length; i++) {
    const channel = channels[i];
    const title = channel.title ?? channel.chatId;
    progress(`[Добавить] ${i + 1}/${channels.length} «${title}» — выбрано ${users.length} чел.`);
    const outcome = await inviteUsersToChannel(client, token, channel, users, progress);
    if (outcome.ok && !outcome.skipped) {
      for (const userId of users) {
        results.push({
          ok: true,
          phase: 'invite',
          method: 'add_member',
          chatId: channel.chatId,
          title,
          childUserId: userId,
        });
      }
    } else if (!outcome.skipped) {
      results.push({
        ok: false,
        phase: 'invite',
        method: 'add_member',
        chatId: channel.chatId,
        title,
        error: outcome.error,
      });
    }
    if (i < channels.length - 1) await sleep(delayMs);
  }
}

async function deliverAddMemberOrForwardLink(
  client,
  token,
  channel,
  userIds,
  delayMs,
  results,
  progress,
) {
  const title = channel.title ?? channel.chatId;
  const outcome = await inviteUsersToChannel(client, token, channel, userIds, progress);
  if (outcome.ok && !outcome.skipped) {
    for (const userId of userIds) {
      results.push({
        ok: true,
        phase: 'invite',
        method: 'add_member',
        chatId: channel.chatId,
        title,
        childUserId: userId,
      });
    }
    return { forwarded: false };
  }

  const hash = groupHash(channel);
  let forwardHash = hash;
  if (!forwardHash) {
    try {
      const fresh = await fetchInviteLinkFromProfile(client, channel.chatId, title, progress);
      forwardHash = groupHash(fresh);
      if (forwardHash) {
        progress(`[Профиль] ссылка для пересылки после сбоя invite: ${joinUrl(forwardHash).slice(0, 48)}…`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`[Профиль] не удалось получить ссылку: ${message}`, 'warn');
    }
  }
  if (!forwardHash) {
    results.push({
      ok: false,
      phase: 'invite',
      method: 'add_member',
      chatId: channel.chatId,
      title,
      error: outcome.error ?? 'Нет invite-ссылки для пересылки',
    });
    return { forwarded: false };
  }

  progress(`[Не-РФ] «${title}» — добавление заблокировано, пересылаем ссылку из профиля`, 'warn', {
    error: outcome.error,
    hash: forwardHash.slice(0, 20),
  });
  try {
    const fresh = await fetchInviteLinkFromProfile(client, channel.chatId, title, progress);
    const profileHash = groupHash(fresh);
    if (profileHash) {
      forwardHash = profileHash;
      progress(`[Профиль] свежая ссылка для пересылки: ${joinUrl(forwardHash).slice(0, 48)}…`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    progress(`[Профиль] не удалось обновить ссылку — используем кэш: ${message}`, 'warn');
  }
  await runForwardLinks(client, token, [forwardHash], userIds, delayMs, results, progress);
  return { forwarded: true, hash: forwardHash };
}

async function deliverChildCascade(client, motherToken, channel, child, delayMs, results, progress) {
  const userId = String(child?.userId ?? '').trim();
  const childToken = String(child?.token ?? '').trim();
  const title = channel.title ?? channel.chatId;
  const chatId = channel.chatId;
  if (!userId) return;

  if (await isUserInChat(client, chatId, userId)) {
    progress(`[Пропуск] id ${userId} уже в «${title}»`);
    results.push({
      ok: true,
      phase: 'invite',
      method: 'already_member',
      chatId,
      title,
      childUserId: userId,
      alreadyMember: true,
    });
    return;
  }

  const inviteOutcome = await inviteUsersToChannel(
    client,
    motherToken,
    channel,
    [userId],
    progress,
    results,
  );
  if (inviteOutcome.ok && !inviteOutcome.skipped && !inviteOutcome.alreadyMember) {
    if (await isUserInChat(client, chatId, userId)) {
      results.push({
        ok: true,
        phase: 'invite',
        method: 'add_member',
        chatId,
        title,
        childUserId: userId,
      });
      return;
    }
  }

  progress(
    `[Каскад] inviteUsers не сработал для id ${userId} («${title}») — пробуем ссылку`,
    'warn',
    { error: inviteOutcome.error ?? null },
  );

  let hash = groupHash(channel);
  if (!hash) {
    try {
      const fresh = await fetchInviteLinkFromProfile(client, chatId, title, progress);
      hash = groupHash(fresh);
    } catch (_) {
      // try forward without fresh hash
    }
  }

  if (hash) {
    try {
      await ensureConnected(client, motherToken);
      await sendInviteLinkToUser(client, userId, hash);
      results.push({ ok: true, phase: 'forward', hash, childUserId: userId, title });
      progress(`[Пересылка] ✓ ${joinUrl(hash).slice(0, 40)}… → id ${userId}`);

      if (childToken) {
        let childClient;
        try {
          const childProxy = child?.proxy ?? currentProxyUrl();
          progress(`[Дочерний] вступаем по ссылке сразу…`, 'info', {
            userId,
            proxy: childProxy ? 'set' : null,
          });
          const connected = await connectWithToken(childToken, childProxy);
          childClient = connected.client;
          const joinEntry = await joinIfNotMember(childClient, hash, connected.profileId, progress);
          results.push({
            ok: true,
            phase: 'child_join',
            hash,
            childUserId: userId,
            chatId: joinEntry.chatId,
            title: joinEntry.title ?? title,
            alreadyMember: joinEntry.alreadyMember === true,
          });
          const suffix = joinEntry.alreadyMember ? ' (уже в группе)' : '';
          progress(`[Дочерний] ✓ вступление по ссылке${suffix}`);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          results.push({
            ok: false,
            phase: 'child_join',
            hash,
            childUserId: userId,
            error: message,
          });
          progress(`[Дочерний] ✗ вступление: ${message}`, 'warn');
        } finally {
          if (childClient) await childClient.disconnect().catch(() => undefined);
        }
      } else {
        progress(
          `[Дочерний] токена нет — ссылка отправлена, вступление вручную/отдельным шагом`,
          'warn',
          { userId },
        );
      }
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      results.push({
        ok: false,
        phase: 'forward',
        childUserId: userId,
        title,
        error: message,
      });
      progress(`[Пересылка] ✗ id ${userId}: ${message}`, 'warn');
    }
  }

  if (!inviteOutcome.skipped) {
    results.push({
      ok: false,
      phase: 'invite',
      chatId,
      title,
      childUserId: userId,
      error: inviteOutcome.error ?? 'Не удалось добавить дочернего',
    });
  }
}

async function deliverChildrenHybrid(client, token, {
  channels,
  childTargets = [],
  forwardUserIds = [],
  childTokens = [],
  delayMs,
  results,
  progress,
  motherUserId = null,
}) {
  const plan = buildChannelDeliveryPlan(channels);
  const allChannels = [...plan.linkChannels, ...plan.inviteChannels];

  let targets = (childTargets ?? [])
    .map((t) => ({
      userId: String(t?.userId ?? '').trim(),
      token: String(t?.token ?? '').trim(),
      phone: t?.phone != null ? String(t.phone) : null,
      proxy: t?.proxy != null && String(t.proxy).trim() ? String(t.proxy).trim() : null,
    }))
    .filter((t) => t.userId);

  if (targets.length === 0 && (forwardUserIds ?? []).length > 0) {
    const ids = [...new Set((forwardUserIds ?? []).map((id) => String(id)).filter(Boolean))];
    const tokens = [...new Set((childTokens ?? []).map((t) => String(t).trim()).filter(Boolean))];
    targets = ids.map((userId, index) => ({
      userId,
      token: tokens[index] ?? tokens[0] ?? '',
      phone: null,
    }));
  }

  progress(
    `[Каналы] со ссылкой: ${plan.linkChannels.length}, по ID: ${plan.inviteChannels.length}`,
  );
  progress(`[Каскад] ${targets.length} дочерних × ${allChannels.length} каналов (ID → ссылка → вступление)`);

  if (allChannels.length === 0) {
    throw new Error('Нет каналов для добавления дочерних');
  }
  if (targets.length === 0) {
    throw new Error('Нет дочерних аккаунтов для добавления');
  }

  for (let i = 0; i < allChannels.length; i++) {
    const channel = allChannels[i];
    for (let j = 0; j < targets.length; j++) {
      await deliverChildCascade(client, token, channel, targets[j], delayMs, results, progress);
      if (j < targets.length - 1) await sleep(delayMs);
    }
    if (i < allChannels.length - 1) await sleep(delayMs);
  }

  const linkHashes = sanitizeHashes(plan.linkChannels.map((c) => c.hash));
  return { plan, linkHashes };
}

function chatFromPayload(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const chat = payload.chat ?? payload;
  if (chat && chat.id != null) return chat;
  return null;
}

async function safeJoinGroupByLink(client, hash) {
  const rawHash = parseJoinHash(hash) ?? (isValidJoinHash(hash) ? String(hash).trim() : null);
  if (!rawHash) throw new Error('Некорректная invite-ссылка');

  const linkVariants = [
    `join/${rawHash}`,
    `https://max.ru/join/${rawHash}`,
    rawHash,
  ];
  const extraPayloads = [
    {},
    { acceptRules: true },
    { agreeRules: true },
    { confirm: true },
    { acceptRules: true, confirm: true },
  ];

  let lastError = null;

  for (const link of linkVariants) {
    for (const extras of extraPayloads) {
      const data = await client.invokeMethod(OPCODES.JOIN_BY_LINK, { link, ...extras });
      const payload = data?.payload ?? {};

      if (!payload.error) {
        let chat = chatFromPayload(payload);
        if (!chat) {
          try {
            const resolved = await resolveGroupByLink(client, rawHash);
            chat = chatFromPayload(resolved?.payload);
          } catch (_) {
            // ignore
          }
        }

        if (!chat?.id) {
          lastError = new Error('JOIN_BY_LINK: нет данных о группе');
          continue;
        }

        try {
          await client.invokeMethod(75, { chatId: chat.id, subscribe: true });
        } catch (_) {
          // optional subscribe
        }

        return {
          hash: rawHash,
          chatId: chat.id,
          title: chat.title ?? chat.name ?? rawHash,
          alreadyMember: !payload.chat,
          acceptedRules: Object.keys(extras).length > 0,
        };
      }

      const err = String(payload.error);
      const details = payload.localizedMessage ?? payload.message ?? payload.title ?? err;
      lastError = new Error(`JOIN_BY_LINK: ${details}`);

      if (/member|already|joined|участник/i.test(err)) {
        const resolved = await resolveGroupByLink(client, rawHash);
        const chat = chatFromPayload(resolved?.payload);
        if (chat?.id) {
          return { hash: rawHash, chatId: chat.id, title: chat.title ?? chat.name ?? rawHash, alreadyMember: true };
        }
      }

      const needsAccept = /rules|agree|confirm|accept|правил|соглас|подтверд/i.test(`${err} ${details}`);
      if (!needsAccept && Object.keys(extras).length > 0) {
        break;
      }
      if (!needsAccept) {
        throw lastError;
      }
    }
  }

  throw lastError ?? new Error('JOIN_BY_LINK: не удалось вступить');
}

async function resolveGroupEntry(client, hash) {
  try {
    const resolved = await resolveGroupByLink(client, hash);
    const chat = chatFromPayload(resolved?.payload);
    if (chat?.id) {
      return { hash, chatId: chat.id, title: chat.title ?? chat.name ?? hash };
    }
  } catch (_) {
    // already member or resolve failed — try join
  }

  return safeJoinGroupByLink(client, hash);
}

async function runChildrenJoin(hashes, childTokenList, delayMs, results, progress, motherUserId = null, childProxies = []) {
  for (let c = 0; c < childTokenList.length; c++) {
    const childToken = childTokenList[c];
    const childProxy = childProxies[c] ?? currentProxyUrl();
    progress(`[Дочерний ${c + 1}/${childTokenList.length}] вступление в группы`);
    let childClient;
    let childUserId = null;
    try {
      ({ client: childClient, profileId: childUserId } = await connectWithToken(childToken, childProxy));
      let joinHashes = hashes;

      if (motherUserId != null) {
        await sleep(Math.min(delayMs, 3000));
        try {
          const chats = await getAllChats(childClient);
          const dialogId = findDialogWithUser(chats, motherUserId);
          if (dialogId != null) {
            progress(`[Дочерний ${c + 1}] читаем личку с маткой (id ${motherUserId})`);
            const fromDm = await readJoinHashesFromDialog(childClient, dialogId, motherUserId);
            if (fromDm.length > 0) {
              joinHashes = fromDm;
              progress(`[Дочерний ${c + 1}] ссылок в личке: ${fromDm.length}`);
            } else {
              progress(`[Дочерний ${c + 1}] в личке пока нет ссылок — берём из списка`);
            }
          } else {
            progress(`[Дочерний ${c + 1}] личка с маткой не найдена — берём из списка`);
          }
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          progress(`[Дочерний ${c + 1}] не удалось прочитать личку: ${message}`);
        }
      }

      for (let i = 0; i < joinHashes.length; i++) {
        const hash = joinHashes[i];
        try {
          const entry = await joinIfNotMember(childClient, hash, childUserId, progress);
          results.push({
            hash,
            ok: true,
            phase: 'child_join',
            childIndex: c,
            chatId: entry.chatId,
            alreadyMember: entry.alreadyMember === true || entry.skipped === true,
          });
          const suffix = entry.alreadyMember ? ' (уже в группе)' : '';
          progress(`[Дочерний ${c + 1}] ✓ ${hash.slice(0, 12)}…$suffix`);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          results.push({
            hash,
            ok: false,
            phase: 'child_join',
            childIndex: c,
            error: message,
          });
          progress(`[Дочерний ${c + 1}] ✗ ${hash.slice(0, 12)}…: ${message}`);
        }
        if (i < joinHashes.length - 1) await sleep(delayMs);
      }
    } catch (error) {
      const message = error instanceof Error
        ? (error.message || error.name || 'неизвестная ошибка')
        : String(error || 'неизвестная ошибка');
      results.push({
        ok: false,
        phase: 'child_connect',
        childIndex: c,
        error: message,
      });
      progress(`[Дочерний ${c + 1}] ✗ вход: ${message}`, 'error');
    } finally {
      if (childClient) await childClient.disconnect().catch(() => undefined);
    }
  }
}

async function cmdDiscoverChannels({
  token,
  count = 10,
  topics = [],
  excludeHashes = [],
  excludeChatIds = [],
  scanChats = 24,
  messageDepth = 120,
  kind = 'chats',
}) {
  if (!token) fail('Укажите токен аккаунта для поиска');

  const target = Math.max(1, Math.min(Number(count) || 10, 200));
  const discoverKind = ['chats', 'channels', 'all'].includes(String(kind)) ? String(kind) : 'chats';
  const knownHashes = new Set(sanitizeHashes(excludeHashes));
  const knownChatIds = new Set((excludeChatIds ?? []).map((id) => String(id)));
  const found = [];
  const foundHashes = new Set();
  const foundChatIds = new Set();

  // Empty topics = open search: broad crawl for ANY chats/channels of the selected kind.
  const userTopics = [...new Set((topics ?? []).map((t) => String(t).trim()).filter(Boolean))];
  const isOpenSearch = userTopics.length === 0;

  const DEFAULT_TOPICS_CHATS = [
    'чат',
    'группа',
    'обсуждение',
    'общение',
    'друзья',
    'знакомства',
    'работа',
    'игры',
    'крипто',
    'новости',
    'учёба',
    'универ',
    'продажи',
    'бизнес',
    'авто',
    'спорт',
    'музыка',
    'кино',
    'мемы',
    'юмор',
    'вакансии',
    'подработка',
    'аренда',
    'объявления',
    'соседи',
    'москва',
    'chat',
    'group',
  ];

  const DEFAULT_TOPICS_CHANNELS = [
    'новости',
    'канал',
    'подписаться',
    'крипто',
    'технологии',
    'москва',
    'спорт',
    'юмор',
    'музыка',
    'кино',
    'игры',
    'бизнес',
    'путешествия',
    'еда',
    'образование',
    'авто',
    'здоровье',
    'скидки',
    'вакансии',
    'блог',
    'финансы',
    'мемы',
    'channel',
  ];

  const DEFAULT_TOPICS = discoverKind === 'channels'
    ? DEFAULT_TOPICS_CHANNELS
    : discoverKind === 'all'
      ? [...new Set([...DEFAULT_TOPICS_CHATS, ...DEFAULT_TOPICS_CHANNELS])]
      : DEFAULT_TOPICS_CHATS;

  let topicQueue = isOpenSearch
    ? [...DEFAULT_TOPICS].sort(() => Math.random() - 0.5)
    : [...userTopics].sort(() => Math.random() - 0.5);

  const { client } = await connectWithToken(token);

  function expandTopicQueries(topic) {
    const t = String(topic ?? '').trim();
    if (!t) return [];
    // Open search: one query per topic — cover many themes instead of 5× expansions.
    if (isOpenSearch) return [t];
    const out = [t];
    if (discoverKind === 'chats' || discoverKind === 'all') {
      out.push(`${t} чат`, `${t} группа`, `чат ${t}`, `${t} chat`);
    }
    if (discoverKind === 'channels' || discoverKind === 'all') {
      out.push(`${t} канал`, `${t} channel`);
    }
    return [...new Set(out.map((q) => q.trim()).filter(Boolean))];
  }

  function collectCandidatesFromSearchPayload(payload) {
    const candidates = [];
    const seenLocal = new Set();

    function pushHash(hash, meta = {}) {
      if (!isValidJoinHash(hash)) return;
      if (knownHashes.has(hash) || foundHashes.has(hash) || seenLocal.has(hash)) return;
      const chatId = meta.chatId != null ? String(meta.chatId) : null;
      // Skip already-known chats before paying for resolve.
      if (chatId && (knownChatIds.has(chatId) || foundChatIds.has(chatId))) return;
      seenLocal.add(hash);
      candidates.push({
        hash,
        title: meta.title ?? null,
        type: meta.type ?? null,
        chatId,
      });
    }

    for (const row of payload?.result ?? []) {
      const chat = row?.chat ?? row?.channel ?? null;
      const title = chat?.title ?? chat?.name ?? row?.title ?? null;
      const type = chat?.type ?? row?.type ?? null;
      const chatId = chat?.id != null ? String(chat.id) : null;
      const hashFromChat = extractHashFromChatObject(chat);
      if (hashFromChat) pushHash(hashFromChat, { title, type, chatId });

      // Public link like max.ru/name — not always a join hash; still try parse.
      const linkHash = parseJoinHash(chat?.link ?? chat?.inviteLink ?? row?.link);
      if (linkHash) pushHash(linkHash, { title, type, chatId });

      const msg = row?.message ?? chat?.lastMessage;
      const elements = (msg?.elements ?? [])
        .map((el) => el?.attributes?.url ?? el?.url ?? '')
        .join(' ');
      const text = `${msg?.text ?? ''} ${elements} ${JSON.stringify(chat ?? '')}`;
      for (const hash of extractHashesFromText(text)) {
        pushHash(hash, { title, type, chatId });
      }
    }
    return candidates;
  }

  async function tryGlobalSearch(query) {
    try {
      const response = await client.invokeMethod(60, { query, count: 50 });
      const payload = rpcPayload(response, 'MSG_SEARCH_GLOBAL');
      const resultCount = Array.isArray(payload?.result) ? payload.result.length : 0;
      const candidates = collectCandidatesFromSearchPayload(payload);
      progress(`[Поиск] «${query}» → строк: ${resultCount}, invite-хешей: ${candidates.length}`);
      if (candidates.length > 0) {
        for (const c of candidates.slice(0, 8)) {
          progress(
            `[Поиск] кандидат: «${c.title ?? c.hash.slice(0, 10)}…» `
            + `тип=${c.type ?? '?'} hash=${c.hash.slice(0, 12)}…`,
          );
        }
        if (candidates.length > 8) {
          progress(`[Поиск] …ещё ${candidates.length - 8} кандидатов`);
        }
      }
      return candidates;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`[Поиск] «${query}»: ${message}`, 'warn');
      // MAX rate-limit — stop burning the queue.
      if (String(message).includes('too-many-global-search-attempts')) {
        progress('[Поиск] лимит MAX на глобальный поиск — делаем паузу 8с', 'warn');
        await sleep(8000);
      }
      return [];
    }
  }

  async function scanGroupChatsForLinks() {
    const hashes = [];
    const chats = (await getAllChats(client)).filter(isGroupLikeChat);
    const slice = chats.sort(() => Math.random() - 0.5).slice(0, Math.max(1, Number(scanChats) || 24));

    for (let i = 0; i < slice.length && found.length < target; i++) {
      const chat = slice[i];
      const title = chat.title ?? chat.name ?? chat.id;
      progress(`[Скан чатов] ${i + 1}/${slice.length}: «${title}»`);
      try {
        const response = await client.invokeMethod(OPCODES.GET_MESSAGES, {
          chatId: chat.id,
          forward: 0,
          backward: Math.max(40, Number(messageDepth) || 120),
          getMessages: true,
        });
        const messages = rpcPayload(response, 'GET_MESSAGES').messages ?? [];
        for (const msg of messages) {
          const elements = (msg.elements ?? [])
            .map((el) => el?.attributes?.url ?? el?.url ?? '')
            .join(' ');
          const text = `${msg.text ?? ''} ${elements}`;
          for (const hash of extractHashesFromText(text)) {
            if (!isValidJoinHash(hash)) continue;
            if (knownHashes.has(hash) || foundHashes.has(hash)) continue;
            if (!hashes.includes(hash)) hashes.push(hash);
          }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Скан чатов] ✗ «${title}»: ${message}`, 'warn');
      }
      if (i < slice.length - 1) await sleep(250);
    }
    return hashes.map((hash) => ({ hash, title: null, type: null, chatId: null }));
  }

  async function resolveCandidate(candidate, topic) {
    const hash = typeof candidate === 'string' ? candidate : candidate?.hash;
    const previewTitle = typeof candidate === 'object' ? candidate?.title : null;
    const previewType = typeof candidate === 'object' ? candidate?.type : null;
    const previewChatId = typeof candidate === 'object' && candidate?.chatId != null
      ? String(candidate.chatId)
      : null;
    if (!isValidJoinHash(hash)) {
      progress(`[Пропуск] битый hash «${previewTitle ?? hash}»`);
      return null;
    }
    if (knownHashes.has(hash) || foundHashes.has(hash)) {
      progress(`[Пропуск] уже известен hash ${hash.slice(0, 12)}… («${previewTitle ?? '?'}»)`);
      return null;
    }
    if (previewChatId && (knownChatIds.has(previewChatId) || foundChatIds.has(previewChatId))) {
      progress(`[Пропуск] «${previewTitle ?? previewChatId}» уже известен (chatId)`);
      return null;
    }
    if (previewType && !matchesDiscoverKind(previewType, discoverKind)) {
      progress(
        `[Пропуск] «${previewTitle ?? hash.slice(0, 10)}» тип ${previewType} `
        + `(нужны: ${discoverKind === 'chats' ? 'чаты CHAT' : discoverKind === 'channels' ? 'каналы CHANNEL' : 'все'})`,
      );
      return null;
    }

    try {
      const resolved = await resolveGroupByLink(client, hash);
      const payload = resolved?.payload ?? {};
      if (payload.error) {
        const details = payload.localizedMessage ?? payload.message ?? payload.error;
        progress(`[Пропуск] resolve «${previewTitle ?? hash.slice(0, 10)}»: ${details}`);
        return null;
      }

      const chat = chatFromPayload(payload) ?? chatFromInfoPayload(payload);
      if (!chat?.id) {
        progress(`[Пропуск] resolve «${previewTitle ?? hash.slice(0, 10)}»: нет chat.id`);
        return null;
      }

      const chatId = String(chat.id);
      if (knownChatIds.has(chatId) || foundChatIds.has(chatId)) {
        progress(`[Пропуск] «${chat.title ?? previewTitle ?? chatId}» уже в базе (chatId)`);
        return null;
      }

      const type = String(chat.type ?? previewType ?? 'CHAT').toUpperCase();
      if (type === 'DIALOG') {
        progress(`[Пропуск] «${chat.title ?? previewTitle}» — личный диалог`);
        return null;
      }
      if (!matchesDiscoverKind(type, discoverKind)) {
        progress(
          `[Пропуск] «${chat.title ?? chat.name ?? hash}» тип ${type} `
          + `(нужны: ${discoverKind === 'chats' ? 'чаты CHAT' : discoverKind === 'channels' ? 'каналы CHANNEL' : 'все'})`,
        );
        return null;
      }

      const profileHash = extractHashFromChatObject(chat);
      const finalHash = isValidJoinHash(profileHash) ? profileHash : hash;
      const entrySource = typeof candidate === 'object' && candidate?.source
        ? candidate.source
        : 'discover';

      return {
        chatId,
        title: chat.title ?? chat.name ?? previewTitle ?? hash,
        type: chat.type ?? (discoverKind === 'channels' ? 'CHANNEL' : 'CHAT'),
        hash: finalHash,
        inviteUrl: joinUrl(finalHash),
        topic: topic ?? null,
        source: entrySource,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`[Пропуск] ошибка resolve «${previewTitle ?? hash.slice(0, 10)}»: ${message}`);
      return null;
    }
  }

  try {
    const kindLabel = discoverKind === 'chats'
      ? 'чатов (можно писать)'
      : discoverKind === 'channels'
        ? 'каналов'
        : 'чатов и каналов';

    // Group chats are invite-only in MAX — use external directory for kind=chats.
    if (discoverKind === 'chats' || discoverKind === 'all') {
      progress(
        `[Каталог] импорт ${kindLabel} с max-catalog.com`
        + (isOpenSearch ? ' (без ключевых слов)' : ` по словам: ${userTopics.join(', ')}`),
      );
      const webCandidates = await collectMaxCatalogChatCandidates({
        topics: userTopics,
        target,
        excludeHashes: knownHashes,
        onProgress: progress,
      });
      progress(`[Каталог web] кандидатов со ссылками: ${webCandidates.length}`);

      for (const candidate of webCandidates) {
        if (found.length >= target) break;
        const entry = await resolveCandidate(candidate, candidate.title ?? 'max-catalog');
        if (!entry) continue;
        // For "all" keep both; for "chats" resolveCandidate already filtered CHAT.
        found.push(entry);
        foundChatIds.add(entry.chatId);
        foundHashes.add(entry.hash);
        knownHashes.add(entry.hash);
        progress(`[Каталог] + «${entry.title}» [${entry.type}] → ${entry.inviteUrl}`);
        await sleep(220);
      }
    }

    // Channels / leftover: MAX global search (indexes mostly CHANNEL).
    if (found.length < target && (discoverKind === 'channels' || discoverKind === 'all')) {
      progress(
        isOpenSearch
          ? `[Каталог] глобальный поиск MAX: до ${target - found.length} каналов`
          : `[Каталог] глобальный поиск MAX по словам…`,
      );
      if (!isOpenSearch) {
        progress(`[Каталог] ключевые слова: ${topicQueue.join(', ')}`);
      } else {
        progress(`[Каталог] темы обхода: ${topicQueue.length}`);
      }

      let topicIndex = 0;
      let dryQueryStreak = 0;
      let stopEarly = false;
      while (found.length < target && topicIndex < topicQueue.length && !stopEarly) {
        const topic = topicQueue[topicIndex++];
        const queries = expandTopicQueries(topic);
        progress(`[Поиск] ключ «${topic}» → запросы: ${queries.join(' | ')}`);

        for (const query of queries) {
          if (found.length >= target || stopEarly) break;
          const before = found.length;
          const candidates = await tryGlobalSearch(query);
          if (candidates.length === 0) {
            progress(`[Поиск] «${query}» — пусто`);
          }

          for (const candidate of candidates) {
            if (found.length >= target) break;
            const entry = await resolveCandidate(candidate, topic);
            if (!entry) continue;
            found.push(entry);
            foundChatIds.add(entry.chatId);
            foundHashes.add(entry.hash);
            knownHashes.add(entry.hash);
            progress(`[Каталог] + «${entry.title}» [${entry.type}] → ${entry.inviteUrl}`);
            await sleep(isOpenSearch ? 200 : 350);
          }

          if (found.length > before) {
            dryQueryStreak = 0;
          } else {
            dryQueryStreak++;
            if (!isOpenSearch && found.length > 0 && dryQueryStreak >= 6) {
              progress(
                `[Каталог] новых почти нет — возвращаем ${found.length} из ${target} (лимит не обязателен)`,
              );
              stopEarly = true;
              break;
            }
          }
          await sleep(isOpenSearch ? 180 : 300);
        }
        await sleep(120);
      }
    } else if (found.length < target && discoverKind === 'chats') {
      progress(
        `[Каталог] с max-catalog.com набрано ${found.length}/${target}`
        + (found.length === 0
          ? ' — глобальный поиск MAX для чатов почти бесполезен, пропускаем'
          : ''),
      );
    }

    const withLink = found.filter((g) => g.hash).length;
    progress(
      found.length >= target
        ? `[Каталог] готово: ${found.length} (лимит ${target}), со ссылкой: ${withLink}`
        : `[Каталог] готово: ${found.length} — всё что нашлось (до ${target}), со ссылкой: ${withLink}`,
    );
    ok({
      channels: found,
      groups: found,
      added: found.length,
      requested: target,
      withInviteLink: withLink,
      kind: discoverKind,
      source: discoverKind === 'chats' ? 'max-catalog' : 'mixed',
    });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdListGroups({ token, scanMessages = true }) {
  if (!token) fail('Укажите токен матки');

  const { client, loginChats, chatMarker } = await connectWithToken(token);
  try {
    progress('[Каналы] загрузка списка чатов…');
    const rawChats = await getAllChats(client, {
      seedChats: loginChats,
      chatMarker,
    });
    progress(`[Каналы] в аккаунте чатов: ${rawChats.length}`);
    const groups = [];
    for (const chat of rawChats ?? []) {
      if (!isGroupLikeChat(chat)) continue;
      const chatId = String(chat.id);
      const title = chat.title ?? chat.name ?? chatId;
      let entry = {
        chatId,
        title,
        type: chat.type ?? 'CHAT',
        hash: extractHashFromChatObject(chat),
        inviteUrl: null,
        source: extractHashFromChatObject(chat) ? 'chat_list' : null,
      };
      if (entry.hash) entry.inviteUrl = joinUrl(entry.hash);

      // For mailing we only need chatId — skip slow invite lookup when scanMessages=false.
      if (!entry.hash && scanMessages) {
        entry = await fetchInviteLinkFromProfile(client, chatId, title, progress);
      }

      groups.push(entry);
    }
    groups.sort((a, b) => String(a.title).localeCompare(String(b.title), 'ru'));
    const withLink = groups.filter((g) => g.hash).length;
    progress(`[Каналы] групп/каналов: ${groups.length}, invite: ${withLink}`);
    ok({ groups, total: groups.length, withInviteLink: withLink });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdFetchProfileInviteLinks({ token, chatIds = [], groups = [] }) {
  if (!token) fail('Укажите токен матки');
  if (!Array.isArray(chatIds) || chatIds.length === 0) fail('Укажите chatIds каналов');

  const { client } = await connectWithToken(token);
  try {
    const groupsResult = await fetchInviteLinksForChatIds(client, chatIds, progress, groups);
    const withLink = groupsResult.filter((g) => g.hash).length;
    ok({ groups: groupsResult, total: groupsResult.length, withInviteLink: withLink });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

/**
 * Resolve invite URL for an existing channel.
 * If chatId omitted — pick the newest CHANNEL owned by this account.
 */
async function cmdResolveChannelInvite({ token, chatId }) {
  if (!token) fail('Укажите токен');
  const { client, profileId } = await connectWithToken(token);
  try {
    let id = chatId != null && String(chatId).trim() ? normalizeChatId(chatId) : null;
    let title = null;

    if (id == null) {
      progress('[Канал] ищем свой CHANNEL…');
      const chats = await getAllChats(client);
      const owned = (chats ?? [])
        .filter((c) => {
          const t = String(c?.type ?? '').toUpperCase();
          if (!t.includes('CHANNEL')) return false;
          if (profileId == null) return true;
          return String(c.owner ?? '') === String(profileId);
        })
        .sort((a, b) => Number(b.lastEventTime ?? b.created ?? 0) - Number(a.lastEventTime ?? a.created ?? 0));
      if (owned.length === 0) {
        fail('У аккаунта нет своего канала (CHANNEL)');
      }
      id = normalizeChatId(owned[0].id);
      title = owned[0].title ?? owned[0].name ?? null;
      progress(`[Канал] найден «${title ?? id}» (${id})`);
    }

    const entry = await fetchInviteLinkFromProfile(client, id, title ?? String(id), progress);
    if (!entry?.hash) {
      fail('Не удалось получить invite-ссылку канала');
    }
    ok({
      ok: true,
      chatId: String(id),
      title: entry.title ?? title,
      inviteHash: entry.hash,
      inviteUrl: entry.inviteUrl ?? joinUrl(entry.hash),
    });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdScanChatInvites({ token, chatIds = [] }) {
  return cmdFetchProfileInviteLinks({ token, chatIds });
}

async function cmdJoinGroups({ token, links, delayMs = 2500 }) {
  if (!token) fail('Укажите токен матки');
  if (!Array.isArray(links) || links.length === 0) fail('Список ссылок пуст');

  const hashes = [...new Set(links.map(parseJoinHash).filter(Boolean))];
  if (hashes.length === 0) fail('Не найдено ссылок max.ru/join/…');

  const { client, profileId } = await connectWithToken(token);
  const results = [];

  try {
    for (let i = 0; i < hashes.length; i++) {
      const hash = hashes[i];
      progress(`Вступление ${i + 1}/${hashes.length}: ${hash.slice(0, 12)}…`);
      try {
        const entry = await joinIfNotMember(client, hash, profileId, progress);
        results.push({
          hash,
          ok: true,
          chatId: entry.chatId,
          title: entry.title,
        });
      } catch (error) {
        results.push({
          hash,
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      if (i < hashes.length - 1) await sleep(delayMs);
    }
  } finally {
    await client.disconnect().catch(() => undefined);
  }

  const okCount = results.filter((r) => r.ok).length;
  ok({
    results,
    groups: groupsFromJoinResults(results),
    joined: okCount,
    failed: results.length - okCount,
    total: hashes.length,
  });
}

async function leaveChat(client, chatId, progress, profileId = null) {
  const id = normalizeChatId(chatId);
  let title = String(chatId);
  try {
    const chat = await getChatInfo(client, id);
    if (chat?.title || chat?.name) title = chat.title ?? chat.name;
  } catch (_) {
    // title optional
  }

  progress?.(`[Выход] «${title}»…`);
  // opcode 58 CHAT_LEAVE — реально покинуть чат/канал.
  // opcode 75 CHAT_SUBSCRIBE (subscribe:false) только отписывает от пушей, членство остаётся.
  const response = await client.invokeMethod(58, { chatId: id });
  assertRpcOk(response, 'CHAT_LEAVE');

  // Если владелец/ограничения не дали выйти — пробуем remove себя через MANAGE_USERS.
  if (profileId != null) {
    const stillIn = await isUserInChat(client, id, profileId);
    if (stillIn) {
      progress?.(`[Выход] «${title}»: повтор через remove…`);
      const selfIds = normalizeUserIds([profileId]);
      const removeResponse = await client.invokeMethod(77, {
        chatId: id,
        userIds: selfIds,
        operation: 'remove',
        cleanMsgPeriod: 0,
      });
      assertRpcOk(removeResponse, 'CHAT_LEAVE/remove');
      const stillAfter = await isUserInChat(client, id, profileId);
      if (stillAfter) {
        throw new Error('Сервер принял запрос, но аккаунт всё ещё в чате');
      }
    }
  }

  return { chatId: String(id), title, ok: true };
}

async function cmdLeaveGroups({ token, chatIds = [], delayMs = 2500 }) {
  if (!token) fail('Укажите токен матки');
  const ids = [...new Set((chatIds ?? []).map((id) => String(id).trim()).filter(Boolean))];
  if (ids.length === 0) fail('Список chatIds пуст');

  const { client, profileId } = await connectWithToken(token);
  const results = [];

  try {
    for (let i = 0; i < ids.length; i++) {
      const chatId = ids[i];
      progress(`Выход ${i + 1}/${ids.length}: ${chatId}`);
      try {
        const entry = await leaveChat(client, chatId, progress, profileId);
        results.push({
          ok: true,
          phase: 'leave',
          chatId: entry.chatId,
          title: entry.title,
        });
      } catch (error) {
        results.push({
          ok: false,
          phase: 'leave',
          chatId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      if (i < ids.length - 1) await sleep(delayMs);
    }
  } finally {
    await client.disconnect().catch(() => undefined);
  }

  const left = results.filter((r) => r.ok).length;
  ok({
    results,
    left,
    failed: results.length - left,
    total: ids.length,
  });
}

async function cmdMotherDeploy({
  token,
  links,
  groups = [],
  chatIds = [],
  inviteUserIds = [],
  forwardUserIds = [],
  childTokens = [],
  childTargets = [],
  delayMs = 2500,
  inviteChildren = false,
  forwardChildren = true,
  childrenJoin = false,
}) {
  if (!token) fail('Укажите токен матки');

  progress('[Старт] mother-deploy', 'info', {
    inviteChildren,
    forwardChildren,
    childrenJoin,
    linksCount: (links ?? []).length,
    groupsCount: (groups ?? []).length,
    chatIdsCount: (chatIds ?? []).length,
    inviteUserIds,
    forwardUserIds,
    childTargetsCount: (childTargets ?? []).length,
    childTokensCount: (childTokens ?? []).length,
  });

  const joinHashes = parseHashes(links);
  const childChatIds = [
    ...new Set([
      ...(chatIds ?? []).map((id) => String(id)),
      ...(groups ?? []).map((g) => String(g?.chatId ?? '')).filter(Boolean),
    ]),
  ];

  if (joinHashes.length === 0 && childChatIds.length === 0) {
    fail('Вставьте ссылку для вступления матки или выберите каналы');
  }

  const userIds = [...new Set((inviteUserIds ?? []).map((id) => String(id)).filter(Boolean))];
  const forwardIds = [...new Set((forwardUserIds ?? []).map((id) => String(id)).filter(Boolean))];
  const childTokenList = [...new Set((childTokens ?? []).map((t) => String(t).trim()).filter(Boolean))];
  const targets = (childTargets ?? [])
    .map((t) => ({
      token: String(t?.token ?? '').trim(),
      userId: String(t?.userId ?? '').trim(),
      phone: t?.phone != null ? String(t.phone) : null,
      joinByLink: t?.joinByLink,
    }))
    .filter((t) => t.userId);

  if (targets.length === 0 && forwardIds.length > 0) {
    for (let i = 0; i < forwardIds.length; i++) {
      targets.push({
        userId: forwardIds[i],
        token: childTokenList[i] ?? '',
        phone: null,
        joinByLink: undefined,
      });
    }
  }

  const { client, profileId: motherUserId } = await connectWithToken(token);
  const motherToken = token;
  const results = [];
  const joined = [];
  let forwardGroups = [];
  let forwardHashes = [];

  try {
    for (let i = 0; i < joinHashes.length; i++) {
      const hash = joinHashes[i];
      progress(`[Матка] вступление ${i + 1}/${joinHashes.length}`);
      try {
        await ensureConnected(client, motherToken);
        const entry = await joinIfNotMember(client, hash, motherUserId, progress);
        joined.push(entry);
        results.push({
          hash,
          ok: true,
          phase: 'join',
          chatId: entry.chatId,
          title: entry.title,
          alreadyMember: entry.alreadyMember === true || entry.skipped === true,
        });
      } catch (error) {
        results.push({
          hash,
          ok: false,
          phase: 'join',
          error: error instanceof Error ? error.message : String(error),
        });
      }
      if (i < joinHashes.length - 1) await sleep(delayMs);
    }

    const idsForChildren = childChatIds.length > 0
      ? childChatIds
      : joined.map((g) => String(g.chatId)).filter(Boolean);

    progress('[План] idsForChildren', 'debug', { idsForChildren, joined: joined.map((g) => g.chatId) });

    let deliveryTargets = targets;
    if (deliveryTargets.length === 0 && userIds.length > 0) {
      deliveryTargets = userIds.map((userId, index) => ({
        userId,
        token: childTokenList[index] ?? childTokenList[0] ?? '',
        phone: null,
      }));
    }

    const shouldDeliverChildren = idsForChildren.length > 0 && deliveryTargets.length > 0;
    progress('[План] ветка', 'info', {
      shouldDeliverChildren,
      cascade: 'ID → ссылка → вступление',
      targets: deliveryTargets.map((t) => ({ userId: t.userId, phone: t.phone, hasToken: Boolean(t.token) })),
    });

    if (shouldDeliverChildren) {
      progress('[Каналы] проверяем invite-ссылки в профиле');
      await ensureConnected(client, motherToken);
      forwardGroups = await resolveForwardGroups(
        client,
        { groups, chatIds: idsForChildren, links: [] },
        progress,
      );

      const { linkHashes } = await deliverChildrenHybrid(client, motherToken, {
        channels: forwardGroups,
        childTargets: deliveryTargets,
        delayMs,
        results,
        progress,
        motherUserId,
      });
      forwardHashes = linkHashes;
    } else if (deliveryTargets.length > 0) {
      progress('[План] дочерние шаги пропущены — выберите каналы', 'warn');
    }
  } finally {
    await safeDisconnect(client);
  }

  const joinedCount = results.filter((r) => r.phase === 'join' && r.ok).length;
  const invitedCount = results.filter((r) => r.phase === 'invite' && r.ok).length;
  const forwardedCount = results.filter((r) => r.phase === 'forward' && r.ok).length;
  const failed = results.filter((r) => r.ok !== true);
  progress('[Итог] mother-deploy', 'info', {
    joined: joinedCount,
    invited: invitedCount,
    forwarded: forwardedCount,
    failed: failed.length,
    logFile: getMotherLogPath(),
  });
  for (const row of failed.slice(0, 20)) {
    progress(`[Итог] ✗ ${row.phase ?? '?'}: ${row.error ?? row.hash ?? row.chatId ?? '?'}`, 'warn');
  }
  if (getMotherLogPath()) {
    progress(`[Лог] полный журнал: ${getMotherLogPath()}`, 'info');
  }
  ok({
    results,
    groups: groupsFromJoinResults(results).concat(
      joined.map((g) => ({
        chatId: String(g.chatId),
        title: g.title ?? g.chatId,
        hash: g.hash,
        inviteUrl: g.hash ? joinUrl(g.hash) : null,
        type: 'CHAT',
      })),
    ),
    joined: joinedCount,
    invited: invitedCount,
    forwarded: forwardedCount,
    total: Math.max(joinHashes.length, forwardHashes.length, childChatIds.length, forwardGroups.length),
    children: childTokenList.length,
    logFile: getMotherLogPath(),
  });
}

async function cmdInviteChildren({
  token,
  links,
  groups = [],
  chatIds = [],
  inviteUserIds = [],
  childTargets = [],
  childTokens = [],
  delayMs = 2500,
}) {
  if (!token) fail('Укажите токен матки');

  const hashes = mergeHashesFromLinksAndGroups(links, groups);
  const directChatIds = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];

  if (hashes.length === 0 && directChatIds.length === 0) {
    fail('Укажите ссылки, каналы со ссылкой или chatId групп');
  }

  const userIds = [...new Set((inviteUserIds ?? []).map((id) => String(id)).filter(Boolean))];
  const hasTargets = (childTargets ?? []).some((t) => String(t?.userId ?? '').trim());
  if (userIds.length === 0 && !hasTargets) fail('Укажите ID дочерних аккаунтов');

  const { client } = await connectWithToken(token);
  const motherToken = token;
  const results = [];
  const resolvedGroups = [];

  try {
    const profileGroups = await resolveForwardGroups(
      client,
      { groups, chatIds: directChatIds, links: hashes.length ? links : [] },
      progress,
    );
    for (const group of profileGroups) {
      if (!group?.chatId) continue;
      const existing = resolvedGroups.find((g) => String(g.chatId) === String(group.chatId));
      if (existing) {
        existing.hash = group.hash ?? existing.hash;
        existing.title = group.title ?? existing.title;
      } else {
        resolvedGroups.push(group);
      }
    }

    for (let i = 0; i < hashes.length; i++) {
      const hash = hashes[i];
      progress(`[Приглашение] поиск группы ${i + 1}/${hashes.length}`);
      try {
        await ensureConnected(client, motherToken);
        const entry = await resolveGroupEntry(client, hash);
        const existing = resolvedGroups.find((g) => String(g.chatId) === String(entry.chatId));
        if (existing) {
          existing.hash = entry.hash ?? existing.hash;
          existing.title = entry.title ?? existing.title;
          progress(`[Приглашение] дубль chatId ${entry.chatId} — объединяем`, 'debug');
        } else {
          resolvedGroups.push(entry);
        }
        results.push({ hash, ok: true, phase: 'resolve', chatId: entry.chatId, title: entry.title });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Приглашение] ✗ resolve ${hash?.slice?.(0, 12) ?? hash}: ${message}`, 'warn');
        results.push({
          hash,
          ok: false,
          phase: 'resolve',
          error: message,
        });
      }
      if (i < hashes.length - 1) await sleep(delayMs);
    }

    if (resolvedGroups.length === 0) {
      fail('Не удалось найти группы для приглашения');
    }

    progress(`[Приглашение] каскад: inviteUsers → ссылка в ЛС → вступление дочки`, 'info', {
      groups: resolvedGroups.length,
      inviteUserIds: userIds,
      childTargets: (childTargets ?? []).length,
      childTokens: (childTokens ?? []).length,
    });

    await deliverChildrenHybrid(client, motherToken, {
      channels: resolvedGroups,
      childTargets,
      forwardUserIds: userIds,
      childTokens,
      delayMs,
      results,
      progress,
    });
  } finally {
    await safeDisconnect(client);
  }

  const invitedCount = results.filter(
    (r) => r.phase === 'invite' && r.ok && r.method === 'add_member',
  ).length;
  const alreadyCount = results.filter(
    (r) => r.phase === 'invite' && r.method === 'already_member',
  ).length;
  const forwardedCount = results.filter((r) => r.phase === 'forward' && r.ok).length;
  const childJoined = results.filter((r) => r.phase === 'child_join' && r.ok).length;
  const failedCount = results.filter(
    (r) =>
      (r.phase === 'invite' || r.phase === 'forward' || r.phase === 'child_join') && !r.ok,
  ).length;
  progress(
    `[Приглашение] итог: invite=${invitedCount}, уже=${alreadyCount}, ` +
      `пересылка=${forwardedCount}, вход дочки=${childJoined}, ошибок=${failedCount}`,
  );
  ok({
    results,
    groups: resolvedGroups.map((g) => ({
      chatId: String(g.chatId),
      title: g.title ?? g.chatId,
      hash: g.hash ?? null,
      inviteUrl: g.hash ? joinUrl(g.hash) : null,
      type: 'CHAT',
    })),
    joined: childJoined,
    invited: invitedCount + alreadyCount,
    forwarded: forwardedCount,
    total: Math.max(resolvedGroups.length, hashes.length + directChatIds.length),
  });
}

async function cmdForwardLinks({ token, links, groups = [], chatIds = [], forwardUserIds = [], delayMs = 2500 }) {
  if (!token) fail('Укажите токен матки');

  const userIds = [...new Set((forwardUserIds ?? []).map((id) => String(id)).filter(Boolean))];
  if (userIds.length === 0) fail('Укажите ID дочерних аккаунтов');

  const { client } = await connectWithToken(token);
  const motherToken = token;
  const results = [];
  let resolvedGroups = [];
  let hashes = [];

  try {
    const ids = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];
    if (ids.length > 0) {
      progress('[Каналы] проверяем invite-ссылки в профиле');
      resolvedGroups = await resolveForwardGroups(client, { groups, chatIds: ids, links: [] }, progress);
      const { linkHashes } = await deliverChildrenHybrid(client, motherToken, {
        channels: resolvedGroups,
        forwardUserIds: userIds,
        childTokens: [],
        delayMs,
        results,
        progress,
      });
      hashes = linkHashes;
      const extra = sanitizeHashes(mergeHashesFromLinksAndGroups(links, []));
      if (extra.length > 0) {
        progress(`[Доп. ссылки] пересылка ещё ${extra.length}`);
        await runForwardLinks(client, motherToken, extra, userIds, delayMs, results, progress);
        hashes = [...new Set([...hashes, ...extra])];
      }
    } else {
      hashes = sanitizeHashes(mergeHashesFromLinksAndGroups(links, groups));
      if (hashes.length === 0) fail('Нет каналов или ссылок для пересылки');
      await runForwardLinks(client, motherToken, hashes, userIds, delayMs, results, progress);
    }
  } finally {
    await safeDisconnect(client);
  }

  const forwardedCount = results.filter((r) => r.phase === 'forward' && r.ok).length;
  const invitedCount = results.filter((r) => r.phase === 'invite' && r.ok).length;
  ok({
    results,
    groups: resolvedGroups,
    joined: 0,
    invited: invitedCount,
    forwarded: forwardedCount,
    total: Math.max(hashes.length, resolvedGroups.length),
    children: userIds.length,
  });
}

async function cmdForwardAndJoin({ token, links, groups = [], chatIds = [], childTargets = [], delayMs = 2500 }) {
  if (!token) fail('Укажите токен матки');

  const targets = (childTargets ?? [])
    .map((t) => ({
      token: String(t?.token ?? '').trim(),
      userId: String(t?.userId ?? '').trim(),
      phone: t?.phone != null ? String(t.phone) : null,
      joinByLink: t?.joinByLink,
      proxy: t?.proxy != null && String(t.proxy).trim() ? String(t.proxy).trim() : null,
    }))
    .filter((t) => t.token && t.userId);

  if (targets.length === 0) fail('Укажите токены и ID дочерних аккаунтов');

  const results = [];
  const { client, profileId: motherUserId } = await connectWithToken(token);
  const motherToken = token;
  let resolvedGroups = [];
  let hashes = [];

  try {
    const ids = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];
    if (ids.length > 0) {
      progress('[Каналы] проверяем invite-ссылки в профиле');
      resolvedGroups = await resolveForwardGroups(client, { groups, chatIds: ids, links: [] }, progress);
      const { linkHashes } = await deliverChildrenHybrid(client, motherToken, {
        channels: resolvedGroups,
        childTargets: targets,
        delayMs,
        results,
        progress,
        motherUserId,
      });
      hashes = linkHashes;
      const extra = sanitizeHashes(mergeHashesFromLinksAndGroups(links, []));
      if (extra.length > 0) {
        progress(`[Доп. ссылки] пересылка и вступление ещё ${extra.length}`);
        await runForwardLinks(
          client,
          motherToken,
          extra,
          targets.map((t) => t.userId),
          delayMs,
          results,
          progress,
        );
        await sleep(Math.max(delayMs, 1500));
        await runChildrenJoin(
          extra,
          targets.map((t) => t.token),
          delayMs,
          results,
          progress,
          motherUserId,
          targets.map((t) => t.proxy ?? null),
        );
        hashes = [...new Set([...hashes, ...extra])];
      }
    } else {
      hashes = sanitizeHashes(mergeHashesFromLinksAndGroups(links, groups));
      if (hashes.length === 0) fail('Выберите каналы или укажите ссылки');
      progress('[Матка] пересылка ссылок дочерним в личку');
      await runForwardLinks(
        client,
        motherToken,
        hashes,
        targets.map((t) => t.userId),
        delayMs,
        results,
        progress,
      );
      progress('[Дочерние] вступление по ссылкам из лички с маткой');
      await sleep(Math.max(delayMs, 1500));
      await runChildrenJoin(
        hashes,
        targets.map((t) => t.token),
        delayMs,
        results,
        progress,
        motherUserId,
        targets.map((t) => t.proxy ?? null),
      );
    }
  } finally {
    await safeDisconnect(client);
  }

  const forwardedCount = results.filter((r) => r.phase === 'forward' && r.ok).length;
  const invitedCount = results.filter((r) => r.phase === 'invite' && r.ok).length;
  const childJoinOk = results.filter((r) => r.phase === 'child_join' && r.ok).length;
  ok({
    results,
    groups: resolvedGroups,
    joined: childJoinOk,
    invited: invitedCount,
    forwarded: forwardedCount,
    total: Math.max(hashes.length, resolvedGroups.length),
    children: targets.length,
  });
}

async function cmdChildrenJoinOnly({
  childTokens,
  links,
  groups = [],
  chatIds = [],
  motherToken,
  delayMs = 2500,
  childProxies = [],
  childTargets = [],
}) {
  let childTokenList = [...new Set((childTokens ?? []).map((t) => String(t).trim()).filter(Boolean))];
  let proxies = [...(childProxies ?? [])].map((p) => (p != null && String(p).trim() ? String(p).trim() : null));

  if (childTokenList.length === 0 && Array.isArray(childTargets) && childTargets.length > 0) {
    childTokenList = childTargets.map((t) => String(t?.token ?? '').trim()).filter(Boolean);
    proxies = childTargets.map((t) => (t?.proxy != null && String(t.proxy).trim() ? String(t.proxy).trim() : null));
  }

  if (childTokenList.length === 0) fail('Укажите токены дочерних аккаунтов');

  const results = [];
  let hashes = [];
  const ids = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];

  if (ids.length > 0) {
    if (!motherToken) fail('Укажите токен матки для получения ссылок из профиля каналов');
    const { client } = await connectWithToken(String(motherToken).trim());
    try {
      progress('[Профиль] invite-ссылки для дочерних из профиля каналов');
      const resolvedGroups = await resolveForwardGroups(client, { groups, chatIds: ids, links: [] }, progress);
      hashes = resolvedGroups.map((g) => g.hash).filter(Boolean);
    } finally {
      await client.disconnect().catch(() => undefined);
    }
    const extra = mergeHashesFromLinksAndGroups(links, []);
    if (extra.length > 0) {
      progress(`[Доп. ссылки] +${extra.length} к каналам матки`);
      hashes = [...new Set([...hashes, ...extra])];
    }
  } else {
    hashes = mergeHashesFromLinksAndGroups(links, groups);
  }

  if (hashes.length === 0) {
    fail('Не получены invite-ссылки. Выберите каналы — ссылка берётся из профиля');
  }

  await runChildrenJoin(hashes, childTokenList, delayMs, results, progress, null, proxies);

  const childJoinOk = results.filter((r) => r.phase === 'child_join' && r.ok).length;
  ok({
    results,
    joined: childJoinOk,
    invited: 0,
    total: hashes.length,
    children: childTokenList.length,
  });
}

function extractCreatedChatId(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const candidates = [
    payload.chatId,
    payload.chat?.id,
    payload.message?.chatId,
    payload.message?.chat?.id,
  ];
  for (const a of payload.message?.attaches ?? payload.attaches ?? []) {
    if (a?.chatId != null) candidates.push(a.chatId);
    if (a?.chat?.id != null) candidates.push(a.chat.id);
    if (a?.id != null && String(a._type ?? '').toUpperCase().includes('CONTROL')) {
      candidates.push(a.id);
    }
  }
  for (const c of candidates) {
    if (c != null && String(c).trim()) return String(c);
  }
  return null;
}

async function findChatIdByTitle(client, title) {
  const want = String(title ?? '').trim().toLowerCase();
  if (!want) return null;
  try {
    const chats = await getAllChats(client);
    const found = chats.find((c) => String(c.title ?? c.name ?? '').trim().toLowerCase() === want);
    return found?.id != null ? String(found.id) : null;
  } catch (_) {
    return null;
  }
}

async function applyChannelDescription(client, chatId, description, title = null) {
  const id = normalizeChatId(chatId);
  const text = String(description ?? '').trim();
  if (!text) return false;

  // MAX CHAT_SETTINGS (op 55): description + optional theme (title).
  const attempts = [
    { chatId: id, description: text },
  ];
  const theme = title != null ? String(title).trim() : '';
  if (theme) {
    attempts.push({ chatId: id, theme, description: text });
  }

  let lastError = null;
  for (const payload of attempts) {
    try {
      const response = await client.invokeMethod(OPCODES.CHANGE_GROUP_SETTINGS, payload);
      assertRpcOk(response, 'CHAT_UPDATE');
      return true;
    } catch (error) {
      lastError = error;
      const message = error instanceof Error ? error.message : String(error);
      progress(`[Воронка] описание попытка: ${message}`, 'warn');
    }
  }
  if (lastError) {
    progress(
      `[Воронка] описание не применено: ${lastError instanceof Error ? lastError.message : lastError}`,
      'warn',
    );
  }
  return false;
}

/** Upload image via op 80 and return photoToken (for avatar / attaches). */
async function uploadPhotoToken(client, photoPath) {
  const mediaPath = String(photoPath ?? '').trim();
  if (!mediaPath || !existsSync(mediaPath)) {
    throw new Error(`Файл фото не найден: ${mediaPath || '(пусто)'}`);
  }

  const photoData = await readFile(mediaPath);
  const ext = path.extname(mediaPath).toLowerCase() || '.jpg';
  const fileName = `avatar-${Date.now()}${ext}`;

  const uploadUrlResponse = await client.invokeMethod(OPCODES.REQUEST_UPLOAD_URL, { count: 1 });
  const uploadUrl = uploadUrlResponse?.payload?.url;
  if (!uploadUrl) throw new Error('Не удалось получить URL загрузки фото');

  const mimeType =
    ext === '.png'
      ? 'image/png'
      : ext === '.gif'
        ? 'image/gif'
        : ext === '.webp'
          ? 'image/webp'
          : 'image/jpeg';

  const blob = new Blob([photoData], { type: mimeType });
  const formData = new FormData();
  formData.append('file', blob, fileName);

  const uploadResponse = await fetch(uploadUrl, { method: 'POST', body: formData });
  if (!uploadResponse.ok) {
    throw new Error(`HTTP загрузка фото: ${uploadResponse.status} ${uploadResponse.statusText}`);
  }

  const uploadResult = await uploadResponse.json();
  const photoKey = Object.keys(uploadResult?.photos || {})[0];
  const photoToken = uploadResult?.photos?.[photoKey]?.token;
  if (!photoToken) throw new Error('Сервер не вернул photoToken');
  return { photoToken, photoKey };
}

/** Set channel/group avatar via CHAT_SETTINGS { chatId, photoToken }. */
async function applyChannelPhoto(client, chatId, photoPath) {
  const id = normalizeChatId(chatId);
  const { photoToken } = await uploadPhotoToken(client, photoPath);
  const response = await client.invokeMethod(OPCODES.CHANGE_GROUP_SETTINGS, {
    chatId: id,
    photoToken,
  });
  assertRpcOk(response, 'CHAT_UPDATE');
  return true;
}

async function sendChannelPost(client, chatId, text, mediaPath) {
  const id = normalizeChatId(chatId);
  const body = String(text ?? '').trim();
  const photo = mediaPath && existsSync(mediaPath) ? mediaPath : null;
  const parsed = parseMessageWithLinks(body);
  const messageText = parsed.text || (photo ? ' ' : '');

  if (photo) {
    let lastError = null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        // Upload then SEND_MESSAGE so caption can carry LINK elements.
        // uploadAndSendPhoto always sends elements: [] and drops hyperlinks.
        const { photoToken, photoKey } = await uploadPhotoToken(client, photo);
        const message = {
          text: messageText,
          cid: generateRandomId(),
          elements: parsed.elements.length > 0 ? parsed.elements : [],
          attaches: [
            {
              _type: 'PHOTO',
              type: 'PHOTO',
              photoId: photoKey,
              photoToken,
              width: 300,
              height: 200,
              baseUrl: `https://i.oneme.ru/i?r=${photoKey}`,
            },
          ],
        };
        const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
          chatId: id,
          message,
          notify: true,
        });
        assertRpcOk(response, 'SEND_MESSAGE');
        return {
          sent: true,
          withPhoto: true,
          messageId: extractMessageId(rpcPayload(response, 'SEND_MESSAGE')),
        };
      } catch (error) {
        lastError = error;
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Воронка] загрузка фото попытка ${attempt}/2: ${message}`, 'warn');
        if (attempt < 2) {
          await new Promise((r) => setTimeout(r, 1200 * attempt));
        }
      }
    }
    // Fallback: publish text (with links) without photo.
    if (body) {
      progress(
        `[Воронка] фото не ушло (${lastError instanceof Error ? lastError.message : lastError}) — шлём текст`,
        'warn',
      );
      const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
        chatId: id,
        message: buildTextMessagePayload(body),
        notify: true,
      });
      assertRpcOk(response, 'SEND_MESSAGE');
      return {
        sent: true,
        withPhoto: false,
        photoError: lastError instanceof Error ? lastError.message : String(lastError),
        messageId: extractMessageId(rpcPayload(response, 'SEND_MESSAGE')),
      };
    }
    throw lastError ?? new Error('Не удалось отправить фото');
  }

  if (!body) return { sent: false, withPhoto: false };

  const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
    chatId: id,
    message: buildTextMessagePayload(body),
    notify: true,
  });
  assertRpcOk(response, 'SEND_MESSAGE');
  return {
    sent: true,
    withPhoto: false,
    messageId: extractMessageId(rpcPayload(response, 'SEND_MESSAGE')),
  };
}

async function cmdSendChatMessages(args) {
  const token = String(args.token ?? '').trim();
  if (!token) fail('Укажите token');
  const messages = Array.isArray(args.messages) ? args.messages : [];
  if (messages.length === 0) fail('Нет сообщений для отправки');

  const { client } = await connectWithToken(token, args.proxy);
  try {
    let sent = 0;
    const results = [];
    for (let i = 0; i < messages.length; i++) {
      const row = messages[i] ?? {};
      const chatIdRaw = String(row.chatId ?? '').trim();
      const text = String(row.text ?? '');
      const title = String(row.title ?? chatIdRaw);
      const mediaPath = String(row.mediaPath ?? '').trim();
      if (!chatIdRaw || (!text.trim() && !mediaPath)) {
        results.push({ ok: false, chatId: chatIdRaw, error: 'пустое сообщение' });
        continue;
      }
      try {
        const chatId = normalizeChatId(chatIdRaw);
        const outcome = await sendChannelPost(client, chatId, text, mediaPath || null);
        if (!outcome?.sent) {
          results.push({ ok: false, chatId: chatIdRaw, error: 'не отправлено' });
          progress(`[Письмо] ✗ → ${title}: не отправлено`, 'warn');
        } else {
          sent += 1;
          results.push({
            ok: true,
            chatId: chatIdRaw,
            title,
            ...(outcome.messageId ? { messageId: outcome.messageId } : {}),
            ...(outcome.withPhoto ? { withPhoto: true } : {}),
            ...(outcome.photoError ? { photoError: outcome.photoError } : {}),
          });
          progress(
            `[Письмо] ✓ → ${title}${outcome.withPhoto ? ' · фото' : ''}${outcome.photoError ? ' (фото✗)' : ''}`,
          );
        }
      } catch (error) {
        const err = error instanceof Error ? error.message : String(error);
        results.push({ ok: false, chatId: chatIdRaw, error: err });
        progress(`[Письмо] ✗ → ${title}: ${err}`, 'warn');
      }
      const delayMs = Number(row.delayMs ?? 600);
      if (i < messages.length - 1 && delayMs > 0) {
        await sleep(Math.min(Math.max(0, delayMs), 60000));
      }
    }
    ok({ sent, total: messages.length, results });
  } finally {
    await safeDisconnect(client);
  }
}

/**
 * Delete messages in chats. Each item: { chatId, messageIds: string[] }.
 * forMe=false deletes for everyone when allowed.
 */
async function cmdDeleteChatMessages(args) {
  const token = String(args.token ?? '').trim();
  if (!token) fail('Укажите token');
  const items = Array.isArray(args.items) ? args.items : [];
  if (items.length === 0) fail('Нет сообщений для удаления');
  const forMe = args.forMe === true;

  const { client } = await connectWithToken(token, args.proxy);
  try {
    let deleted = 0;
    const results = [];
    for (let i = 0; i < items.length; i++) {
      const row = items[i] ?? {};
      const chatIdRaw = String(row.chatId ?? '').trim();
      const messageIds = (Array.isArray(row.messageIds) ? row.messageIds : [])
        .map((id) => String(id ?? '').trim())
        .filter(Boolean);
      if (!chatIdRaw || messageIds.length === 0) {
        results.push({ ok: false, chatId: chatIdRaw, error: 'нет chatId/messageIds' });
        continue;
      }
      try {
        const chatId = normalizeChatId(chatIdRaw);
        await client.invokeMethod(OPCODES.DELETE_MESSAGE, {
          chatId,
          messageIds,
          forMe,
        });
        deleted += messageIds.length;
        results.push({ ok: true, chatId: chatIdRaw, deleted: messageIds.length });
        progress(`[Удаление] ✓ → ${chatIdRaw} (${messageIds.length})`);
      } catch (error) {
        const err = error instanceof Error ? error.message : String(error);
        results.push({ ok: false, chatId: chatIdRaw, error: err });
        progress(`[Удаление] ✗ → ${chatIdRaw}: ${err}`, 'warn');
      }
      if (i < items.length - 1) {
        await sleep(400);
      }
    }
    ok({ deleted, total: items.length, results, forMe });
  } finally {
    await safeDisconnect(client);
  }
}

function normalizeHistoryMessage(msg, sourceChatId) {
  const id = String(msg?.id ?? msg?.messageId ?? '').trim();
  const text = String(msg?.text ?? '');
  const attaches = Array.isArray(msg?.attaches) ? msg.attaches : [];
  const hasPhoto = attaches.some((a) =>
    String(a?._type ?? a?.type ?? '')
      .toUpperCase()
      .includes('PHOTO'),
  );
  const linkType = String(msg?.link?.type ?? '').toUpperCase();
  const preview = text.trim()
    || (hasPhoto ? '[фото]' : '')
    || (attaches.length > 0 ? '[медиа]' : '')
    || (linkType === 'FORWARD' ? '[репост]' : '')
    || '(пусто)';
  return {
    id,
    chatId: String(sourceChatId),
    time: Number(msg?.time ?? 0) || null,
    text,
    type: String(msg?.type ?? 'USER'),
    sender: msg?.sender ?? null,
    hasPhoto,
    hasMedia: attaches.length > 0,
    attachCount: attaches.length,
    isForward: linkType === 'FORWARD',
    preview: preview.slice(0, 500),
    raw: msg,
  };
}

async function fetchChatHistory(client, chatId, { backward = 50, from = null } = {}) {
  const id = normalizeChatId(chatId);
  const payload = {
    chatId: id,
    forward: 0,
    backward: Math.min(Math.max(1, Number(backward) || 50), 200),
    getMessages: true,
    getChat: false,
    from: from != null ? Number(from) : Date.now(),
  };
  const response = await client.invokeMethod(OPCODES.GET_MESSAGES, payload);
  const body = rpcPayload(response, 'GET_MESSAGES');
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  return messages.map((m) => normalizeHistoryMessage(m, chatId));
}

async function cmdListChatMessages(args) {
  const token = String(args.token ?? '').trim();
  if (!token) fail('Укажите token');
  const chatId = String(args.chatId ?? '').trim();
  if (!chatId) fail('Укажите chatId');
  const backward = Number(args.backward ?? args.limit ?? 50);
  const from = args.from != null ? Number(args.from) : null;

  const { client } = await connectWithToken(token, args.proxy);
  try {
    progress(`[Посты] загружаю историю ${chatId}…`);
    const messages = await fetchChatHistory(client, chatId, { backward, from });
    messages.sort((a, b) => (b.time ?? 0) - (a.time ?? 0));
    progress(`[Посты] получено: ${messages.length}`);
    ok({
      chatId,
      count: messages.length,
      messages: messages.map(({ raw, ...rest }) => rest),
      rawMessages: messages.map((m) => m.raw).filter(Boolean),
    });
  } finally {
    await safeDisconnect(client);
  }
}

async function forwardOneMessage(client, {
  sourceChatId,
  targetChatId,
  messageId,
  rawMessage = null,
  comment = '',
}) {
  const target = normalizeChatId(targetChatId);
  const source = normalizeChatId(sourceChatId);
  const mid = String(messageId ?? rawMessage?.id ?? '').trim();
  if (!mid) throw new Error('нет messageId');

  const msgObj = rawMessage && typeof rawMessage === 'object'
    ? {
        id: rawMessage.id ?? mid,
        time: rawMessage.time,
        sender: rawMessage.sender,
        type: rawMessage.type ?? 'USER',
        text: rawMessage.text ?? '',
        attaches: Array.isArray(rawMessage.attaches) ? rawMessage.attaches : [],
        elements: Array.isArray(rawMessage.elements) ? rawMessage.elements : [],
      }
    : { id: mid };

  const attempts = [
    {
      name: 'SEND_MESSAGE link FORWARD',
      run: async () => {
        const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
          chatId: target,
          message: {
            text: String(comment ?? ''),
            cid: generateRandomId(),
            elements: [],
            link: {
              type: 'FORWARD',
              chatId: source,
              message: msgObj,
            },
          },
          notify: true,
        });
        assertRpcOk(response, 'SEND_MESSAGE FORWARD');
        return {
          mode: 'forward',
          messageId: extractMessageId(rpcPayload(response, 'SEND_MESSAGE')),
        };
      },
    },
    {
      name: 'SEND_MESSAGE link forward mid',
      run: async () => {
        const response = await client.invokeMethod(OPCODES.SEND_MESSAGE, {
          chatId: target,
          message: {
            text: String(comment ?? ''),
            cid: generateRandomId(),
            elements: [],
            link: {
              type: 'forward',
              mid: String(mid),
              chatId: source,
            },
          },
          notify: true,
        });
        assertRpcOk(response, 'SEND_MESSAGE forward mid');
        return {
          mode: 'forward',
          messageId: extractMessageId(rpcPayload(response, 'SEND_MESSAGE')),
        };
      },
    },
    {
      name: 'opcode 70',
      run: async () => {
        const response = await client.invokeMethod(70, {
          chatId: target,
          text: String(comment ?? ''),
          messageIds: [mid],
          linkChatId: source,
        });
        assertRpcOk(response, 'FORWARD_MESSAGE');
        return {
          mode: 'forward70',
          messageId: extractMessageId(rpcPayload(response, 'FORWARD_MESSAGE')),
        };
      },
    },
  ];

  const errors = [];
  for (const attempt of attempts) {
    try {
      return await attempt.run();
    } catch (error) {
      errors.push(`${attempt.name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  const text = String(rawMessage?.text ?? comment ?? '').trim();
  if (!text) {
    throw new Error(`пересылка не удалась (${errors.join(' | ')})`);
  }
  const copied = await sendChannelPost(client, target, text, null);
  if (!copied?.sent) {
    throw new Error(`пересылка/копия не удалась (${errors.join(' | ')})`);
  }
  return {
    mode: 'copy',
    messageId: copied.messageId ?? null,
    warn: errors.join(' | '),
  };
}

async function cmdForwardChatMessages(args) {
  const token = String(args.token ?? '').trim();
  if (!token) fail('Укажите token');
  const sourceChatId = String(args.sourceChatId ?? args.fromChatId ?? '').trim();
  if (!sourceChatId) fail('Укажите sourceChatId');
  const targetChatIds = [
    ...new Set(
      (Array.isArray(args.targetChatIds) ? args.targetChatIds : [])
        .map((id) => String(id ?? '').trim())
        .filter(Boolean),
    ),
  ];
  if (targetChatIds.length === 0) fail('Укажите targetChatIds');
  const messageIds = [
    ...new Set(
      (Array.isArray(args.messageIds) ? args.messageIds : [])
        .map((id) => String(id ?? '').trim())
        .filter(Boolean),
    ),
  ];
  const rawMessages = Array.isArray(args.rawMessages) ? args.rawMessages : [];
  const comment = String(args.comment ?? '').trim();
  const delayMs = Math.min(Math.max(0, Number(args.delayMs ?? 800)), 60000);

  if (messageIds.length === 0 && rawMessages.length === 0) {
    fail('Укажите messageIds или rawMessages');
  }

  const { client } = await connectWithToken(token, args.proxy);
  try {
    let sourceMsgs = [];
    if (rawMessages.length > 0) {
      sourceMsgs = rawMessages
        .filter((m) => m && (m.id != null || m.messageId != null))
        .map((m) => ({ ...m, id: m.id ?? m.messageId }));
    } else {
      progress(`[Пересылка] подгружаю историю источника ${sourceChatId}…`);
      const history = await fetchChatHistory(client, sourceChatId, { backward: 100 });
      const byId = new Map(history.map((m) => [String(m.id), m.raw]));
      const missing = messageIds.filter((id) => !byId.has(id));
      if (missing.length > 0) {
        try {
          const response = await client.invokeMethod(71, {
            chatId: normalizeChatId(sourceChatId),
            messageIds: missing,
          });
          const body = rpcPayload(response, 'GET_MESSAGE');
          for (const m of body?.messages ?? []) {
            if (m?.id != null) byId.set(String(m.id), m);
          }
        } catch (error) {
          progress(
            `[Пересылка] GET_MESSAGE: ${error instanceof Error ? error.message : String(error)}`,
            'warn',
          );
        }
      }
      for (const id of messageIds) {
        const raw = byId.get(id);
        sourceMsgs.push(raw ? { ...raw, id: raw.id ?? id } : { id });
      }
    }

    if (sourceMsgs.length === 0) fail('Нет сообщений для пересылки');

    let forwarded = 0;
    let copied = 0;
    const results = [];
    let step = 0;
    const total = sourceMsgs.length * targetChatIds.length;

    for (const msg of sourceMsgs) {
      for (const targetChatId of targetChatIds) {
        step += 1;
        try {
          const out = await forwardOneMessage(client, {
            sourceChatId,
            targetChatId,
            messageId: msg.id,
            rawMessage: msg,
            comment,
          });
          if (out.mode === 'copy') copied += 1;
          else forwarded += 1;
          results.push({
            ok: true,
            targetChatId,
            sourceMessageId: String(msg.id),
            mode: out.mode,
            messageId: out.messageId ?? null,
            warn: out.warn ?? null,
          });
          progress(`[Пересылка] ✓ ${step}/${total} → ${targetChatId} (${out.mode})`);
        } catch (error) {
          const err = error instanceof Error ? error.message : String(error);
          results.push({
            ok: false,
            targetChatId,
            sourceMessageId: String(msg.id),
            error: err,
          });
          progress(`[Пересылка] ✗ ${step}/${total} → ${targetChatId}: ${err}`, 'warn');
        }
        if (step < total && delayMs > 0) await sleep(delayMs);
      }
    }

    ok({
      forwarded,
      copied,
      failed: results.filter((r) => !r.ok).length,
      total: results.length,
      results,
    });
  } finally {
    await safeDisconnect(client);
  }
}

/**
 * Publish funnel posts into an existing channel (no create).
 * Also returns inviteUrl when available (for backfilling {channel_link}).
 */
async function cmdFunnelPublish(args) {
  const token = String(args.token ?? '').trim();
  const chatId = String(args.chatId ?? '').trim();
  if (!token) fail('Укажите token');
  if (!chatId) fail('Укажите chatId канала');

  const posts = Array.isArray(args.posts) ? args.posts : [];

  const { client } = await connectWithToken(token, args.proxy);
  try {
    progress(`[Воронка] публикация в chat ${chatId} (${posts.length} пост.)…`);
    let postsSent = 0;
    let photoFailures = 0;

    for (let i = 0; i < posts.length; i++) {
      const post = posts[i] ?? {};
      const text = String(post.text ?? '').trim();
      const media = asString(post.mediaPath);
      if (!text && !media) continue;
      try {
        progress(`[Воронка] публикация ${i + 1}/${posts.length}…`);
        const sent = await sendChannelPost(client, chatId, text, media);
        if (sent?.sent) postsSent += 1;
        if (sent?.photoError) photoFailures += 1;
        progress(`[Воронка] ✓ пост ${i + 1}${sent?.withPhoto ? ' (с фото)' : ''}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Воронка] ✗ пост ${i + 1}: ${message}`, 'warn');
      }
      const delayMs = Number(post.delayMs ?? post.delayAfterMs ?? 2000);
      if (i < posts.length - 1 && delayMs > 0) {
        await new Promise((r) => setTimeout(r, Math.min(delayMs, 60000)));
      }
    }

    let inviteHash = null;
    try {
      const chat = await getChatInfo(client, chatId);
      inviteHash = extractHashFromChatObject(chat);
      if (!inviteHash) {
        const refreshed = await reworkInviteLink(client, chatId, false);
        inviteHash = extractHashFromChatObject(refreshed);
      }
    } catch (_) {
      // optional
    }

    ok({
      ok: true,
      chatId: String(normalizeChatId(chatId)),
      postsSent,
      photoFailures,
      inviteHash,
      inviteUrl: inviteHash ? joinUrl(inviteHash) : null,
    });
  } finally {
    await safeDisconnect(client);
  }
}

/**
 * Create a channel from template, optionally set description and publish posts.
 */
async function cmdFunnelSetup(args) {
  const token = String(args.token ?? '').trim();
  const title = String(args.title ?? '').trim();
  if (!token) fail('Укажите token');
  if (!title) fail('Укажите title канала');

  const description = asString(args.description);
  const photoPath = asString(args.photoPath);
  const posts = Array.isArray(args.posts) ? args.posts : [];
  const publish = args.publish !== false;

  const { client } = await connectWithToken(token, args.proxy);
  try {
    progress(`[Воронка] создание канала «${title}»…`);
    const created = await createChannel(client, title);
    const createPayload = assertRpcOk(created, 'CREATE_CHANNEL');
    progress('[Воронка] createChannel ответ', 'debug', summarizeRpc(created));

    let chatId = extractCreatedChatId(createPayload);
    if (!chatId) {
      await new Promise((r) => setTimeout(r, 800));
      chatId = await findChatIdByTitle(client, title);
    }
    if (!chatId) {
      fail('Канал создан, но не удалось получить chatId из ответа API');
    }

    progress(`[Воронка] ✓ канал создан: ${chatId}`);
    // Brief pause — freshly created channel may reject settings for a moment.
    await new Promise((r) => setTimeout(r, 600));

    let descriptionOk = false;
    if (description) {
      descriptionOk = await applyChannelDescription(client, chatId, description, title);
      progress(
        descriptionOk
          ? '[Воронка] ✓ описание канала обновлено'
          : '[Воронка] ✗ не удалось выставить описание',
        descriptionOk ? 'info' : 'warn',
      );
    }

    let avatarOk = false;
    if (photoPath && existsSync(photoPath)) {
      try {
        progress('[Воронка] установка фото канала…');
        avatarOk = await applyChannelPhoto(client, chatId, photoPath);
        progress('[Воронка] ✓ фото канала установлено');
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Воронка] ✗ фото канала: ${message}`, 'warn');
      }
    } else if (photoPath) {
      progress(`[Воронка] файл фото не найден: ${photoPath}`, 'warn');
    }

    let postsSent = 0;
    let photoFailures = 0;
    if (publish) {
      const queue = [...posts];
      // Channel avatar is set above — do not reuse photoPath as a post attachment.

      for (let i = 0; i < queue.length; i++) {
        const post = queue[i] ?? {};
        const text = String(post.text ?? '').trim();
        const media = asString(post.mediaPath);
        if (!text && !media) continue;
        try {
          progress(`[Воронка] публикация ${i + 1}/${queue.length}…`);
          const sent = await sendChannelPost(client, chatId, text, media);
          if (sent?.sent) postsSent += 1;
          if (sent?.photoError) photoFailures += 1;
          progress(`[Воронка] ✓ пост ${i + 1}${sent?.withPhoto ? ' (с фото)' : ''}`);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          progress(`[Воронка] ✗ пост ${i + 1}: ${message}`, 'warn');
        }
        const delayMs = Number(post.delayMs ?? post.delayAfterMs ?? 2000);
        if (i < queue.length - 1 && delayMs > 0) {
          await new Promise((r) => setTimeout(r, Math.min(delayMs, 60000)));
        }
      }
    }

    let inviteHash = null;
    try {
      const chat = await getChatInfo(client, chatId);
      inviteHash = extractHashFromChatObject(chat);
      if (!inviteHash) {
        const refreshed = await reworkInviteLink(client, chatId, false);
        inviteHash = extractHashFromChatObject(refreshed);
      }
    } catch (_) {
      // optional
    }

    ok({
      ok: true,
      chatId: String(chatId),
      title,
      descriptionApplied: descriptionOk,
      avatarApplied: avatarOk,
      postsSent,
      photoFailures,
      inviteHash,
      inviteUrl: inviteHash ? joinUrl(inviteHash) : null,
      privateChannel: Boolean(args.privateChannel),
      commentsEnabled: args.commentsEnabled !== false,
    });
  } finally {
    await safeDisconnect(client);
  }
}

const [,, command, rawArgs] = process.argv;

/** Inline JSON, or `@path` / `--args-file=path` for large payloads (Windows argv limit). */
async function loadCliArgs(raw) {
  if (raw == null || raw === '') return {};
  const text = String(raw);
  if (text.startsWith('@')) {
    return JSON.parse(await readFile(text.slice(1), 'utf-8'));
  }
  if (text.startsWith('--args-file=')) {
    return JSON.parse(await readFile(text.slice('--args-file='.length), 'utf-8'));
  }
  return JSON.parse(text);
}

const args = await loadCliArgs(rawArgs);

const MOTHER_COMMANDS = new Set([
  'mother-deploy',
  'invite-children',
  'forward-links',
  'forward-and-join',
  'children-join',
  'list-groups',
  'discover-channels',
  'fetch-profile-invite-links',
  'scan-chat-invites',
  'resolve-channel-invite',
  'join-groups',
  'leave-groups',
  'funnel-setup',
  'funnel-publish',
  'send-chat-messages',
  'delete-chat-messages',
  'list-chat-messages',
  'forward-chat-messages',
]);

try {
  if (args.proxy) {
    try {
      const used = applyProxy(args.proxy);
      if (used && MOTHER_COMMANDS.has(command)) {
        progress(`[Прокси] ${maskProxy(used)}`);
      }
    } catch (error) {
      fail(error instanceof Error ? error.message : String(error));
    }
  }
  if (MOTHER_COMMANDS.has(command)) {
    await initMotherLog(command);
    progress(`[CLI] команда: ${command}`, 'info');
    progress('[CLI] аргументы', 'debug', summarizeArgs(args));
  }
  switch (command) {
    case 'send-code':
      if (!args.phone) fail('Укажите номер телефона');
      await cmdSendCode(String(args.phone).trim());
      break;
    case 'verify-code':
      if (!args.phone || !args.code) fail('Укажите номер и код');
      await cmdVerifyCode(String(args.phone).trim(), String(args.code).trim());
      break;
    case 'verify-2fa':
      if (!args.phone || !args.password) fail('Укажите номер и пароль 2FA');
      await cmdVerify2FA(String(args.phone).trim(), String(args.password));
      break;
    case 'login-token':
      if (!args.token) fail('Укажите токен');
      await cmdLoginToken(String(args.token).trim(), args.proxy);
      break;
    case 'join-groups':
      await cmdJoinGroups(args);
      break;
    case 'leave-groups':
      await cmdLeaveGroups(args);
      break;
    case 'mother-deploy':
      await cmdMotherDeploy(args);
      break;
    case 'invite-children':
      await cmdInviteChildren(args);
      break;
    case 'forward-links':
      await cmdForwardLinks(args);
      break;
    case 'forward-and-join':
      await cmdForwardAndJoin(args);
      break;
    case 'children-join':
      await cmdChildrenJoinOnly(args);
      break;
    case 'list-groups':
      await cmdListGroups(args);
      break;
    case 'discover-channels':
      await cmdDiscoverChannels(args);
      break;
    case 'scan-chat-invites':
      await cmdScanChatInvites(args);
      break;
    case 'fetch-profile-invite-links':
      await cmdFetchProfileInviteLinks(args);
      break;
    case 'resolve-channel-invite':
      await cmdResolveChannelInvite(args);
      break;
    case 'funnel-setup':
      await cmdFunnelSetup(args);
      break;
    case 'funnel-publish':
      await cmdFunnelPublish(args);
      break;
    case 'send-chat-messages':
      await cmdSendChatMessages(args);
      break;
    case 'delete-chat-messages':
      await cmdDeleteChatMessages(args);
      break;
    case 'list-chat-messages':
      await cmdListChatMessages(args);
      break;
    case 'forward-chat-messages':
      await cmdForwardChatMessages(args);
      break;
    default:
      fail('Неизвестная команда');
  }
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (/ENOTFOUND|ETIMEDOUT|ECONNREFUSED|getaddrinfo/i.test(message)) {
    fail(
      'Нет доступа к ws-api.oneme.ru (DNS/сеть). Проверьте интернет или добавьте аккаунт без проверки в приложении.',
      { code: 'network.error' },
    );
  }
  fail(message);
}
