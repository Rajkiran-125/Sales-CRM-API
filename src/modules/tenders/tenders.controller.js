// @ts-check
'use strict';

/** Tenders (12.8): HTTP only. */
const service = require('./tenders.service');
const { sendData, sendList } = require('../../shared/response');
const { logView, logExport } = require('../../shared/readModel');
const { requestMeta } = require('../../shared/requestMeta');
const { sendWorkbook } = require('../../integrations/excel');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

const allowAny = (/** @type {Req} */ r) => r.user.dataScope.widest === 'ALL';
const date = (/** @type {any} */ v) =>
  v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async list(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.list(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },

  /** @type {import('../../shared/types').Handler} */
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    const data = await service.get(r.user.id, id);
    await logView(req, 'TENDER', id);
    sendData(req, res, data);
  },

  /** @type {import('../../shared/types').Handler} */
  async editGet(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.editGet(r.user.id, r.valid.params.id));
  },

  /** @type {import('../../shared/types').Handler} */
  async create(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.save(null, r.valid.body, requestMeta(req), allowAny(r)), 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async update(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    sendData(req, res, await service.save(id, r.valid.body, requestMeta(req), allowAny(r)));
  },

  /** @type {import('../../shared/types').Handler} */
  async transition(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    sendData(req, res, await service.transition(id, r.valid.body, requestMeta(req), allowAny(r)));
  },

  /** @type {import('../../shared/types').Handler} */
  async checklistSave(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, itemId } = r.valid.params;
    const data = await service.checklistSave(
      id,
      itemId ?? null,
      r.valid.body,
      requestMeta(req),
      allowAny(r),
    );
    sendData(req, res, data, itemId ? 200 : 201);
  },

  /** @type {import('../../shared/types').Handler} */
  async checklistDelete(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, itemId } = r.valid.params;
    await service.checklistDelete(id, itemId, requestMeta(req), allowAny(r));
    res.status(204).end();
  },

  /** @type {import('../../shared/types').Handler} */
  async exportList(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'TENDER', q);
    await sendWorkbook(
      res,
      'tenders',
      'Tenders',
      [
        { header: 'Tender no', key: 'tenderNo', width: 14 },
        { header: 'Reference', key: 'referenceNo', width: 20 },
        { header: 'Authority', key: 'authority', width: 28 },
        { header: 'Title', key: 'title', width: 36 },
        { header: 'Account', key: 'accountName', width: 26 },
        { header: 'Product', key: 'productName', width: 20 },
        { header: 'Estimated value (INR)', key: 'estimatedValue', width: 18, format: Number },
        { header: 'Status', key: 'statusName', width: 18 },
        { header: 'Our role', key: 'ourRole', width: 12 },
        { header: 'Bidder partner', key: 'bidderPartnerName', width: 24 },
        { header: 'Pre-bid', key: 'preBidOn', width: 12, format: date },
        { header: 'Submission', key: 'submissionOn', width: 12, format: date },
        { header: 'Opening', key: 'openingOn', width: 12, format: date },
        { header: 'Readiness %', key: 'readinessPct', width: 12, format: Number },
        { header: 'Deal', key: 'opportunityNo', width: 14 },
        { header: 'Owner', key: 'ownerName', width: 22 },
      ],
      rows,
    );
  },
};
