// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const createBody = z.strictObject({
  opportunityId: schemas.id,
  offerValue: z.string().regex(/^\d+(\.\d{1,2})?$/, 'Must be a positive decimal string'),
  listValue: z
    .string()
    .regex(/^\d+(\.\d{1,2})?$/)
    .nullish()
    .transform((v) => v ?? null),
  discountPct: z
    .number()
    .min(0)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  valueAdds: z
    .string()
    .trim()
    .max(2000)
    .nullish()
    .transform((v) => v ?? null),
  paymentTerms: z
    .string()
    .trim()
    .max(500)
    .nullish()
    .transform((v) => v ?? null),
  validTill: z.iso.date(),
});

const submitBody = z.strictObject({});

const approveBody = z.strictObject({
  approved: z.boolean(),
  approvalRemark: z
    .string()
    .trim()
    .max(1000)
    .nullish()
    .transform((v) => v ?? null),
});

const sendBody = z.strictObject({
  sentTo: z
    .string()
    .trim()
    .max(500)
    .nullish()
    .transform((v) => v ?? null),
});

const respondBody = z.strictObject({
  accepted: z.boolean(),
  customerResponse: z
    .string()
    .trim()
    .max(2000)
    .nullish()
    .transform((v) => v ?? null),
});

const reviseBody = z.strictObject({});

module.exports = {
  create: { body: createBody },
  /** every figure is sent: the form edits the whole draft */
  update: { params: schemas.idParam, body: createBody.omit({ opportunityId: true }) },
  submit: { params: schemas.idParam, body: submitBody },
  approve: { params: schemas.idParam, body: approveBody },
  send: { params: schemas.idParam, body: sendBody },
  respond: { params: schemas.idParam, body: respondBody },
  revise: { params: schemas.idParam, body: reviseBody },
};
