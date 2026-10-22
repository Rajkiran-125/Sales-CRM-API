// @ts-check
'use strict';

/**
 * Create the first CRM Admin (tech doc 11.5) and print a one-time invitation link.
 * No default password ships with the system. Refused once any CRM Admin exists.
 *
 *   npm run bootstrap:admin -- --email admin@cnergee.com --name "CRM Admin"
 */
const { parseArgs } = require('util');
const config = require('../config');
const db = require('../db/pool');
const { randomToken, sha256, uuid } = require('../shared/crypto');

async function main() {
  const { values } = parseArgs({
    options: { email: { type: 'string' }, name: { type: 'string' } },
  });
  const email = (values.email || '').trim().toLowerCase();
  const name = (values.name || '').trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || name.length < 2) {
    console.error('Usage: npm run bootstrap:admin -- --email <work email> --name "<full name>"');
    process.exitCode = 2;
    return;
  }

  const token = randomToken();
  try {
    const row = await db.callProcedureOne('sp_user_bootstrap_admin', [
      email,
      name,
      sha256(token),
      '127.0.0.1',
      `cli-${uuid()}`,
    ]);
    if (!row) throw new Error('The procedure returned no row.');
    const link = `${config.uiBaseUrl}/accept-invitation?token=${encodeURIComponent(token)}`;
    console.log(`\nCRM Admin created: ${row.fullName} <${row.email}> (user id ${row.id}).`);
    console.log(
      `Valid until ${new Date(row.expiresAt).toISOString()} (UTC). Open this link once to set the password:\n`,
    );
    console.log(`  ${link}\n`);
    console.log('Share it only with that person, over a private channel. It works once.');
  } catch (err) {
    console.error(`Could not create the CRM Admin: ${/** @type {Error} */ (err).message}`);
    process.exitCode = 1;
  } finally {
    await db.close();
  }
}

main();
