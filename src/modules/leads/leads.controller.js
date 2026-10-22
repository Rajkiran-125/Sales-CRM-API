// @ts-check
'use strict';

/** Leads (12.4): HTTP only. */
const service = require('./leads.service');
const { sendData, sendList } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');
const { logView, logExport } = require('../../shared/readModel');
const { sendWorkbook } = require('../../integrations/excel');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async exportList(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'LEAD', q);
    const date = (/** @type {any} */ v) =>
      v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';
    await sendWorkbook(
      res,
      'leads',
      'Leads',
      [
        { header: 'Lead no', key: 'leadNo', width: 14 },
        { header: 'Account', key: 'accountName', width: 30 },
        { header: 'Contact', key: 'contactName', width: 22 },
        { header: 'Industry', key: 'industryName', width: 16 },
        { header: 'Stage', key: 'stageName', width: 16 },
        { header: 'Qualification %', key: 'qualificationPct', width: 14 },
        { header: 'Projected value (INR)', key: 'roughValue', width: 16, format: Number },
        { header: 'Projected timing', key: 'roughTiming', width: 14 },
        { header: 'Owner', key: 'ownerName', width: 22 },
        { header: 'Partner', key: 'partnerName', width: 22 },
        { header: 'Next action', key: 'nextAction', width: 30 },
        { header: 'Next action due', key: 'nextActionDueOn', width: 14, format: date },
        { header: 'Deal', key: 'opportunityNo', width: 14 },
        { header: 'Created', key: 'createdAt', width: 12, format: date },
      ],
      rows,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.list(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },

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
  async disqualify(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.disqualify(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async dmuAdd(req, res) {
    const r = /** @type {Req} */ (req);
    const data = await service.dmuSave(r.valid.params.id, null, r.valid.body, requestMeta(req));
    sendData(req, res, data, 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async dmuUpdate(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, dmuId } = r.valid.params;
    sendData(req, res, await service.dmuSave(id, dmuId, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async dmuRemove(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, dmuId } = r.valid.params;
    sendData(req, res, await service.dmuRemove(id, dmuId, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async convert(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.convert(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    const data = await service.get(r.user.id, r.valid.params.id);
    await logView(req, 'LEAD', r.valid.params.id);
    sendData(req, res, data);
  },
};
