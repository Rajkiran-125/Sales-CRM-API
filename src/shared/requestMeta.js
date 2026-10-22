// @ts-check
'use strict';

/**
 * The request context every write procedure receives first:
 * p_actor_user_id, p_request_id, p_ip (plus the user agent for security events).
 * @param {import('express').Request} req
 */
function requestMeta(req) {
  const r = /** @type {any} */ (req);
  return {
    actorUserId: r.user ? r.user.id : null,
    requestId: r.requestId,
    ip: req.ip ?? null,
    userAgent: (req.get('user-agent') || '').slice(0, 255),
  };
}

/** @typedef {ReturnType<typeof requestMeta>} RequestMeta */

module.exports = { requestMeta };
