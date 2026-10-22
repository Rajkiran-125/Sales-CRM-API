// @ts-check
'use strict';

/** Orders (12.9): HTTP only. */
const service = require('./orders.service');
const { sendData, sendList } = require('../../shared/response');
const { logView, logExport } = require('../../shared/readModel');
const { sendWorkbook } = require('../../integrations/excel');
const { requestMeta } = require('../../shared/requestMeta');

/** @typedef {import('express').Request & { valid: any, user: any }} Req */

const allowAny = (/** @type {Req} */ r) => r.user.dataScope.widest === 'ALL';

module.exports = {
  /** @type {import('../../shared/types').Handler} */
  async exportList(req, res) {
    const r = /** @type {Req} */ (req);
    const q = r.valid.query;
    const rows = await service.exportRows(r.user.id, q);
    await logExport(req, 'ORDER', q);
    const date = (/** @type {any} */ v) =>
      v ? String(v instanceof Date ? v.toISOString() : v).slice(0, 10) : '';
    await sendWorkbook(
      res,
      'orders',
      'Orders',
      [
        { header: 'Order no', key: 'orderNo', width: 16 },
        { header: 'Deal no', key: 'opportunityNo', width: 16 },
        { header: 'Title', key: 'title', width: 32 },
        { header: 'Account', key: 'accountName', width: 28 },
        { header: 'Partner', key: 'partnerName', width: 22 },
        { header: 'PO number', key: 'poNumber', width: 16 },
        { header: 'PO date', key: 'poDate', width: 12, format: date },
        { header: 'PO value (INR)', key: 'poValue', width: 16, format: Number },
        { header: 'Status', key: 'statusName', width: 18 },
        { header: 'Invoiced (INR)', key: 'invoicedValue', width: 16, format: Number },
        { header: 'Received (INR)', key: 'receivedValue', width: 16, format: Number },
        { header: 'Outstanding (INR)', key: 'outstanding', width: 16, format: Number },
        {
          header: 'Released to partner (INR)',
          key: 'releasedToPartner',
          width: 18,
          format: Number,
        },
        { header: 'Order to book (days)', key: 'orderToBookDays', width: 14 },
        { header: 'Revenue (INR)', key: 'revenue', width: 16, format: Number },
        { header: 'GM %', key: 'gmPct', width: 8 },
        { header: 'Overdue invoices', key: 'overdueInvoices', width: 12 },
        { header: 'Owner', key: 'ownerName', width: 22 },
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
  async get(req, res) {
    const r = /** @type {Req} */ (req);
    const id = r.valid.params.id;
    const data = await service.get(
      r.user.id,
      id,
      r.user.permissions.has('partner_commercial.view'),
    );
    await logView(req, 'ORDER', id);
    sendData(req, res, data);
  },

  /** @type {import('../../shared/types').Handler} */
  async addEvent(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.addEvent(r.valid.params.id, r.valid.body, requestMeta(req), allowAny(r)),
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async createInvoice(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.createInvoice(r.valid.params.id, r.valid.body, requestMeta(req)),
      201,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async updateInvoice(req, res) {
    const r = /** @type {Req} */ (req);
    const { id, invoiceId } = r.valid.params;
    sendData(req, res, await service.updateInvoice(id, invoiceId, r.valid.body, requestMeta(req)));
  },

  /** @type {import('../../shared/types').Handler} */
  async createPayment(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.createPayment(r.valid.params.id, r.valid.body, requestMeta(req)),
      201,
    );
  },

  /** @type {import('../../shared/types').Handler} */
  async updateFinance(req, res) {
    const r = /** @type {Req} */ (req);
    sendData(
      req,
      res,
      await service.updateFinance(r.valid.params.id, r.valid.body, requestMeta(req)),
    );
  },
};
