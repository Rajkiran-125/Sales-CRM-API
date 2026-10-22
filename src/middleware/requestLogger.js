// @ts-check
'use strict';

/**
 * One log line per request when the response finishes (8.9): method, path (no query
 * string, so search terms and tokens never reach the logs), status, duration, request id
 * and user id. warn for status >= 400; health probes at debug level.
 */
const logger = require('../config/logger');

const SILENT = new Set(['/favicon.ico', '/robots.txt']);

/** @type {import('../shared/types').Handler} */
function requestLogger(req, res, next) {
  const started = process.hrtime.bigint();

  res.on('finish', () => {
    const path = (req.originalUrl || '').split('?')[0];
    if (SILENT.has(path.toLowerCase())) return;

    const durationMs = Number((process.hrtime.bigint() - started) / 1000000n);
    const status = res.statusCode;
    const r = /** @type {any} */ (req);
    const level = status >= 400 ? 'warn' : path.endsWith('/health') ? 'debug' : 'info';
    logger.log(level, `${req.method} ${path} ${status}`, {
      method: req.method,
      path,
      status,
      durationMs,
      requestId: r.requestId,
      userId: r.user ? r.user.id : undefined,
    });
  });

  next();
}

module.exports = requestLogger;
