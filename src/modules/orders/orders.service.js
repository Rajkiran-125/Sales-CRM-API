// @ts-check
'use strict';

/**
 * Orders (12.9, UM 6.6): list, workspace (read), and the write side — events, invoices,
 * payments and finance fields (V019).
 *
 * The price to partner and its margin need partner_commercial.view, as on the deal workspace;
 * revenue / GM / NP show to everyone who can see the order until OD-31 decides otherwise.
 */
const repo = require('./orders.repository');
const { shape, shapeAll } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');

const EXPORT_LIMIT = 10000;

module.exports = {
  /**
   * The filtered list for Excel (8.11, 19.1 "every list screen also offers an Excel export").
   * shortcut: capped at EXPORT_LIMIT rows, move to an async job (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.list(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return rows;
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total, statusCounts, figures } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: shapeAll(rows, { numbers: ['gmPct'] }),
      meta: {
        page: q.page,
        pageSize: q.pageSize,
        total,
        sort: q.sort,
        statusCounts,
        totals: shape(figures, { numbers: ['avgOrderToBookDays'] }),
      },
    };
  },

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  addEvent: (id, body, meta, allowAny) => repo.addEvent(id, body, meta, allowAny),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  createInvoice: (id, body, meta) => repo.createInvoice(id, body, meta),

  /**
   * @param {number} orderId
   * @param {number} invoiceId
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  updateInvoice: (orderId, invoiceId, body, meta) =>
    repo.updateInvoice(orderId, invoiceId, body, meta),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  createPayment: (id, body, meta) => repo.createPayment(id, body, meta),

  /**
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  updateFinance: (id, body, meta) => repo.updateFinance(id, body, meta),

  /**
   * @param {number} userId
   * @param {number} id
   * @param {boolean} canSeeCommercial  partner_commercial.view
   */
  async get(userId, id, canSeeCommercial) {
    const [[order], track, events, invoices, payments, [release], activities] = await repo.get(
      userId,
      id,
    );
    let partnerRelease = release
      ? shape(release, { bools: ['payAfterCustomer', 'withinRule'], numbers: ['partnerMarginPct'] })
      : null;
    if (partnerRelease && !canSeeCommercial)
      partnerRelease = {
        ...partnerRelease,
        partnerPrice: null,
        partnerMarginPct: null,
        partnerPaymentTerms: null,
      };
    return {
      order: shape(order, { bools: ['payPartnerAfterCustomer'], numbers: ['gmPct', 'npPct'] }),
      track,
      events,
      invoices,
      payments,
      partnerRelease,
      activities,
    };
  },
};
