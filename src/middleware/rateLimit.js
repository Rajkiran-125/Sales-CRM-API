// @ts-check
'use strict';

/**
 * Rate limiters (17.6). The field-keyed factory follows the Orchestrator's
 * node/ratelimiter.js pattern: key on a request field (e.g. the login email), fall back to
 * the client IP. In-memory store: correct for one API instance (20.3).
 */
const { rateLimit, ipKeyGenerator } = require('express-rate-limit');
const config = require('../config');
const { sendError } = require('../shared/response');

/** @type {import('express-rate-limit').Options['handler']} */
function handler(req, res, _next, options) {
  const retryAfter = Math.ceil(options.windowMs / 1000);
  sendError(
    req,
    res,
    429,
    'RATE_LIMITED',
    `Too many attempts. Try again in ${retryAfter} seconds.`,
  );
}

/**
 * @param {{ windowMs: number, limit: number, field?: string }} opts
 */
function createRateLimiter({ windowMs, limit, field }) {
  return rateLimit({
    windowMs,
    limit,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    handler,
    keyGenerator(req) {
      if (field) {
        const value = req.body?.[field];
        if (typeof value === 'string' && value.trim())
          return `${field}:${value.trim().toLowerCase()}`;
      }
      return ipKeyGenerator(req.ip || '0.0.0.0');
    },
  });
}

const limiters = {
  global: createRateLimiter({ windowMs: 60000, limit: config.rateLimit.globalPerMinute }),
  login: createRateLimiter({ windowMs: 60000, limit: config.rateLimit.loginPerMinute }),
  forgotByEmail: createRateLimiter({
    windowMs: 3600000,
    limit: config.rateLimit.forgotPerHourEmail,
    field: 'email',
  }),
  forgotByIp: createRateLimiter({ windowMs: 3600000, limit: config.rateLimit.forgotPerHourIp }),
  token: createRateLimiter({ windowMs: 900000, limit: config.rateLimit.tokenPer15Min }),
};

module.exports = { createRateLimiter, limiters };
