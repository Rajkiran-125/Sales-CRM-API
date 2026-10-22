// @ts-check
'use strict';

const { callProcedure, callProcedureOne } = require('../../db/pool');

module.exports = {
  /**
   * @param {{ userId: number, entityType: string, entityId: number | null, accessType: string, detail?: string | null, ip: string, requestId: string }} opts
   */
  recordAccess: ({ userId, entityType, entityId, accessType, detail = null, ip, requestId }) =>
    callProcedureOne('sp_record_access_write', [
      userId,
      entityType,
      entityId ?? null,
      accessType,
      detail ?? null,
      ip,
      requestId,
    ]),

  /** @param {{ entityType?: string, entityId?: string, userId?: number, action?: string, from?: Date, to?: Date, offset: number, limit: number }} q */
  async auditLogs(q) {
    const [rows, totals] = await callProcedure('sp_audit_log_list', [
      q.entityType ?? null,
      q.entityId ?? null,
      q.userId ?? null,
      q.action ?? null,
      q.from ?? null,
      q.to ?? null,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },

  /** @param {{ eventCode?: string, userId?: number, from?: Date, to?: Date, offset: number, limit: number }} q */
  async securityEvents(q) {
    const [rows, totals] = await callProcedure('sp_security_event_list', [
      q.eventCode ?? null,
      q.userId ?? null,
      q.from ?? null,
      q.to ?? null,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },

  /** @param {{ entityType?: string, entityId?: number, userId?: number, accessType?: string, from?: Date, to?: Date, offset: number, limit: number }} q */
  async recordAccessLogs(q) {
    const [rows, totals] = await callProcedure('sp_record_access_log_list', [
      q.entityType ?? null,
      q.entityId ?? null,
      q.userId ?? null,
      q.accessType ?? null,
      q.from ?? null,
      q.to ?? null,
      q.offset,
      q.limit,
    ]);
    return { rows: rows ?? [], total: Number(totals?.[0]?.total ?? 0) };
  },
};
