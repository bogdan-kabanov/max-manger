import { appendFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { homedir } from 'node:os';

let logPath = null;
let latestPath = null;

function logDir() {
  if (process.env.MAX_MOTHER_LOG_DIR) return process.env.MAX_MOTHER_LOG_DIR;
  const appData = process.env.APPDATA ?? path.join(homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'com.maxmanager', 'max_desktop', 'logs');
}

export function getMotherLogPath() {
  return logPath;
}

export function getMotherLatestLogPath() {
  return latestPath;
}

export async function initMotherLog(command) {
  const dir = logDir();
  await mkdir(dir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  logPath = path.join(dir, `mother-${stamp}.log`);
  latestPath = path.join(dir, 'mother-latest.log');
  const header = `\n========== ${command} @ ${new Date().toISOString()} ==========\n`;
  await appendFile(logPath, header, 'utf-8');
  await appendFile(latestPath, header, 'utf-8');
  return logPath;
}

async function writeFileLog(level, message, data) {
  if (!logPath) return;
  const line = `[${new Date().toISOString()}] [${level}] ${message}${
    data != null ? ` | ${JSON.stringify(data)}` : ''
  }\n`;
  await appendFile(logPath, line, 'utf-8').catch(() => undefined);
  if (latestPath) {
    await appendFile(latestPath, line, 'utf-8').catch(() => undefined);
  }
}

export function progress(message, level = 'info', data = null) {
  const entry = {
    type: 'progress',
    level,
    message,
    ts: new Date().toISOString(),
  };
  if (data != null) entry.data = data;
  process.stderr.write(`${JSON.stringify(entry)}\n`);
  void writeFileLog(level, message, data);
}

export function maskToken(token) {
  if (token == null) return null;
  const raw = String(token).trim();
  if (!raw) return null;
  if (raw.length <= 10) return '***';
  return `${raw.slice(0, 6)}…${raw.slice(-4)}`;
}

export function summarizeArgs(args = {}) {
  const out = { ...args };
  for (const key of ['token', 'motherToken']) {
    if (out[key]) out[key] = maskToken(out[key]);
  }
  if (out.proxy) {
    try {
      const u = new URL(String(out.proxy).includes('://') ? out.proxy : `http://${out.proxy}`);
      if (u.password) u.password = '***';
      out.proxy = u.toString();
    } catch {
      out.proxy = String(out.proxy).replace(/:[^:@/]+@/, ':***@');
    }
  }
  if (Array.isArray(out.childTokens)) {
    out.childTokens = out.childTokens.map((t) => maskToken(t));
  }
  if (Array.isArray(out.childTargets)) {
    out.childTargets = out.childTargets.map((t) => ({
      userId: t?.userId,
      phone: t?.phone ?? null,
      joinByLink: t?.joinByLink,
      token: maskToken(t?.token),
    }));
  }
  return out;
}

export function summarizeRpc(response) {
  if (response == null) return { empty: true };
  const payload = response.payload ?? response;
  if (!payload || typeof payload !== 'object') {
    return { type: typeof payload };
  }
  return {
    error: payload.error ?? null,
    chatId: payload.chat?.id ?? payload.chatId ?? null,
    title: payload.chat?.title ?? payload.chat?.name ?? null,
    keys: Object.keys(payload).slice(0, 16),
  };
}
