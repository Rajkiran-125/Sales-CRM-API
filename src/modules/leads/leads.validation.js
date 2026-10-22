// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');
const { SOURCES } = require('../dashboard/dashboard.validation');

const STAGES = ['NEW', 'CONTACTED', 'QUALIFYING', 'CONVERTED', 'DISQUALIFIED'];

const BUDGET_KNOWN = ['YES', 'NO', 'TBD'];

const dmuBody = z.strictObject({
  name: schemas.name,
  designation: schemas.optionalText(100),
  dmuRole: z.enum(['TECH_BUYER', 'COMM_BUYER', 'INFLUENCER_INT', 'INFLUENCER_EXT']),
  influenceLevel: z
    .number()
    .int()
    .min(1)
    .max(5)
    .nullish()
    .transform((v) => v ?? null),
  stand: z.enum(['CHAMPION', 'NEUTRAL', 'BLOCKER', 'UNKNOWN']).default('UNKNOWN'),
  notes: schemas.optionalText(1000),
});

const dmuIdParams = z.strictObject({
  id: z.coerce.number().int().positive(),
  dmuId: z.coerce.number().int().positive(),
});

const qualificationFields = {
  problemStatement: z
    .string()
    .trim()
    .min(1)
    .max(4000)
    .nullish()
    .transform((v) => v ?? null),
  productId: schemas.id.nullish().transform((v) => v ?? null),
  solutionId: schemas.id.nullish().transform((v) => v ?? null),
  commercialWindowValue: z
    .number()
    .positive()
    .max(99999999999999)
    .nullish()
    .transform((v) => v ?? null),
  budgetKnown: z
    .enum(['YES', 'NO', 'TBD'])
    .nullish()
    .transform((v) => v ?? null),
  budgetMin: z
    .number()
    .positive()
    .max(99999999999999)
    .nullish()
    .transform((v) => v ?? null),
  budgetMax: z
    .number()
    .positive()
    .max(99999999999999)
    .nullish()
    .transform((v) => v ?? null),
  procurementTypeId: schemas.id.nullish().transform((v) => v ?? null),
  procurementStepsKnown: z.boolean().optional().default(false),
  expectedCloseDate: z.iso
    .date()
    .nullish()
    .transform((v) => v ?? null),
};

module.exports = {
  STAGES,
  BUDGET_KNOWN,
  list: {
    query: listQuery(
      ['createdAt', 'nextActionDueOn', 'roughValue', 'accountName'],
      '-createdAt',
    ).extend({
      stage: z.enum(STAGES).optional(),
      source: z.enum(SOURCES).optional(),
      ownerUserId: schemas.id.optional(),
    }),
  },
  byId: { params: schemas.idParam },
  create: {
    body: z.strictObject({
      source: z.enum(SOURCES),
      partnerId: schemas.id.nullish().transform((v) => v ?? null),
      partnerContact: schemas.optionalText(200),
      accountId: schemas.id.nullish().transform((v) => v ?? null),
      accountNameText: schemas.optionalText(200),
      industryId: schemas.id,
      contactName: schemas.name,
      contactDesignation: schemas.optionalText(100),
      contactEmail: schemas.email.nullish().or(z.literal('').transform(() => null)),
      contactPhone: schemas.phone.nullish().or(z.literal('').transform(() => null)),
      city: z.string().trim().min(1, 'Required.').max(100),
      locationsCount: z
        .number()
        .int()
        .min(1)
        .max(100000)
        .nullish()
        .transform((v) => v ?? null),
      needText: z.string().trim().min(1, 'Required.').max(4000),
      roughValue: z
        .number()
        .positive('Enter an amount above zero.')
        .max(99999999999999)
        .nullish()
        .transform((v) => v ?? null),
      roughTiming: schemas.optionalText(40),
      ownerUserId: schemas.id.nullish().transform((v) => v ?? null),
      backupOwnerUserId: schemas.id.nullish().transform((v) => v ?? null),
      nextAction: z.string().trim().min(1, 'Required.').max(500),
      nextActionDueOn: z.iso.date({ message: 'Enter a valid date.' }),
      productIds: z.array(schemas.id).max(30).default([]),
    }),
  },
  update: {
    params: schemas.idParam,
    body: z
      .strictObject({
        rowVersion: z.number().int().min(0),
        source: z.enum(SOURCES),
        partnerId: schemas.id.nullish().transform((v) => v ?? null),
        partnerContact: schemas.optionalText(200),
        accountId: schemas.id.nullish().transform((v) => v ?? null),
        accountNameText: schemas.optionalText(200),
        industryId: schemas.id,
        contactName: schemas.name,
        contactDesignation: schemas.optionalText(100),
        contactEmail: schemas.email.nullish().or(z.literal('').transform(() => null)),
        contactPhone: schemas.phone.nullish().or(z.literal('').transform(() => null)),
        city: z.string().trim().min(1, 'Required.').max(100),
        locationsCount: z
          .number()
          .int()
          .min(1)
          .max(100000)
          .nullish()
          .transform((v) => v ?? null),
        needText: z.string().trim().min(1, 'Required.').max(4000),
        roughValue: z
          .number()
          .positive('Enter an amount above zero.')
          .max(99999999999999)
          .nullish()
          .transform((v) => v ?? null),
        roughTiming: schemas.optionalText(40),
        ownerUserId: schemas.id.nullish().transform((v) => v ?? null),
        backupOwnerUserId: schemas.id.nullish().transform((v) => v ?? null),
        nextAction: z.string().trim().min(1, 'Required.').max(500),
        nextActionDueOn: z.iso.date({ message: 'Enter a valid date.' }),
        productIds: z.array(schemas.id).max(30).default([]),
        ...qualificationFields,
      })
      .refine((d) => !(d.budgetKnown === 'YES' && d.budgetMin === null && d.budgetMax === null), {
        message: 'Enter the budget range when budget is known.',
        path: ['budgetMin'],
      }),
  },
  disqualify: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: z.number().int().min(0),
      reasonId: schemas.id,
      note: schemas.optionalText(1000),
    }),
  },
  dmuAdd: { params: schemas.idParam, body: dmuBody },
  dmuUpdate: { params: dmuIdParams, body: dmuBody },
  dmuRemove: { params: dmuIdParams },
  convert: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: z.number().int().min(0),
      title: z.string().trim().min(1, 'Required.').max(250),
    }),
  },
};
