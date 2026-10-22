// @ts-check
'use strict';

/**
 * /api/v1/targets (12.14 "dedicated endpoints for … targets", OD-15): value, deal-count and
 * new-logo targets per owner and fiscal quarter; the dashboard and the hierarchy funnel use them.
 */
const { z, schemas } = require('../../shared/schemas');
const { callProcedure, callProcedureOne } = require('../../db/pool');
const { sendData } = require('../../shared/response');
const { requestMeta } = require('../../shared/requestMeta');

const period = {
  fiscalYear: z.coerce.number().int().min(2000).max(2100),
  quarter: z.coerce.number().int().min(1).max(4),
};

/** @typedef {import('express').Request & { valid: any }} Req */

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['target.manage'],
    summary: "Every active user with the quarter's targets",
    schema: { query: z.strictObject(period) },
    handler: async (req, res) => {
      const q = /** @type {Req} */ (req).valid.query;
      const [rows] = await callProcedure('sp_target_list', [q.fiscalYear, q.quarter]);
      sendData(
        req,
        res,
        (rows ?? []).map((r) => ({
          ...r,
          targetCount: Number(r.targetCount),
          newLogoTarget: r.newLogoTarget === null ? null : Number(r.newLogoTarget),
        })),
      );
    },
  },
  {
    method: 'put',
    path: '/',
    access: ['target.manage'],
    summary:
      'Set the quarter targets of owners; zero value and count with no new-logo target removes one',
    schema: {
      body: z.strictObject({
        ...period,
        items: z
          .array(
            z.strictObject({
              ownerUserId: schemas.id,
              targetValue: z.number().min(0).max(99999999999999),
              targetCount: z.number().int().min(0).max(100000),
              newLogoTarget: z.number().int().min(0).max(100000).nullable(),
            }),
          )
          .min(1)
          .max(1000),
      }),
    },
    handler: async (req, res) => {
      const b = /** @type {Req} */ (req).valid.body;
      const m = requestMeta(req);
      const row = await callProcedureOne('sp_target_save', [
        m.actorUserId,
        m.requestId,
        m.ip,
        b.fiscalYear,
        b.quarter,
        JSON.stringify(b.items),
      ]);
      sendData(req, res, { targets: Number(row?.targets ?? 0) });
    },
  },
];
