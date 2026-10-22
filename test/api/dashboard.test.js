'use strict';

/**
 * Management dashboard v1 (12.2, 14.3): the numbers, their reconciliation, filters,
 * drill-down and the data scope of every role (10.8).
 *
 * Fixture (dates relative to today, IST, so it is always inside the current quarter/month):
 *   O1 exec1  NEGOTIATION  10,00,000  weighted 7,00,000   closes today   COMMIT this month
 *   O2 exec2  PROPOSAL     20,00,000  weighted 10,00,000  closes today   partner P (SOURCED)
 *   O3 exec1  WON           5,00,000  PO 4,80,000         closed now
 *   O4 exec2  LOST          8,00,000  reason PRICE        closed now
 *   O5 exec1  QUALIFIED     3,00,000                      closes 2099 (outside every period)
 * Reporting line: manager <- exec1; head <- exec2. The partner manager owns partner P.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, manager, exec1, exec2, partnerMgr, finance, noDashboard;
const todayIst = new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);

/**
 * @param {import('mysql2/promise').Connection} c
 * @param {Record<string, unknown>} o
 */
async function insertDeal(c, o) {
  const [res] = await c.query(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       currency, fx_rate, weighted_value, expected_close_date, owner_user_id, po_value, closed_at,
       created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3) - INTERVAL 30 DAY)`,
    [
      o.no,
      o.title,
      o.accountId,
      o.source ?? 'DIRECT',
      o.stage,
      o.value,
      o.currency ?? 'INR',
      o.fxRate ?? 1,
      o.weighted ?? 0,
      o.close ?? null,
      o.owner,
      o.po ?? null,
      o.closed ? new Date() : null,
    ],
  );
  return /** @type {any} */ (res).insertId;
}

beforeAll(async () => {
  admin = await adminSession();
  manager = await createActiveUser(admin.token, {
    email: 'dash.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec1 = await createActiveUser(admin.token, {
    email: 'dash.exec1@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  const head = await createActiveUser(admin.token, {
    email: 'dash.head@test.local',
    roles: ['SALES_HEAD'],
  });
  exec2 = await createActiveUser(admin.token, {
    email: 'dash.exec2@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: head.id,
  });
  partnerMgr = await createActiveUser(admin.token, {
    email: 'dash.partners@test.local',
    roles: ['PARTNER_MGR'],
  });
  finance = await createActiveUser(admin.token, {
    email: 'dash.finance@test.local',
    roles: ['FINANCE'],
  });

  const role = await api()
    .post('/api/v1/roles')
    .set(bearer(admin.token))
    .send({
      code: 'NO_DASHBOARD',
      name: 'No dashboard',
      dataScope: 'ALL',
      permissionCodes: ['lead.view'],
    });
  expect(role.status).toBe(201);
  noDashboard = await createActiveUser(admin.token, {
    email: 'dash.none@test.local',
    roles: ['NO_DASHBOARD'],
  });

  const c = await dba();
  const [acc] = await c.query(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('T-ACC-1', 'Dashboard Test Account', ?)`,
    [exec1.id],
  );
  const accountId = /** @type {any} */ (acc).insertId;
  const [ptr] = await c.query(
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('T-PTR-1', 'Dashboard Test Partner Pvt Ltd', 'Test Partner', 'India', ?)`,
    [partnerMgr.id],
  );
  const partnerId = /** @type {any} */ (ptr).insertId;

  const o1 = await insertDeal(c, {
    no: 'T-OPP-1',
    title: 'Deal one',
    accountId,
    stage: 'NEGOTIATION',
    value: 1000000,
    weighted: 700000,
    close: todayIst,
    owner: exec1.id,
  });
  const o2 = await insertDeal(c, {
    no: 'T-OPP-2',
    title: 'Deal two',
    accountId,
    source: 'PARTNER',
    stage: 'PROPOSAL',
    value: 2000000,
    weighted: 1000000,
    close: todayIst,
    owner: exec2.id,
  });
  await insertDeal(c, {
    no: 'T-OPP-3',
    title: 'Deal three',
    accountId,
    stage: 'WON',
    value: 500000,
    weighted: 500000,
    close: todayIst,
    owner: exec1.id,
    po: 480000,
    closed: true,
  });
  const o4 = await insertDeal(c, {
    no: 'T-OPP-4',
    title: 'Deal four',
    accountId,
    stage: 'LOST',
    value: 800000,
    close: todayIst,
    owner: exec2.id,
    closed: true,
  });
  await insertDeal(c, {
    no: 'T-OPP-5',
    title: 'Deal five',
    accountId,
    stage: 'QUALIFIED',
    value: 300000,
    weighted: 60000,
    close: '2099-01-01',
    owner: exec1.id,
  });

  await c.query(
    `INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, is_primary) VALUES (?, ?, 'SOURCED', 1)`,
    [o2, partnerId],
  );
  await c.query(
    `INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value)
     VALUES (?, DATE_FORMAT(?, '%Y-%m-01'), 'COMMIT', 1000000)`,
    [o1, todayIst],
  );
  await c.query(
    `INSERT INTO win_loss (opportunity_id, outcome, loss_reason_id, detail, recorded_by)
     SELECT ?, 'LOST', id, 'Lost on price to a cheaper bid.', ? FROM reason WHERE reason_type = 'LOSS' AND code = 'PRICE'`,
    [o4, exec2.id],
  );
});
afterAll(closeAll);

/** @param {string} token @param {string} [query] */
const dashboard = (token, query = '') => api().get(`/api/v1/dashboard${query}`).set(bearer(token));

describe('dashboard', () => {
  test('needs a session and dashboard.view', async () => {
    expect((await api().get('/api/v1/dashboard')).status).toBe(401);
    const denied = await dashboard(noDashboard.token);
    expect(denied.status).toBe(403);
  });

  test('a CRM Admin (ALL scope) sees every deal, and the tiles reconcile', async () => {
    const res = await dashboard(admin.token);
    expect(res.status).toBe(200);
    const d = res.body.data;

    expect(d.period.label).toMatch(/^FY \d{4}-\d{2} Q[1-4]$/);
    expect(d.period.fromDate <= todayIst && todayIst <= d.period.toDate).toBe(true);
    expect(d.kpi).toMatchObject({
      openCount: 2,
      openValue: '3000000.00',
      weightedValue: '1700000.00',
      thisMonthCount: 2,
      thisMonthValue: '3000000.00',
      committedCount: 1,
      committedValue: '1000000.00',
      wonCount: 1,
      wonValue: '480000.00',
      lostCount: 1,
      lostValue: '800000.00',
    });
    expect(d.winLoss).toMatchObject({ wonCount: 1, lostCount: 1, winRatePct: 50 });
    expect(d.winLoss.topLossReasons).toEqual([
      expect.objectContaining({ reasonName: 'Price', count: 1, value: '800000.00' }),
    ]);

    // money is a decimal string with 2 decimals (OD-27)
    expect(d.funnelByStage[0].value).toMatch(/^\d+\.\d{2}$/);
    // the funnel and the sources add up to the KPI (20: figures reconcile)
    const sum = (/** @type {any[]} */ rows, /** @type {string} */ k) =>
      rows.reduce((t, r) => t + Number(r[k]), 0);
    expect(sum(d.funnelByStage, 'count')).toBe(d.kpi.openCount);
    expect(sum(d.funnelByStage, 'value')).toBe(Number(d.kpi.openValue));
    expect(sum(d.funnelByStage, 'weighted')).toBe(Number(d.kpi.weightedValue));
    expect(sum(d.bySource, 'value')).toBe(Number(d.kpi.openValue));
    expect(d.funnelByStage.map((/** @type {any} */ s) => s.stageCode)).toEqual([
      'QUALIFIED',
      'TECH_ENGAGEMENT',
      'POC',
      'PROPOSAL',
      'NEGOTIATION',
      'COMMERCIAL_CLOSED',
      'CONTRACT_SIGNED',
    ]);
    expect(d.detail.map((/** @type {any} */ r) => r.opportunityNo)).toEqual(['T-OPP-2', 'T-OPP-1']);
    expect(d.closures).toEqual([
      expect.objectContaining({ ownerUserId: exec1.id, committed: '1000000.00' }),
    ]);
    expect(d.topPartners).toEqual([
      expect.objectContaining({
        partnerName: 'Test Partner',
        sourcedDeals: 1,
        pipelineValue: '2000000.00',
      }),
    ]);
    expect(d.filterOptions.owners.map((/** @type {any} */ o) => o.id)).toEqual(
      expect.arrayContaining([manager.id, exec1.id, exec2.id]),
    );
  });

  test('a manager sees the team, an executive only their own deals (OWN_AND_TEAM)', async () => {
    const m = (await dashboard(manager.token)).body.data;
    expect(m.kpi).toMatchObject({
      openCount: 1,
      openValue: '1000000.00',
      wonCount: 1,
      lostCount: 0,
    });

    const e2 = (await dashboard(exec2.token)).body.data;
    expect(e2.kpi).toMatchObject({
      openCount: 1,
      openValue: '2000000.00',
      wonCount: 0,
      lostCount: 1,
    });
    expect(e2.detail.map((/** @type {any} */ r) => r.opportunityNo)).toEqual(['T-OPP-2']);
    expect(e2.filterOptions.owners.map((/** @type {any} */ o) => o.id)).toEqual([exec2.id]);
  });

  test('a partner manager sees the deals of their partners; finance sees no deals (MODULE_LIMITED)', async () => {
    const p = (await dashboard(partnerMgr.token)).body.data;
    expect(p.kpi).toMatchObject({ openCount: 1, openValue: '2000000.00' });

    const f = (await dashboard(finance.token)).body.data;
    expect(f.kpi).toMatchObject({ openCount: 0, wonCount: 0, lostCount: 0 });
  });

  test('filters: owner (with team), source, whole fiscal year, and invalid input', async () => {
    const team = (await dashboard(admin.token, `?ownerUserId=${manager.id}`)).body.data;
    expect(team.kpi).toMatchObject({ openCount: 1, openValue: '1000000.00' });

    const partner = (await dashboard(admin.token, '?source=PARTNER')).body.data;
    expect(partner.kpi).toMatchObject({ openCount: 1, openValue: '2000000.00', targetValue: null });

    const current = (await dashboard(admin.token)).body.data.period;
    const year = (await dashboard(admin.token, `?fiscalYear=${current.fiscalYear}`)).body.data;
    expect(year.period).toMatchObject({ fiscalYear: current.fiscalYear, quarter: null });
    expect(year.period.label).toBe(current.label.replace(/ Q\d$/, ''));
    expect(year.kpi.openCount).toBe(2);

    expect((await dashboard(admin.token, '?quarter=2')).status).toBe(422);
    expect((await dashboard(admin.token, '?source=CARRIER_PIGEON')).status).toBe(422);
    expect((await dashboard(admin.token, '?unknown=1')).status).toBe(422);
  });

  test('drill-down lists the deals behind a tile, in scope and paged', async () => {
    const stage = await api()
      .get('/api/v1/dashboard/drill/STAGE?key=NEGOTIATION')
      .set(bearer(admin.token));
    expect(stage.status).toBe(200);
    expect(stage.body.data.map((/** @type {any} */ r) => r.opportunityNo)).toEqual(['T-OPP-1']);

    const open = await api()
      .get('/api/v1/dashboard/drill/open?pageSize=1')
      .set(bearer(admin.token));
    expect(open.body.meta).toMatchObject({ page: 1, pageSize: 1, total: 2 });
    expect(open.body.data).toHaveLength(1);

    const won = await api().get('/api/v1/dashboard/drill/WON').set(bearer(admin.token));
    expect(won.body.data[0]).toMatchObject({ opportunityNo: 'T-OPP-3', closedValue: '480000.00' });

    const scoped = await api().get('/api/v1/dashboard/drill/OPEN').set(bearer(exec2.token));
    expect(scoped.body.data.map((/** @type {any} */ r) => r.opportunityNo)).toEqual(['T-OPP-2']);

    expect((await api().get('/api/v1/dashboard/drill/NOPE').set(bearer(admin.token))).status).toBe(
      404,
    );
    expect((await api().get('/api/v1/dashboard/drill/STAGE').set(bearer(admin.token))).status).toBe(
      422,
    );
    expect(
      (await api().get('/api/v1/dashboard/drill/PARTNER?key=abc').set(bearer(admin.token))).status,
    ).toBe(422);
  });

  test('a foreign-currency deal counts in INR: value x fx rate, weighted already in INR (D-17)', async () => {
    const c = await dba();
    const [[acc]] = /** @type {any} */ (
      await c.query(`SELECT id FROM account WHERE account_no = 'T-ACC-1'`)
    );
    // USD 10,000 at 80 = INR 8,00,000; at 50 % the stored weighted value is INR 4,00,000
    await insertDeal(c, {
      no: 'T-OPP-6',
      title: 'Deal six (USD)',
      accountId: acc.id,
      stage: 'PROPOSAL',
      value: 10000,
      currency: 'USD',
      fxRate: 80,
      weighted: 400000,
      close: todayIst,
      owner: exec2.id,
    });
    const d = (await dashboard(admin.token)).body.data;
    expect(d.kpi).toMatchObject({
      openCount: 3,
      openValue: '3800000.00',
      weightedValue: '2100000.00',
    });
    const row = d.detail.find((/** @type {any} */ r) => r.opportunityNo === 'T-OPP-6');
    expect(row).toMatchObject({ value: '800000.00', weighted: '400000.00' });
  });
});
