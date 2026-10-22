// @ts-check
'use strict';

/** Management dashboard (12.2): HTTP only. */
const service = require('./dashboard.service');
const { sendData, sendList } = require('../../shared/response');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.get(r.user.id, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async drill(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    const { rows, total } = await service.drill(r.user.id, r.valid.params.tile, q);
    sendList(req, res, rows, { page: q.page, pageSize: q.pageSize, total });
  },
};
