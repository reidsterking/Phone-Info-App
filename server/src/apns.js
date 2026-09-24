// Minimal Apple Push Notification service client using only Node built-ins.
// Uses token-based auth (.p8 key from developer.apple.com > Keys).
import http2 from 'node:http2';
import crypto from 'node:crypto';
import fs from 'node:fs';

const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

const base64url = (input) =>
  Buffer.from(input).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

export function makeJwt({ keyPem, keyId, teamId, now = Math.floor(Date.now() / 1000) }) {
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: keyPem,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}

export class ApnsClient {
  constructor({ keyPem, keyId, teamId, bundleId }) {
    this.keyPem = keyPem;
    this.keyId = keyId;
    this.teamId = teamId;
    this.bundleId = bundleId;
    this.jwt = null;
    this.jwtIssuedAt = 0;
  }

  static fromEnv(env = process.env) {
    const keyPem = env.APNS_KEY || (env.APNS_KEY_PATH && fs.readFileSync(env.APNS_KEY_PATH, 'utf8'));
    if (!keyPem || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_BUNDLE_ID) return null;
    return new ApnsClient({
      keyPem,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      bundleId: env.APNS_BUNDLE_ID,
    });
  }

  token() {
    const now = Math.floor(Date.now() / 1000);
    // Apple rejects tokens older than 1 hour and throttles refreshing more than every 20 minutes.
    if (!this.jwt || now - this.jwtIssuedAt > 50 * 60) {
      this.jwt = makeJwt({ keyPem: this.keyPem, keyId: this.keyId, teamId: this.teamId, now });
      this.jwtIssuedAt = now;
    }
    return this.jwt;
  }

  sendOnce(environment, deviceToken, payload, { pushType, priority }) {
    return new Promise((resolve, reject) => {
      const session = http2.connect(HOSTS[environment]);
      session.on('error', reject);
      const req = session.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${this.token()}`,
        'apns-topic': this.bundleId,
        'apns-push-type': pushType,
        'apns-priority': String(priority),
        'content-type': 'application/json',
      });
      let status = 0;
      let body = '';
      req.on('response', (headers) => { status = headers[':status']; });
      req.setEncoding('utf8');
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        session.close();
        let reason = null;
        try { reason = body ? JSON.parse(body).reason : null; } catch { reason = body; }
        resolve({ ok: status === 200, status, reason, environment });
      });
      req.on('error', (err) => { session.close(); reject(err); });
      req.end(JSON.stringify(payload));
    });
  }

  // Tries the environment the device reported first. A token from a development build
  // only works against sandbox and vice versa, so on BadDeviceToken we retry the other one.
  async send(device, payload, opts) {
    const first = device.apnsEnvironment === 'production' ? 'production' : 'sandbox';
    const second = first === 'production' ? 'sandbox' : 'production';
    const result = await this.sendOnce(first, device.pushToken, payload, opts);
    if (result.ok || result.reason !== 'BadDeviceToken') return result;
    return this.sendOnce(second, device.pushToken, payload, opts);
  }

  ping(device, command) {
    return this.send(device, {
      aps: {
        alert: { title: 'Find My Device', body: `${device.name || 'This device'} is being pinged.` },
        sound: 'ping.wav',
        'interruption-level': 'time-sensitive',
        // Also wake the app so it sends a fresh location along with the sound.
        'content-available': 1,
      },
      command: 'ping',
      requestedAt: command.requestedAt,
    }, { pushType: 'alert', priority: 10 });
  }

  // Silent push asking the app to wake up and send a fresh report. iOS throttles these
  // and never delivers them to an app the user force-quit, so treat it as best effort.
  refresh(device) {
    return this.send(device, { aps: { 'content-available': 1 }, command: 'refresh' },
      { pushType: 'background', priority: 5 });
  }
}
