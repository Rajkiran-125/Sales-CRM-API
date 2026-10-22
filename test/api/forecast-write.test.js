'use strict';

/**
 * Forecast write (V038, 12.10): monthly closure commits of own / team deals (BR-FC-03), the
 * manager's nudge giving one task per team member with weekly status pending.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, head, exec, other;
const ids = /** @type {Record<string, number>} */ ({});
const ist = new Date(Date.now() + 330 * 60000);
const month = ist.toISOString().slice(0, 7);
const monday = (() => {
  const d = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate()));
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
})();

beforeAll(async () => {
  admin = await adminSession();
  head = await createActiveUser(admin.token, {
    email: 'fw.head@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'fw.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: head.id,
  });
  other = await createActiveUser(admin.token, {
    email: 'fw.other@test.local',
    roles: ['SALES_EXEC'],
  });
  const c = await dba();
  const [acc] = await c.query(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('FW-ACC-1', 'Forecast Co', ?)`,
    [exec.id],
  );
  const [opp] = await c.query(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       weighted_value, expected_close_date, owner_user_id)
     VALUES ('FW-OPP-1', 'Forecast deal', ?, 'DIRECT', 'NEGOTIATION', 900000, 600000, LAST_DAY(CURDATE()), ?)`,
    [/** @type {any} */ (acc).insertId, exec.id],
  );
  ids.opp = /** @type {any} */ (opp).insertId;
});

afterAll(closeAll);

const commit = (token, items) =>
  api().put('/api/v1/forecast/monthly').set(bearer(token)).send({ month, items });

describe('monthly closure commits', () => {
  test('the owner commits; the manager may change it; someone else may not', async () => {
    const res = await commit(exec.token, [
      { opportunityId: ids.opp, commitType: 'COMMIT', commitValue: 900000 },
    ]);
    expect(res.status).toBe(200);
    expect(
      (
        await commit(head.token, [
          { opportunityId: ids.opp, commitType: 'UPSIDE', commitValue: 850000 },
        ])
      ).status,
    ).toBe(200);
    expect(
      (
        await commit(other.token, [
          { opportunityId: ids.opp, commitType: 'COMMIT', commitValue: 1 },
        ])
      ).status,
    ).toBe(403);
    const c = await dba();
    const [[row]] = await c.query(
      'SELECT commit_type AS t, commit_value AS v FROM monthly_commit WHERE opportunity_id = ?',
      [ids.opp],
    );
    expect(row).toEqual({ t: 'UPSIDE', v: '850000.00' });
  });

  test('a type without a value → 422; no type removes the commit', async () => {
    expect(
      (
        await commit(exec.token, [
          { opportunityId: ids.opp, commitType: 'COMMIT', commitValue: null },
        ])
      ).status,
    ).toBe(422);
    expect(
      (await commit(exec.token, [{ opportunityId: ids.opp, commitType: null, commitValue: null }]))
        .status,
    ).toBe(200);
    const c = await dba();
    const [[n]] = await c.query(
      'SELECT COUNT(*) AS n FROM monthly_commit WHERE opportunity_id = ?',
      [ids.opp],
    );
    expect(n.n).toBe(0);
  });
});

describe('POST /forecast/nudges', () => {
  test('the manager nudges: one task for the team member, again moves the same task', async () => {
    const res = await api()
      .post('/api/v1/forecast/nudges')
      .set(bearer(head.token))
      .send({ weekStart: monday });
    expect(res.status).toBe(200);
    expect(res.body.data.nudged).toBe(1);
    await api().post('/api/v1/forecast/nudges').set(bearer(head.token)).send({ weekStart: monday });
    const c = await dba();
    const [[t]] = await c.query(
      `SELECT COUNT(*) AS n FROM task WHERE source_ref = ? AND owner_user_id = ? AND status = 'OPEN'`,
      [`NUDGE:${exec.id}:${monday}`, exec.id],
    );
    expect(t.n).toBe(1);
  });

  test('a week that does not start on Monday → 422', async () => {
    const res = await api()
      .post('/api/v1/forecast/nudges')
      .set(bearer(head.token))
      .send({ weekStart: '2026-10-14' });
    expect(res.status).toBe(422);
  });
});
