'use strict';

/**
 * Sales screens, read side (D-27): My day, leads, opportunities, accounts, forecast. Checks the
 * data scope (10.8) on every list and record, 404 outside the scope, the permission-gated parts
 * (validations, offer approvals, partner commercial, team forecast) and the record access log.
 *
 * Fixture: manager <- exec1 (account A, lead L1, deal O1); exec2 (account B, lead L2, deal O2);
 * presales is the pre-sales owner of O1; head = Sales Head (validator, approver).
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, head, manager, exec1, exec2, presales;
const ids = /** @type {Record<string, number>} */ ({});
const todayIst = new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);
// the fixture deals close (and are committed) in a far month, so they never change the
// current-period dashboard figures checked by dashboard.test.js
const FAR_MONTH = '2099-06';
const FAR_CLOSE = '2099-06-30';
const weekStart = (() => {
  const d = new Date(`${todayIst}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
})();

/**
 * @param {import('mysql2/promise').Connection} c
 * @param {string} sql
 * @param {unknown[]} params
 */
async function insert(c, sql, params) {
  const [res] = await c.query(sql, params);
  return /** @type {any} */ (res).insertId;
}

beforeAll(async () => {
  admin = await adminSession();
  head = await createActiveUser(admin.token, {
    email: 'sales.head@test.local',
    roles: ['SALES_HEAD'],
  });
  manager = await createActiveUser(admin.token, {
    email: 'sales.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec1 = await createActiveUser(admin.token, {
    email: 'sales.exec1@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  exec2 = await createActiveUser(admin.token, {
    email: 'sales.exec2@test.local',
    roles: ['SALES_EXEC'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'sales.presales@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  const industry = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI'`))[0][0].id;
  ids.accA = await insert(
    c,
    `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES ('S-ACC-1', 'Sales Test Bank', ?, ?)`,
    [industry, exec1.id],
  );
  ids.accB = await insert(
    c,
    `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES ('S-ACC-2', 'Other Test Corp', ?, ?)`,
    [industry, exec2.id],
  );
  ids.contact = await insert(
    c,
    `INSERT INTO contact (account_id, name, designation, influence_level, stand) VALUES (?, 'Test CIO', 'CIO', 5, 'CHAMPION')`,
    [ids.accA],
  );
  ids.l1 = await insert(
    c,
    `INSERT INTO sales_lead (lead_no, source, account_id, industry_id, contact_name, city, need_text, owner_user_id,
       next_action, next_action_due_on, stage_code, problem_statement, expected_close_date, qualification_pct)
     VALUES ('S-LD-1', 'DIRECT', ?, ?, 'Lead Contact', 'Pune', 'Needs SD-WAN', ?, 'Call back', ?, 'QUALIFYING',
       'MPLS is expensive', ?, 33.33)`,
    [ids.accA, industry, exec1.id, todayIst, todayIst],
  );
  ids.l2 = await insert(
    c,
    `INSERT INTO sales_lead (lead_no, source, account_name_text, industry_id, contact_name, city, need_text, owner_user_id,
       next_action, next_action_due_on)
     VALUES ('S-LD-2', 'EVENT', 'New Prospect Ltd', ?, 'Someone', 'Delhi', 'Wi-Fi', ?, 'Call', ?)`,
    [industry, exec2.id, todayIst],
  );
  ids.o1 = await insert(
    c,
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
       expected_close_date, owner_user_id, presales_owner_user_id, validation_status)
     VALUES ('S-OPP-1', 'Bank SD-WAN', ?, 'DIRECT', 'PROPOSAL', 5000000, 2500000, ?, ?, ?, 'VALID')`,
    [ids.accA, FAR_CLOSE, exec1.id, presales.id],
  );
  ids.o2 = await insert(
    c,
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
       expected_close_date, owner_user_id)
     VALUES ('S-OPP-2', 'Corp firewall', ?, 'DIRECT', 'QUALIFIED', 2000000, 400000, ?, ?)`,
    [ids.accB, FAR_CLOSE, exec2.id],
  );
  const partner = await insert(
    c,
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('S-PTR-1', 'Sales Test Partner Pvt Ltd', 'Sales Partner', 'India', ?)`,
    [head.id],
  );
  await c.query(
    `INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, is_primary) VALUES (?, ?, 'SOURCED', 1)`,
    [ids.o1, partner],
  );
  await c.query(
    `INSERT INTO partner_commercial (opportunity_id, partner_id, account_id, partner_role, version_no, deal_size_basis,
       price_to_partner, partner_margin_pct, payment_terms)
     VALUES (?, ?, ?, 'SOURCED', 1, 'Deal value 50 L', 4200000, 12, '45 days')`,
    [ids.o1, partner, ids.accA],
  );
  await c.query(
    `INSERT INTO opportunity_dmu (opportunity_id, contact_id, dmu_role, influence_level, stand) VALUES (?, ?, 'TECH_BUYER', 5, 'CHAMPION')`,
    [ids.o1, ids.contact],
  );
  await c.query(
    `INSERT INTO offer (opportunity_id, version_no, offer_no, offer_value, discount_pct, valid_till, status, submitted_by, submitted_at)
     VALUES (?, 1, 'S-OPP-1/v1', 5000000, 18, ?, 'PENDING_APPROVAL', ?, UTC_TIMESTAMP(3))`,
    [ids.o1, todayIst, exec1.id],
  );
  await c.query(
    `INSERT INTO activity (entity_type, entity_id, opportunity_id, account_id, activity_type, activity_at, subject, by_user_id)
     VALUES ('OPP', ?, ?, ?, 'MEETING', UTC_TIMESTAMP(3), 'Discovery meeting', ?)`,
    [ids.o1, ids.o1, ids.accA, exec1.id],
  );
  await c.query(
    `INSERT INTO weekly_status (opportunity_id, week_start, status, this_week, next_step, stage_code, submitted_by)
     VALUES (?, ?, 'ON_TRACK', 'Demo done', 'Send BoQ', 'PROPOSAL', ?)`,
    [ids.o1, weekStart, exec1.id],
  );
  await c.query(
    `INSERT INTO monthly_commit (opportunity_id, commit_month, commit_type, commit_value)
     VALUES (?, ?, 'COMMIT', 5000000)`,
    [ids.o1, `${FAR_MONTH}-01`],
  );
  await c.query(
    `INSERT INTO task (entity_type, entity_id, task_type, title, owner_user_id, due_at)
     VALUES ('OPP', ?, 'FOLLOW_UP', 'Overdue follow-up', ?, UTC_TIMESTAMP(3) - INTERVAL 3 DAY),
            ('LEAD', ?, 'FOLLOW_UP', 'Call the lead', ?, UTC_TIMESTAMP(3))`,
    [ids.o1, exec1.id, ids.l1, exec1.id],
  );
});
afterAll(closeAll);

/** @param {{ token: string }} who @param {string} path */
const get = (who, path) => api().get(`/api/v1${path}`).set(bearer(who.token));
const nos = (/** @type {any[]} */ rows, /** @type {string} */ k) => rows.map((r) => r[k]).sort();

describe('leads', () => {
  test('scope: own, team, others; counts per stage; 404 outside the scope', async () => {
    const own = (await get(exec1, '/leads')).body;
    expect(nos(own.data, 'leadNo')).toEqual(['S-LD-1']);
    expect(
      own.meta.stageCounts.find((/** @type {any} */ s) => s.stageCode === 'QUALIFYING').count,
    ).toBe(1);

    expect(nos((await get(manager, '/leads')).body.data, 'leadNo')).toEqual(['S-LD-1']);
    expect(nos((await get(head, '/leads?search=S-LD')).body.data, 'leadNo')).toEqual([
      'S-LD-1',
      'S-LD-2',
    ]);
    expect((await get(exec1, `/leads/${ids.l2}`)).status).toBe(404);
    expect((await get(presales, '/leads')).status).toBe(403);
  });

  test('the lead page counts the six qualification facts and logs the view', async () => {
    const res = await get(exec1, `/leads/${ids.l1}`);
    expect(res.status).toBe(200);
    expect(res.body.data.lead).toMatchObject({
      leadNo: 'S-LD-1',
      stageCode: 'QUALIFYING',
      isNewAccount: false,
    });
    expect(res.body.data.qualification).toMatchObject({ done: 2, total: 6 });
    expect(res.body.data.qualification.facts.map((/** @type {any} */ f) => f.code)).toEqual([
      'PROBLEM',
      'SOLUTION',
      'COMMERCIAL',
      'DMU',
      'PROCUREMENT',
      'CLOSE_DATE',
    ]);
    const c = await dba();
    const [[log]] = /** @type {any} */ (
      await c.query(
        `SELECT COUNT(*) AS n FROM record_access_log WHERE entity_type = 'LEAD' AND entity_id = ? AND user_id = ?`,
        [ids.l1, exec1.id],
      )
    );
    expect(Number(log.n)).toBe(1);
  });
});

describe('opportunities', () => {
  test('list by view with counts; kanban columns; scope', async () => {
    const list = (await get(head, '/opportunities?search=S-OPP')).body;
    expect(nos(list.data, 'opportunityNo')).toEqual(['S-OPP-1', 'S-OPP-2']);
    expect(list.meta.counts).toMatchObject({ open: 2, won: 0, all: 2, openValue: '7000000.00' });
    expect((await get(head, '/opportunities?search=S-OPP&view=WON')).body.data).toEqual([]);

    expect(nos((await get(exec2, '/opportunities')).body.data, 'opportunityNo')).toEqual([
      'S-OPP-2',
    ]);
    // pre-sales sees the deals where they are the pre-sales owner (ASSIGNED_AND_TEAM)
    expect(nos((await get(presales, '/opportunities')).body.data, 'opportunityNo')).toEqual([
      'S-OPP-1',
    ]);

    const kanban = (await get(manager, '/opportunities/kanban')).body.data.columns;
    expect(kanban.map((/** @type {any} */ c) => c.stageCode)).toContain('PROPOSAL');
    const proposal = kanban.find((/** @type {any} */ c) => c.stageCode === 'PROPOSAL');
    expect(proposal).toMatchObject({ count: 1, value: '5000000.00' });
    expect(proposal.cards[0]).toMatchObject({
      opportunityNo: 'S-OPP-1',
      partnerName: 'Sales Partner',
    });
  });

  test('the workspace, with partner commercial only for its holders; 404 outside the scope', async () => {
    const ws = (await get(exec1, `/opportunities/${ids.o1}`)).body.data;
    expect(ws.deal).toMatchObject({
      opportunityNo: 'S-OPP-1',
      stageName: 'Proposal',
      confidencePct: 50,
    });
    expect(ws.dmu[0]).toMatchObject({ name: 'Test CIO', dmuRole: 'TECH_BUYER' });
    expect(ws.partners[0]).toMatchObject({ partnerName: 'Sales Partner', partnerRole: 'SOURCED' });
    expect(ws.offers[0]).toMatchObject({
      offerNo: 'S-OPP-1/v1',
      status: 'PENDING_APPROVAL',
      discountPct: 18,
    });
    expect(ws.partnerCommercials[0]).toMatchObject({
      priceToPartner: '4200000.00',
      partnerMarginPct: 12,
    });
    expect(ws.activities[0].subject).toBe('Discovery meeting');
    expect(ws.weeklyStatus[0]).toMatchObject({ weekStart, status: 'ON_TRACK' });
    expect(ws.stages.map((/** @type {any} */ s) => s.code)).toContain('CONTRACT_SIGNED');

    // pre-sales has no partner_commercial.view (OD-31 default)
    expect(
      (await get(presales, `/opportunities/${ids.o1}`)).body.data.partnerCommercials,
    ).toBeNull();
    expect((await get(exec2, `/opportunities/${ids.o1}`)).status).toBe(404);
  });
});

describe('accounts', () => {
  test('visible by ownership or by a visible deal; Account 360 counts only visible deals', async () => {
    expect(nos((await get(exec1, '/accounts')).body.data, 'accountNo')).toEqual(['S-ACC-1']);
    // pre-sales owns no account but sees account A through deal O1 (10.8 rule 4)
    expect(nos((await get(presales, '/accounts')).body.data, 'accountNo')).toEqual(['S-ACC-1']);

    const a360 = (await get(exec1, `/accounts/${ids.accA}/360`)).body.data;
    expect(a360.account).toMatchObject({ accountNo: 'S-ACC-1', name: 'Sales Test Bank' });
    expect(a360.kpis).toMatchObject({ openDeals: 1, openPipeline: '5000000.00' });
    expect(a360.contacts[0]).toMatchObject({ name: 'Test CIO' });
    expect(a360.partners[0]).toMatchObject({ partnerName: 'Sales Partner', deals: 1 });
    expect((await get(exec1, `/accounts/${ids.accB}/360`)).status).toBe(404);
  });
});

describe('my day', () => {
  test('tasks by bucket; validations and offer approvals only for their holders', async () => {
    const mine = (await get(exec1, '/tasks/my-day')).body.data;
    expect(mine.summary).toMatchObject({ overdue: 1, dueToday: 1 });
    expect(mine.tasks.map((/** @type {any} */ t) => t.bucket)).toEqual(['OVERDUE', 'TODAY']);
    expect(mine.tasks[0]).toMatchObject({ linkType: 'OPP', linkId: ids.o1 });
    expect(mine.validations).toBeNull();
    expect(mine.offers).toBeNull();

    const boss = (await get(head, '/tasks/my-day')).body.data;
    expect(boss.validations.map((/** @type {any} */ v) => v.opportunityNo)).toContain('S-OPP-2');
    expect(boss.offers.map((/** @type {any} */ o) => o.offerNo)).toContain('S-OPP-1/v1');
  });
});

describe('forecast', () => {
  test('weekly: own deals, or the team with forecast.view_team', async () => {
    const own = (await get(exec1, '/forecast/weekly')).body.data;
    expect(own).toMatchObject({ team: false, week: { weekStart, isCurrentWeek: true } });
    expect(own.deals.map((/** @type {any} */ d) => d.opportunityNo)).toEqual(['S-OPP-1']);
    expect(own.summary).toMatchObject({ deals: 1, updated: 1, pending: 0 });

    const team = (await get(manager, '/forecast/weekly?team=true')).body.data;
    expect(team.team).toBe(true);
    expect(team.deals.map((/** @type {any} */ d) => d.opportunityNo)).toEqual(['S-OPP-1']);
    // pre-sales has no forecast.view_team: the team flag is ignored
    expect((await get(presales, '/forecast/weekly?team=true')).body.data.team).toBe(false);
  });

  test('monthly closure and the hierarchy funnel', async () => {
    const month = (await get(exec1, `/forecast/monthly?month=${FAR_MONTH}`)).body.data;
    expect(month.totals).toMatchObject({ committed: '5000000.00', committedDeals: 1 });
    expect(month.deals[0]).toMatchObject({
      opportunityNo: 'S-OPP-1',
      commitType: 'COMMIT',
      achieved: false,
    });

    const tree = (await get(manager, `/forecast/hierarchy?month=${FAR_MONTH}`)).body.data.people;
    const me = tree.find((/** @type {any} */ p) => p.userId === manager.id);
    expect(me).toMatchObject({ openDeals: 1, openValue: '5000000.00', committed: '5000000.00' });
    expect(tree.map((/** @type {any} */ p) => p.userId)).not.toContain(exec2.id);
    expect((await get(presales, '/forecast/hierarchy')).status).toBe(403);
    expect((await get(exec1, '/forecast/monthly?month=2026-13')).status).toBe(422);
  });
});
