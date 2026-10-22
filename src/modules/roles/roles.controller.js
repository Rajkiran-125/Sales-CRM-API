// @ts-check
'use strict';

const service = require('./roles.service');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData } = require('../../shared/response');

/** @typedef {import('express').Request & { valid: any }} Req */
const v = (/** @type {import('express').Request} */ req) => /** @type {Req} */ (req).valid;

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    sendData(req, res, await service.list(v(req).query.includeInactive));
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
  async permissions(req, res) {
    sendData(req, res, await service.permissions());
  },
};
