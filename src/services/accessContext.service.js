// @ts-check
'use strict';

/**
 * User context for every authenticated request (8.4): status, token version, roles,
 * effective permission codes and data-scope summary, read from sp_auth_user_context and
 * cached in memory for a short time. Role, permission and scope data are NEVER taken
 * from the request body.
 */
const config = require('../config');
const { callProcedure } = require('../db/pool');

const SCOPE_ORDER = ['MODULE_LIMITED', 'OWN_AND_TEAM', 'ASSIGNED_AND_TEAM', 'PARTNER_OWNED', 'ALL'];

/**
 * @typedef {Object} UserContext
 * @property {number} id
 * @property {string} email
 * @property {string} fullName
 * @property {string | null} mobile
 * @property {string | null} designation
 * @property {string | null} department
 * @property {number | null} reportingToUserId
 * @property {string | null} reportingToName
 * @property {string} status
 * @property {boolean} isActive  ACTIVE, or LOCKED with the lock period over
 * @property {number} tokenVersion
 * @property {boolean} mustChangePassword
 * @property {Array<{ id: number, code: string, name: string, dataScope: string }>} roles
 * @property {Set<string>} permissions
 * @property {string[]} moduleScopes
 * @property {{ widest: string | null, scopes: string[], teamSize: number }} dataScope
 */

/** @type {Map<number, { expiresAt: number, value: UserContext }>} */
const cache = new Map();

/**
 * @param {number} userId
 * @returns {Promise<UserContext | null>}
 */
async function loadFromDb(userId) {
  const [users, roles, permissions, modules, team] = await callProcedure('sp_auth_user_context', [
    userId,
  ]);
  const u = users?.[0];
  if (!u) return null;

  const lockedUntil = u.lockedUntil ? new Date(u.lockedUntil) : null;
  const isActive =
    u.status === 'ACTIVE' || (u.status === 'LOCKED' && !!lockedUntil && lockedUntil <= new Date());
  const scopes = [...new Set(roles.map((r) => String(r.dataScope)))];
  const widest = SCOPE_ORDER.filter((s) => scopes.includes(s)).pop() ?? null;

  return {
    id: Number(u.id),
    email: u.email,
    fullName: u.fullName,
    mobile: u.mobile,
    designation: u.designation,
    department: u.department,
    reportingToUserId: u.reportingToUserId,
    reportingToName: u.reportingToName,
    status: u.status,
    isActive,
    tokenVersion: Number(u.tokenVersion),
    mustChangePassword: Boolean(u.mustChangePassword),
    roles: roles.map((r) => ({
      id: Number(r.id),
      code: r.code,
      name: r.name,
      dataScope: r.dataScope,
    })),
    permissions: new Set(permissions.map((p) => String(p.code))),
    moduleScopes: modules.map((m) => String(m.module)),
    dataScope: { widest, scopes, teamSize: Number(team?.[0]?.teamSize ?? 0) },
  };
}

/**
 * @param {number} userId
 * @returns {Promise<UserContext | null>}
 */
async function getUserContext(userId) {
  const ttl = config.auth.userContextCacheSeconds * 1000;
  const hit = cache.get(userId);
  if (hit && hit.expiresAt > Date.now()) return hit.value;

  const value = await loadFromDb(userId);
  if (value && ttl > 0) cache.set(userId, { expiresAt: Date.now() + ttl, value });
  else cache.delete(userId);
  return value;
}

/** Drop one user's cached context (after their roles, status or sessions changed). */
function invalidate(/** @type {number} */ userId) {
  cache.delete(userId);
}

/** Drop every cached context (after a role's permissions changed). */
function invalidateAll() {
  cache.clear();
}

/** @param {UserContext} ctx */
function toPublicProfile(ctx) {
  return {
    id: ctx.id,
    email: ctx.email,
    fullName: ctx.fullName,
    mobile: ctx.mobile,
    designation: ctx.designation,
    department: ctx.department,
    reportingToUserId: ctx.reportingToUserId,
    reportingToName: ctx.reportingToName,
    status: ctx.status,
    mustChangePassword: ctx.mustChangePassword,
    roles: ctx.roles,
    permissions: [...ctx.permissions].sort(),
    dataScope: { ...ctx.dataScope, modules: ctx.moduleScopes },
  };
}

module.exports = { getUserContext, invalidate, invalidateAll, toPublicProfile };
