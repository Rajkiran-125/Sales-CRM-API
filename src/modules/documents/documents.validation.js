// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const ENTITY = z.enum(['LEAD', 'OPP', 'ACCOUNT', 'PARTNER', 'TENDER', 'ORDER']);

module.exports = {
  // newest first (shared on, else uploaded on); no other sort
  list: {
    query: z.strictObject({
      page: z.coerce.number().int().min(1).max(100000).default(1),
      pageSize: z.coerce.number().int().min(1).max(100).default(25),
      search: z.string().trim().max(100).optional(),
      type: schemas.code.optional(),
      entityType: ENTITY.optional(),
      sharedWith: z.enum(['CUSTOMER', 'PARTNER', 'INTERNAL']).optional(),
      partnerId: schemas.id.optional(),
      accountId: schemas.id.optional(),
      tag: z.string().trim().min(1).max(60).optional(),
    }),
  },
  /** multipart fields arrive as strings */
  upload: {
    body: z.strictObject({
      entityType: ENTITY,
      entityId: z.coerce.number().int().positive(),
      documentTypeCode: schemas.code,
      /** one title for a single file; empty = the file name */
      title: schemas.optionalText(250),
      /** comma-separated */
      tags: z
        .string()
        .max(1000)
        .optional()
        .transform((v) =>
          (v ?? '')
            .split(',')
            .map((t) => t.trim().toLowerCase())
            .filter((t) => t && t.length <= 60),
        ),
      sharedWith: z.enum(['CUSTOMER', 'PARTNER', 'INTERNAL']).default('INTERNAL'),
      sharedWithPartnerId: z.coerce.number().int().positive().optional(),
      sharedOn: z.iso.date().optional(),
      notes: schemas.optionalText(1000),
    }),
  },
  byId: { params: schemas.idParam },
  /** a field left out keeps its value; tags replace the whole set */
  update: {
    params: schemas.idParam,
    body: z
      .strictObject({
        tags: z
          .array(z.string().trim().toLowerCase().min(1).max(60))
          .max(30)
          .transform((t) => [...new Set(t)])
          .optional(),
        notes: z.string().trim().max(1000).nullable().optional(),
      })
      .refine((b) => b.tags !== undefined || b.notes !== undefined, {
        message: 'Send tags or notes.',
      }),
  },
};
