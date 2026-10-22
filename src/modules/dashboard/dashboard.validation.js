// @ts-check
'use strict';

const { z, schemas } = require('../../shared/schemas');

const SOURCES = ['DIRECT', 'PARTNER', 'TENDER', 'EVENT', 'WEBSITE', 'REFERRAL'];

/**
 * Global filters (12.2). Without fiscalYear: the current fiscal quarter. With fiscalYear and
 * no quarter: the whole fiscal year.
 */
const filters = {
  fiscalYear: z.coerce.number().int().min(2000).max(2100).optional(),
  quarter: z.coerce.number().int().min(1).max(4).optional(),
  source: z.enum(SOURCES).optional(),
  productId: schemas.id.optional(),
  industryId: schemas.id.optional(),
  ownerUserId: schemas.id.optional(),
  partnerId: schemas.id.optional(),
};

/** @param {{ fiscalYear?: number, quarter?: number }} q */
const quarterNeedsYear = (q) => q.quarter === undefined || q.fiscalYear !== undefined;
const quarterMessage = { message: 'Choose the fiscal year with the quarter.', path: ['quarter'] };

module.exports = {
  SOURCES,
  get: {
    query: z.strictObject(filters).refine(quarterNeedsYear, quarterMessage),
  },
  drill: {
    params: z.object({ tile: z.string().trim().min(1).max(20) }),
    query: z
      .strictObject({
        ...filters,
        key: z.string().trim().max(40).optional(),
        page: z.coerce.number().int().min(1).max(100000).default(1),
        pageSize: z.coerce.number().int().min(1).max(100).default(25),
      })
      .refine(quarterNeedsYear, quarterMessage),
  },
};
