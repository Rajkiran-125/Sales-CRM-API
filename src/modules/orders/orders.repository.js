// @ts-check
'use strict';

/** Orders read (V010) and write (V019) procedures. */
const { callProcedure, callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals, statusCounts, [figures]] = await callProcedure('sp_order_list', [
      userId,
      q.search ?? null,
      q.status ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return {
      rows: rows ?? [],
      total: Number(totals?.[0]?.total ?? 0),
      statusCounts: statusCounts ?? [],
      figures,
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  get: (userId, id) => callProcedure('sp_order_get', [userId, id]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  addEvent: (id, b, meta, allowAny) =>
    callProcedureOne('sp_order_event', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.status,
      b.eventDate,
      b.remark,
      b.documentId,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  createInvoice: (id, b, meta) =>
    callProcedureOne('sp_invoice_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.invoiceNo,
      b.invoiceDate,
      b.dueDate,
      b.amount,
      b.documentId,
    ]),

  /**
   * @param {number} orderId
   * @param {number} invoiceId
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  updateInvoice: (orderId, invoiceId, b, meta) =>
    callProcedureOne('sp_invoice_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      invoiceId,
      b.invoiceNo,
      b.invoiceDate,
      b.dueDate,
      b.amount,
      b.documentId,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  createPayment: (id, b, meta) =>
    callProcedureOne('sp_payment_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.direction,
      b.invoiceId,
      b.partnerId,
      b.amount,
      b.paidOn,
      b.reference,
      b.remarks,
    ]),

  /**
   * @param {number} id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  updateFinance: (id, b, meta) =>
    callProcedureOne('sp_order_finance', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.revenue,
      b.gmPct,
      b.npPct,
      b.recognisedOn,
    ]),
};
