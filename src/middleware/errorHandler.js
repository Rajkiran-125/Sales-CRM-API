// @ts-check
'use strict';

/**
 * Global error handler (8.7): known errors keep their status and code; malformed JSON
 * becomes 400; anything else is 500 INTERNAL_ERROR with a generic message. Stack traces
 * and SQL are logged, never returned.
 */
const logger = require('../config/logger');
const { AppError, fromDbError } = require('../shared/errors');
const { sendError } = require('../shared/response');

/** @type {import('express').ErrorRequestHandler} */
function errorHandler(err, req, res, _next) {
  if (res.headersSent) return;

  let e = err;
  if (!(e instanceof AppError)) e = fromDbError(err) || e;

  if (e instanceof AppError) {
    if (e.status >= 500) logger.error(`${e.code}: ${e.message}`, { stack: err?.stack });
    return sendError(req, res, e.status, e.code, e.message, e.details);
  }

  if (err?.type === 'entity.parse.failed') {
    return sendError(req, res, 400, 'BAD_REQUEST', 'The request body is not valid JSON.');
  }
  if (err?.type === 'entity.too.large') {
    return sendError(req, res, 413, 'PAYLOAD_TOO_LARGE', 'The request body is too large.');
  }

  logger.error(`Unhandled error: ${err?.message}`, { stack: err?.stack });
  return sendError(
    req,
    res,
    500,
    'INTERNAL_ERROR',
    'Something went wrong. Quote the request id to support.',
  );
}

/** @type {import('../shared/types').Handler} */
function notFound(req, res) {
  sendError(req, res, 404, 'NOT_FOUND', 'The requested endpoint does not exist.');
}

module.exports = { errorHandler, notFound };
