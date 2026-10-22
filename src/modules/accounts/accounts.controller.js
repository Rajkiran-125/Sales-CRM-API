// @ts-check
'use strict';

/** Accounts (12.6): HTTP only. */
const service = require('./accounts.service');
const { sendData, sendList } = require('../../shared/response');
const { logView, logExport } = require('../../shared/readModel');
const { sendWorkbook } = require('../../integrations/excel');
const { appError } = require('../../shared/errors');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.list(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },

  /** @type {import('../../shared/types').Handler} */
  async get360(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    const data = await service.get360(r.user.id, id);
    await logView(req, 'ACCOUNT', id);
    sendData(req, res, data);
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(req, res, await service.create(r.valid.body, requestMeta(req), allowAny), 201);
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

  /** @type {import('../../shared/types').Handler} */
  async merge(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.merge(r.valid.params.id, r.valid.body.survivorAccountId, requestMeta(req)),
    );
  },

  /** Needs account.view as well as report.export (the route checks the second). @type {import('../../shared/types').Handler} */
  async exportList(req, res) {
    const r = /** @type {Req} */ (req);
    if (!r.user.permissions.has('account.view')) {
      throw appError('FORBIDDEN', 'You do not have permission to view accounts.');
    }
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'ACCOUNT', q);
    const date = (/** @type {any} */ v) => (v ? String(v).slice(0, 10) : '');
    await sendWorkbook(
      res,
      'accounts',
      'Accounts',
      [
        { header: 'Account no', key: 'accountNo', width: 14 },
        { header: 'Name', key: 'name', width: 36 },
        { header: 'Type', key: 'accountType', width: 12 },
        {
          header: 'Strategic',
          key: 'isStrategic',
          width: 10,
          format: (v) => (Number(v) ? 'Yes' : 'No'),
        },
        { header: 'Industry', key: 'industryName', width: 20 },
        { header: 'City', key: 'city', width: 16 },
        { header: 'State', key: 'state', width: 16 },
        { header: 'Owner', key: 'ownerName', width: 22 },
        { header: 'Open deals', key: 'openDeals', width: 11, format: Number },
        { header: 'Open pipeline (INR)', key: 'openPipeline', width: 18, format: Number },
        { header: 'Won deals', key: 'wonDeals', width: 11, format: Number },
        { header: 'Won value (INR)', key: 'wonValue', width: 18, format: Number },
        { header: 'Last won', key: 'lastWonOn', width: 12, format: date },
        { header: 'New logo on', key: 'firstWonOn', width: 12, format: date },
        { header: 'Contacts', key: 'contacts', width: 10, format: Number },
      ],
      rows,
    );
  },
};
