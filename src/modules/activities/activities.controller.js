// @ts-check
'use strict';

/** Activities (12.20): HTTP only. */
const service = require('./activities.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.create(r.valid.body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    // ALL-scope users (admin / head) may edit any activity; others only their own
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(
      req,
      res,
      await service.update(r.valid.params.id, r.valid.body, requestMeta(req), allowAny),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async del(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(req, res, await service.delete(r.valid.params.id, requestMeta(req), allowAny));
  },
};
