import { MaxClient, inviteUsers, resolveGroupByLink, addContact, OPCODES, generateRandomId } from '@mqpanda/vkmax-node';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
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
  return String(value);
}

function extractProfile(payload) {
  const profile = payload?.profile ?? {};
  const contact = profile.contact ?? profile;
  const names = contact.names;
  const name = Array.isArray(names) ? names[0]?.name : contact.name;
  const phone = asString(contact.phone ?? profile.phone);
  return {
    name: asString(name) ?? phone,
    phone,
    id: contact.id,
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

    const profile = extractProfile(payload);
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
    progress(`[API] аккаунт: id=${profile.id}, name=${profile.name ?? '?'}, phone=${profile.phone ?? '?'}`, 'info');
    return { client, profileId: profile.id, token };
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

async function buildGroupCatalog(client, { chatIds = null } = {}, progress) {
  const chats = await getAllChats(client);
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

async function getAllChats(client) {
  const response = await client.invokeMethod(48, { chatIds: [0] });
  return rpcPayload(response, 'GET_CHATS').chats ?? [];
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
      await sleep(Math.max(delayMs, 1200));

      if (childToken) {
        let childClient;
        try {
          const childProxy = child?.proxy ?? currentProxyUrl();
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
}) {
  if (!token) fail('Укажите токен аккаунта для поиска');

  const target = Math.max(1, Math.min(Number(count) || 10, 50));
  const knownHashes = new Set(sanitizeHashes(excludeHashes));
  const knownChatIds = new Set((excludeChatIds ?? []).map((id) => String(id)));
  const found = [];
  const foundHashes = new Set();
  const foundChatIds = new Set();

  const DEFAULT_TOPICS = [
    'новости',
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
    'реклама',
    'канал',
    'чат',
    'подписаться',
    'приглашение',
    'max.ru/join',
    'телеграм',
    'блог',
    'лайфхаки',
    'финансы',
    'недвижимость',
    'дизайн',
    'мемы',
  ];

  let topicQueue = [...new Set((topics ?? []).map((t) => String(t).trim()).filter(Boolean))];
  if (topicQueue.length === 0) {
    topicQueue = [...DEFAULT_TOPICS].sort(() => Math.random() - 0.5);
  } else {
    topicQueue = [...topicQueue].sort(() => Math.random() - 0.5);
  }

  const { client } = await connectWithToken(token);

  function rememberHash(hash) {
    if (!isValidJoinHash(hash)) return false;
    if (knownHashes.has(hash) || foundHashes.has(hash)) return false;
    foundHashes.add(hash);
    return true;
  }

  function collectHashesFromSearchPayload(payload) {
    const hashes = [];
    for (const row of payload?.result ?? []) {
      const chat = row?.chat;
      const hashFromChat = extractHashFromChatObject(chat);
      if (hashFromChat && rememberHash(hashFromChat)) hashes.push(hashFromChat);

      const msg = row?.message ?? chat?.lastMessage;
      const elements = (msg?.elements ?? [])
        .map((el) => el?.attributes?.url ?? el?.url ?? '')
        .join(' ');
      const text = `${msg?.text ?? ''} ${elements} ${JSON.stringify(chat ?? '')}`;
      for (const hash of extractHashesFromText(text)) {
        if (rememberHash(hash)) hashes.push(hash);
      }
    }
    return hashes;
  }

  async function tryGlobalSearch(query) {
    try {
      const response = await client.invokeMethod(60, { query, count: 25 });
      const payload = rpcPayload(response, 'MSG_SEARCH_GLOBAL');
      return collectHashesFromSearchPayload(payload);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      progress(`[Поиск] «${query}»: ${message}`, 'warn');
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
            if (rememberHash(hash)) hashes.push(hash);
          }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        progress(`[Скан чатов] ✗ «${title}»: ${message}`, 'warn');
      }
      if (i < slice.length - 1) await sleep(250);
    }
    return hashes;
  }

  async function resolveCandidate(hash, topic) {
    try {
      const resolved = await resolveGroupByLink(client, hash);
      const payload = resolved?.payload ?? {};
      if (payload.error) return null;

      const chat = chatFromPayload(payload) ?? chatFromInfoPayload(payload);
      if (!chat?.id) return null;

      const chatId = String(chat.id);
      if (knownChatIds.has(chatId) || foundChatIds.has(chatId)) return null;

      const type = String(chat.type ?? 'CHAT').toUpperCase();
      if (type === 'DIALOG') return null;

      const profileHash = extractHashFromChatObject(chat);
      const finalHash = isValidJoinHash(profileHash) ? profileHash : hash;

      return {
        chatId,
        title: chat.title ?? chat.name ?? hash,
        type: chat.type ?? 'CHANNEL',
        hash: finalHash,
        inviteUrl: joinUrl(finalHash),
        topic: topic ?? null,
        source: 'discover',
      };
    } catch (_) {
      return null;
    }
  }

  try {
    progress(`[Каталог] ищем ${target} новых каналов…`);

    let topicIndex = 0;
    while (found.length < target && topicIndex < topicQueue.length) {
      const topic = topicQueue[topicIndex++];
      progress(`[Поиск] тема «${topic}»`);
      const hashes = await tryGlobalSearch(topic);
      progress(`[Поиск] «${topic}» → кандидатов: ${hashes.length}`);

      for (const hash of hashes) {
        if (found.length >= target) break;
        const entry = await resolveCandidate(hash, topic);
        if (!entry) continue;
        found.push(entry);
        foundChatIds.add(entry.chatId);
        foundHashes.add(entry.hash);
        progress(`[Каталог] + «${entry.title}» → ${entry.inviteUrl}`);
        await sleep(350);
      }
      await sleep(400);
    }

    if (found.length < target) {
      progress('[Скан чатов] глобальный поиск дал мало — сканируем сообщения…');
      const scanned = await scanGroupChatsForLinks();
      progress(`[Скан чатов] новых хешей: ${scanned.length}`);

      for (const hash of scanned) {
        if (found.length >= target) break;
        const entry = await resolveCandidate(hash, 'scan');
        if (!entry) continue;
        found.push(entry);
        foundChatIds.add(entry.chatId);
        foundHashes.add(entry.hash);
        progress(`[Каталог] + «${entry.title}» → ${entry.inviteUrl}`);
        await sleep(350);
      }
    }

    const withLink = found.filter((g) => g.hash).length;
    progress(`[Каталог] готово: ${found.length} из ${target}, со ссылкой: ${withLink}`);
    ok({
      channels: found,
      groups: found,
      added: found.length,
      requested: target,
      withInviteLink: withLink,
    });
  } finally {
    await client.disconnect().catch(() => undefined);
  }
}

async function cmdListGroups({ token, scanMessages = true }) {
  if (!token) fail('Укажите токен матки');

  const { client } = await connectWithToken(token);
  try {
    progress('[Каналы] загрузка списка чатов матки…');
    const groups = await buildGroupCatalog(client, {}, progress);
    const withLink = groups.filter((g) => g.hash).length;
    progress(`[Каналы] найдено ${groups.length}, invite из профиля: ${withLink}`);
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

async function cmdInviteChildren({ token, links, groups = [], chatIds = [], inviteUserIds = [], delayMs = 2500 }) {
  if (!token) fail('Укажите токен матки');

  const hashes = mergeHashesFromLinksAndGroups(links, groups);
  const directChatIds = [...new Set((chatIds ?? []).map((id) => String(id)).filter(Boolean))];

  if (hashes.length === 0 && directChatIds.length === 0) {
    fail('Укажите ссылки, каналы со ссылкой или chatId групп');
  }

  const userIds = [...new Set((inviteUserIds ?? []).map((id) => String(id)).filter(Boolean))];
  if (userIds.length === 0) fail('Укажите ID дочерних аккаунтов');

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
        resolvedGroups.push(entry);
        results.push({ hash, ok: true, phase: 'resolve', chatId: entry.chatId, title: entry.title });
      } catch (error) {
        results.push({
          hash,
          ok: false,
          phase: 'resolve',
          error: error instanceof Error ? error.message : String(error),
        });
      }
      if (i < hashes.length - 1) await sleep(delayMs);
    }

    for (let i = 0; i < resolvedGroups.length; i++) {
      const group = resolvedGroups[i];
      progress(`[Приглашение] ${i + 1}/${resolvedGroups.length} → «${group.title ?? group.chatId}»`);
      try {
        await ensureConnected(client, motherToken);
        await inviteUsersToChat(client, group.chatId, userIds);
        results.push({
          hash: group.hash,
          ok: true,
          phase: 'invite',
          chatId: group.chatId,
          invited: userIds.length,
        });
      } catch (error) {
        results.push({
          hash: group.hash,
          ok: false,
          phase: 'invite',
          chatId: group.chatId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      if (i < resolvedGroups.length - 1) await sleep(delayMs);
    }
  } finally {
    await safeDisconnect(client);
  }

  const invitedCount = results.filter((r) => r.phase === 'invite' && r.ok).length;
  ok({
    results,
    groups: resolvedGroups.map((g) => ({
      chatId: String(g.chatId),
      title: g.title ?? g.chatId,
      hash: g.hash ?? null,
      inviteUrl: g.hash ? joinUrl(g.hash) : null,
      type: 'CHAT',
    })),
    joined: resolvedGroups.length,
    invited: invitedCount,
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

const [,, command, rawArgs] = process.argv;
const args = rawArgs ? JSON.parse(rawArgs) : {};

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
  'join-groups',
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
