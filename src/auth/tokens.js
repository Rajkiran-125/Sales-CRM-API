// @ts-check
'use strict';

/**
 * Access tokens (10.4, 10.14): JWT HS512 with a key id (kid) for rotation, CRM-only
 * issuer and audience, algorithm allow-list. Claims: sub, tv, iat, exp, iss, aud, jti.
 * No permissions or personal data in the token: they are resolved server-side per request.
 */
const jwt = require('jsonwebtoken');
const config = require('../config');
const { uuid } = require('../shared/crypto');
const { errors } = require('../shared/errors');

const ALGORITHM = 'HS512';

/** @param {{ id: number, tokenVersion: number }} user */
function signAccessToken(user) {
  const [current] = config.auth.keys;
  const expiresIn = config.auth.accessTokenTtlMinutes * 60;
  const token = jwt.sign({ tv: user.tokenVersion }, current.secret, {
    algorithm: ALGORITHM,
    keyid: current.kid,
    subject: String(user.id),
    issuer: config.auth.issuer,
    audience: config.auth.audience,
    expiresIn,
    jwtid: uuid(),
  });
  return { accessToken: token, expiresIn, tokenType: 'Bearer' };
}

/**
 * Verify a token. Unknown kid, wrong algorithm, issuer or audience -> 401 UNAUTHENTICATED;
 * an expired token -> 401 TOKEN_EXPIRED (the UI then refreshes).
 * @param {string} token
 * @returns {{ userId: number, tokenVersion: number, jti: string }}
 */
function verifyAccessToken(token) {
  const decoded = jwt.decode(token, { complete: true });
  const kid = decoded && typeof decoded === 'object' ? decoded.header.kid : undefined;
  const key = config.auth.keys.find((k) => k.kid === kid);
  if (!key) throw errors.unauthenticated('Invalid session token.');

  try {
    const payload = /** @type {jwt.JwtPayload} */ (
      jwt.verify(token, key.secret, {
        algorithms: [ALGORITHM],
        issuer: config.auth.issuer,
        audience: config.auth.audience,
      })
    );
    const userId = Number(payload.sub);
    if (!Number.isSafeInteger(userId) || userId <= 0 || typeof payload.tv !== 'number') {
      throw errors.unauthenticated('Invalid session token.');
    }
    return { userId, tokenVersion: payload.tv, jti: String(payload.jti) };
  } catch (err) {
    if (err instanceof jwt.TokenExpiredError) throw errors.tokenExpired();
    if (err instanceof jwt.JsonWebTokenError)
      throw errors.unauthenticated('Invalid session token.');
    throw err;
  }
}

module.exports = { signAccessToken, verifyAccessToken };
