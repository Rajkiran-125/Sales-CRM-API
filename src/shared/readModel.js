// @ts-check
'use strict';

/**
 * Helpers for the read-side modules (D-27): 0/1 columns computed by SQL expressions become
 * booleans, decimal percentages become numbers, and opening a record is written to the
 * record access log (10.8 rule 6, UM 12 "every view is logged").
 */
const auditRepo = require('../modules/audit/audit.repository');
const { requestMeta } = require('./requestMeta');

/**
 * @param {Record<string, any>} row
 * @param {{ bools?: string[], numbers?: string[] }} keys
 */
function shape(row, keys) {
  if (!row) return row;
  const out = { ...row };
  for (const k of keys.bools ?? [])
    if (out[k] !== null && out[k] !== undefined) out[k] = Boolean(Number(out[k]));
  for (const k of keys.numbers ?? [])
    if (out[k] !== null && out[k] !== undefined) out[k] = Number(out[k]);
  return out;
}

/**
 * @param {Array<Record<string, any>> | undefined} rows
 * @param {{ bools?: string[], numbers?: string[] }} keys
 */
const shapeAll = (rows, keys) => (rows ?? []).map((r) => shape(r, keys));

/**
 * @param {import('express').Request} req
 * @param {string} entityType
 * @param {number} entityId
 */
async function logView(req, entityType, entityId) {
  const meta = requestMeta(req);
  await auditRepo.recordAccess({
    userId: /** @type {any} */ (req).user.id,
    entityType,
    entityId,
    accessType: 'VIEW',
    ip: meta.ip ?? '',
    requestId: meta.requestId,
  });
}

/**
 * An Excel export of a list, with its filters (17.6 "exports are logged").
 * @param {import('express').Request} req
 * @param {string} entityType
 * @param {any} filters
 */
async function logExport(req, entityType, filters) {
  const meta = requestMeta(req);
  await auditRepo.recordAccess({
    userId: /** @type {any} */ (req).user.id,
    entityType,
    entityId: /** @type {any} */ (null),
    accessType: 'EXPORT',
    detail: JSON.stringify(filters).slice(0, 500),
    ip: meta.ip ?? '',
    requestId: meta.requestId,
  });
}

module.exports = { shape, shapeAll, logView, logExport };
