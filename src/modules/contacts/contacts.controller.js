// @ts-check
'use strict';

/** Contacts (12.6): HTTP only. */
const service = require('./contacts.service');
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
    sendData(req, res, await service.update(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async deactivate(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.deactivate(r.valid.params.id, requestMeta(req)));
  },
};
