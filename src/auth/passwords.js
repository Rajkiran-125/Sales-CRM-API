// @ts-check
'use strict';

/**
 * Password hashing with Argon2id (10.5) and an optional server-side pepper.
 * Passwords are never logged, emailed, returned or stored reversibly (17.3).
 *
 * Uses Node's built-in crypto.argon2 (no native addon, so Windows Application Control
 * cannot block it). Hashes use the standard PHC string, the same format the `argon2`
 * npm package wrote, so existing hashes still verify.
 */
const crypto = require('node:crypto');
const { promisify } = require('node:util');
const config = require('../config');

const argon2 = promisify(crypto.argon2);

const PARAMS = {
  memory: 19456, // 19 MiB (OWASP baseline for Argon2id)
  passes: 2,
  parallelism: 1,
  tagLength: 32,
};
const SALT_BYTES = 16;
const VERSION = 19;
const SECRET = config.auth.pepper ? Buffer.from(config.auth.pepper, 'utf8') : undefined;

// params in any order: the old `argon2` package wrote m,p,t; this module writes m,t,p
const PHC =
  /^\$(argon2id|argon2i|argon2d)\$v=(\d+)\$([a-z]=\d+(?:,[a-z]=\d+)*)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/;

/** @param {Buffer} buf */
const b64 = (buf) => buf.toString('base64').replace(/=+$/, '');

/** @param {string} password */
async function hashPassword(password) {
  const nonce = crypto.randomBytes(SALT_BYTES);
  const tag = await argon2('argon2id', { message: password, nonce, secret: SECRET, ...PARAMS });
  const { memory: m, passes: t, parallelism: p } = PARAMS;
  return `$argon2id$v=${VERSION}$m=${m},t=${t},p=${p}$${b64(nonce)}$${b64(tag)}`;
}

/**
 * @param {string | null | undefined} hash
 * @param {string} password
 */
async function verifyPassword(hash, password) {
  if (!hash) return false;
  const match = PHC.exec(hash);
  if (!match || Number(match[2]) !== VERSION) return false;
  const [, algorithm, , params, salt, digest] = match;
  const { m, t, p } = Object.fromEntries(params.split(',').map((kv) => kv.split('=')));
  if (!m || !t || !p) return false;
  const expected = Buffer.from(digest, 'base64');
  try {
    const actual = await argon2(/** @type {crypto.Argon2Algorithm} */ (algorithm), {
      message: password,
      nonce: Buffer.from(salt, 'base64'),
      secret: SECRET,
      memory: Number(m),
      passes: Number(t),
      parallelism: Number(p),
      tagLength: expected.length,
    });
    return crypto.timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

/** @type {Promise<string> | null} */
let dummyHash = null;

/**
 * Verify against a fixed dummy hash, so an unknown email takes as long as a wrong
 * password (no user enumeration by timing, 10.2 step 3).
 * @param {string} password
 */
async function verifyDummy(password) {
  dummyHash = dummyHash || hashPassword('not-a-real-password-dummy-value');
  await verifyPassword(await dummyHash, password);
  return false;
}

module.exports = { hashPassword, verifyPassword, verifyDummy };
