// @ts-check
'use strict';

/**
 * Declarative route tables (decision D-19). Every route states its access on the route
 * itself (8.5):
 *   'public'         no token (rate limited where relevant)
 *   'authenticated'  any active signed-in user
 *   ['perm.code',..] signed-in user holding ANY of the permission codes
 * The chain is: [route limiters] -> authenticate -> loadUserContext -> forced password
 * change gate -> authorizePermission -> validate -> handler. The registry feeds the
 * OpenAPI document and the "every route declares its access" test (21.1).
 */
const express = require('express');
const authenticate = require('../middleware/authenticate');
const loadUserContext = require('../middleware/loadUserContext');
const enforcePasswordChange = require('../middleware/enforcePasswordChange');
const authorizePermission = require('../middleware/authorizePermission');
const validate = require('../middleware/validate');

/**
 * @typedef {Object} RouteDef
 * @property {'get'|'post'|'put'|'patch'|'delete'} method
 * @property {string} path  relative to the module base, Express syntax (/:id)
 * @property {'public' | 'authenticated' | string[]} access
 * @property {string} summary
 * @property {string} [description]
 * @property {boolean} [allowDuringPasswordChange]
 * @property {import('../middleware/validate').RouteSchema} [schema]
 * @property {import('express').RequestHandler[]} [before]
 * @property {import('express').RequestHandler[]} [parse]  body parsers that must run after the access check (multipart uploads)
 * @property {import('express').RequestHandler} handler
 * @property {number} [successStatus]
 * @property {string} [produces]  e.g. an xlsx download
 */

/** @typedef {RouteDef & { fullPath: string, tag: string }} RegisteredRoute */

/** @type {RegisteredRoute[]} */
const registry = [];

/**
 * @param {string} basePath e.g. /api/v1/users
 * @param {string} tag      OpenAPI tag
 * @param {RouteDef[]} defs
 */
function buildRouter(basePath, tag, defs) {
  const router = express.Router();

  for (const def of defs) {
    const isPermissionList = Array.isArray(def.access);
    if (!def.access || (isPermissionList && def.access.length === 0)) {
      throw new Error(
        `Route ${def.method.toUpperCase()} ${basePath}${def.path} does not declare its access`,
      );
    }

    /** @type {import('express').RequestHandler[]} */
    const chain = [...(def.before ?? [])];
    if (def.access !== 'public') {
      chain.push(
        authenticate,
        loadUserContext,
        enforcePasswordChange(!!def.allowDuringPasswordChange),
      );
      if (isPermissionList)
        chain.push(authorizePermission(.../** @type {string[]} */ (def.access)));
    }
    chain.push(...(def.parse ?? []), validate(def.schema), def.handler);

    router[def.method](def.path, ...chain);
    const fullPath = `${basePath}${def.path === '/' ? '' : def.path}`;
    if (!registry.some((r) => r.method === def.method && r.fullPath === fullPath)) {
      registry.push({ ...def, fullPath, tag });
    }
  }

  return router;
}

module.exports = { buildRouter, registry };
