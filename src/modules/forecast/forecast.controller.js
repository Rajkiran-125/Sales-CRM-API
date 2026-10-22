// @ts-check
'use strict';

/** Forecast & status (12.10): HTTP only. */
const service = require('./forecast.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async monthlySave(req, res) {
    const r = /** @type {any} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(req, res, await service.monthlySave(r.valid.body, requestMeta(req), allowAny));
  },

  /** @type {import('../../shared/types').Handler} */
  async nudge(req, res) {
    const r = /** @type {any} */ (req);
    sendData(req, res, await service.nudge(r.valid.body.weekStart, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async weekly(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.weekly(r.user.id, r.user.permissions, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async monthly(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.monthly(r.user.id, r.user.permissions, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async hierarchy(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.hierarchy(r.user.id, r.valid.query));
  },
};
