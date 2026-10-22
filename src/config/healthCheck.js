// @ts-check
'use strict';

/**
 * Health endpoints (8.12, 10.11, 17.7), same statuses as the Orchestrator
 * (UP / DOWN / UNKNOWN / DISABLED):
 *   GET /api/v1/health        public liveness, no data
 *   GET /api/v1/health/ready  readiness with dependency checks, internal network only
 */
const fs = require('fs/promises');
const express = require('express');
const config = require('./index');
const db = require('../db/pool');

const started = Date.now();

/** Loopback and private (RFC 1918 / unique local) addresses. */
function isInternal(/** @type {string | undefined} */ ip) {
  if (!ip) return false;
  const v4 = ip.startsWith('::ffff:') ? ip.slice(7) : ip;
  return (
    v4 === '127.0.0.1' ||
    ip === '::1' ||
    /^10\./.test(v4) ||
    /^192\.168\./.test(v4) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(v4) ||
    /^f[cd][0-9a-f]{2}:/i.test(ip)
  );
}

async function checkMail() {
  if (config.mail.transport === 'smtp') return { status: config.mail.smtp.host ? 'UP' : 'DOWN' };
  try {
    await fs.mkdir(config.mail.fileDir, { recursive: true });
    return { status: 'UP', transport: 'file' };
  } catch {
    return { status: 'DOWN', transport: 'file' };
  }
}

const router = express.Router();

router.get('/', (_req, res) => {
  res.json({ success: true, data: { status: 'UP', timestamp: new Date().toISOString() } });
});

router.get('/ready', async (req, res) => {
  if (!isInternal(req.ip)) {
    res.status(404).json({ success: false, error: { code: 'NOT_FOUND', message: 'Not found.' } });
    return;
  }
  const dbStart = Date.now();
  const database = (await db.ping()) ? 'UP' : 'DOWN';
  const checks = {
    app: { status: 'UP', uptimeSeconds: Math.round((Date.now() - started) / 1000) },
    database: { status: database, responseTimeMs: Date.now() - dbStart },
    mail: await checkMail(),
    fileStorage: { status: 'DISABLED' },
  };
  const status = database === 'UP' && checks.mail.status === 'UP' ? 'UP' : 'DEGRADED';
  res.status(status === 'UP' ? 200 : 503).json({
    success: status === 'UP',
    data: { status, environment: config.env, version: 'v1', checks },
    timestamp: new Date().toISOString(),
  });
});

module.exports = { router, isInternal };
