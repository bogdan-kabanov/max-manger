import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataPath =
  process.env.MAX_DATA_JSON ??
  'C:/Users/bogda/AppData/Roaming/com.maxmanager/max_desktop/max_desktop/data.json';

function loadAccounts() {
  const data = JSON.parse(readFileSync(dataPath, 'utf8'));
  const accounts = data.accounts ?? [];
  const mother = accounts.find((a) => a.label?.includes('Богдан')) ?? accounts[0];
  const child = accounts.find((a) => a.id !== mother?.id) ?? accounts[1];
  if (!mother?.apiToken || !child?.apiToken) {
    throw new Error('Нет apiToken у матки или дочернего в data.json');
  }
  const groups = (data.motherGroups?.[mother.id] ?? []).map((g) => ({
    chatId: String(g.chatId),
    title: g.title,
    hash: g.inviteHash ?? null,
    inviteUrl: g.inviteHash ? `https://max.ru/join/${g.inviteHash}` : null,
  }));
  return { mother, child, groups };
}

function runCli(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn('node', [path.join(__dirname, 'cli.mjs'), command, JSON.stringify(args)], {
      cwd: __dirname,
      env: { ...process.env, NODE_NO_WARNINGS: '1' },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      stderr += text;
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        try {
          const msg = JSON.parse(line);
          if (msg.type === 'progress') process.stderr.write(`  ${msg.message}\n`);
        } catch (_) {
          // ignore
        }
      }
    });
    child.on('close', (code) => {
      const lines = stdout.trim().split('\n').filter(Boolean);
      const lastLine = lines[lines.length - 1] ?? '';
      let json;
      try {
        json = JSON.parse(lastLine);
      } catch (e) {
        reject(new Error(`Bad JSON: ${lastLine.slice(0, 200) || stderr.slice(0, 200)}`));
        return;
      }
      if (code !== 0 || json.ok === false) {
        reject(new Error(json.error ?? stderr ?? `exit ${code}`));
        return;
      }
      resolve(json);
    });
  });
}

const { mother, child, groups } = loadAccounts();

console.log('=== LIVE TEST (токены из data.json) ===');
console.log(`Матка: ${mother.label} (id ${mother.viewerId})`);
console.log(`Дочерний: ${child.label} (id ${child.viewerId})`);
console.log(`Каналов в storage: ${groups.length}`);

console.log('\n1) login-token матки…');
const login = await runCli('login-token', { token: mother.apiToken });
console.log(`   ok=${login.ok}, profile=${login.profile?.name ?? login.profile?.id ?? '?'}`);

const chatIds = groups.map((g) => g.chatId);
console.log('\n2) fetch-profile-invite-links…');
const profile = await runCli('fetch-profile-invite-links', {
  token: mother.apiToken,
  chatIds,
  groups,
});
for (const g of profile.groups ?? []) {
  const method = g.hash ? 'по ссылке' : 'добавить по ID';
  console.log(`   «${g.title}» → ${method}${g.hash ? ` (${String(g.hash).slice(0, 14)}…)` : ''}`);
}

const vipStored = groups.find((g) => String(g.title).includes('VIP'));
const testChatIds = vipStored ? [String(vipStored.chatId)] : chatIds.slice(0, 1);

console.log('\n3) forward-and-join (тестовый канал)…');
console.log(`   канал: ${vipStored?.title ?? testChatIds[0]}`);
const result = await runCli('forward-and-join', {
  token: mother.apiToken,
  links: [],
  groups: groups.filter((g) => testChatIds.includes(String(g.chatId))),
  chatIds: testChatIds,
  childTargets: [{ userId: String(child.viewerId), token: child.apiToken, phone: child.phone }],
  delayMs: 2000,
});

const forwarded = result.results?.filter((r) => r.phase === 'forward' && r.ok).length ?? 0;
const invited = result.results?.filter((r) => r.phase === 'invite' && r.ok).length ?? 0;
const joined = result.results?.filter((r) => r.phase === 'child_join' && r.ok).length ?? 0;
const failed = result.results?.filter((r) => r.ok !== true) ?? [];

console.log(`\n=== ИТОГ ===`);
console.log(`forward ok: ${forwarded}, invite ok: ${invited}, child_join ok: ${joined}`);
if (failed.length) {
  console.log('ошибки:');
  for (const row of failed.slice(0, 8)) {
    console.log(`  [${row.phase}] ${row.error ?? row.hash ?? row.chatId ?? '?'}`);
  }
} else {
  console.log('ошибок нет');
}
