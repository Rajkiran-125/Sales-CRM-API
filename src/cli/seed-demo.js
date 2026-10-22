// @ts-check
'use strict';

/**
 * Demo data for showing Phase 0 (never for production): a sales team of 20 people in a
 * reporting hierarchy across the seven roles, a few extra master entries, and real sign-in
 * activity. Everything goes through the same procedures and services as the app, so every
 * rule applies and the audit log records it. Safe to re-run: existing entries are skipped.
 *
 *   npm run seed:demo
 *   npm run seed:demo -- --password "<shared demo password>"
 */
const { parseArgs } = require('util');
const config = require('../config');
const db = require('../db/pool');
const mailer = require('../integrations/mailer');
const usersRepo = require('../modules/users/users.repository');
const usersService = require('../modules/users/users.service');
const authRepo = require('../modules/auth/auth.repository');
const authService = require('../modules/auth/auth.service');
const rolesRepo = require('../modules/roles/roles.repository');
const masters = require('../modules/masters/masters.repository');
const { checkPasswordPolicy } = require('../auth/passwordPolicy');
const { randomToken, sha256, uuid } = require('../shared/crypto');

const DEFAULT_PASSWORD = 'Demo-Team-2026!';
// .test is reserved (RFC 2606): demo emails can never reach a real mailbox
const DOMAIN = 'cnergee.test';

/**
 * Managers come before the people who report to them.
 * state: active (default), invited (never accepted), locked (too many failed sign-ins),
 * inactive (deactivated with a reason).
 * @typedef {{ key?: string, name: string, designation: string, department: string, roles: string[], manager?: string, state?: 'invited' | 'locked' | 'inactive' }} Member
 * @type {Member[]}
 */
const TEAM = [
  {
    key: 'md',
    name: 'Arvind Kulkarni',
    designation: 'Managing Director',
    department: 'Management',
    roles: ['MANAGEMENT'],
  },
  {
    key: 'head',
    name: 'Vikram Mehta',
    designation: 'Head of Sales',
    department: 'Sales',
    roles: ['SALES_HEAD'],
    manager: 'md',
  },
  {
    key: 'west',
    name: 'Neha Joshi',
    designation: 'Regional Sales Manager - West',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'head',
  },
  {
    key: 'south',
    name: 'Karthik Raman',
    designation: 'Regional Sales Manager - South',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'head',
  },
  {
    key: 'north',
    name: 'Amandeep Singh',
    designation: 'Regional Sales Manager - North',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'head',
  },
  {
    name: 'Rohan Deshpande',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'west',
  },
  {
    name: 'Sneha Patil',
    designation: 'Senior Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'west',
  },
  {
    name: 'Imran Shaikh',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'west',
    state: 'inactive',
  },
  {
    name: 'Divya Narayanan',
    designation: 'Senior Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'south',
  },
  {
    name: 'Arjun Rao',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'south',
  },
  {
    name: 'Lakshmi Iyer',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'south',
  },
  {
    name: 'Pooja Sharma',
    designation: 'Senior Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'north',
  },
  {
    name: 'Rahul Verma',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'north',
    state: 'locked',
  },
  {
    name: 'Simran Kaur',
    designation: 'Sales Executive',
    department: 'Sales',
    roles: ['SALES_EXEC'],
    manager: 'north',
    state: 'invited',
  },
  {
    key: 'presales',
    name: 'Sanjay Gupta',
    designation: 'Pre-sales Lead',
    department: 'Pre-sales',
    roles: ['PRESALES'],
    manager: 'head',
  },
  {
    name: 'Ananya Bose',
    designation: 'Pre-sales Engineer',
    department: 'Pre-sales',
    roles: ['PRESALES'],
    manager: 'presales',
  },
  {
    name: 'Farhan Qureshi',
    designation: 'Partner Manager',
    department: 'Channels',
    roles: ['PARTNER_MGR', 'SALES_EXEC'],
    manager: 'head',
  },
  {
    key: 'finance',
    name: 'Meera Nair',
    designation: 'Finance Manager',
    department: 'Finance',
    roles: ['FINANCE'],
    manager: 'md',
  },
  {
    name: 'Suresh Pillai',
    designation: 'Accounts Executive',
    department: 'Finance',
    roles: ['FINANCE'],
    manager: 'finance',
  },
  { name: 'Kavita Rao', designation: 'CRM Administrator', department: 'IT', roles: ['CRM_ADMIN'] },
];

const INDUSTRIES = [
  { code: 'MANUFACTURING', name: 'Manufacturing' },
  { code: 'IT_ITES', name: 'IT / ITeS' },
  { code: 'HOSPITALITY', name: 'Hospitality' },
  { code: 'LOGISTICS', name: 'Logistics' },
];

const COMPETITORS = [
  { name: 'Palo Alto Networks', products: 'Firewall, SD-WAN, Endpoint' },
  { name: 'Sophos', products: 'Firewall, Endpoint' },
  { name: 'Check Point', products: 'Firewall' },
  { name: 'Juniper Networks', products: 'SD-WAN, Wi-Fi' },
];

/** Solutions under the products seeded by V002 (by product code). */
const SOLUTIONS = [
  { product: 'SDWAN', name: 'Branch SD-WAN with dual ISP' },
  { product: 'FIREWALL', name: 'Perimeter firewall with HA pair' },
  { product: 'WIFI', name: 'Campus Wi-Fi with guest access' },
  { product: 'ENDPOINT', name: 'Endpoint protection with central console' },
];

/** @param {string} name */
const emailOf = (name) => `${name.toLowerCase().replace(/\s+/g, '.')}@${DOMAIN}`;

/**
 * Request context for the procedures: actor null = the person themself (sign-in, invitation).
 * @param {number | null} actorUserId
 */
const meta = (actorUserId) => ({
  actorUserId,
  requestId: `seed-demo-${uuid()}`,
  ip: '127.0.0.1',
  userAgent: 'seed-demo',
});

/** @param {Member} m */
function stateLabel(m) {
  return m.state
    ? { invited: 'Invited', locked: 'Locked', inactive: 'Inactive' }[m.state]
    : 'Active';
}

/** @returns {Promise<number>} id of the first active CRM Admin (the actor for every change) */
async function findAdmin() {
  const adminRole = (await rolesRepo.list(true)).find((r) => r.code === 'CRM_ADMIN');
  const { rows } = adminRole
    ? await usersRepo.list({
        status: 'ACTIVE',
        roleId: Number(adminRole.id),
        sort: 'createdAt',
        offset: 0,
        limit: 1,
      })
    : { rows: [] };
  if (!rows.length) {
    throw new Error(
      'No active CRM Admin yet. Run `npm run bootstrap:admin` and set its password first.',
    );
  }
  return Number(rows[0].id);
}

/**
 * @param {number} adminId
 * @param {string} password
 */
async function seedTeam(adminId, password) {
  const roleIds = new Map((await rolesRepo.list(true)).map((r) => [r.code, Number(r.id)]));
  const settings = await authRepo.settingValues(['auth.lockout.threshold']);
  const threshold = Number(settings.find((s) => s.key === 'auth.lockout.threshold')?.value ?? 5);
  /** @type {Map<string, number>} */
  const ids = new Map();
  let created = 0;

  for (const m of TEAM) {
    const email = emailOf(m.name);
    const existing = await authRepo.getLoginUser(email);
    if (existing) {
      if (m.key) ids.set(m.key, Number(existing.id));
      continue;
    }

    const token = randomToken();
    const user = await usersRepo.create(
      {
        email,
        fullName: m.name,
        mobile: null,
        designation: m.designation,
        department: m.department,
        reportingToUserId: m.manager ? (ids.get(m.manager) ?? null) : null,
        roleIds: m.roles.map((code) => {
          const id = roleIds.get(code);
          if (!id) throw new Error(`Role ${code} is missing: run the V002 script first.`);
          return id;
        }),
      },
      sha256(token),
      meta(adminId),
    );
    if (!user) throw new Error(`sp_user_create returned no row for ${email}`);
    const id = Number(user.id);
    if (m.key) ids.set(m.key, id);
    created += 1;

    if (m.state === 'invited') {
      // the invitation email lands in the mail folder, like any new user
      authService.sendInvitation(user, token);
      continue;
    }

    await authService.useLink(token, 'INVITE', password, meta(null));
    await authService.login({ email, password }, meta(null));

    if (m.state === 'locked') {
      for (let i = 0; i < threshold; i += 1) {
        await authService
          .login({ email, password: `not-the-password-${i}` }, meta(null))
          .catch(() => undefined);
      }
    }
    if (m.state === 'inactive') {
      await usersService.setStatus(
        id,
        { status: 'INACTIVE', reason: 'Left the company (demo data).' },
        meta(adminId),
      );
    }
  }
  return created;
}

/** @param {number} adminId */
async function seedMasters(adminId) {
  let created = 0;

  const industries = await masters.simple.list('INDUSTRY', true);
  let sort = industries.reduce((max, r) => Math.max(max, Number(r.sortOrder ?? 0)), 0);
  for (const ind of INDUSTRIES) {
    if (industries.some((r) => r.code === ind.code)) continue;
    sort += 1;
    await masters.simple.create('INDUSTRY', { ...ind, sortOrder: sort }, meta(adminId));
    created += 1;
  }

  const competitors = await masters.competitor.list(null, true);
  for (const c of COMPETITORS) {
    if (competitors.some((r) => String(r.name).toLowerCase() === c.name.toLowerCase())) continue;
    await masters.competitor.create({ ...c, strengths: null, weaknesses: null }, meta(adminId));
    created += 1;
  }

  const products = await masters.simple.list('PRODUCT', true);
  for (const s of SOLUTIONS) {
    const product = products.find((p) => p.code === s.product);
    if (!product) continue;
    const existing = await masters.solution.list({ productId: Number(product.id) }, true);
    if (existing.some((r) => String(r.name).toLowerCase() === s.name.toLowerCase())) continue;
    await masters.solution.create(
      {
        productId: Number(product.id),
        name: s.name,
        description: null,
        sortOrder: existing.length + 1,
      },
      meta(adminId),
    );
    created += 1;
  }
  return created;
}

async function main() {
  const { values } = parseArgs({ options: { password: { type: 'string' } } });
  const password = values.password ?? DEFAULT_PASSWORD;

  if (config.isProduction) {
    console.error('Refused: demo data is never loaded into production (NODE_ENV=production).');
    process.exitCode = 2;
    return;
  }
  const problems = new Set(
    TEAM.flatMap((m) =>
      checkPasswordPolicy(password, { email: emailOf(m.name), fullName: m.name }),
    ),
  );
  if (problems.size) {
    console.error(
      `The demo password is not accepted by the password policy:\n  ${[...problems].join('\n  ')}`,
    );
    process.exitCode = 2;
    return;
  }

  console.log(
    `Loading demo data into ${config.db.database} on ${config.db.host}:${config.db.port} ...`,
  );
  try {
    const adminId = await findAdmin();
    const users = await seedTeam(adminId, password);
    const entries = await seedMasters(adminId);
    await mailer.flush();

    console.log(
      `\nDone: ${users} new users, ${entries} new master entries (existing ones were skipped).\n`,
    );
    console.log(`Every demo user signs in with the password: ${password}\n`);
    for (const m of TEAM) {
      console.log(
        `  ${emailOf(m.name).padEnd(34)} ${m.roles.join(' + ').padEnd(24)} ${stateLabel(m)}`,
      );
    }
    console.log(
      "\nSimran Kaur's invitation is still open: the email is in the mail folder" +
        ` (${config.mail.transport === 'file' ? config.mail.fileDir : 'SMTP'}).`,
    );
    console.log('Rahul Verma is locked after too many wrong passwords: unlock from the user page.');
  } catch (err) {
    console.error(`Could not load the demo data: ${/** @type {Error} */ (err).message}`);
    process.exitCode = 1;
  } finally {
    await mailer.flush();
    await db.close();
  }
}

main();
