// @ts-check
'use strict';

/** Opportunities (12.5): HTTP only. */
const service = require('./opportunities.service');
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
    await logExport(req, 'OPPORTUNITY', q);
    const date = (/** @type {any} */ v) =>
      v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';
    await sendWorkbook(
      res,
      'opportunities',
      'Opportunities',
      [
        { header: 'Deal no', key: 'opportunityNo', width: 16 },
        { header: 'Title', key: 'title', width: 36 },
        { header: 'Account', key: 'accountName', width: 28 },
        { header: 'Stage', key: 'stageName', width: 18 },
        { header: 'Confidence %', key: 'confidencePct', width: 12 },
        { header: 'Value (INR)', key: 'value', width: 16, format: Number },
        { header: 'Weighted (INR)', key: 'weighted', width: 16, format: Number },
        { header: 'Expected close', key: 'expectedCloseDate', width: 14, format: date },
        { header: 'Owner', key: 'ownerName', width: 22 },
        { header: 'Pre-sales', key: 'presalesName', width: 22 },
        { header: 'Partner', key: 'partnerName', width: 22 },
        { header: 'Products', key: 'products', width: 28 },
        { header: 'Validation', key: 'validationStatus', width: 12 },
        { header: 'Last status', key: 'lastStatus', width: 12 },
        { header: 'Last activity', key: 'lastActivityAt', width: 14, format: date },
        { header: 'Closed on', key: 'closedAt', width: 12, format: date },
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
  async kanban(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.kanban(r.user.id, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    const canSeeCommercial = r.user.permissions.has('partner_commercial.view');
    const data = await service.get(r.user.id, r.valid.params.id, canSeeCommercial);
    await logView(req, 'OPP', r.valid.params.id);
    sendData(req, res, data);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    const sentKeys = Object.keys(req.body ?? {});
    sendData(
      req,
      res,
      await service.update(r.valid.params.id, r.valid.body, requestMeta(req), sentKeys),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async moveStage(req, res) {
    const r = /** @type {Req} */ (req);
    const canOverride = r.user.permissions.has('opportunity.stage_override');
    sendData(
      req,
      res,
      await service.moveStage(r.valid.params.id, r.valid.body, requestMeta(req), canOverride),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async gate(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.gate(r.user.id, r.valid.params.id));
  },

  /** @type {import('../../shared/types').Handler} */
  async pocGet(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.pocGet(r.user.id, r.valid.params.id));
  },

  /** @type {import('../../shared/types').Handler} */
  async poc(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.pocSave(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async validate(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.validate(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async close(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.close(r.valid.params.id, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async dmuUpsert(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(
      req,
      res,
      await service.dmuUpsert(r.valid.params.id, r.valid.body, requestMeta(req), allowAny),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async dmuRemove(req, res) {
    const r = /** @type {Req} */ (req);
    const allowAny = r.user.dataScope.widest === 'ALL';
    sendData(
      req,
      res,
      await service.dmuRemove(r.valid.params.id, r.valid.params.dmuId, requestMeta(req), allowAny),
    );
  },
};
