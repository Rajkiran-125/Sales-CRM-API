// @ts-check
'use strict';

/** Custom fields (12.15): HTTP only. */
const service = require('./customFields.service');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');
const { appError } = require('../../shared/errors');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const q = /** @type {Req} */ (req).valid.query;
    sendData(req, res, await service.list(q.entity ?? null, q.includeInactive === 'true'));
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.save(null, r.valid.body, requestMeta(req)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.save(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async values(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    sendData(req, res, await service.values(r.user.id, q.entity, q.recordId));
  },

  /** @type {import('../../shared/types').Handler} */
  async saveValues(req, res) {
    const r = /** @type {Req} */ (req);
    const b = r.valid.body;
    const perm =
      service.EDIT_PERMISSION[/** @type {keyof typeof service.EDIT_PERMISSION} */ (b.entity)];
    if (!r.user.permissions.has(perm)) {
      throw appError('FORBIDDEN', 'You do not have permission to change this record.');
    }
    sendData(
      req,
      res,
      await service.saveValues(b, requestMeta(req), r.user.dataScope.widest === 'ALL'),
    );
  },
};
