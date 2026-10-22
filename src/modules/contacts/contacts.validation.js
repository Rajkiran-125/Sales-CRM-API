// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const STAND = /** @type {[string, ...string[]]} */ (['CHAMPION', 'NEUTRAL', 'BLOCKER', 'UNKNOWN']);

const SPOC_TYPES = /** @type {[string, ...string[]]} */ ([
  'TOP_MGMT',
  'DMU',
  'TECH',
  'FINANCE',
  'LEGAL',
  'COMMERCIAL',
]);

const contactBody = z
  .strictObject({
    accountId: schemas.id.nullish().transform((v) => v ?? null),
    partnerId: schemas.id.nullish().transform((v) => v ?? null),
    name: z.string().trim().min(1, 'Required.').max(150),
    designation: z
      .string()
      .trim()
      .max(100)
      .nullish()
      .transform((v) => v ?? null),
    department: z
      .string()
      .trim()
      .max(100)
      .nullish()
      .transform((v) => v ?? null),
    email: z
      .string()
      .trim()
      .email()
      .max(150)
      .nullish()
      .transform((v) => v ?? null),
    phone: z
      .string()
      .trim()
      .max(20)
      .nullish()
      .transform((v) => v ?? null),
    seniority: z
      .string()
      .trim()
      .max(40)
      .nullish()
      .transform((v) => v ?? null),
    influenceLevel: z
      .number()
      .int()
      .min(1)
      .max(5)
      .nullish()
      .transform((v) => v ?? null),
    stand: z.enum(STAND).default('UNKNOWN'),
    intelNotes: z
      .string()
      .trim()
      .max(4000)
      .nullish()
      .transform((v) => v ?? null),
    spocType: z
      .enum(SPOC_TYPES)
      .nullish()
      .transform((v) => v ?? null),
  })
  .superRefine((d, ctx) => {
    const hasAccount = d.accountId !== null && d.accountId !== undefined;
    const hasPartner = d.partnerId !== null && d.partnerId !== undefined;
    if (hasAccount === hasPartner) {
      ctx.addIssue({
        code: 'custom',
        path: ['accountId'],
        message: 'Exactly one of accountId or partnerId is required.',
      });
    }
  });

const updateBody = z.strictObject({
  name: z.string().trim().min(1, 'Required.').max(150),
  designation: z
    .string()
    .trim()
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  department: z
    .string()
    .trim()
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  email: z
    .string()
    .trim()
    .email()
    .max(150)
    .nullish()
    .transform((v) => v ?? null),
  phone: z
    .string()
    .trim()
    .max(20)
    .nullish()
    .transform((v) => v ?? null),
  seniority: z
    .string()
    .trim()
    .max(40)
    .nullish()
    .transform((v) => v ?? null),
  influenceLevel: z
    .number()
    .int()
    .min(1)
    .max(5)
    .nullish()
    .transform((v) => v ?? null),
  stand: z.enum(STAND),
  intelNotes: z
    .string()
    .trim()
    .max(4000)
    .nullish()
    .transform((v) => v ?? null),
  spocType: z
    .enum(SPOC_TYPES)
    .nullish()
    .transform((v) => v ?? null),
});

module.exports = {
  create: { body: contactBody },
  update: { params: schemas.idParam, body: updateBody },
  deactivate: { params: schemas.idParam },
};
