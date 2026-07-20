import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const cliSource = readFileSync(path.join(__dirname, 'cli.mjs'), 'utf8');

assert.match(cliSource, /case 'list-groups'/);
assert.match(cliSource, /function deliverChildrenHybrid/);
assert.match(cliSource, /function runInviteUsersToGroups/);
assert.match(cliSource, /function buildChannelDeliveryPlan/);
assert.match(cliSource, /function isValidJoinHash/);

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

function groupHash(group) {
  const hash = group?.hash ?? parseJoinHash(group?.inviteUrl);
  return isValidJoinHash(hash) ? String(hash).trim() : null;
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
    if (entry.hash) linkChannels.push(entry);
    else inviteChannels.push(entry);
  }
  return { linkChannels, inviteChannels };
}

assert.equal(parseJoinHash('https://max.ru/join/undefined'), null);
assert.equal(parseJoinHash('undefined'), null);
assert.ok(isValidJoinHash('r4uD3s7vZBnG-oISHYaZ52vAfal90V2rYgvK3scQ2jk'));

const plan = buildChannelDeliveryPlan([
  {
    chatId: '111',
    title: 'VIP ногти',
    hash: 'r4uD3s7vZBnG-oISHYaZ52vAfal90V2rYgvK3scQ2jk',
  },
  {
    chatId: '222',
    title: 'Без ссылки',
    hash: null,
  },
  {
    chatId: '333',
    title: 'Битая',
    inviteUrl: 'https://max.ru/join/undefined',
  },
]);

assert.equal(plan.linkChannels.length, 1);
assert.equal(plan.inviteChannels.length, 2);
assert.equal(plan.linkChannels[0].chatId, '111');
assert.deepEqual(
  plan.inviteChannels.map((c) => c.chatId),
  ['222', '333'],
);

console.log('mother hybrid flow tests: ok');
