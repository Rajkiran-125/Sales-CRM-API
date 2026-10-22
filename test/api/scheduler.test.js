'use strict';

/**
 * Scheduler jobs (V025): weekly status tasks, Monday report, stale deals, close-date slip,
 * the job lock and the run log. The jobs work on every deal of the test database, so the
 * assertions look at this file's fixtures and afterAll undoes what the jobs changed.
 */
const {
  api,
  dba,
  closeAll,
  adminSession,
  createActiveUser,
  bearer,
  lastMail,
} = require('../helpers');
const { JOBS, runJob } = require('../../src/jobs/scheduler');
const { istMonday } = require('../../src/jobs/time');

const job = (name) => JOBS.find((j) => j.name === name);
let admin, manager, exec, head;
const ids = /** @type {Record<string, number>} */ ({});
const WEEK = istMonday(new Date());

beforeAll(async () => {
  admin = await adminSession();
  manager = await createActiveUser(admin.token, {
    email: 'sch.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'sch.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  head = await createActiveUser(admin.token, {
    email: 'sch.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  const ins = async (sql, args) => /** @type {any} */ ((await c.query(sql, args))[0]).insertId;
  ids.acc = await ins(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('SCH-ACC-1', 'Sched Corp', ?)`,
    [exec.id],
  );
  const opp = (no, close, createdDaysAgo) =>
    ins(
      `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
         weighted_value, expected_close_date, owner_user_id, created_at)
       VALUES (?, ?, ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, ?, ?, UTC_TIMESTAMP(3) - INTERVAL ? DAY)`,
      [no, `Deal ${no}`, ids.acc, close, exec.id, createdDaysAgo],
    );
  ids.quiet = await opp('SCH-OPP-QUIET', '2099-01-01', 100);
  ids.slipped = await opp('SCH-OPP-SLIP', '2020-01-01', 1);
  ids.fine = await opp('SCH-OPP-FINE', '2099-01-01', 1);
});

afterAll(async () => {
  // undo the jobs' changes so later suites see the data they expect
  const c = await dba();
  await c.query(`DELETE FROM task WHERE source_ref LIKE 'WS:%' OR source_ref LIKE 'SLIP:%'`);
  await c.query(
    `UPDATE opportunity SET health = 'ON_TRACK'
      WHERE id IN (SELECT entity_id FROM audit_log WHERE action IN ('HEALTH_STALE', 'HEALTH_SLIPPED'))`,
  );
  await c.query(`UPDATE opportunity SET is_active = 0 WHERE opportunity_no LIKE 'SCH-OPP-%'`);
  await closeAll();
});

const health = async (id) => {
  const c = await dba();
  return (await c.query('SELECT health FROM opportunity WHERE id = ?', [id]))[0][0].health;
};

describe('weekly-status-tasks', () => {
  test('one task per open deal, due on the set day and time (IST); a re-run adds none', async () => {
    const first = await runJob(job('weekly-status-tasks'));
    expect(first.status).toBe('SUCCESS');
    const c = await dba();
    const [[t]] = await c.query(
      `SELECT task_type AS type, owner_user_id AS owner, status, due_at AS dueAt FROM task WHERE source_ref = ?`,
      [`WS:${ids.fine}:${WEEK}`],
    );
    expect(t).toMatchObject({ type: 'WEEKLY_STATUS', owner: exec.id, status: 'OPEN' });
    // the configuration suite may have changed the due day (default FRIDAY 18:00)
    const [settings] = await c.query(
      `SELECT setting_key AS k, setting_value AS v FROM setting
        WHERE setting_key IN ('weekly_status.due_day', 'weekly_status.due_time')`,
    );
    const s = Object.fromEntries(settings.map((r) => [r.k, r.v]));
    const days = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
    const due = new Date(`${WEEK}T${s['weekly_status.due_time']}:00+05:30`);
    due.setUTCDate(due.getUTCDate() + days.indexOf(s['weekly_status.due_day']));
    expect(new Date(t.dueAt).toISOString()).toBe(due.toISOString());

    const again = await runJob(job('weekly-status-tasks'));
    expect(again).toMatchObject({ status: 'SUCCESS', processed: 0 });
  });

  test('submitting the weekly status closes the task', async () => {
    const res = await api().post('/api/v1/weekly-status').set(bearer(exec.token)).send({
      opportunityId: ids.fine,
      weekStart: WEEK,
      status: 'ON_TRACK',
      thisWeek: 'Demo done.',
      nextStep: 'Proposal.',
    });
    expect(res.status).toBe(200);
    const c = await dba();
    const [[t]] = await c.query(
      'SELECT status, completed_by AS doneBy FROM task WHERE source_ref = ?',
      [`WS:${ids.fine}:${WEEK}`],
    );
    expect(t).toEqual({ status: 'DONE', doneBy: exec.id });
  });
});

describe('stale-deals', () => {
  test('a quiet deal turns STALE; owner and manager are emailed once', async () => {
    const r = await runJob(job('stale-deals'));
    expect(r.status).toBe('SUCCESS');
    expect(await health(ids.quiet)).toBe('STALE');
    expect(await health(ids.fine)).toBe('ON_TRACK');
    const toOwner = await lastMail(exec.email, 'DEAL_STALE');
    expect(toOwner.subject).toContain('SCH-OPP-QUIET');
    expect(await lastMail(manager.email, 'DEAL_STALE')).not.toBeNull();

    const again = await runJob(job('stale-deals'));
    const c = await dba();
    const [[n]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE action = 'HEALTH_STALE' AND entity_id = ?`,
      [ids.quiet],
    );
    expect(again.status).toBe('SUCCESS');
    expect(n.n).toBe(1);
  });
});

describe('close-date-slip', () => {
  test('a past close date: SLIPPED + one CLOSE_DATE task; a new date puts it back', async () => {
    expect((await runJob(job('close-date-slip'))).status).toBe('SUCCESS');
    expect(await health(ids.slipped)).toBe('SLIPPED');
    const c = await dba();
    const [tasks] = await c.query(`SELECT task_type AS t FROM task WHERE source_ref = ?`, [
      `SLIP:${ids.slipped}:2020-01-01`,
    ]);
    expect(tasks).toEqual([{ t: 'CLOSE_DATE' }]);

    await runJob(job('close-date-slip'));
    const [again] = await c.query(`SELECT id FROM task WHERE source_ref LIKE ?`, [
      `SLIP:${ids.slipped}:%`,
    ]);
    expect(again).toHaveLength(1);

    await c.query(`UPDATE opportunity SET expected_close_date = '2099-06-30' WHERE id = ?`, [
      ids.slipped,
    ]);
    await runJob(job('close-date-slip'));
    expect(await health(ids.slipped)).toBe('ON_TRACK');
  });
});

describe('monday-report', () => {
  test('the sales head gets the report for last week', async () => {
    const r = await runJob(job('monday-report'));
    expect(r.status).toBe('SUCCESS');
    expect(r.processed).toBeGreaterThanOrEqual(1);
    const mail = await lastMail(head.email, 'WEEKLY_STATUS_REPORT');
    expect(mail.subject).toMatch(/^Weekly status report, week of \d{4}-\d{2}-\d{2}$/);
    expect(mail.text).toContain('Open deals:');
  });
});

describe('lock and run log', () => {
  test('a job held by another runner is skipped; runs are logged', async () => {
    const c = await dba();
    await c.query(
      `INSERT INTO job_lock (job_name, locked_until, locked_by) VALUES ('stale-deals', UTC_TIMESTAMP() + INTERVAL 5 MINUTE, 'other-host')
       ON DUPLICATE KEY UPDATE locked_until = VALUES(locked_until), locked_by = VALUES(locked_by)`,
    );
    expect((await runJob(job('stale-deals'))).status).toBe('LOCKED');
    await c.query(
      `UPDATE job_lock SET locked_until = NULL, locked_by = NULL WHERE job_name = 'stale-deals'`,
    );

    const [rows] = await c.query(
      `SELECT job_name AS j, status FROM job_run_log WHERE job_name IN ('weekly-status-tasks', 'monday-report')`,
    );
    expect(rows.every((r) => r.status === 'SUCCESS')).toBe(true);
    expect(new Set(rows.map((r) => r.j)).size).toBe(2);
  });
});
