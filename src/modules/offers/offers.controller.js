// @ts-check
'use strict';

/** Offers (14.5): HTTP only. */
const service = require('./offers.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

const allowAny = (/** @type {Req} */ r) => r.user.dataScope.widest === 'ALL';

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.create(r.valid.body, requestMeta(req), allowAny(r)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async submit(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.submit(r.valid.params.id, requestMeta(req), allowAny(r)));
  },

  /** @type {import('../../shared/types').Handler} */
  async approve(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.approve(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async send(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.send(r.valid.params.id, r.valid.body, requestMeta(req), allowAny(r)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async respond(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.respond(r.valid.params.id, r.valid.body, requestMeta(req), allowAny(r)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.update(r.valid.params.id, r.valid.body, requestMeta(req), allowAny(r)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async revise(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.revise(r.valid.params.id, requestMeta(req), allowAny(r)), 201);
  },
};
