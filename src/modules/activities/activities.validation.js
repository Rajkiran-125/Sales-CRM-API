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

const ACTIVITY_TYPES = /** @type {[string, ...string[]]} */ ([
  'CALL',
  'MEETING',
  'EMAIL',
  'VISIT',
  'CEC_VISIT',
  'DEMO',
  'NEGOTIATION',
  'NOTE',
  'INTEL',
]);

const activityBody = z
  .strictObject({
    entityType: z.enum(ENTITY_TYPES),
    entityId: schemas.id,
    activityType: z.enum(ACTIVITY_TYPES),
    activityAt: z.iso.datetime({ offset: true }),
    subject: z.string().trim().min(1).max(250),
    peopleMet: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => v ?? null),
    notes: z
      .string()
      .trim()
      .max(4000)
      .nullish()
      .transform((v) => v ?? null),
    outcome: z
      .string()
      .trim()
      .max(1000)
      .nullish()
      .transform((v) => v ?? null),
    nextAction: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => v ?? null),
    nextActionOn: z.iso
      .date()
      .nullish()
      .transform((v) => v ?? null),
    nextActionOwnerId: schemas.id.nullish().transform((v) => v ?? null),
    contactIds: z
      .array(schemas.id)
      .max(50)
      .nullish()
      .transform((v) => v ?? null),
  })
  .superRefine((d, ctx) => {
    if (d.nextAction && !d.nextActionOn) {
      ctx.addIssue({
        code: 'custom',
        path: ['nextActionOn'],
        message: 'Required when next action is set.',
      });
    }
  });

const updateBody = z
  .strictObject({
    activityType: z.enum(ACTIVITY_TYPES),
    activityAt: z.iso.datetime({ offset: true }),
    subject: z.string().trim().min(1).max(250),
    peopleMet: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => v ?? null),
    notes: z
      .string()
      .trim()
      .max(4000)
      .nullish()
      .transform((v) => v ?? null),
    outcome: z
      .string()
      .trim()
      .max(1000)
      .nullish()
      .transform((v) => v ?? null),
    nextAction: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => v ?? null),
    nextActionOn: z.iso
      .date()
      .nullish()
      .transform((v) => v ?? null),
    nextActionOwnerId: schemas.id.nullish().transform((v) => v ?? null),
    contactIds: z
      .array(schemas.id)
      .max(50)
      .nullish()
      .transform((v) => v ?? null),
  })
  .superRefine((d, ctx) => {
    if (d.nextAction && !d.nextActionOn) {
      ctx.addIssue({
        code: 'custom',
        path: ['nextActionOn'],
        message: 'Required when next action is set.',
      });
    }
  });

module.exports = {
  create: { body: activityBody },
  update: { params: schemas.idParam, body: updateBody },
  delete: { params: schemas.idParam },
};
