// @ts-check
'use strict';

/**
 * AppError hierarchy (8.7): an HTTP status, a stable UPPER_SNAKE code, a message
 * and optional details[] ({ field, code, message }).
 */

/** @typedef {{ field?: string, code?: string, message: string, tab?: string }} ErrorDetail */

class AppError extends Error {
  /**
   * @param {number} status
   * @param {string} code
   * @param {string} message
   * @param {ErrorDetail[]} [details]
   */
  constructor(status, code, message, details) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/** HTTP status of each error code the API and the stored procedures use. */
const STATUS_BY_CODE = Object.freeze({
  BAD_REQUEST: 400,
  UNAUTHENTICATED: 401,
  TOKEN_EXPIRED: 401,
  INVALID_CREDENTIALS: 401,
  FORBIDDEN: 403,
  ACCOUNT_LOCKED: 403,
  ACCOUNT_INACTIVE: 403,
  PASSWORD_CHANGE_REQUIRED: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  DUPLICATE: 409,
  FILE_TOO_LARGE: 413,
  UNSUPPORTED_FILE_TYPE: 415,
  VALIDATION_FAILED: 422,
  GATE_NOT_MET: 422,
  BUSINESS_RULE_VIOLATION: 422,
  RATE_LIMITED: 429,
  INTERNAL_ERROR: 500,
  SERVICE_UNAVAILABLE: 503,
});

/**
 * @param {string} code
 * @param {string} message
 * @param {ErrorDetail[]} [details]
 */
function appError(code, message, details) {
  const status = /** @type {Record<string, number>} */ (STATUS_BY_CODE)[code] ?? 500;
  return new AppError(status, code, message, details);
}

const errors = {
  badRequest: (/** @type {string} */ message, /** @type {ErrorDetail[]} */ details) =>
    appError('BAD_REQUEST', message, details),
  unauthenticated: (message = 'Authentication required.') => appError('UNAUTHENTICATED', message),
  tokenExpired: () => appError('TOKEN_EXPIRED', 'The session token has expired.'),
  invalidCredentials: () => appError('INVALID_CREDENTIALS', 'Invalid email or password.'),
  forbidden: (message = 'You do not have permission to do this.') => appError('FORBIDDEN', message),
  notFound: (message = 'Record not found or not visible to you.') => appError('NOT_FOUND', message),
  validation: (/** @type {ErrorDetail[]} */ details, message = 'Some fields are not valid.') =>
    appError('VALIDATION_FAILED', message, details),
  serviceUnavailable: (message = 'The service is temporarily unavailable. Try again shortly.') =>
    appError('SERVICE_UNAVAILABLE', message),
};

/** MySQL errors that mean the database cannot be reached / used right now. */
const UNAVAILABLE_ERRORS = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ETIMEDOUT',
  'EHOSTUNREACH',
  'PROTOCOL_CONNECTION_LOST',
  'ER_ACCESS_DENIED_ERROR',
  'ER_CON_COUNT_ERROR',
  'POOL_CLOSED',
]);

/**
 * Translate a database error into an AppError (8.7, decision D-12).
 * Stored-procedure business errors arrive as SQLSTATE 45000 with MESSAGE_TEXT "CODE|field|message".
 * @param {any} err
 * @returns {AppError | null} null when the error is not a known database condition
 */
function fromDbError(err) {
  if (!err || typeof err !== 'object') return null;

  if (err.sqlState === '45000' && typeof err.sqlMessage === 'string') {
    const [code, field, ...rest] = err.sqlMessage.split('|');
    const message = rest.join('|') || 'The request could not be completed.';
    const details = field ? [{ field, message }] : undefined;
    return appError(code in STATUS_BY_CODE ? code : 'BUSINESS_RULE_VIOLATION', message, details);
  }

  switch (err.errno) {
    case 1062:
      return appError('DUPLICATE', 'A record with the same value already exists.');
    case 1451:
      return appError('CONFLICT', 'The record is still referenced by other records.');
    case 1452:
      return appError('VALIDATION_FAILED', 'A referenced record does not exist.');
    case 3819:
      return appError('VALIDATION_FAILED', 'A value is outside the allowed range.');
    case 1213:
    case 1205:
      return errors.serviceUnavailable('The database is busy. Try again.');
    default:
      break;
  }

  if (UNAVAILABLE_ERRORS.has(err.code)) return errors.serviceUnavailable();
  return null;
}

module.exports = { AppError, STATUS_BY_CODE, appError, errors, fromDbError };
