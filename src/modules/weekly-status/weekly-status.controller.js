// @ts-check
'use strict';

/** Weekly status write side (12.21): HTTP only. */
const service = require('./weekly-status.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async upsert(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(req, res, await service.upsert(r.valid.body, requestMeta(req), allowAny));
  },

  /** @type {import('../../shared/types').Handler} */
  async del(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(req, res, await service.del(r.valid.params.id, requestMeta(req), allowAny));
  },
};
