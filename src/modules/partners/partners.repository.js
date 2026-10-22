// @ts-check
'use strict';

/** Partners and partner performance: read side (V009), Partner Master write (V030). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

const json = (/** @type {unknown[]} */ a) => JSON.stringify(a);

/** Section saves: procedure and its fields after (id, rowVersion), in parameter order. */
const SECTION_CALLS = {
  /** @param {any} b */
  ENTITY: (b) => [
    'sp_partner_save_entity',
    [
      b.legalName,
      b.shortName,
      b.country,
      b.address,
      b.city,
      b.website,
      b.email,
      b.phone,
      b.registrationNo,
      b.gstNo,
      b.panNo,
      b.currency,
      b.annualRevenue,
      b.revenueFy,
      b.creditRating,
      b.financialStatus,
      b.employeeCount,
      b.agreementStatus,
      b.agreementValidTill,
      b.agreementDocumentId,
    ],
  ],
  /** @param {any} b */
  TYPE: (b) => [
    'sp_partner_save_type',
    [
      json(b.typeIds),
      b.tier,
      b.parentPartnerId,
      json(b.certificationTypeIds),
      json(b.otherCertifications),
    ],
  ],
  /** @param {any} b */
  INDUSTRY: (b) => [
    'sp_partner_save_industry',
    [
      json(b.industryIds),
      b.topCustomers,
      b.ourSharePct,
      b.smeCount,
      b.canRunPoc === null ? null : Number(b.canRunPoc),
      b.certifiedEngineers,
      b.salesForceSize,
      b.usesCrm === null ? null : Number(b.usesCrm),
      b.salesCoverage,
      json(b.regions),
      b.influencerConnect,
      b.dmuImpact,
      b.dmuImpactNotes,
    ],
  ],
  /** @param {any} b */
  ENGAGEMENT: (b) => [
    'sp_partner_save_engagement',
    [
      b.topManagement,
      b.partnerDmu,
      b.relationshipOwnerUserId,
      b.backupOwnerUserId,
      b.techOnboardingStatus,
      b.gtmPlanStatus,
      b.gtmDocumentId,
      b.pocInvestmentCount,
      b.pocInvestmentValue,
      b.customerFeedbackRating,
      b.customerFeedbackNotes,
      b.publications,
    ],
  ],
};

module.exports = {
  /** @param {any} q */
  duplicates: (q) =>
    callProcedure('sp_partner_duplicates', [
      q.name ?? null,
      q.gstNo ?? null,
      q.website ?? null,
      q.excludeId ?? null,
    ]),

  /** @param {any} b @param {Meta} m @param {boolean} allowAny */
  create: (b, m, allowAny) =>
    callProcedureOne('sp_partner_create', [
      m.actorUserId,
      m.requestId,
      m.ip,
      b.legalName,
      b.shortName,
      b.country,
      json(b.typeIds),
      b.relationshipOwnerUserId ?? m.actorUserId,
      b.backupOwnerUserId,
      b.city,
      b.website,
      b.gstNo,
      b.email ?? null,
      b.phone ?? null,
      b.currency ?? null,
      b.confirmDuplicate ? 1 : 0,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} partnerId @param {number | null} id  null = new
   * @param {any} b @param {Meta} m @param {boolean} allowAny
   */
  engagementSave: (partnerId, id, b, m, allowAny) =>
    callProcedureOne('sp_partner_engagement_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      partnerId,
      id,
      b.engagementType,
      b.engagementOn,
      b.withWhom,
      b.notes,
      b.outcome,
      b.nextAction,
      b.nextActionOn,
      b.accountId,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} partnerId @param {number | null} id  null = new
   * @param {any} b @param {Meta} m @param {boolean} allowAny
   */
  accountMapSave: (partnerId, id, b, m, allowAny) =>
    callProcedureOne('sp_partner_account_map_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      partnerId,
      id,
      b.accountId,
      b.planPeriod,
      b.status,
      b.notes,
      allowAny ? 1 : 0,
    ]),

  /** @param {number} partnerId @param {number} id @param {Meta} m @param {boolean} allowAny */
  accountMapDelete: (partnerId, id, m, allowAny) =>
    callProcedure('sp_partner_account_map_delete', [
      m.actorUserId,
      m.requestId,
      m.ip,
      partnerId,
      id,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} partnerId @param {number | null} id  null = new
   * @param {any} b @param {Meta} m @param {boolean} allowAny
   */
  customerCodeSave: (partnerId, id, b, m, allowAny) =>
    callProcedureOne('sp_partner_customer_code_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      partnerId,
      id,
      b.accountId,
      b.customerName,
      b.code,
      allowAny ? 1 : 0,
    ]),

  /** @param {number} partnerId @param {number} id @param {Meta} m @param {boolean} allowAny */
  customerCodeDelete: (partnerId, id, m, allowAny) =>
    callProcedure('sp_partner_customer_code_delete', [
      m.actorUserId,
      m.requestId,
      m.ip,
      partnerId,
      id,
      allowAny ? 1 : 0,
    ]),

  /** @param {number} userId @param {number} id */
  editGet: (userId, id) => callProcedure('sp_partner_edit_get', [userId, id]),

  /** @param {number} id @param {any} b  one validated section @param {Meta} m @param {boolean} allowAny */
  saveSection(id, b, m, allowAny) {
    const [proc, fields] = SECTION_CALLS[/** @type {keyof typeof SECTION_CALLS} */ (b.section)](b);
    return callProcedureOne(/** @type {string} */ (proc), [
      m.actorUserId,
      m.requestId,
      m.ip,
      id,
      b.rowVersion,
      .../** @type {unknown[]} */ (fields),
      allowAny ? 1 : 0,
    ]);
  },

  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals, [period]] = await callProcedure('sp_partner_list', [
      userId,
      q.search ?? null,
      q.type ?? null,
      q.tier ?? null,
      q.agreement ?? null,
      q.ownerUserId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0), period };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  get: (userId, id) => callProcedure('sp_partner_get', [userId, id]),

  /**
   * @param {number} userId
   * @param {any} q
   */
  performance: (userId, q) =>
    callProcedure('sp_partner_performance', [
      userId,
      q.fiscalYear ?? null,
      q.quarter ?? null,
      q.ownerUserId ?? null,
      q.type ?? null,
    ]),

  /**
   * @param {number} userId
   * @param {number} partnerId
   * @param {any} q
   */
  performanceOne: (userId, partnerId, q) =>
    callProcedure('sp_partner_performance_get', [
      userId,
      partnerId,
      q.fiscalYear ?? null,
      q.quarter ?? null,
    ]),
};
