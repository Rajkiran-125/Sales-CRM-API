// @ts-check
'use strict';

/**
 * /api/v1/settings (12.14): business thresholds editable by the CRM Admin. Type and range
 * checks and the audit trail are done by sp_setting_update (one transaction per batch).
 */
const { callProcedure } = require('../../db/pool');
const { z } = require('../../shared/schemas');
const { requestMeta } = require('../../shared/requestMeta');
const { sendData } = require('../../shared/response');

/** @type {import('../../shared/routeTable').RouteDef[]} */
module.exports = [
  {
    method: 'get',
    path: '/',
    access: ['setting.manage'],
    summary: 'All business settings with their type, range and description',
    schema: { query: z.object({ module: z.string().trim().toUpperCase().max(40).optional() }) },
    handler: async (req, res) => {
      const q = /** @type {any} */ (req).valid.query;
      sendData(req, res, (await callProcedure('sp_setting_list', [q.module ?? null]))[0] ?? []);
    },
  },
  {
    method: 'patch',
    path: '/',
    access: ['setting.manage'],
    summary: 'Change settings (all or nothing)',
    schema: {
      body: z.strictObject({
        items: z
          .array(
            z.strictObject({
              key: z.string().trim().min(1).max(80),
              value: z.string().trim().min(1).max(1000),
            }),
          )
          .min(1)
          .max(50),
      }),
    },
    handler: async (req, res) => {
      const m = requestMeta(req);
      const body = /** @type {any} */ (req).valid.body;
      const sets = await callProcedure('sp_setting_update', [
        m.actorUserId,
        m.requestId,
        m.ip,
        JSON.stringify(body.items),
      ]);
      sendData(req, res, sets[0] ?? []);
    },
  },
];
