// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const ENTITY_TYPES = /** @type {[string, ...string[]]} */ ([
  'LEAD',
  'OPP',
  'ACCOUNT',
  'PARTNER',
  'TENDER',
  'ORDER',
]);

const STATUSES = /** @type {[string, ...string[]]} */ (['OPEN', 'DONE', 'CANCELLED']);

const nullableId = schemas.id.nullish().transform((v) => v ?? null);

module.exports = {
  create: {
    body: z
      .strictObject({
        entityType: z
          .enum(ENTITY_TYPES)
          .nullish()
          .transform((v) => v ?? null),
        entityId: nullableId,
        title: z.string().trim().min(1).max(250),
        description: z
          .string()
          .trim()
          .max(1000)
          .nullish()
          .transform((v) => v ?? null),
        ownerUserId: nullableId,
        dueAt: schemas.isoDateTime,
      })
      .superRefine((d, ctx) => {
        if (d.entityType && !d.entityId) {
          ctx.addIssue({
            code: 'custom',
            path: ['entityId'],
            message: 'Required when entity type is set.',
          });
        }
      }),
  },
  update: {
    params: schemas.idParam,
    body: z.strictObject({
      title: z.string().trim().min(1).max(250),
      description: z
        .string()
        .trim()
        .max(1000)
        .nullish()
        .transform((v) => v ?? null),
      dueAt: schemas.isoDateTime,
      ownerUserId: schemas.id,
      status: z.enum(STATUSES),
    }),
  },
};
