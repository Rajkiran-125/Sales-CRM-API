// @ts-check
'use strict';

/**
 * HTTP application (8.12 boot order): request id -> request logger -> security headers ->
 * CORS -> rate limit -> body parsers -> cookies -> protected-field filter -> health and
 * API docs -> module routes (each declaring its own access) -> 404 -> global error handler.
 */
const express = require('express');
const helmet = require('helmet').default;
const cookieParser = require('cookie-parser');
const swaggerUi = require('swagger-ui-express');

const config = require('./config');
const requestId = require('./middleware/requestId');
const requestLogger = require('./middleware/requestLogger');
const cors = require('./middleware/cors');
const { limiters } = require('./middleware/rateLimit');
const { blockProtectedFields } = require('./middleware/allowFields');
const { errorHandler, notFound } = require('./middleware/errorHandler');
const { router: healthRouter } = require('./config/healthCheck');
const { buildOpenApi } = require('./config/openapi');
const { buildApiRouter } = require('./routes');
const { registry } = require('./shared/routeTable');

function createApp() {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.trustProxy);
  app.set('query parser', 'simple');

  app.use(requestId);
  app.use(requestLogger);
  app.use(
    helmet({
      frameguard: { action: 'deny' },
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          frameAncestors: ["'none'"],
          imgSrc: ["'self'", 'data:'],
          styleSrc: ["'self'", "'unsafe-inline'"],
          scriptSrc: ["'self'"],
        },
      },
    }),
  );
  app.use(cors);
  app.use(limiters.global);
  app.use(express.json({ limit: '1mb' }));
  app.use(cookieParser());
  app.use(blockProtectedFields);

  app.use(`${config.apiBasePath}/health`, healthRouter);
  app.use(config.apiBasePath, buildApiRouter());

  if (config.swaggerEnabled) {
    const spec = buildOpenApi(registry);
    app.get('/api-docs/openapi.json', (_req, res) => res.json(spec));
    app.use(
      '/api-docs',
      swaggerUi.serve,
      swaggerUi.setup(spec, { swaggerOptions: { persistAuthorization: true } }),
    );
  }

  app.use(notFound);
  app.use(errorHandler);
  return app;
}

module.exports = { createApp };
