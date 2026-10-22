// @ts-check
'use strict';

/** Tenders: read side (V009), write side (V037). */
const { callProcedure, callProcedureOne } = require('../../db/pool');

/** @typedef {import('../../shared/requestMeta').RequestMeta} Meta */

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q  validated query plus offset / limit
   */
  async list(userId, q) {
    const [rows, totals, statusCounts] = await callProcedure('sp_tender_list', [
      userId,
      q.search ?? null,
      q.status ?? null,
      q.ownerUserId ?? null,
      q.sort,
      q.offset,
      q.limit,
    ]);
    return {
      rows: rows ?? [],
      total: Number(totals?.[0]?.total ?? 0),
      statusCounts: statusCounts ?? [],
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  get: (userId, id) => callProcedure('sp_tender_get', [userId, id]),

  /** @param {number} userId @param {number} id */
  editGet: (userId, id) => callProcedureOne('sp_tender_edit_get', [userId, id]),

  /**
   * @param {number | null} id  null = create
   * @param {any} b
   * @param {Meta} m
   * @param {boolean} allowAny
   */
  save: (id, b, m, allowAny) =>
    callProcedureOne('sp_tender_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      id,
      b.rowVersion ?? null,
      b.referenceNo,
      b.portal,
      b.authority,
      b.accountId,
      b.title,
      b.productId,
      b.estimatedValue,
      b.ourRole,
      b.bidderPartnerId,
      b.preBidOn,
      b.submissionOn,
      b.openingOn,
      b.specInfluenced ? 1 : 0,
      b.rfpInfluenced ? 1 : 0,
      b.prebidQueriesFiled ? 1 : 0,
      b.intelligenceNotes,
      b.ownerUserId,
      b.backupOwnerUserId,
      allowAny ? 1 : 0,
    ]),

  /** @param {number} id @param {any} b @param {Meta} m @param {boolean} allowAny */
  transition: (id, b, m, allowAny) =>
    callProcedureOne('sp_tender_transition', [
      m.actorUserId,
      m.requestId,
      m.ip,
      id,
      b.rowVersion,
      b.toStatus,
      b.result,
      b.l1Price,
      b.ourPrice,
      b.winner,
      b.lossReasonId,
      b.opportunityId,
      b.reason,
      allowAny ? 1 : 0,
    ]),

  /**
   * @param {number} tenderId
   * @param {number | null} itemId  null = new item
   * @param {any} b
   * @param {Meta} m
   * @param {boolean} allowAny
   */
  checklistSave: (tenderId, itemId, b, m, allowAny) =>
    callProcedureOne('sp_tender_checklist_save', [
      m.actorUserId,
      m.requestId,
      m.ip,
      tenderId,
      itemId,
      b.itemText,
      b.isMandatory ? 1 : 0,
      b.isDone ? 1 : 0,
      b.documentId,
      allowAny ? 1 : 0,
    ]),

  /** @param {number} tenderId @param {number} itemId @param {Meta} m @param {boolean} allowAny */
  checklistDelete: (tenderId, itemId, m, allowAny) =>
    callProcedure('sp_tender_checklist_delete', [
      m.actorUserId,
      m.requestId,
      m.ip,
      tenderId,
      itemId,
      allowAny ? 1 : 0,
    ]),
};
