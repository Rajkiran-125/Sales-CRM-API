// @ts-check
'use strict';

/**
 * Print a new { kid, secret } pair for access-token key rotation (10.14):
 *   1. move the current pair to CRM_ACCESS_TOKEN_SECRET_PREVIOUS(_KID)
 *   2. put the new pair in CRM_ACCESS_TOKEN_SECRET_CURRENT(_KID)
 *   3. restart; remove the previous pair after one access-token lifetime
 */
const crypto = require('crypto');

const kid = `k${new Date().toISOString().slice(0, 10).replace(/-/g, '')}-${crypto.randomBytes(3).toString('hex')}`;
const secret = crypto.randomBytes(64).toString('base64url');

console.log(`CRM_ACCESS_TOKEN_SECRET_CURRENT_KID=${kid}`);
console.log(`CRM_ACCESS_TOKEN_SECRET_CURRENT=${secret}`);
