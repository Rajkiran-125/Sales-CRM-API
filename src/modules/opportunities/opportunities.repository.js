// @ts-check
'use strict';

/** Opportunities, read + write side (V008, V013 procedures). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals, counts] = await callProcedure('sp_opportunity_list', [
      userId,
      q.search ?? null,
      q.view,
      q.stage ?? null,
      q.source ?? null,
      q.ownerUserId ?? null,
      q.partnerId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0), counts: counts?.[0] ?? {} };
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async kanban(userId, q) {
    const [columns, cards] = await callProcedure('sp_opportunity_kanban', [
      userId,
      q.search ?? null,
      q.source ?? null,
      q.ownerUserId ?? null,
      q.partnerId ?? null,
    ]);
    return { columns: columns ?? [], cards: cards ?? [] };
  },

  /**
   * @param {number} userId
   * @param {number} id
   * @param {boolean} canSeeCommercial
   */
  get: (userId, id, canSeeCommercial) =>
    callProcedure('sp_opportunity_get', [userId, id, canSeeCommercial ? 1 : 0]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  update: (id, b, meta) =>
    callProcedureOne('sp_opportunity_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.rowVersion,
      b.title,
      b.solutionId,
      b.problemStatement ?? null,
      b.technicalRequirement ?? null,
      b.locationsCount,
      b.expectedValue,
      b.currency,
      b.fxRate,
      b.expectedCloseDate,
      b.commercialWindowValue,
      b.commercialWindowAccepted,
      b.budgetKnown,
      b.budgetMin,
      b.budgetMax,
      b.procurementTypeId,
      b.procurementStepsKnown ? 1 : 0,
      b.currentProcurementStepId,
      b.ownerUserId,
      b.backupOwnerUserId,
      b.presalesOwnerUserId,
      b.sponsorUserId,
      b.confidenceOverridePct,
      b.confidenceOverrideReason ?? null,
      b.partnerTbm ? 1 : 0,
      b.noCompetition ? 1 : 0,
      b.paymentTerms ?? null,
      b.bundleTag ?? null,
      b.productIds !== null ? JSON.stringify(b.productIds) : null,
    ]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} canOverride  true when user has opportunity.stage_override
   */
  moveStage: (id, b, meta, canOverride) =>
    callProcedureOne('sp_opportunity_move_stage', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.rowVersion,
      b.toStage,
      canOverride ? 1 : 0,
      b.override ? 1 : 0,
      b.reason,
    ]),

  /** @param {number} userId @param {number} id */
  pocGet: (userId, id) => callProcedureOne('sp_opportunity_poc_get', [userId, id]),

  /** Current editable values, keyed like the PATCH body (V026). @param {number} id */
  editValues: (id) => callProcedureOne('sp_opportunity_edit_values', [id]),

  /** @param {number} userId @param {number} id */
  gate: (userId, id) => callProcedure('sp_opportunity_gate', [userId, id]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  pocSave: (id, b, meta) =>
    callProcedureOne('sp_opportunity_poc_save', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.skipped ? 1 : 0,
      b.skipReason,
      b.externalPocRef,
      b.status,
      b.startDate,
      b.endDate,
      b.successCriteria,
      b.exitCriteria,
      b.customerLeadContactId,
      b.cnergeeLeadUserId,
      b.result,
      b.customerValidated === null ? null : b.customerValidated ? 1 : 0,
      b.readoutDate,
      b.notes,
    ]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  validate: (id, b, meta) =>
    callProcedureOne('sp_opportunity_validate', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.rowVersion,
      b.status,
      b.remark ?? null,
    ]),

  /**
   * @param {number} id  opportunity id
   * @param {any} b
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  dmuUpsert: (id, b, meta, allowAny) =>
    callProcedureOne('sp_opportunity_dmu_upsert', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.contactId,
      b.dmuRole,
      b.influenceLevel,
      b.stand,
      b.notes,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id  opportunity id
   * @param {number} dmuId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  dmuRemove: (id, dmuId, meta, allowAny) =>
    callProcedureOne('sp_opportunity_dmu_remove', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      dmuId,
      id,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} id
   * @param {any} b  validated body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  close: (id, b, meta) =>
    callProcedureOne('sp_opportunity_close', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      id,
      b.rowVersion,
      b.outcome,
      b.finalValue ?? null,
      b.poNumber ?? null,
      b.poValue ?? null,
      b.poDate ?? null,
      b.lossReasonIds !== null ? JSON.stringify(b.lossReasonIds) : null,
      b.competitorId ?? null,
      b.dormantReasonId ?? null,
      b.dormantNote ?? null,
      b.wakeUpDate ?? null,
    ]),
};
