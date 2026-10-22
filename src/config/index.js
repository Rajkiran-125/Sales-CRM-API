// @ts-check
'use strict';

/**
 * Configuration from environment variables only, validated at start-up (fail fast, 17.11, 22.3).
 * The environment is chosen by configuration, never by editing a source file.
 */
const path = require('path');
const { z } = require('zod');

require('dotenv').config({
  path: process.env.DOTENV_PATH || path.join(__dirname, '..', '..', '.env'),
  quiet: true,
});

/** @param {boolean} def */
const bool = (def) =>
  z
    .enum(['true', 'false'])
    .default(def ? 'true' : 'false')
    .transform((v) => v === 'true');

/** @param {number} def @param {number} min @param {number} max */
const int = (def, min, max) => z.coerce.number().int().min(min).max(max).default(def);

const list = z
  .string()
  .default('')
  .transform((v) =>
    v
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  );

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: int(4100, 1, 65535),
  APP_NAME: z.string().min(1).default('Sales CRM'),
  UI_BASE_URL: z.url(),
  CORS_ORIGINS: list,
  TRUST_PROXY: int(0, 0, 10),

  DB_HOST: z.string().min(1),
  DB_PORT: int(3306, 1, 65535),
  DB_NAME: z.string().min(1),
  DB_USER: z.string().min(1),
  DB_PASSWORD: z.string().min(1),
  DB_POOL_SIZE: int(10, 1, 100),
  DB_SSL: bool(false),

  CRM_ACCESS_TOKEN_SECRET_CURRENT: z.string().min(64, 'must be at least 64 characters'),
  CRM_ACCESS_TOKEN_SECRET_CURRENT_KID: z.string().min(1),
  CRM_ACCESS_TOKEN_SECRET_PREVIOUS: z.string().optional().default(''),
  CRM_ACCESS_TOKEN_SECRET_PREVIOUS_KID: z.string().optional().default(''),
  CRM_JWT_ISSUER: z.string().min(1).default('sales-crm-api'),
  CRM_JWT_AUDIENCE: z.string().min(1).default('sales-crm-ui'),
  ACCESS_TOKEN_TTL_MINUTES: int(15, 1, 60),
  REFRESH_TOKEN_TTL_MINUTES: int(480, 5, 7 * 24 * 60),
  REFRESH_COOKIE_NAME: z.string().min(1).default('crm_refresh'),
  REFRESH_COOKIE_SECURE: bool(true),
  PASSWORD_PEPPER: z.string().optional().default(''),
  USER_CONTEXT_CACHE_SECONDS: int(60, 0, 600),

  MAIL_TRANSPORT: z.enum(['file', 'smtp']).default('file'),
  MAIL_FILE_DIR: z.string().default('var/mail'),
  /** Uploaded documents (OD-18 default: a backed-up disk volume outside the web root). */
  FILE_DIR: z.string().default('var/files'),
  /** Background jobs run only where this is true: exactly one instance per environment (8.10). */
  SCHEDULER_ENABLED: bool(false),
  MAIL_FROM: z.string().min(3).default('Sales CRM <no-reply@localhost>'),
  SMTP_HOST: z.string().optional().default(''),
  SMTP_PORT: int(587, 1, 65535),
  SMTP_SECURE: bool(false),
  SMTP_USER: z.string().optional().default(''),
  SMTP_PASSWORD: z.string().optional().default(''),

  LOG_LEVEL: z.enum(['error', 'warn', 'info', 'debug']).default('info'),
  LOG_DIR: z.string().default('logs'),
  SWAGGER_ENABLED: bool(true),

  RATE_LIMIT_GLOBAL_PER_MINUTE: int(600, 1, 100000),
  RATE_LIMIT_LOGIN_PER_MINUTE: int(10, 1, 10000),
  RATE_LIMIT_FORGOT_PER_HOUR_EMAIL: int(3, 1, 10000),
  RATE_LIMIT_FORGOT_PER_HOUR_IP: int(10, 1, 10000),
  RATE_LIMIT_TOKEN_PER_15MIN: int(10, 1, 10000),
});

/**
 * Production must not start with development values (10.14, 22.3).
 * @param {z.infer<typeof schema>} c
 * @returns {string[]}
 */
function productionProblems(c) {
  /** @type {string[]} */
  const problems = [];
  if (c.NODE_ENV !== 'production') return problems;
  if (!c.REFRESH_COOKIE_SECURE) problems.push('REFRESH_COOKIE_SECURE must be true');
  if (c.ACCESS_TOKEN_TTL_MINUTES < 5)
    problems.push('ACCESS_TOKEN_TTL_MINUTES is a test value (< 5)');
  if (c.REFRESH_TOKEN_TTL_MINUTES < 60)
    problems.push('REFRESH_TOKEN_TTL_MINUTES is a test value (< 60)');
  if (c.MAIL_TRANSPORT !== 'smtp') problems.push('MAIL_TRANSPORT must be smtp');
  if (c.SWAGGER_ENABLED) problems.push('SWAGGER_ENABLED must be false (OD-23)');
  if (!c.UI_BASE_URL.startsWith('https://')) problems.push('UI_BASE_URL must use https');
  if (c.CRM_JWT_ISSUER.startsWith('ugwebapplicationapi'))
    problems.push('CRM_JWT_ISSUER must not reuse the Orchestrator issuer');
  return problems;
}

/** @returns {Readonly<ReturnType<typeof build>>} */
function load() {
  const parsed = schema.safeParse(process.env);
  if (!parsed.success) {
    const lines = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`);
    throw new Error(`Invalid configuration:\n${lines.join('\n')}`);
  }
  const c = parsed.data;
  const problems = productionProblems(c);
  if (c.MAIL_TRANSPORT === 'smtp' && !c.SMTP_HOST) problems.push('SMTP_HOST is required for smtp');
  if (c.CRM_ACCESS_TOKEN_SECRET_PREVIOUS && !c.CRM_ACCESS_TOKEN_SECRET_PREVIOUS_KID)
    problems.push('CRM_ACCESS_TOKEN_SECRET_PREVIOUS_KID is required with a previous secret');
  if (problems.length) {
    throw new Error(`Invalid configuration:\n  ${problems.join('\n  ')}`);
  }
  return Object.freeze(build(c));
}

/** @param {z.infer<typeof schema>} c */
function build(c) {
  const root = path.join(__dirname, '..', '..');
  return {
    env: c.NODE_ENV,
    isProduction: c.NODE_ENV === 'production',
    isTest: c.NODE_ENV === 'test',
    port: c.PORT,
    appName: c.APP_NAME,
    apiBasePath: '/api/v1',
    uiBaseUrl: c.UI_BASE_URL.replace(/\/+$/, ''),
    corsOrigins: c.CORS_ORIGINS,
    trustProxy: c.TRUST_PROXY,
    db: {
      host: c.DB_HOST,
      port: c.DB_PORT,
      database: c.DB_NAME,
      user: c.DB_USER,
      password: c.DB_PASSWORD,
      poolSize: c.DB_POOL_SIZE,
      ssl: c.DB_SSL,
    },
    auth: {
      keys: [
        { kid: c.CRM_ACCESS_TOKEN_SECRET_CURRENT_KID, secret: c.CRM_ACCESS_TOKEN_SECRET_CURRENT },
        ...(c.CRM_ACCESS_TOKEN_SECRET_PREVIOUS
          ? [
              {
                kid: c.CRM_ACCESS_TOKEN_SECRET_PREVIOUS_KID,
                secret: c.CRM_ACCESS_TOKEN_SECRET_PREVIOUS,
              },
            ]
          : []),
      ],
      issuer: c.CRM_JWT_ISSUER,
      audience: c.CRM_JWT_AUDIENCE,
      accessTokenTtlMinutes: c.ACCESS_TOKEN_TTL_MINUTES,
      refreshTokenTtlMinutes: c.REFRESH_TOKEN_TTL_MINUTES,
      refreshCookieName: c.REFRESH_COOKIE_NAME,
      refreshCookieSecure: c.REFRESH_COOKIE_SECURE,
      pepper: c.PASSWORD_PEPPER,
      userContextCacheSeconds: c.USER_CONTEXT_CACHE_SECONDS,
    },
    mail: {
      transport: c.MAIL_TRANSPORT,
      fileDir: path.resolve(root, c.MAIL_FILE_DIR),
      from: c.MAIL_FROM,
      smtp: {
        host: c.SMTP_HOST,
        port: c.SMTP_PORT,
        secure: c.SMTP_SECURE,
        user: c.SMTP_USER,
        password: c.SMTP_PASSWORD,
      },
    },
    files: { dir: path.resolve(root, c.FILE_DIR) },
    scheduler: { enabled: c.SCHEDULER_ENABLED },
    log: { level: c.LOG_LEVEL, dir: path.resolve(root, c.LOG_DIR) },
    swaggerEnabled: c.SWAGGER_ENABLED,
    rateLimit: {
      globalPerMinute: c.RATE_LIMIT_GLOBAL_PER_MINUTE,
      loginPerMinute: c.RATE_LIMIT_LOGIN_PER_MINUTE,
      forgotPerHourEmail: c.RATE_LIMIT_FORGOT_PER_HOUR_EMAIL,
      forgotPerHourIp: c.RATE_LIMIT_FORGOT_PER_HOUR_IP,
      tokenPer15Min: c.RATE_LIMIT_TOKEN_PER_15MIN,
    },
  };
}

module.exports = load();
