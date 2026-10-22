// @ts-check
'use strict';

/** Leads, read + write side (V008, V011, V012 procedures). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {number} userId
   * @param {{ search?: string, stage?: string, source?: string, ownerUserId?: number, sort: string, offset: number, limit: number }} q
   */
  async list(userId, q) {
    const [rows, totals, stageCounts] = await callProcedure('sp_lead_list', [
      userId,
      q.search ?? null,
      q.stage ?? null,
      q.source ?? null,
      q.ownerUserId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return {
      rows: rows ?? [],
      total: Number(totals?.[0]?.total ?? 0),
      stageCounts: stageCounts ?? [],
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  get: (userId, id) => callProcedure('sp_lead_get', [userId, id]),

  /**
   * @param {any} b validated request body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  create: (b, meta) =>
    callProcedureOne('sp_lead_create', [
      meta.actorUserId,
      meta.requestId,
      meta.ip,
      b.source,
      b.partnerId,
      b.partnerContact,
      b.accountId,
      b.accountNameText,
      b.industryId,
      b.contactName,
      b.contactDesignation,
      b.contactEmail ?? null,
      b.contactPhone ?? null,
      b.city,
      b.locationsCount,
      b.needText,
      b.roughValue,
      b.roughTiming,
      b.ownerUserId,
      b.backupOwnerUserId,
      b.nextAction,
      b.nextActionDueOn,
      JSON.stringify(b.productIds),
    ]),

  /**
   * @param {number} id
   * @param {any} b validated request body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  update: (id, b, meta) =>
    callProcedureOne('sp_lead_update', [
      meta.actorUserId,
      meta.requestId,
      meta.ip ?? '',
      id,
      b.rowVersion,
      b.source,
      b.partnerId,
      b.partnerContact,
      b.accountId,
      b.accountNameText,
      b.industryId,
      b.contactName,
      b.contactDesignation,
      b.contactEmail ?? null,
      b.contactPhone ?? null,
      b.city,
      b.locationsCount,
      b.needText,
      b.roughValue,
      b.roughTiming,
      b.ownerUserId,
      b.backupOwnerUserId,
      b.nextAction,
      b.nextActionDueOn,
      JSON.stringify(b.productIds),
      b.problemStatement ?? null,
      b.productId ?? null,
      b.solutionId ?? null,
      b.commercialWindowValue ?? null,
      b.budgetKnown ?? null,
      b.budgetMin ?? null,
      b.budgetMax ?? null,
      b.procurementTypeId ?? null,
      b.procurementStepsKnown ? 1 : 0,
      b.expectedCloseDate ?? null,
    ]),

  /**
   * @param {number} id
   * @param {any} b validated request body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  disqualify: (id, b, meta) =>
    callProcedureOne('sp_lead_disqualify', [
      meta.actorUserId,
      meta.requestId,
      meta.ip ?? '',
      id,
      b.rowVersion,
      b.reasonId,
      b.note ?? null,
    ]),

  /**
   * @param {number} id lead id
   * @param {number | null} dmuId null = add
   * @param {any} b validated request body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  dmuSave: (id, dmuId, b, meta) =>
    callProcedureOne('sp_lead_dmu_save', [
      meta.actorUserId,
      meta.requestId,
      meta.ip ?? '',
      id,
      dmuId,
      b.name,
      b.designation,
      b.dmuRole,
      b.influenceLevel,
      b.stand,
      b.notes,
    ]),

  /**
   * @param {number} id lead id
   * @param {number} dmuId
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  dmuRemove: (id, dmuId, meta) =>
    callProcedureOne('sp_lead_dmu_remove', [
      meta.actorUserId,
      meta.requestId,
      meta.ip ?? '',
      id,
      dmuId,
    ]),

  /**
   * @param {number} id
   * @param {any} b validated request body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  convert: (id, b, meta) =>
    callProcedureOne('sp_lead_convert', [
      meta.actorUserId,
      meta.requestId,
      meta.ip ?? '',
      id,
      b.rowVersion,
      b.title,
    ]),
};
