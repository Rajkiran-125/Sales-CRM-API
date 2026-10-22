'use strict';

/** Reports catalogue (19.1): the list per permissions, every Excel report exports and is logged. */
const ExcelJS = require('exceljs');
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, head, presales;
let accountId;

beforeAll(async () => {
  admin = await adminSession();
  head = await createActiveUser(admin.token, {
    email: 'rc.head@test.local',
    roles: ['SALES_HEAD'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'rc.ps@test.local',
    roles: ['PRESALES'],
  });
  const c = await dba();
  const [acc] = await c.query(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('RC-ACC-1', 'Report Co', ?)`,
    [head.id],
  );
  accountId = /** @type {any} */ (acc).insertId;
});

afterAll(closeAll);

/** @param {string} url */
const xlsx = (url) =>
  api()
    .get(url)
    .set(bearer(head.token))
    .buffer(true)
    .parse((r, cb) => {
      const chunks = [];
      r.on('data', (ch) => chunks.push(ch));
      r.on('end', () => cb(null, Buffer.concat(chunks)));
    });

test('the catalogue lists the ten reports for the sales head', async () => {
  const res = await api().get('/api/v1/reports').set(bearer(head.token));
  expect(res.status).toBe(200);
  expect(res.body.data.map((r) => r.code)).toHaveLength(10);
  expect(res.body.data.find((r) => r.code === 'PARTNER_QUARTERLY')).toMatchObject({
    output: 'PDF',
  });
});

test.each([
  ['WEEKLY_STATUS', '?team=true', 1],
  ['MONTHLY_CLOSURE', '', 1],
  ['HIERARCHY_FUNNEL', '', 1],
  ['WIN_LOSS', '', 1],
  ['ACCOUNT_360', '?accountId=ACC', 4],
  ['TENDER_PIPELINE', '', 1],
  ['PRODUCT_MIX', '', 2],
  ['REVENUE_GM', '?dimension=PARTNER', 1],
  ['PARTNER_SCORECARD', '', 1],
])('%s exports to Excel', async (code, query, sheets) => {
  const res = await xlsx(
    `/api/v1/reports/${code}/export${query.replace('ACC', String(accountId))}`,
  );
  expect(res.status).toBe(200);
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(res.body);
  expect(wb.worksheets).toHaveLength(sheets);
});

test('exports are logged; the PDF report and a missing account are 422; no view permission → 403', async () => {
  const c = await dba();
  const [[log]] = await c.query(
    `SELECT COUNT(*) AS n FROM record_access_log WHERE user_id = ? AND entity_type LIKE 'REPORT_%' AND access_type = 'EXPORT'`,
    [head.id],
  );
  expect(log.n).toBeGreaterThanOrEqual(9);
  expect(
    (await api().get('/api/v1/reports/PARTNER_QUARTERLY/export').set(bearer(head.token))).status,
  ).toBe(422);
  expect(
    (await api().get('/api/v1/reports/ACCOUNT_360/export').set(bearer(head.token))).status,
  ).toBe(422);
  expect(
    (await api().get('/api/v1/reports/WIN_LOSS/export').set(bearer(presales.token))).status,
  ).toBe(403);
});
