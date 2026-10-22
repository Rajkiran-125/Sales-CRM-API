// @ts-check
'use strict';

/**
 * Process start and graceful shutdown (8.12): on SIGTERM / SIGINT stop accepting
 * connections, let open requests finish, stop the scheduler, wait for queued emails, close the DB pool;
 * force exit after 10 seconds.
 */
const config = require('./config');
const logger = require('./config/logger');
const db = require('./db/pool');
const mailer = require('./integrations/mailer');
const scheduler = require('./jobs/scheduler');
const { createApp } = require('./app');

const DB_MAX_RETRIES = 10;
const DB_RETRY_INTERVAL_MS = 5000;

async function checkDbConnection() {
  for (let attempt = 1; attempt <= DB_MAX_RETRIES; attempt += 1) {
    const ok = await db.ping();
    if (ok) {
      logger.info(`Database connected (${config.db.host}:${config.db.port}/${config.db.database})`);
      return;
    }
    if (attempt < DB_MAX_RETRIES) {
      logger.warn(
        `Database not reachable — retrying (${attempt}/${DB_MAX_RETRIES}) in ${DB_RETRY_INTERVAL_MS / 1000}s`,
      );
      await new Promise((resolve) => setTimeout(resolve, DB_RETRY_INTERVAL_MS));
    } else {
      logger.error(
        `Database unreachable after ${DB_MAX_RETRIES} attempts (${config.db.host}:${config.db.port}/${config.db.database}) — server is up but DB calls will fail`,
      );
    }
  }
}

const app = createApp();
const server = app.listen(config.port, () => {
  logger.info(`Sales CRM API listening on port ${config.port} (${config.env})`);
  checkDbConnection();
  if (config.scheduler.enabled) scheduler.start();
});

let shuttingDown = false;

/** @param {string} signal */
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info(`${signal} received: shutting down`);

  const force = setTimeout(() => {
    logger.error('Forced exit after 10 s');
    process.exit(1);
  }, 10000);
  force.unref();

  server.close(async () => {
    try {
      await scheduler.stop();
      await mailer.flush();
      await db.close();
      logger.info('Shutdown complete');
      process.exit(0);
    } catch (err) {
      logger.error(`Shutdown error: ${/** @type {Error} */ (err).message}`);
      process.exit(1);
    }
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => {
  logger.error(
    `Unhandled promise rejection: ${reason instanceof Error ? reason.stack : String(reason)}`,
  );
});
process.on('uncaughtException', (err) => {
  logger.error(`Uncaught exception: ${err.stack}`);
  shutdown('uncaughtException');
});
