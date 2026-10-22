// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const ROLES = /** @type {[string, ...string[]]} */ ([
  'SOURCED',
  'INFLUENCED',
  'FULFILMENT',
  'SERVICE',
]);

const rowParams = z.strictObject({
  id: z.coerce.number().int().positive(),
  rowId: z.coerce.number().int().positive(),
});

const nullableId = schemas.id.nullish().transform((v) => v ?? null);

const partnerFields = {
  partnerRole: z.enum(ROLES),
  partnerContactId: nullableId,
  engagementLevel: z
    .enum(['HIGH', 'MEDIUM', 'LOW'])
    .nullish()
    .transform((v) => v ?? null),
  isPrimary: z.boolean().default(false),
  commercialConfirmed: z.boolean().default(false),
  notes: schemas.optionalText(1000),
};

const competitorFields = {
  theirPrice: z
    .number()
    .min(0)
    .max(99999999999999)
    .nullish()
    .transform((v) => v ?? null),
  theirStrength: schemas.optionalText(1000),
  ourDifferentiator: schemas.optionalText(1000),
};

module.exports = {
  partnerAdd: {
    params: schemas.idParam,
    body: z.strictObject({ partnerId: schemas.id, ...partnerFields }),
  },
  partnerUpdate: { params: rowParams, body: z.strictObject(partnerFields) },
  competitorAdd: {
    params: schemas.idParam,
    body: z.strictObject({ competitorId: schemas.id, ...competitorFields }),
  },
  competitorUpdate: { params: rowParams, body: z.strictObject(competitorFields) },
  rowRemove: { params: rowParams },
  commercialCreate: {
    params: schemas.idParam,
    body: z.strictObject({
      partnerId: schemas.id,
      partnerRole: z.enum(ROLES),
      dealSizeBasis: z.string().trim().min(1, 'Required.').max(250),
      priceToPartner: z.number().positive().max(99999999999999),
      partnerMarginPct: z
        .number()
        .min(0)
        .max(100)
        .nullish()
        .transform((v) => v ?? null),
      paymentTerms: z.string().trim().min(1, 'Required.').max(250),
      payPartnerAfterCustomer: z.boolean().default(true),
      validTill: z.iso
        .date()
        .nullish()
        .transform((v) => v ?? null),
      bundleTag: schemas.optionalText(60),
      remarks: schemas.optionalText(1000),
    }),
  },
};
