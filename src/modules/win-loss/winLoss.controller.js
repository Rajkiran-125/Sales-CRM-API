// @ts-check
'use strict';

/** Win / loss analysis (12.12): HTTP only. */
const service = require('./winLoss.service');
const { sendData, sendList } = require('../../shared/response');
const { logExport } = require('../../shared/readModel');
const { sendWorkbook } = require('../../integrations/excel');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async summary(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(req, res, await service.summary(r.user.id, r.valid.query));
  },

  /** @type {import('../../shared/types').Handler} */
  async exportDeals(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'WIN_LOSS', q);
    const date = (/** @type {any} */ v) =>
      v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';
    await sendWorkbook(
      res,
      'win-loss',
      'Closed deals',
      [
        { header: 'Deal no', key: 'opportunityNo', width: 16 },
        { header: 'Title', key: 'title', width: 36 },
        { header: 'Account', key: 'accountName', width: 28 },
        { header: 'Owner', key: 'ownerName', width: 22 },
        { header: 'Outcome', key: 'stageCode', width: 10 },
        { header: 'Value (INR)', key: 'value', width: 16, format: Number },
        { header: 'Closed on', key: 'closedOn', width: 12, format: date },
        { header: 'Loss reason', key: 'lossReason', width: 22 },
        { header: 'Competitor', key: 'competitor', width: 22 },
        { header: 'Win reasons', key: 'winReasons', width: 28 },
        { header: 'Products', key: 'products', width: 28 },
        { header: 'Partner', key: 'partnerName', width: 24 },
        { header: 'Detail', key: 'detail', width: 40 },
      ],
      rows,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async deals(req, res) {
    const r = /** @type {Req} */ (req);
    const { rows, meta } = await service.deals(r.user.id, r.valid.query);
    sendList(req, res, rows, meta);
  },
};
