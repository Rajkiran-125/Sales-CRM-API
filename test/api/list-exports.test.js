'use strict';

/** List exports (19.1 "every list screen also offers an Excel export"): leads, deals, orders. */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, presales;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'lx.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'lx.ps@test.local',
    roles: ['PRESALES'],
  });
});

afterAll(closeAll);

describe.each([
  ['/leads/export', 'LEAD'],
  ['/opportunities/export', 'OPPORTUNITY'],
  ['/orders/export', 'ORDER'],
])('GET %s', (path, entity) => {
  test('xlsx within scope; logged as EXPORT', async () => {
    const res = await api().get(`/api/v1${path}`).set(bearer(exec.token));
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/spreadsheetml/);
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM record_access_log WHERE user_id = ? AND entity_type = ? AND access_type = 'EXPORT'`,
      [exec.id, entity],
    );
    expect(log.n).toBe(1);
  });
});

test('pre-sales has no lead.export → 403', async () => {
  expect((await api().get('/api/v1/leads/export').set(bearer(presales.token))).status).toBe(403);
});
