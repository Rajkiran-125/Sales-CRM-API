// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');
const { SOURCES } = require('../dashboard/dashboard.validation');

const STAGES = [
  'QUALIFIED',
  'TECH_ENGAGEMENT',
  'POC',
  'PROPOSAL',
  'NEGOTIATION',
  'COMMERCIAL_CLOSED',
  'CONTRACT_SIGNED',
  'WON',
  'LOST',
  'DORMANT',
];

const OPEN_STAGES = [
  'QUALIFIED',
  'TECH_ENGAGEMENT',
  'POC',
  'PROPOSAL',
  'NEGOTIATION',
  'COMMERCIAL_CLOSED',
  'CONTRACT_SIGNED',
];

const filters = {
  source: z.enum(SOURCES).optional(),
  ownerUserId: schemas.id.optional(),
  partnerId: schemas.id.optional(),
};

/** Decimal money value: positive, max 14 digits, null-safe. */
const money = z
  .number()
  .positive()
  .max(99999999999999)
  .nullish()
  .transform((v) => v ?? null);

/** Core update fields shared between create-side (future) and update. */
const updateBody = z.strictObject({
  rowVersion: z.number().int().min(0),
  title: z.string().trim().min(1, 'Required.').max(250),
  solutionId: schemas.id.nullish().transform((v) => v ?? null),
  problemStatement: schemas.optionalText(4000),
  technicalRequirement: schemas.optionalText(4000),
  locationsCount: z
    .number()
    .int()
    .min(1)
    .max(100000)
    .nullish()
    .transform((v) => v ?? null),
  expectedValue: money,
  currency: z
    .string()
    .trim()
    .length(3)
    .nullish()
    .transform((v) => v ?? null),
  fxRate: z
    .number()
    .positive()
    .max(999999)
    .nullish()
    .transform((v) => v ?? null),
  expectedCloseDate: z.iso
    .date()
    .nullish()
    .transform((v) => v ?? null),
  commercialWindowValue: money,
  commercialWindowAccepted: z
    .boolean()
    .nullish()
    .transform((v) => v ?? null),
  budgetKnown: z
    .enum(['YES', 'NO', 'UNKNOWN'])
    .nullish()
    .transform((v) => v ?? null),
  budgetMin: money,
  budgetMax: money,
  procurementTypeId: schemas.id.nullish().transform((v) => v ?? null),
  procurementStepsKnown: z.boolean().optional().default(false),
  currentProcurementStepId: schemas.id.nullish().transform((v) => v ?? null),
  ownerUserId: schemas.id.nullish().transform((v) => v ?? null),
  backupOwnerUserId: schemas.id.nullish().transform((v) => v ?? null),
  presalesOwnerUserId: schemas.id.nullish().transform((v) => v ?? null),
  sponsorUserId: schemas.id.nullish().transform((v) => v ?? null),
  confidenceOverridePct: z
    .number()
    .min(0)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
  confidenceOverrideReason: schemas.optionalText(500),
  partnerTbm: z.boolean().optional().default(false),
  noCompetition: z.boolean().optional().default(false),
  paymentTerms: schemas.optionalText(500),
  bundleTag: schemas.optionalText(60),
  // null = keep existing products; [] = remove all; [{productId, isPrimary}] = replace
  productIds: z
    .array(
      z.object({
        productId: schemas.id,
        isPrimary: z.boolean().optional().default(false),
      }),
    )
    .max(30)
    .nullish()
    .transform((v) => v ?? null),
});

const DMU_ROLES = /** @type {[string, ...string[]]} */ ([
  'TECH_BUYER',
  'COMM_BUYER',
  'INFLUENCER_INT',
  'INFLUENCER_EXT',
  'SPONSOR',
]);

const STAND = /** @type {[string, ...string[]]} */ (['CHAMPION', 'NEUTRAL', 'BLOCKER', 'UNKNOWN']);

const dmuIdParams = z.strictObject({
  id: z.coerce.number().int().positive(),
  dmuId: z.coerce.number().int().positive(),
});

module.exports = {
  STAGES,
  OPEN_STAGES,
  list: {
    query: listQuery(
      ['value', 'weighted', 'expectedCloseDate', 'closedAt', 'title', 'createdAt'],
      '-weighted',
    ).extend({
      ...filters,
      view: z.enum(['OPEN', 'WON', 'LOST', 'DORMANT', 'ALL']).default('OPEN'),
      stage: z.enum(STAGES).optional(),
    }),
  },
  kanban: {
    query: z.strictObject({ ...filters, search: z.string().trim().max(100).optional() }),
  },
  byId: { params: schemas.idParam },
  update: {
    params: schemas.idParam,
    body: updateBody,
  },
  moveStage: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: z.number().int().min(0),
      toStage: z.enum(/** @type {[string, ...string[]]} */ (OPEN_STAGES)),
      /** gate or order override: needs opportunity.stage_override and a reason */
      override: z.boolean().default(false),
      reason: schemas.optionalText(1000),
    }),
  },
  validate: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: z.number().int().min(0),
      status: z.enum(['VALID', 'NOT_VALID']),
      remark: schemas.optionalText(1000),
    }),
  },
  dmuUpsert: {
    params: schemas.idParam,
    body: z.strictObject({
      contactId: schemas.id,
      dmuRole: z.enum(DMU_ROLES),
      influenceLevel: z
        .number()
        .int()
        .min(1)
        .max(5)
        .nullish()
        .transform((v) => v ?? null),
      stand: z.enum(STAND).default('UNKNOWN'),
      notes: z
        .string()
        .trim()
        .max(1000)
        .nullish()
        .transform((v) => v ?? null),
    }),
  },
  dmuRemove: { params: dmuIdParams },
  poc: {
    params: schemas.idParam,
    body: z.strictObject({
      skipped: z.boolean().default(false),
      skipReason: schemas.optionalText(1000),
      externalPocRef: schemas.optionalText(60),
      status: z.enum(['REQUESTED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED']).default('REQUESTED'),
      startDate: z.iso
        .date()
        .nullish()
        .transform((v) => v ?? null),
      endDate: z.iso
        .date()
        .nullish()
        .transform((v) => v ?? null),
      successCriteria: schemas.optionalText(4000),
      exitCriteria: schemas.optionalText(4000),
      customerLeadContactId: schemas.id.nullish().transform((v) => v ?? null),
      cnergeeLeadUserId: schemas.id.nullish().transform((v) => v ?? null),
      result: z
        .enum(['SUCCESS', 'FAIL', 'INCONCLUSIVE'])
        .nullish()
        .transform((v) => v ?? null),
      customerValidated: z
        .boolean()
        .nullish()
        .transform((v) => v ?? null),
      readoutDate: z.iso
        .date()
        .nullish()
        .transform((v) => v ?? null),
      notes: schemas.optionalText(4000),
    }),
  },
  close: {
    params: schemas.idParam,
    body: z
      .strictObject({
        rowVersion: z.number().int().min(0),
        outcome: z.enum(['WON', 'LOST', 'DORMANT']),
        // WON
        finalValue: money,
        poNumber: schemas.optionalText(60),
        poValue: money,
        poDate: z.iso
          .date()
          .nullish()
          .transform((v) => v ?? null),
        // LOST
        lossReasonIds: z
          .array(schemas.id)
          .max(10)
          .nullish()
          .transform((v) => v ?? null),
        competitorId: schemas.id.nullish().transform((v) => v ?? null),
        // DORMANT
        dormantReasonId: schemas.id.nullish().transform((v) => v ?? null),
        dormantNote: schemas.optionalText(1000),
        wakeUpDate: z.iso
          .date()
          .nullish()
          .transform((v) => v ?? null),
      })
      .superRefine((d, ctx) => {
        if (d.outcome === 'WON') {
          if (!d.finalValue)
            ctx.addIssue({ code: 'custom', path: ['finalValue'], message: 'Required.' });
          if (!d.poNumber)
            ctx.addIssue({ code: 'custom', path: ['poNumber'], message: 'Required.' });
          if (!d.poValue) ctx.addIssue({ code: 'custom', path: ['poValue'], message: 'Required.' });
          if (!d.poDate) ctx.addIssue({ code: 'custom', path: ['poDate'], message: 'Required.' });
        }
        if (d.outcome === 'LOST') {
          if (!d.lossReasonIds || d.lossReasonIds.length === 0)
            ctx.addIssue({
              code: 'custom',
              path: ['lossReasonIds'],
              message: 'Choose at least one loss reason.',
            });
        }
        if (d.outcome === 'DORMANT') {
          if (!d.dormantReasonId)
            ctx.addIssue({ code: 'custom', path: ['dormantReasonId'], message: 'Required.' });
          if (!d.wakeUpDate)
            ctx.addIssue({ code: 'custom', path: ['wakeUpDate'], message: 'Required.' });
        }
      }),
  },
};
