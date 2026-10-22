// @ts-check
'use strict';

/** /api/v1/orders (12.9, 14.8): read side + write side (events, invoices, payments, finance). */
const c = require('./orders.controller');
const v = require('./orders.validation');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['order.view'],
    summary: 'Orders with invoiced / received / outstanding; counts per status and totals in meta',
    schema: v.list,
    handler: c.list,
  },
  {
    method: 'get',
    path: '/export',
    access: ['order.view'],
    summary: 'Export the filtered list (xlsx); logged',
    schema: v.list,
    handler: c.exportList,
    produces: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  },
  {
    method: 'get',
    path: '/:id',
    access: ['order.view'],
    summary: 'Order workspace: PO-to-payment track, invoices, payments, partner release rule',
    schema: v.byId,
    handler: c.get,
  },
  {
    method: 'post',
    path: '/:id/events',
    access: ['order.update'],
    summary: 'Record an order status event and advance the order status (BR-OR-02)',
    schema: v.event,
    handler: c.addEvent,
  },
  {
    method: 'post',
    path: '/:id/invoices',
    access: ['order.finance'],
    summary: 'Raise an invoice; first invoice sets order-to-book days (BR-OR-03)',
    schema: v.invoiceCreate,
    handler: c.createInvoice,
  },
  {
    method: 'patch',
    path: '/:id/invoices/:invoiceId',
    access: ['order.finance'],
    summary: 'Edit an existing invoice',
    schema: v.invoiceUpdate,
    handler: c.updateInvoice,
  },
  {
    method: 'post',
    path: '/:id/payments',
    access: ['order.finance'],
    summary: 'Record a received or released payment (BR-OR-04, BR-OR-05)',
    schema: v.paymentCreate,
    handler: c.createPayment,
  },
  {
    method: 'patch',
    path: '/:id/finance',
    access: ['order.finance'],
    summary: 'Update revenue, GM % and NP % — finance only (BR-OR-06)',
    schema: v.finance,
    handler: c.updateFinance,
  },
];
