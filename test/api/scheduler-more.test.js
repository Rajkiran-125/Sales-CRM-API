'use strict';

/**
 * The remaining scheduler jobs (V039, 12.18). They work on every row of the test database, so
 * the assertions look at this file's fixtures and afterAll removes the tasks they created.
 */
const { dba, closeAll, adminSession, createActiveUser, lastMail } = require('../helpers');
const { JOBS, runJob } = require('../../src/jobs/scheduler');
const { dueDayMorning } = require('../../src/jobs/moreJobs');
const { istMonday } = require('../../src/jobs/time');

const run = (name) => runJob(/** @type {any} */ (JOBS.find((j) => j.name === name)));
let admin, manager, exec;
const ids = /** @type {Record<string, number>} */ ({});
const WEEK = istMonday(new Date());

beforeAll(async () => {
  admin = await adminSession();
  manager = await createActiveUser(admin.token, {
    email: 'jm.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'jm.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  const c = await dba();
  const ins = async (sql, args) => /** @type {any} */ ((await c.query(sql, args))[0]).insertId;
  ids.acc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('JM-ACC-1', 'Jobs Corp', ?)`,
    [exec.id],
  );
  const opp = (no, stage, extra = '') =>
    ins(
      `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
         weighted_value, expected_close_date, owner_user_id${extra ? ', ' + extra.split('=')[0] : ''})
       VALUES (?, ?, ?, 'DIRECT', ?, 1000000, 200000, '2099-01-01', ?${extra ? ', ' + extra.split('=')[1] : ''})`,
      [no, `Deal ${no}`, ids.acc, stage, exec.id],
    );
  ids.open = await opp(
    'JM-OPP-OPEN',
    'PROPOSAL',
    'stage_entered_at=UTC_TIMESTAMP(3) - INTERVAL 100 DAY',
  );
  ids.dormant = await opp('JM-OPP-DORM', 'DORMANT', 'wake_up_date=CURDATE() - INTERVAL 1 DAY');
  ids.order = await ins(
    `INSERT INTO sales_order (order_no, opportunity_id, account_id, po_number, po_date, po_value, status)
     VALUES ('JM-ORD-1', ?, ?, 'PO-JM', CURDATE() - INTERVAL 40 DAY, 1000000, 'PO_RECEIVED')`,
    [ids.open, ids.acc],
  );
  ids.invoice = await ins(
    `INSERT INTO invoice (order_id, invoice_no, invoice_date, due_date, amount)
     VALUES (?, 'JM-INV-1', CURDATE() - INTERVAL 31 DAY, CURDATE() - INTERVAL 1 DAY, 500000)`,
    [ids.order],
  );
  await c.query(
    `INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at, status, source_ref)
     VALUES ('OPP', ?, 'WEEKLY_STATUS', 'Weekly status', ?, UTC_TIMESTAMP(3), 'OPEN', ?)`,
    [ids.open, exec.id, `WS:${ids.open}:${WEEK}`],
  );
});

afterAll(async () => {
  const c = await dba();
  await c.query(
    `DELETE FROM task WHERE source_ref LIKE 'MC:%' OR source_ref LIKE 'WAKE:%' OR source_ref LIKE 'INV:%'
        OR source_ref = ?`,
    [`WS:${ids.open}:${WEEK}`],
  );
  await closeAll();
});

describe('more scheduler jobs (V039)', () => {
  test('dueDayMorning: this week once the due day has passed, else last week', () => {
    // Wednesday 2026-10-14 12:00 IST
    const wed = new Date('2026-10-14T06:30:00Z');
    expect(dueDayMorning(wed, 'MONDAY').toISOString()).toBe('2026-10-12T03:30:00.000Z');
    expect(dueDayMorning(wed, 'FRIDAY').toISOString()).toBe('2026-10-09T03:30:00.000Z');
  });

  test('weekly status reminder: one email per owner, once', async () => {
    expect((await run('weekly-status-reminder')).status).toBe('SUCCESS');
    const mail = await lastMail('jm.exec@test.local', 'WEEKLY_STATUS_REMINDER');
    expect(mail).not.toBeNull();
    const c = await dba();
    const [[t]] = await c.query('SELECT reminder_sent_at AS at FROM task WHERE source_ref = ?', [
      `WS:${ids.open}:${WEEK}`,
    ]);
    expect(t.at).not.toBeNull();
  });

  test('wake-up: a task and an email once per wake-up date', async () => {
    await run('wake-up');
    await run('wake-up');
    const c = await dba();
    const [[n]] = await c.query(
      `SELECT COUNT(*) AS n FROM task WHERE task_type = 'WAKE_UP' AND entity_id = ?`,
      [ids.dormant],
    );
    expect(n.n).toBe(1);
    expect(await lastMail('jm.exec@test.local', 'DEAL_WAKE_UP')).not.toBeNull();
  });

  test('invoice due: past due becomes OVERDUE with one task for the deal owner', async () => {
    await run('invoice-due');
    await run('invoice-due');
    const c = await dba();
    const [[inv]] = await c.query('SELECT status FROM invoice WHERE id = ?', [ids.invoice]);
    expect(inv.status).toBe('OVERDUE');
    const [tasks] = await c.query('SELECT owner_user_id AS o FROM task WHERE source_ref = ?', [
      `INV:${ids.invoice}`,
    ]);
    expect(tasks).toEqual([{ o: exec.id }]);
  });

  test('stage ageing: the manager gets the digest', async () => {
    await run('stage-ageing');
    const mail = await lastMail('jm.manager@test.local', 'STAGE_AGEING_DIGEST');
    expect(mail).not.toBeNull();
    expect(JSON.stringify(mail)).toContain('JM-OPP-OPEN');
  });

  test('monthly close: a commit task for the owner; housekeeping and engagement reminder run', async () => {
    expect((await run('monthly-close')).status).toBe('SUCCESS');
    const c = await dba();
    const [[t]] = await c.query(
      `SELECT COUNT(*) AS n FROM task WHERE task_type = 'MONTHLY_COMMIT' AND owner_user_id = ?`,
      [exec.id],
    );
    expect(t.n).toBe(1);
    expect((await run('housekeeping')).status).toBe('SUCCESS');
    expect((await run('engagement-reminder')).status).toBe('SUCCESS');
  });
});
