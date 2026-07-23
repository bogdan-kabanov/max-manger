import { MaxClient } from '@mqpanda/vkmax-node';
import { HttpsProxyAgent } from 'https-proxy-agent';
import { SocksProxyAgent } from 'socks-proxy-agent';
import WebSocket from 'ws';
import { WS_HOST, USER_AGENT } from '@mqpanda/vkmax-node/dist/src/constants.js';

/** @type {import('http').Agent | null} */
let activeAgent = null;
/** @type {string | null} */
let activeProxyUrl = null;
let patched = false;

export function currentProxyUrl() {
  return activeProxyUrl;
}

/**
 * Temporarily switch proxy for a callback, then restore previous.
 * @template T
 * @param {string | null | undefined} proxy
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
export async function withProxy(proxy, fn) {
  const prev = activeProxyUrl;
  const next = proxy == null || !String(proxy).trim() ? prev : normalizeProxyUrl(proxy);
  if (next !== prev) {
    applyProxy(next);
  }
  try {
    return await fn();
  } finally {
    if (next !== prev) {
      applyProxy(prev);
    }
  }
}

/**
 * @param {string | null | undefined} raw
 * @returns {string | null}
 */
export function normalizeProxyUrl(raw) {
  if (raw == null) return null;
  let value = String(raw).trim();
  if (!value) return null;

  // scheme://user:pass@host:port:CountryLabel → drop trailing label
  const trailingLabel = /^(.*?:\/\/.+?:\d+):([A-Za-z][\w\- ]*)$/.exec(value);
  if (trailingLabel) {
    value = trailingLabel[1];
  }

  if (/^(https?|socks4a?|socks5h?):\/\//i.test(value)) {
    return value;
  }
  // host:port → http proxy
  if (/^[^:]+:\d+$/.test(value)) {
    return `http://${value}`;
  }
  // host:port:user:pass[:Country]
  const colonParts = value.split(':');
  if (!value.includes('@') && colonParts.length >= 4 && /^\d+$/.test(colonParts[1])) {
    const host = colonParts[0];
    const port = colonParts[1];
    const user = colonParts[2];
    let pass;
    if (
      colonParts.length >= 5 &&
      /^[A-Za-z][\w\- ]*$/.test(colonParts[colonParts.length - 1])
    ) {
      pass = colonParts.slice(3, -1).join(':');
    } else {
      pass = colonParts.slice(3).join(':');
    }
    return `http://${user}:${pass}@${host}:${port}`;
  }
  // user:pass@host:port
  if (/^.+@.+:\d+$/.test(value)) {
    return `http://${value}`;
  }
  throw new Error(
    `Некорректный прокси. Примеры: http://user:pass@host:port, host:port:user:pass, socks5://127.0.0.1:1080`,
  );
}

/**
 * @param {string} proxyUrl
 */
function createAgent(proxyUrl) {
  const lower = proxyUrl.toLowerCase();
  if (lower.startsWith('socks')) {
    return new SocksProxyAgent(proxyUrl);
  }
  return new HttpsProxyAgent(proxyUrl);
}

function patchMaxClientConnect() {
  if (patched) return;
  patched = true;

  MaxClient.prototype.connect = async function connectViaProxy() {
    if (this._connection) {
      throw new Error('Already connected');
    }

    const via = activeProxyUrl ? ` via ${maskProxy(activeProxyUrl)}` : '';
    console.log(`Connecting to ${WS_HOST}${via}...`);

    return new Promise((resolve, reject) => {
      /** @type {import('ws').ClientOptions} */
      const options = {
        origin: 'https://web.max.ru',
        headers: {
          'user-agent': USER_AGENT.headerUserAgent,
        },
      };
      if (activeAgent) {
        options.agent = activeAgent;
      }

      this._connection = new WebSocket(WS_HOST, options);
      this._connection.on('open', () => {
        console.log('Connected. Receive task started.');
        this._isConnected = true;
        this._startRecvLoop();
        resolve(this._connection);
      });
      this._connection.on('error', (error) => {
        console.error('WebSocket error:', error);
        reject(error);
      });
      this._connection.on('close', () => {
        console.log('WebSocket connection closed');
        this._isConnected = false;
        this._connection = null;
      });
    });
  };
}

/**
 * @param {string | null | undefined} raw
 */
export function applyProxy(raw) {
  const normalized = normalizeProxyUrl(raw);
  activeProxyUrl = normalized;
  activeAgent = normalized ? createAgent(normalized) : null;
  patchMaxClientConnect();
  return normalized;
}

/**
 * @param {string} proxyUrl
 */
export function maskProxy(proxyUrl) {
  try {
    const u = new URL(proxyUrl);
    if (u.password) u.password = '***';
    return u.toString();
  } catch {
    return proxyUrl.replace(/:[^:@/]+@/, ':***@');
  }
}
