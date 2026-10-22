// @ts-check
'use strict';

const { z, schemas, listQuery } = require('../../shared/schemas');

const STATUS = z.enum(['INVITED', 'ACTIVE', 'LOCKED', 'INACTIVE']);
const roleIds = z.array(schemas.id).min(1, 'Select at least one role.').max(20);
const optionalPhone = schemas.phone.nullish().or(z.literal('').transform(() => null));

module.exports = {
  list: {
    query: listQuery(['name', 'email', 'status', 'lastLoginAt', 'createdAt'], 'name').extend({
      status: STATUS.optional(),
      roleId: schemas.id.optional(),
      managerId: schemas.id.optional(),
    }),
  },
  lookup: {
    query: z.object({
      search: z.string().trim().max(100).optional(),
      includeInactive: schemas.boolQuery,
      limit: z.coerce.number().int().min(1).max(50).default(20),
    }),
  },
  byId: { params: schemas.idParam },
  create: {
    body: z.strictObject({
      email: schemas.email,
      fullName: schemas.name,
      mobile: optionalPhone.transform((v) => v ?? null),
      designation: schemas.optionalText(100),
      department: schemas.optionalText(100),
      reportingToUserId: schemas.id.nullish().transform((v) => v ?? null),
      roleIds,
    }),
  },
  update: {
    params: schemas.idParam,
    body: z.strictObject({
      rowVersion: schemas.rowVersion,
      fullName: schemas.name.optional(),
      mobile: optionalPhone,
      designation: schemas.optionalText(100).optional(),
      department: schemas.optionalText(100).optional(),
      reportingToUserId: schemas.id.nullable().optional(),
      roleIds: roleIds.optional(),
    }),
  },
  status: {
    params: schemas.idParam,
    body: z.strictObject({
      status: z.enum(['ACTIVE', 'INACTIVE']),
      reason: z.string().trim().min(3, 'Give a reason (at least 3 characters).').max(500),
    }),
  },
};
