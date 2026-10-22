// @ts-check
'use strict';

/**
 * One MySQL connection pool per API process (9.8). The API reaches data only through
 * stored procedures (decision D-02); every call binds its values as ? parameters.
 */
const mysql = require('mysql2/promise');
const config = require('../config');
const logger = require('../config/logger');
const { fromDbError } = require('../shared/errors');

const PROCEDURE_NAME = /^sp_[a-z0-9_]+$/;

const pool = mysql.createPool({
  host: config.db.host,
  port: config.db.port,
  database: config.db.database,
  user: config.db.user,
  password: config.db.password,
  connectionLimit: config.db.poolSize,
  waitForConnections: true,
  queueLimit: 0,
  enableKeepAlive: true,
  connectTimeout: 10000,
  charset: 'utf8mb4_0900_ai_ci',
  timezone: 'Z',
  dateStrings: ['DATE'],
  decimalNumbers: false,
  supportBigNumbers: true,
  bigNumberStrings: false,
  multipleStatements: false,
  ssl: config.db.ssl ? { rejectUnauthorized: true } : undefined,
  typeCast(field, next) {
    // TINYINT(1) columns are booleans
    if (field.type === 'TINY' && field.length === 1) {
      const value = field.string();
      return value === null ? null : value === '1';
    }
    return next();
  },
});

/**
 * Call a stored procedure and return its result sets (without the trailing OK packet).
 * A deadlock or lock wait is retried once: the procedure's transaction was rolled back.
 * @param {string} name procedure name (sp_...)
 * @param {unknown[]} [params]
 * @returns {Promise<Array<Array<Record<string, any>>>>}
 */
async function callProcedure(name, params = []) {
  if (!PROCEDURE_NAME.test(name)) throw new Error(`Invalid procedure name: ${name}`);
  const sql = `CALL ${name}(${params.map(() => '?').join(', ')})`;
  const values = params.map((p) => (p === undefined ? null : p));

  for (let attempt = 1; ; attempt += 1) {
    try {
      const [result] = await pool.query(sql, values);
      const sets = Array.isArray(result) ? result : [];
      return /** @type {Array<Array<Record<string, any>>>} */ (sets.filter((s) => Array.isArray(s)));
    } catch (err) {
      const e = /** @type {any} */ (err);
      if (attempt === 1 && (e.errno === 1213 || e.errno === 1205)) {
        logger.warn(`Retrying ${name} after ${e.code}`);
        continue;
      }
      const mapped = fromDbError(e);
      if (mapped) {
        if (mapped.status >= 500) logger.error(`Database error in ${name}: ${e.code} ${e.message}`);
        throw mapped;
      }
      throw err;
    }
  }
}

/**
 * First row of the first result set, or null.
 * @param {string} name
 * @param {unknown[]} [params]
 */
async function callProcedureOne(name, params = []) {
  const sets = await callProcedure(name, params);
  return sets[0]?.[0] ?? null;
}

/** @returns {Promise<boolean>} */
async function ping() {
  try {
    await pool.query('SELECT 1');
    return true;
  } catch {
    return false;
  }
}

async function close() {
  await pool.end();
}

module.exports = { pool, callProcedure, callProcedureOne, ping, close };
