// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const DATA_SCOPE = z.enum([
  'OWN_AND_TEAM',
  'ASSIGNED_AND_TEAM',
  'PARTNER_OWNED',
  'MODULE_LIMITED',
  'ALL',
]);
const MODULE = z.enum(['LEADS', 'OPPORTUNITIES', 'ACCOUNTS', 'PARTNERS', 'TENDERS', 'ORDERS']);
const permissionCodes = z
  .array(
    z
      .string()
      .trim()
      .regex(/^[a-z_]+(\.[a-z_]+)+$/, 'Unknown permission code.'),
  )
  .max(200);

module.exports = {
  list: { query: z.object({ includeInactive: schemas.boolQuery }) },
  byId: { params: schemas.idParam },
  create: {
    body: z.strictObject({
      code: schemas.code,
      name: z.string().trim().min(2).max(100),
      description: schemas.optionalText(500),
      dataScope: DATA_SCOPE,
      permissionCodes,
      moduleScopes: z.array(MODULE).max(6).optional(),
    }),
  },
  update: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: schemas.rowVersion,
      name: z.string().trim().min(2).max(100).optional(),
      description: schemas.optionalText(500).optional(),
      dataScope: DATA_SCOPE.optional(),
      isActive: z.boolean().optional(),
      permissionCodes: permissionCodes.optional(),
      moduleScopes: z.array(MODULE).max(6).optional(),
    }),
  },
};
