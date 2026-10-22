// @ts-check
'use strict';

const service = require('./users.service');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData, sendList, sendNoContent } = require('../../shared/response');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */
const v = (/** @type {import('express').Request} */ req) => /** @type {Req} */ (req).valid;

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const { rows, meta } = await service.list(v(req).query);
    sendList(req, res, rows, meta);
  },

  /** @type {import('../../shared/types').Handler} */
  async lookup(req, res) {
    sendData(req, res, await service.lookup(v(req).query));
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    sendData(req, res, await service.get(v(req).params.id));
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    sendData(req, res, await service.create(v(req).body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    sendData(req, res, await service.update(v(req).params.id, v(req).body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async setStatus(req, res) {
    sendData(req, res, await service.setStatus(v(req).params.id, v(req).body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async unlock(req, res) {
    sendData(req, res, await service.unlock(v(req).params.id, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async passwordReset(req, res) {
    await service.sendPasswordReset(v(req).params.id, requestMeta(req));
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async invitation(req, res) {
    await service.resendInvitation(v(req).params.id, requestMeta(req));
    sendNoContent(res);
  },

  /** @type {import('../../shared/types').Handler} */
  async revokeSessions(req, res) {
    await service.revokeSessions(v(req).params.id, requestMeta(req));
    sendNoContent(res);
  },
};
