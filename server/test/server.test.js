import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { createServer } from '../src/server.js';
import { Store } from '../src/store.js';
import { makeJwt } from '../src/apns.js';

const API_KEY = 'test-key-0123456789abcdef';
const DEVICE_ID = '3F2504E0-4F89-11D3-9A0C-0305E82C3301';

async function withServer(opts, fn) {
  const store = new Store(null);
  const server = createServer({ apiKey: API_KEY, store, apns: null, ...opts });
  await new Promise((r) => server.listen(0, r));
  const base = `http://localhost:${server.address().port}`;
  const call = (method, path, body, key = API_KEY) => fetch(base + path, {
    method,
    headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  try { await fn({ call, store, base }); } finally { server.close(); }
}

test('refuses to start with a weak API key', () => {
  assert.throws(() => createServer({ apiKey: 'short', store: new Store(null) }));
});

test('rejects requests without the API key', async () => {
  await withServer({}, async ({ call }) => {
    assert.equal((await call('GET', '/api/devices', null, 'wrong-key-wrong-key')).status, 401);
    assert.equal((await call('GET', '/api/devices', null, '')).status, 401);
  });
});

test('serves the dashboard without auth', async () => {
  await withServer({}, async ({ base }) => {
    const res = await fetch(base + '/');
    assert.equal(res.status, 200);
    assert.match(await res.text(), /Device Tracker/);
  });
});

test('stores reports and hides the push token from the dashboard', async () => {
  await withServer({}, async ({ call }) => {
    const report = {
      name: 'Reid iPhone', model: 'iPhone', systemName: 'iOS', systemVersion: '19.0',
      pushToken: 'abc123', apnsEnvironment: 'sandbox', reason: 'manual',
      battery: { level: 0.85, state: 'charging', lowPowerMode: false },
      location: { latitude: 40.7, longitude: -74.0, accuracy: 12, timestamp: '2026-09-24T12:00:00Z' },
    };
    const res = await call('POST', `/api/devices/${DEVICE_ID}/report`, report);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { commands: [] });

    const { devices } = await (await call('GET', '/api/devices')).json();
    assert.equal(devices.length, 1);
    assert.equal(devices[0].battery.level, 0.85);
    assert.equal(devices[0].battery.state, 'charging');
    assert.equal(devices[0].location.latitude, 40.7);
    assert.equal(devices[0].pushToken, undefined);
    assert.equal(devices[0].canPush, true);
  });
});

test('ping without APNs is queued and delivered on next report', async () => {
  await withServer({}, async ({ call }) => {
    await call('POST', `/api/devices/${DEVICE_ID}/report`, { name: 'iPad' });
    const ping = await (await call('POST', `/api/devices/${DEVICE_ID}/ping`)).json();
    assert.equal(ping.queued, true);
    assert.equal(ping.pushed, false);

    const first = await (await call('POST', `/api/devices/${DEVICE_ID}/report`, {})).json();
    assert.equal(first.commands.length, 1);
    assert.equal(first.commands[0].type, 'ping');
    const second = await (await call('POST', `/api/devices/${DEVICE_ID}/report`, {})).json();
    assert.equal(second.commands.length, 0);
  });
});

test('ping uses APNs when configured', async () => {
  const sent = [];
  const apns = { ping: async (d) => { sent.push(d.pushToken); return { ok: true, status: 200, environment: 'production' }; } };
  await withServer({ apns }, async ({ call, store }) => {
    await call('POST', `/api/devices/${DEVICE_ID}/report`, { pushToken: 'tok', apnsEnvironment: 'sandbox' });
    const r = await (await call('POST', `/api/devices/${DEVICE_ID}/ping`)).json();
    assert.equal(r.pushed, true);
    assert.deepEqual(sent, ['tok']);
    assert.equal(store.get(DEVICE_ID).apnsEnvironment, 'production');
  });
});

test('rejects bad ids and unknown devices', async () => {
  await withServer({}, async ({ call }) => {
    assert.equal((await call('POST', '/api/devices/..%2F..%2Fetc/report', {})).status, 400);
    assert.equal((await call('POST', `/api/devices/${DEVICE_ID}/ping`)).status, 404);
  });
});

test('location history is capped and deduplicated', () => {
  const store = new Store(null);
  for (let i = 0; i < 250; i++) {
    const location = { latitude: i, longitude: 0, accuracy: 5, timestamp: `t${i}` };
    store.report(DEVICE_ID, { location });
    store.report(DEVICE_ID, { location });
  }
  assert.equal(store.get(DEVICE_ID).history.length, 200);
  assert.equal(store.get(DEVICE_ID).history[0].latitude, 50);
});

test('APNs JWT is a valid ES256 signature', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwt = makeJwt({ keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }), keyId: 'KEY123', teamId: 'TEAM456', now: 1000 });
  const [h, c, sig] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url')), { iss: 'TEAM456', iat: 1000 });
  const ok = crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url'));
  assert.equal(ok, true);
});
