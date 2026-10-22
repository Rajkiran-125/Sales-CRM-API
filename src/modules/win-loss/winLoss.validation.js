// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const filters = {
  fiscalYear: z.coerce.number().int().min(2000).max(2100).optional(),
  quarter: z.coerce.number().int().min(1).max(4).optional(),
  ownerUserId: schemas.id.optional(),
  productId: schemas.id.optional(),
  industryId: schemas.id.optional(),
  partnerId: schemas.id.optional(),
  competitorId: schemas.id.optional(),
};
/** @param {{ fiscalYear?: number, quarter?: number }} q */
const quarterNeedsYear = (q) => q.quarter === undefined || q.fiscalYear !== undefined;
const quarterMessage = { message: 'Choose the fiscal year with the quarter.', path: ['quarter'] };

const exportQuery = z
  .strictObject({ ...filters, outcome: z.enum(['WON', 'LOST']).optional() })
  .refine(quarterNeedsYear, quarterMessage);

module.exports = {
  export: { query: exportQuery },
  summary: { query: z.strictObject(filters).refine(quarterNeedsYear, quarterMessage) },
  deals: {
    query: z
      .strictObject({
        ...filters,
        outcome: z.enum(['WON', 'LOST']).optional(),
        page: z.coerce.number().int().min(1).max(100000).default(1),
        pageSize: z.coerce.number().int().min(1).max(100).default(25),
      })
      .refine(quarterNeedsYear, quarterMessage),
  },
};
