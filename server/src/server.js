import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Store } from './store.js';
import { ApnsClient } from './apns.js';

const PUBLIC_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const MAX_BODY = 64 * 1024;
const ID_PATTERN = /^[A-Za-z0-9-]{8,64}$/;

function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('Body too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

// Strips fields the dashboard does not need (push token) from API responses.
function publicDevice(device) {
  const { pushToken, pendingCommands, ...rest } = device;
  return { ...rest, canPush: Boolean(pushToken), pendingCommands: (pendingCommands || []).map((c) => c.type) };
}

export function createServer({ apiKey, store, apns }) {
  if (!apiKey || apiKey.length < 16) throw new Error('API_KEY must be set and at least 16 characters long');

  const routes = [
    ['POST', /^\/api\/devices\/([^/]+)\/report$/, async (req, res, id) => {
      const body = await readJson(req);
      const commands = store.report(id, body);
      send(res, 200, { commands });
    }],
    ['GET', /^\/api\/devices$/, async (req, res) => {
      send(res, 200, { devices: store.list().map(publicDevice), pushConfigured: Boolean(apns) });
    }],
    ['POST', /^\/api\/devices\/([^/]+)\/(ping|refresh)$/, async (req, res, id, action) => {
      const device = store.get(id);
      if (!device) return send(res, 404, { error: 'Unknown device' });
      // Queue the command too, so the app picks it up on its next report even if the push is lost.
      const command = { type: action, requestedAt: new Date().toISOString() };
      store.queueCommand(id, command);
      if (!apns) return send(res, 200, { queued: true, pushed: false, reason: 'APNs is not configured on the server' });
      if (!device.pushToken) return send(res, 200, { queued: true, pushed: false, reason: 'Device has not registered for push' });
      const result = await apns[action](device, command);
      if (result.environment && result.ok && result.environment !== device.apnsEnvironment) {
        device.apnsEnvironment = result.environment;
        store.save();
      }
      send(res, 200, { queued: true, pushed: result.ok, reason: result.reason, status: result.status });
    }],
    ['DELETE', /^\/api\/devices\/([^/]+)$/, async (req, res, id) => {
      send(res, store.remove(id) ? 200 : 404, {});
    }],
  ];

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');

      if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        return fs.createReadStream(path.join(PUBLIC_DIR, 'index.html')).pipe(res);
      }
      if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true });
      if (!url.pathname.startsWith('/api/')) return send(res, 404, { error: 'Not found' });

      const auth = req.headers.authorization || '';
      const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
      if (!token || !safeEqual(token, apiKey)) return send(res, 401, { error: 'Unauthorized' });

      for (const [method, pattern, handler] of routes) {
        const match = url.pathname.match(pattern);
        if (!match || req.method !== method) continue;
        const [, id, ...rest] = match;
        if (id !== undefined && !ID_PATTERN.test(id)) return send(res, 400, { error: 'Invalid device id' });
        return await handler(req, res, id, ...rest);
      }
      send(res, 404, { error: 'Not found' });
    } catch (err) {
      if (!res.headersSent) send(res, err.status || 500, { error: err.status ? err.message : 'Internal error' });
      if (!err.status) console.error(err);
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const store = new Store(process.env.DATA_FILE || path.join(process.cwd(), 'data', 'devices.json'));
  const apns = ApnsClient.fromEnv();
  const server = createServer({ apiKey: process.env.API_KEY, store, apns });
  const port = Number(process.env.PORT || 3000);
  server.listen(port, () => {
    console.log(`Device tracker server listening on http://localhost:${port}`);
    if (!apns) console.log('APNs not configured: ping/refresh will be queued only, not pushed.');
  });
}
