'use strict';

/**
 * Shared helpers for the API tests: the app, a migration-account connection for test-only
 * time travel, reading the emails written by the file transport, and user set-up.
 */
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');
const supertest = require('supertest');

const config = require('../src/config');
const db = require('../src/db/pool');
const mailer = require('../src/integrations/mailer');
const { createApp } = require('../src/app');
const { randomToken, sha256 } = require('../src/shared/crypto');

const app = createApp();
const api = () => supertest(app);

const STRONG = 'Correct-Horse-42';
const ADMIN = { email: 'admin@test.local', name: 'Test Admin', password: 'Steady-Harbour-2026!' };

/** @type {import('mysql2/promise').Connection | null} */
let adminConn = null;

/** Migration-account connection (tests only), for setting up time-dependent states. */
async function dba() {
  if (!adminConn) {
    adminConn = await mysql.createConnection({
      host: config.db.host,
      port: config.db.port,
      database: config.db.database,
      user: process.env.TEST_DB_MIGRATOR_USER,
      password: process.env.TEST_DB_MIGRATOR_PASSWORD,
      timezone: 'Z',
    });
  }
  return adminConn;
}

async function closeAll() {
  await mailer.flush();
  if (adminConn) await adminConn.end();
  adminConn = null;
  await db.close();
}

/**
 * Latest email written by the file transport for a recipient (and template code).
 * @param {string} to
 * @param {string} [code]
 */
async function lastMail(to, code) {
  await mailer.flush();
  const dir = config.mail.fileDir;
  if (!fs.existsSync(dir)) return null;
  const safeTo = to.replace(/[^A-Za-z0-9@._-]/g, '_');
  const files = fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(`_${safeTo}.json`) && (!code || f.includes(`_${code}_`)))
    .sort();
  if (!files.length) return null;
  const msg = JSON.parse(fs.readFileSync(path.join(dir, files[files.length - 1]), 'utf8'));
  return { subject: msg.subject, html: msg.html, text: msg.text, file: files[files.length - 1] };
}

/** @param {string} html */
function tokenFromMail(html) {
  const m = /token=([A-Za-z0-9_-]+)/.exec(html);
  if (!m) throw new Error('No token link in the email');
  return decodeURIComponent(m[1]);
}

/** @param {import('supertest').Response} res */
function refreshCookie(res) {
  const cookies = /** @type {string[]} */ (res.headers['set-cookie'] || []);
  const c = cookies.find((x) => x.startsWith(`${config.auth.refreshCookieName}=`));
  return c ? c.split(';')[0] : null;
}

/**
 * @param {string} email
 * @param {string} password
 */
async function login(email, password) {
  const res = await api().post('/api/v1/auth/login').send({ email, password });
  if (res.status !== 200)
    throw new Error(`login ${email} -> ${res.status} ${JSON.stringify(res.body)}`);
  return { token: res.body.data.accessToken, cookie: refreshCookie(res), res };
}

/** The first CRM Admin (created once per test run through the bootstrap procedure). */
async function adminSession() {
  const attempt = await api()
    .post('/api/v1/auth/login')
    .send({ email: ADMIN.email, password: ADMIN.password });
  if (attempt.status === 200)
    return { token: attempt.body.data.accessToken, cookie: refreshCookie(attempt) };

  const token = randomToken();
  await db.callProcedure('sp_user_bootstrap_admin', [
    ADMIN.email,
    ADMIN.name,
    sha256(token),
    '127.0.0.1',
    'test-bootstrap',
  ]);
  const accept = await api()
    .post('/api/v1/auth/invitations/accept')
    .send({ token, newPassword: ADMIN.password });
  if (accept.status !== 204)
    throw new Error(`accept admin invitation -> ${accept.status} ${JSON.stringify(accept.body)}`);
  return login(ADMIN.email, ADMIN.password);
}

/** @param {string} adminToken */
async function roleIds(adminToken) {
  const res = await api().get('/api/v1/roles').set('Authorization', `Bearer ${adminToken}`);
  return Object.fromEntries(res.body.data.map((/** @type {any} */ r) => [r.code, r.id]));
}

/**
 * Invite a user with the given role codes, accept the invitation and sign in.
 * @param {string} adminToken
 * @param {{ email: string, fullName?: string, roles: string[], reportingToUserId?: number | null, password?: string }} u
 */
async function createActiveUser(adminToken, u) {
  const ids = await roleIds(adminToken);
  const res = await api()
    .post('/api/v1/users')
    .set('Authorization', `Bearer ${adminToken}`)
    .send({
      email: u.email,
      fullName: u.fullName ?? u.email.split('@')[0],
      roleIds: u.roles.map((c) => ids[c]),
      reportingToUserId: u.reportingToUserId ?? null,
    });
  if (res.status !== 201)
    throw new Error(`create user -> ${res.status} ${JSON.stringify(res.body)}`);
  const mail = await lastMail(u.email, 'USER_INVITATION');
  const password = u.password ?? STRONG;
  const accept = await api()
    .post('/api/v1/auth/invitations/accept')
    .send({ token: tokenFromMail(mail.html), newPassword: password });
  if (accept.status !== 204)
    throw new Error(`accept -> ${accept.status} ${JSON.stringify(accept.body)}`);
  const session = await login(u.email, password);
  return { id: res.body.data.id, email: u.email, password, ...session };
}

/** @param {string} token */
const bearer = (token) => ({ Authorization: `Bearer ${token}` });

module.exports = {
  api,
  app,
  dba,
  closeAll,
  lastMail,
  tokenFromMail,
  refreshCookie,
  login,
  adminSession,
  createActiveUser,
  roleIds,
  bearer,
  STRONG,
  ADMIN,
};
