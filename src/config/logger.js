// @ts-check
'use strict';

/**
 * One Winston logger for the API (8.9, 18.1): JSON lines with a timestamp,
 * error.log + combined.log rotated at 5 MB x 5, a coloured console outside
 * production. Every line carries requestId and userId when available.
 * Never log passwords, tokens, OTPs, reset links or request bodies of auth endpoints (18.3).
 */
const fs = require('fs');
const path = require('path');
const winston = require('winston');
const config = require('./index');
const requestContext = require('./requestContext');

fs.mkdirSync(config.log.dir, { recursive: true });

const withContext = winston.format((info) => {
  const store = requestContext.current();
  if (store) {
    if (info.requestId === undefined) info.requestId = store.requestId;
    if (info.userId === undefined && store.userId !== undefined) info.userId = store.userId;
  }
  return info;
});

const consoleFormat = winston.format.printf(({ level, message, timestamp, ...meta }) => {
  const rest = { ...meta };
  delete rest.service;
  const extra = Object.keys(rest).length ? ` ${JSON.stringify(rest)}` : '';
  return `${timestamp} [${level}] ${message}${extra}`;
});

/** @type {winston.transport[]} */
const transports = [
  new winston.transports.File({
    filename: path.join(config.log.dir, 'error.log'),
    level: 'error',
    maxsize: 5 * 1024 * 1024,
    maxFiles: 5,
  }),
  new winston.transports.File({
    filename: path.join(config.log.dir, 'combined.log'),
    maxsize: 5 * 1024 * 1024,
    maxFiles: 5,
  }),
];

if (!config.isProduction && !config.isTest) {
  transports.push(
    new winston.transports.Console({
      format: winston.format.combine(winston.format.colorize(), consoleFormat),
    }),
  );
}

const logger = winston.createLogger({
  level: config.log.level,
  format: winston.format.combine(
    withContext(),
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json(),
  ),
  defaultMeta: { service: 'sales-crm-api' },
  transports,
});

module.exports = logger;
