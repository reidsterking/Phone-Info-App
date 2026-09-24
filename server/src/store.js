// Tiny JSON-file store. Plenty for a handful of personal devices.
import fs from 'node:fs';
import path from 'node:path';

const HISTORY_LIMIT = 200;

export class Store {
  constructor(file) {
    this.file = file;
    this.devices = {};
    if (file && fs.existsSync(file)) {
      this.devices = JSON.parse(fs.readFileSync(file, 'utf8')).devices || {};
    }
  }

  save() {
    if (!this.file) return;
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ devices: this.devices }, null, 2));
    fs.renameSync(tmp, this.file);
  }

  list() {
    return Object.values(this.devices).sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }

  get(id) {
    return this.devices[id] || null;
  }

  // Applies a status report from a device and returns (and clears) its pending commands.
  report(id, report, now = new Date()) {
    const device = this.devices[id] || { id, history: [], pendingCommands: [], firstSeen: now.toISOString() };
    for (const key of ['name', 'model', 'systemName', 'systemVersion', 'pushToken', 'apnsEnvironment', 'appVersion']) {
      if (report[key] !== undefined) device[key] = report[key];
    }
    if (report.battery) device.battery = { ...report.battery, reportedAt: now.toISOString() };
    if (report.location) {
      device.location = report.location;
      const last = device.history[device.history.length - 1];
      if (!last || last.timestamp !== report.location.timestamp) {
        device.history.push(report.location);
        if (device.history.length > HISTORY_LIMIT) device.history.splice(0, device.history.length - HISTORY_LIMIT);
      }
    }
    device.lastSeen = now.toISOString();
    device.lastReportReason = report.reason || null;
    const commands = device.pendingCommands || [];
    device.pendingCommands = [];
    this.devices[id] = device;
    this.save();
    return commands;
  }

  queueCommand(id, command) {
    const device = this.devices[id];
    if (!device) return false;
    device.pendingCommands = [...(device.pendingCommands || []).filter((c) => c.type !== command.type), command];
    this.save();
    return true;
  }

  remove(id) {
    if (!this.devices[id]) return false;
    delete this.devices[id];
    this.save();
    return true;
  }
}
