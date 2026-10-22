// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');

const period = {
  fiscalYear: z.coerce.number().int().min(2000).max(2100).optional(),
  quarter: z.coerce.number().int().min(1).max(4).optional(),
};
/** @param {{ fiscalYear?: number, quarter?: number }} q */
const quarterNeedsYear = (q) => q.quarter === undefined || q.fiscalYear !== undefined;
const quarterMessage = { message: 'Choose the fiscal year with the quarter.', path: ['quarter'] };

const text = schemas.optionalText;
const nullId = schemas.id.nullish().transform((v) => v ?? null);
/** distinct ids */
const idList = (min = 0) =>
  z
    .array(schemas.id)
    .min(min, 'Choose at least one.')
    .max(50)
    .transform((a) => [...new Set(a)]);
/** Optional upper-case code matching a pattern ('' becomes null). */
const optCode = (/** @type {RegExp} */ re, /** @type {string} */ message) =>
  z
    .string()
    .trim()
    .toUpperCase()
    .refine((v) => v === '' || re.test(v), message)
    .nullish()
    .transform((v) => v || null);
const gstNo = optCode(
  /^[0-9]{2}[A-Z0-9]{13}$/,
  'A GST number has 15 characters, starting with 2 digits.',
);
/** @param {number} max */
const count = (max) =>
  z
    .number()
    .int()
    .min(0)
    .max(max)
    .nullish()
    .transform((v) => v ?? null);
const money = z
  .number()
  .min(0)
  .max(99999999999999)
  .nullish()
  .transform((v) => v ?? null);
const flag = z
  .boolean()
  .nullish()
  .transform((v) => v ?? null);
const rowVersion = z.number().int().min(1);
/** example.com, www.example.com/x or https://example.com ('' becomes null) */
const website = z
  .string()
  .trim()
  .max(255)
  .refine(
    (v) => v === '' || /^(https?:\/\/)?([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?(\/\S*)?$/i.test(v),
    'Enter a website such as example.com.',
  )
  .nullish()
  .transform((v) => v || null);
const email = z
  .email()
  .max(150)
  .nullish()
  .or(z.literal(''))
  .transform((v) => v || null);
const currency = z.string().trim().toUpperCase().length(3).default('INR');
/** an optional code from a fixed list ('' becomes null) */
const pick = (/** @type {[string, ...string[]]} */ codes) =>
  z
    .enum(codes)
    .nullish()
    .or(z.literal(''))
    .transform((v) => v || null);
/** fiscal year such as 2025-26 */
const fiscalYearLabel = z
  .string()
  .trim()
  .refine((v) => v === '' || /^20\d{2}-\d{2}$/.test(v), 'Use a fiscal year such as 2025-26.')
  .nullish()
  .transform((v) => v || null);

/** @type {[string, ...string[]]} regions a partner covers (V042) */
const REGIONS = [
  'NORTH',
  'SOUTH',
  'EAST',
  'WEST',
  'CENTRAL',
  'NORTH_EAST',
  'PAN_INDIA',
  'INTERNATIONAL',
];

/** PATCH /partners/:id saves one section at a time (12.7). */
const sections = z.discriminatedUnion('section', [
  z.strictObject({
    section: z.literal('ENTITY'),
    rowVersion,
    legalName: z.string().trim().min(1, 'Required.').max(250),
    shortName: text(150),
    country: z.string().trim().min(1, 'Required.').max(80),
    address: z.string().trim().min(1, 'Required.').max(500),
    city: text(100),
    website,
    email,
    phone: text(20),
    registrationNo: text(50),
    gstNo,
    panNo: optCode(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'A PAN looks like ABCDE1234F.'),
    currency,
    annualRevenue: money,
    revenueFy: fiscalYearLabel,
    creditRating: text(40),
    financialStatus: pick(['STRONG', 'STABLE', 'WEAK']),
    /** employee strength */
    employeeCount: count(10000000),
    agreementStatus: z.enum(['NONE', 'IN_NEGOTIATION', 'SIGNED', 'EXPIRED']),
    agreementValidTill: z.iso
      .date()
      .nullish()
      .transform((v) => v ?? null),
    /** an AGREEMENT document of this partner (POST /documents first); required when SIGNED */
    agreementDocumentId: nullId,
  }),
  z.strictObject({
    section: z.literal('TYPE'),
    rowVersion,
    typeIds: idList(1),
    tier: z
      .enum(['STRATEGIC', 'GROWTH', 'TRANSACTIONAL'])
      .nullish()
      .transform((v) => v ?? null),
    /** hierarchy: the partner one level up (e.g. the distributor of a reseller) */
    parentPartnerId: nullId,
    certificationTypeIds: idList(),
    otherCertifications: z.array(z.string().trim().min(1).max(150)).max(30).default([]),
  }),
  z.strictObject({
    section: z.literal('INDUSTRY'),
    rowVersion,
    industryIds: idList(1),
    topCustomers: text(1000),
    ourSharePct: z
      .number()
      .min(0)
      .max(100)
      .nullish()
      .transform((v) => v ?? null),
    smeCount: count(100000),
    canRunPoc: flag,
    certifiedEngineers: count(100000),
    salesForceSize: count(1000000),
    usesCrm: flag,
    salesCoverage: text(255),
    regions: z
      .array(z.enum(REGIONS))
      .max(REGIONS.length)
      .default([])
      .transform((a) => [...new Set(a)]),
    influencerConnect: text(1000),
    dmuImpact: z
      .enum(['HIGH', 'MEDIUM', 'LOW'])
      .nullish()
      .transform((v) => v ?? null),
    dmuImpactNotes: text(1000),
  }),
  z.strictObject({
    section: z.literal('ENGAGEMENT'),
    rowVersion,
    topManagement: text(1000),
    partnerDmu: text(1000),
    /** null keeps the current owner */
    relationshipOwnerUserId: nullId,
    backupOwnerUserId: nullId,
    techOnboardingStatus: pick(['NOT_STARTED', 'IN_PROGRESS', 'TRAINED']),
    gtmPlanStatus: pick(['NOT_STARTED', 'IN_DISCUSSION', 'AGREED']),
    /** a GTM_PLAN document of this partner (POST /documents first) */
    gtmDocumentId: nullId,
    pocInvestmentCount: count(100000),
    pocInvestmentValue: money,
    customerFeedbackRating: z
      .number()
      .int()
      .min(1)
      .max(5)
      .nullish()
      .transform((v) => v ?? null),
    customerFeedbackNotes: text(1000),
    publications: text(10000),
  }),
]);

const engagementBody = z.strictObject({
  engagementType: z.enum([
    'MEETING',
    'QBR',
    'TRAINING',
    'EVENT',
    'GTM_ACTIVITY',
    'CEC_VISIT',
    'CALL',
    'JOINT_VISIT',
  ]),
  engagementOn: z.iso.date(),
  withWhom: text(500),
  notes: text(10000),
  outcome: text(1000),
  nextAction: text(500),
  nextActionOn: z.iso
    .date()
    .nullish()
    .transform((v) => v ?? null),
  /** on an edit, null keeps the stored account */
  accountId: nullId,
});

const accountMapBody = z.strictObject({
  accountId: schemas.id,
  /** half-year plan, e.g. 2026-H2 */
  planPeriod: z
    .string()
    .trim()
    .toUpperCase()
    .regex(/^20\d{2}-H[12]$/, 'Use a half-year such as 2026-H2.'),
  status: z.enum(['PLANNED', 'ENGAGED', 'OPPORTUNITY', 'DROPPED']).default('PLANNED'),
  notes: text(1000),
});

/** "Partner code at customers" (UM 7.1): a known account, or a customer name */
const customerCodeBody = z.strictObject({
  accountId: nullId,
  customerName: text(200),
  code: z.string().trim().min(1, 'Required.').max(60),
});

const partnerParam = z.object({ id: schemas.id });

module.exports = {
  quarterlyReport: {
    params: partnerParam,
    body: z.strictObject({
      fiscalYear: z.number().int().min(2000).max(2100),
      quarter: z.number().int().min(1).max(4),
    }),
  },
  engagementCreate: { params: partnerParam, body: engagementBody },
  engagementUpdate: {
    params: z.object({ id: schemas.id, engagementId: schemas.id }),
    body: engagementBody,
  },
  accountMapCreate: { params: partnerParam, body: accountMapBody },
  accountMapUpdate: {
    params: z.object({ id: schemas.id, rowId: schemas.id }),
    body: accountMapBody,
  },
  accountMapDelete: { params: z.object({ id: schemas.id, rowId: schemas.id }) },
  customerCodeCreate: { params: partnerParam, body: customerCodeBody },
  customerCodeUpdate: {
    params: z.object({ id: schemas.id, codeId: schemas.id }),
    body: customerCodeBody,
  },
  customerCodeDelete: { params: z.object({ id: schemas.id, codeId: schemas.id }) },
  duplicates: {
    query: z
      .strictObject({
        name: z.string().trim().max(250).optional(),
        gstNo: z.string().trim().max(15).optional(),
        website: z.string().trim().max(255).optional(),
        excludeId: schemas.id.optional(),
      })
      .refine((q) => q.name || q.gstNo || q.website, {
        message: 'Send a name, GST number or website.',
      }),
  },
  /** BR-PT-01: name, country, type, owner */
  create: {
    body: z.strictObject({
      legalName: z.string().trim().min(1, 'Required.').max(250),
      shortName: text(150),
      country: z.string().trim().min(1, 'Required.').max(80).default('India'),
      typeIds: idList(1),
      /** defaults to the creator */
      relationshipOwnerUserId: nullId,
      backupOwnerUserId: nullId,
      city: text(100),
      website,
      gstNo,
      email,
      phone: text(20),
      currency,
      /** BR-PT-02: true = the user saw the matching partners and creates a new one anyway */
      confirmDuplicate: z.boolean().default(false),
    }),
  },
  update: { params: schemas.idParam, body: sections },
  list: {
    query: listQuery(
      ['name', 'pipeline', 'wonValue', 'rating', 'nextEngagementOn'],
      '-pipeline',
    ).extend({
      type: schemas.code.optional(),
      tier: z.enum(['STRATEGIC', 'GROWTH', 'TRANSACTIONAL']).optional(),
      agreement: z.enum(['NONE', 'IN_NEGOTIATION', 'SIGNED', 'EXPIRED']).optional(),
      ownerUserId: schemas.id.optional(),
    }),
  },
  byId: { params: schemas.idParam },
  performance: {
    query: z
      .strictObject({
        ...period,
        ownerUserId: schemas.id.optional(),
        type: schemas.code.optional(),
      })
      .refine(quarterNeedsYear, quarterMessage),
  },
  performanceOne: {
    params: z.object({ partnerId: schemas.id }),
    query: z.strictObject(period).refine(quarterNeedsYear, quarterMessage),
  },
};
