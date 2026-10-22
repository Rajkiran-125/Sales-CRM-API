'use strict';

/** Targets (V040, OD-15) and the dashboard v2 cycle times tile. */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, head, exec;
const FY = 2096;

beforeAll(async () => {
  admin = await adminSession();
  head = await createActiveUser(admin.token, {
    email: 'tg.head@test.local',
    roles: ['SALES_HEAD'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'tg.exec@test.local',
    roles: ['SALES_EXEC'],
  });
});

afterAll(closeAll);

const put = (token, items) =>
  api().put('/api/v1/targets').set(bearer(token)).send({ fiscalYear: FY, quarter: 2, items });

describe('targets', () => {
  test('the sales head sets a quarter target; the list shows it; audited', async () => {
    const res = await put(head.token, [
      { ownerUserId: exec.id, targetValue: 5000000, targetCount: 4, newLogoTarget: 1 },
    ]);
    expect(res.status).toBe(200);
    const list = await api()
      .get(`/api/v1/targets?fiscalYear=${FY}&quarter=2`)
      .set(bearer(head.token));
    expect(list.body.data.find((u) => u.userId === exec.id)).toMatchObject({
      targetValue: '5000000.00',
      targetCount: 4,
      newLogoTarget: 1,
    });
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE action = 'TARGET_SET' AND entity_id = ?`,
      [exec.id],
    );
    expect(log.n).toBe(1);
  });

  test('zero clears the target; a sales exec cannot set targets', async () => {
    await put(head.token, [
      { ownerUserId: exec.id, targetValue: 0, targetCount: 0, newLogoTarget: null },
    ]);
    const c = await dba();
    const [[n]] = await c.query(
      'SELECT COUNT(*) AS n FROM target WHERE owner_user_id = ? AND fiscal_year = ?',
      [exec.id, FY],
    );
    expect(n.n).toBe(0);
    expect(
      (
        await put(exec.token, [
          { ownerUserId: exec.id, targetValue: 1, targetCount: 1, newLogoTarget: null },
        ])
      ).status,
    ).toBe(403);
  });
});

test('the dashboard has the cycle times tile', async () => {
  const res = await api().get('/api/v1/dashboard').set(bearer(head.token));
  expect(res.status).toBe(200);
  expect(Object.keys(res.body.data.cycleTimes).sort()).toEqual([
    'dealToWinDays',
    'leadToDealDays',
    'orderToBookDays',
  ]);
});
