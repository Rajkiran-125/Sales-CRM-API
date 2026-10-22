// @ts-check
'use strict';

/** Deal partners, competitors, partner commercial: HTTP only. */
const service = require('./dealParties.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any }} Req */

/** @param {import('express').Request} req */
const v = (req) => /** @type {Req} */ (req).valid;

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async partnerAdd(req, res) {
    const { params, body } = v(req);
    sendData(req, res, await service.partnerAdd(params.id, body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async partnerUpdate(req, res) {
    const { params, body } = v(req);
    sendData(
      req,
      res,
      await service.partnerUpdate(params.id, params.rowId, body, requestMeta(req)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async partnerRemove(req, res) {
    const { params } = v(req);
    await service.partnerRemove(params.id, params.rowId, requestMeta(req));
    res.status(204).end();
  },

  /** @type {import('../../shared/types').Handler} */
  async competitorAdd(req, res) {
    const { params, body } = v(req);
    sendData(req, res, await service.competitorAdd(params.id, body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async competitorUpdate(req, res) {
    const { params, body } = v(req);
    sendData(
      req,
      res,
      await service.competitorUpdate(params.id, params.rowId, body, requestMeta(req)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async competitorRemove(req, res) {
    const { params } = v(req);
    await service.competitorRemove(params.id, params.rowId, requestMeta(req));
    res.status(204).end();
  },

  /** @type {import('../../shared/types').Handler} */
  async commercialCreate(req, res) {
    const { params, body } = v(req);
    sendData(req, res, await service.commercialCreate(params.id, body, requestMeta(req)), 201);
  },
};
