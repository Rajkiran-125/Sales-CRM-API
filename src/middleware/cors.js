// @ts-check
'use strict';

/**
 * CORS with an origin allow-list from configuration (17.6): no wildcard; credentials only
 * for the configured UI origins. Requests without an Origin header (same-origin through the
 * reverse proxy, server-to-server) are allowed.
 */
const cors = require('cors');
const config = require('../config');

module.exports = cors({
  origin(origin, callback) {
    if (!origin || config.corsOrigins.includes(origin)) return callback(null, true);
    return callback(null, false);
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  allowedHeaders: ['Authorization', 'Content-Type', 'X-Request-Id', 'Idempotency-Key'],
  exposedHeaders: ['X-Request-Id', 'Content-Disposition'],
  maxAge: 600,
});
