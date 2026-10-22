// @ts-check
'use strict';

/** /api/v1/audit-logs, /security-events, /record-access-logs (14.2, 18.5) */
const c = require('./audit.controller');
const { z, schemas } = require('../../shared/schemas');

const range = {
  from: schemas.isoDateTime.optional().transform((v) => (v ? new Date(v) : undefined)),
  to: schemas.isoDateTime.optional().transform((v) => (v ? new Date(v) : undefined)),
};
const paging = {
  page: z.coerce.number().int().min(1).max(100000).default(1),
  pageSize: z.coerce.number().int().min(1).max(100).default(25),
};

const auditQuery = z.object({
  ...paging,
  ...range,
  entityType: z.string().trim().toUpperCase().max(40).optional(),
  entityId: z.string().trim().max(80).optional(),
  userId: schemas.id.optional(),
  action: z.string().trim().toUpperCase().max(30).optional(),
});
const securityQuery = z.object({
  ...paging,
  ...range,
  eventCode: z.string().trim().toUpperCase().max(50).optional(),
  userId: schemas.id.optional(),
});
const accessQuery = z.object({
  ...paging,
  ...range,
  entityType: z.string().trim().toUpperCase().max(40).optional(),
  entityId: schemas.id.optional(),
  userId: schemas.id.optional(),
  accessType: z.enum(['VIEW', 'EXPORT', 'DOWNLOAD']).optional(),
});

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

module.exports = {
  /** @type {import('../../shared/routeTable').RouteDef[]} */
  auditLogs: [
    {
      method: 'get',
      path: '/',
      access: ['audit.view'],
      summary: 'Data audit log (who changed what)',
      schema: { query: auditQuery },
      handler: c.auditLogs,
    },
    {
      method: 'get',
      path: '/export',
      access: ['audit.view'],
      summary: 'Export the data audit log (xlsx)',
      schema: { query: auditQuery },
      handler: c.exportAuditLogs,
      produces: XLSX,
    },
  ],
  /** @type {import('../../shared/routeTable').RouteDef[]} */
  securityEvents: [
    {
      method: 'get',
      path: '/',
      access: ['audit.view'],
      summary: 'Security event log',
      schema: { query: securityQuery },
      handler: c.securityEvents,
    },
    {
      method: 'get',
      path: '/export',
      access: ['audit.view'],
      summary: 'Export the security event log (xlsx)',
      schema: { query: securityQuery },
      handler: c.exportSecurityEvents,
      produces: XLSX,
    },
  ],
  /** @type {import('../../shared/routeTable').RouteDef[]} */
  recordAccessLogs: [
    {
      method: 'get',
      path: '/',
      access: ['audit.view'],
      summary: 'Record access log (views, exports, downloads)',
      schema: { query: accessQuery },
      handler: c.recordAccessLogs,
    },
  ],
};
