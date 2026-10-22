// @ts-check
'use strict';

/**
 * Authentication service (10.2-10.6). The business decisions (lockout, rotation, reuse
 * detection, token validity, status changes) are taken by the stored procedures; this
 * service does what MySQL cannot: hashing, token signing, random tokens, the password
 * policy and sending the emails after the procedures commit.
 */
const config = require('../../config');
const repo = require('./auth.repository');
const mailer = require('../../integrations/mailer');
const accessContext = require('../../services/accessContext.service');
const { signAccessToken } = require('../../auth/tokens');
const { hashPassword, verifyPassword, verifyDummy } = require('../../auth/passwords');
const { checkPasswordPolicy } = require('../../auth/passwordPolicy');
const { randomToken, sha256, uuid } = require('../../shared/crypto');
const { appError, errors } = require('../../shared/errors');

/** @typedef {import('../../shared/requestMeta').RequestMeta} RequestMeta */
/** @typedef {import('../../services/accessContext.service').UserContext} UserContext */

/** @param {number} minutes */
function humanDuration(minutes) {
  if (minutes % 1440 === 0 && minutes >= 1440) {
    const d = minutes / 1440;
    return `${d} day${d === 1 ? '' : 's'}`;
  }
  if (minutes % 60 === 0 && minutes >= 60) {
    const h = minutes / 60;
    return `${h} hour${h === 1 ? '' : 's'}`;
  }
  return `${minutes} minute${minutes === 1 ? '' : 's'}`;
}

/** @param {Date | string} value */
function formatIst(value) {
  return new Date(value).toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    dateStyle: 'medium',
    timeStyle: 'short',
  });
}

/**
 * New password checks: policy, then no reuse of the current or recent passwords.
 * @param {string} password
 * @param {{ email?: string, fullName?: string }} user
 * @param {Array<{ passwordHash: string }>} hashes
 * @param {string} field
 */
async function assertAcceptablePassword(password, user, hashes, field) {
  const problems = checkPasswordPolicy(password, user);
  if (problems.length) throw errors.validation(problems.map((message) => ({ field, message })));
  for (const h of hashes) {
    if (await verifyPassword(h.passwordHash, password)) {
      throw errors.validation([
        { field, message: 'You used this password recently. Choose a different one.' },
      ]);
    }
  }
}

/**
 * @param {{ email: string, password: string }} input
 * @param {RequestMeta} meta
 */
async function login(input, meta) {
  const candidate = await repo.getLoginUser(input.email);
  const passwordOk = candidate?.passwordHash
    ? await verifyPassword(candidate.passwordHash, input.password)
    : await verifyDummy(input.password);

  const refreshToken = randomToken();
  const result = await repo.login(
    {
      email: input.email,
      passwordOk,
      refreshHash: sha256(refreshToken),
      familyId: uuid(),
      ttlMinutes: config.auth.refreshTokenTtlMinutes,
    },
    meta,
  );

  if (result?.lockedNow && result.email) {
    mailer.queueTemplate('ACCOUNT_LOCKED', result.email, {
      fullName: result.fullName,
      attempts: Number(result.failedAttempts),
      lockedUntil: formatIst(result.lockedUntil),
    });
  }
  if (!result || result.outcome !== 'SUCCESS') throw errors.invalidCredentials();

  return {
    ...signAccessToken({ id: Number(result.userId), tokenVersion: Number(result.tokenVersion) }),
    mustChangePassword: Boolean(result.mustChangePassword),
    refreshToken,
    sessionExpiresAt: new Date(result.sessionExpiresAt),
  };
}

/**
 * @param {string | null} oldToken
 * @param {RequestMeta} meta
 */
async function refresh(oldToken, meta) {
  if (!oldToken) throw errors.unauthenticated('Session ended. Please sign in again.');
  const newToken = randomToken();
  const result = await repo.refresh(sha256(oldToken), sha256(newToken), meta);

  if (result?.outcome === 'RACE') {
    throw appError('CONFLICT', 'The session is being refreshed by another tab. Retry.');
  }
  if (!result || result.outcome !== 'SUCCESS') {
    throw errors.unauthenticated('Session ended. Please sign in again.');
  }
  return {
    ...signAccessToken({ id: Number(result.userId), tokenVersion: Number(result.tokenVersion) }),
    mustChangePassword: Boolean(result.mustChangePassword),
    refreshToken: newToken,
    sessionExpiresAt: new Date(result.sessionExpiresAt),
  };
}

/** @param {UserContext} user */
async function me(user) {
  const settings = await repo.settingValues(['auth.idle_timeout.minutes']);
  const idle = Number(settings.find((s) => s.key === 'auth.idle_timeout.minutes')?.value ?? 30);
  return {
    ...accessContext.toPublicProfile(user),
    sessionPolicy: {
      idleTimeoutMinutes: idle,
      accessTokenMinutes: config.auth.accessTokenTtlMinutes,
    },
  };
}

/**
 * @param {UserContext} user
 * @param {string | null} refreshToken
 * @param {RequestMeta} meta
 */
async function logout(user, refreshToken, meta) {
  await repo.logout(user.id, refreshToken ? sha256(refreshToken) : null, meta);
}

/**
 * @param {UserContext} user
 * @param {RequestMeta} meta
 */
async function logoutAll(user, meta) {
  await repo.logoutAll(user.id, meta);
  accessContext.invalidate(user.id);
}

/**
 * @param {UserContext} user
 * @param {{ currentPassword: string, newPassword: string }} input
 * @param {string | null} refreshToken  the current session is kept
 * @param {RequestMeta} meta
 */
async function changePassword(user, input, refreshToken, meta) {
  const { hashes } = await repo.passwordHashes(user.id);
  const current = hashes.find((h) => h.kind === 'CURRENT');
  if (!(await verifyPassword(current?.passwordHash, input.currentPassword))) {
    throw appError('INVALID_CREDENTIALS', 'The current password is not correct.', [
      { field: 'currentPassword', message: 'The current password is not correct.' },
    ]);
  }
  await assertAcceptablePassword(input.newPassword, user, hashes, 'newPassword');

  const updated = await repo.changePassword(
    user.id,
    await hashPassword(input.newPassword),
    refreshToken ? sha256(refreshToken) : null,
    meta,
  );
  accessContext.invalidate(user.id);
  if (updated)
    mailer.queueTemplate('PASSWORD_CHANGED', updated.email, { fullName: updated.fullName });
}

/**
 * Always resolves (the caller answers 202 whatever happens, 10.6 step 2).
 * @param {string} email
 * @param {RequestMeta} meta
 */
async function forgotPassword(email, meta) {
  const token = randomToken();
  const target = await repo.createLinkToken(
    { purpose: 'RESET', email, tokenHash: sha256(token) },
    meta,
  );
  if (target) sendResetLink(target, token);
}

/**
 * @param {Record<string, any>} target  row from sp_auth_link_token_create
 * @param {string} token
 */
function sendResetLink(target, token) {
  mailer.queueTemplate(
    'PASSWORD_RESET',
    target.email,
    {
      fullName: target.fullName,
      link: `${config.uiBaseUrl}/reset-password?token=${encodeURIComponent(token)}`,
      expiresIn: humanDuration(Number(target.expiresInMinutes)),
    },
    { entityType: 'USER', entityId: Number(target.userId) },
  );
}

/**
 * @param {Record<string, any>} target  row with userId/id, email, fullName, expiresInMinutes
 * @param {string} token
 */
function sendInvitation(target, token) {
  mailer.queueTemplate(
    'USER_INVITATION',
    target.email,
    {
      fullName: target.fullName,
      link: `${config.uiBaseUrl}/accept-invitation?token=${encodeURIComponent(token)}`,
      expiresIn: humanDuration(Number(target.expiresInMinutes)),
    },
    { entityType: 'USER', entityId: Number(target.userId ?? target.id) },
  );
}

/**
 * @param {string} token
 * @param {'RESET' | 'INVITE'} purpose
 */
async function checkLink(token, purpose) {
  const row = await repo.peekLinkToken(sha256(token), purpose);
  if (!row) {
    throw errors.validation([
      { field: 'token', message: 'This link is invalid or has expired. Please request a new one.' },
    ]);
  }
  return { email: row.email, fullName: row.fullName, expiresAt: row.expiresAt };
}

/**
 * @param {string} token
 * @param {'RESET' | 'INVITE'} purpose
 * @param {string} newPassword
 * @param {RequestMeta} meta
 */
async function useLink(token, purpose, newPassword, meta) {
  const tokenHash = sha256(token);
  const row = await repo.peekLinkToken(tokenHash, purpose);
  if (!row) {
    throw errors.validation([
      { field: 'token', message: 'This link is invalid or has expired. Please request a new one.' },
    ]);
  }
  const { hashes } =
    purpose === 'RESET' ? await repo.passwordHashes(Number(row.userId)) : { hashes: [] };
  await assertAcceptablePassword(newPassword, row, hashes, 'newPassword');

  const done = await repo.consumeLinkToken(
    tokenHash,
    purpose,
    await hashPassword(newPassword),
    meta,
  );
  accessContext.invalidate(Number(row.userId));
  if (done && purpose === 'RESET') {
    mailer.queueTemplate('PASSWORD_RESET_CONFIRMATION', done.email, { fullName: done.fullName });
  }
}

/**
 * @param {UserContext} user
 * @param {string | null} refreshToken
 */
async function sessions(user, refreshToken) {
  const rows = await repo.sessions(user.id, refreshToken ? sha256(refreshToken) : null);
  return rows.map((r) => ({ ...r, isCurrent: Number(r.isCurrent) === 1 }));
}

/**
 * @param {UserContext} user
 * @param {string} sessionId
 * @param {RequestMeta} meta
 */
async function revokeSession(user, sessionId, meta) {
  await repo.revokeSession(user.id, sessionId, meta);
}

module.exports = {
  login,
  refresh,
  me,
  logout,
  logoutAll,
  changePassword,
  forgotPassword,
  checkLink,
  useLink,
  sessions,
  revokeSession,
  sendResetLink,
  sendInvitation,
  humanDuration,
};
