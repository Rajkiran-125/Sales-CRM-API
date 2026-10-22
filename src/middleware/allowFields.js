// @ts-check
'use strict';

/**
 * Second line of defence against mass assignment (8.6, Orchestrator allowFields.js):
 * fields controlled by the server are removed from every request body before validation,
 * whatever the route. The strict zod schemas are the first line.
 */
const PROTECTED_FIELDS = Object.freeze([
  'createdBy',
  'createdAt',
  'updatedBy',
  'updatedAt',
  'created_by',
  'updated_by',
  'tokenVersion',
  'token_version',
  'passwordHash',
  'password_hash',
  'permissions',
  'isSystem',
  'is_system',
]);

/** @type {import('../shared/types').Handler} */
function blockProtectedFields(req, _res, next) {
  if (req.body && typeof req.body === 'object' && !Array.isArray(req.body)) {
    for (const field of PROTECTED_FIELDS) delete req.body[field];
  }
  next();
}

/**
 * Keep only the listed fields of the body.
 * @param {string[]} fields
 * @returns {import('express').RequestHandler}
 */
function allowFields(fields) {
  return (req, _res, next) => {
    if (req.body && typeof req.body === 'object' && !Array.isArray(req.body)) {
      /** @type {Record<string, unknown>} */
      const kept = {};
      for (const f of fields) if (req.body[f] !== undefined) kept[f] = req.body[f];
      req.body = kept;
    }
    next();
  };
}

module.exports = { allowFields, blockProtectedFields, PROTECTED_FIELDS };
