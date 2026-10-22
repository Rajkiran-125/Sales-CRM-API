// @ts-check
'use strict';

/** Tasks (12.3): HTTP only. */
const service = require('./tasks.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async myDay(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.myDay(r.user.id, r.user.permissions));
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.create(r.valid.body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(
      req,
      res,
      await service.update(r.valid.params.id, r.valid.body, requestMeta(req), allowAny),
    );
  },
};
