// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');

const STATUSES = [
  'PO_RECEIVED',
  'PO_TO_MFR',
  'GOODS_DELIVERED',
  'DEPLOYED',
  'INVOICED',
  'PAID',
  'CLOSED',
];

const eventBody = z.strictObject({
  status: z.enum(STATUSES),
  eventDate: z.iso.date(),
  remark: z
    .string()
    .trim()
    .max(1000)
    .nullish()
    .transform((v) => v ?? null),
  documentId: schemas.id.nullish().transform((v) => v ?? null),
});

const invoiceBody = z.strictObject({
  invoiceNo: z.string().trim().min(1).max(60),
  invoiceDate: z.iso.date(),
  dueDate: z.iso.date(),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/, 'Must be a positive decimal string'),
  documentId: schemas.id.nullish().transform((v) => v ?? null),
});

const invoiceParams = z.strictObject({ id: schemas.id, invoiceId: schemas.id });

const paymentBody = z.strictObject({
  direction: z.enum(['RECEIVED', 'RELEASED']),
  invoiceId: schemas.id.nullish().transform((v) => v ?? null),
  partnerId: schemas.id.nullish().transform((v) => v ?? null),
  amount: z.string().regex(/^\d+(\.\d{1,2})?$/, 'Must be a positive decimal string'),
  paidOn: z.iso.date(),
  reference: z
    .string()
    .trim()
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  remarks: z
    .string()
    .trim()
    .max(1000)
    .nullish()
    .transform((v) => v ?? null),
});

const financeBody = z.strictObject({
  revenue: z
    .string()
    .regex(/^\d+(\.\d{1,2})?$/)
    .nullish()
    .transform((v) => v ?? null),
  gmPct: z
    .number()
    .min(-100)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  npPct: z
    .number()
    .min(-100)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  recognisedOn: z.iso
    .date()
    .nullish()
    .transform((v) => v ?? null),
});

module.exports = {
  STATUSES,
  list: {
    query: listQuery(['poDate', 'poValue', 'outstanding'], '-poDate').extend({
      status: z.enum(STATUSES).optional(),
    }),
  },
  byId: { params: schemas.idParam },
  event: { params: schemas.idParam, body: eventBody },
  invoiceCreate: { params: schemas.idParam, body: invoiceBody },
  invoiceUpdate: { params: invoiceParams, body: invoiceBody },
  paymentCreate: { params: schemas.idParam, body: paymentBody },
  finance: { params: schemas.idParam, body: financeBody },
};
