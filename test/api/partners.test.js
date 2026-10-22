'use strict';

/**
 * Partners, partner performance and tenders, read side (D-27, D-28): scope by the relationship
 * owner (10.8), the scorecard measures of UM 7.2, the tender list and page, 404 outside the scope.
 *
 * Fixture (far-future dates so the dashboard figures of the other tests never change):
 *   partner P1 owned by pm (PARTNER_MGR); partner P2 owned by other (PARTNER_MGR)
 *   deals of exec: W won with P1 sourced, L lost with P1 sourced (reason PRICE), O open with P1
 *   influenced; tender T owned by exec, bidder P1, linked to O
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, head, pm, other, exec;
const ids = /** @type {Record<string, number>} */ ({});
const FY = 2098; // fiscal year 2098-99: 1 Apr 2098 - 31 Mar 2099

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
    email: 'ptr.head@test.local',
    roles: ['SALES_HEAD'],
  });
  pm = await createActiveUser(admin.token, { email: 'ptr.pm@test.local', roles: ['PARTNER_MGR'] });
  other = await createActiveUser(admin.token, {
    email: 'ptr.other@test.local',
    roles: ['PARTNER_MGR'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'ptr.exec@test.local',
    roles: ['SALES_EXEC'],
  });

  const c = await dba();
  ids.acc = await insert(
    c,
    `INSERT INTO account (account_no, name, owner_user_id, is_strategic) VALUES ('P-ACC-1', 'Partner Test Bank', ?, 1)`,
    [exec.id],
  );
  ids.p1 = await insert(
    c,
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id, tier, agreement_status)
     VALUES ('P-PTR-1', 'First Partner Pvt Ltd', 'First Partner', 'India', ?, 'GROWTH', 'SIGNED')`,
    [pm.id],
  );
  ids.p2 = await insert(
    c,
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('P-PTR-2', 'Second Partner Pvt Ltd', 'Second Partner', 'India', ?)`,
    [other.id],
  );
  await c.query(
    `INSERT INTO partner_type_map (partner_id, partner_type_id) SELECT ?, id FROM partner_type WHERE code = 'SI'`,
    [ids.p1],
  );
  await c.query(
    `INSERT INTO partner_engagement (partner_id, engagement_type, engagement_on, by_user_id, outcome)
     VALUES (?, 'QBR', '2098-06-15', ?, 'Agreed the plan'), (?, 'CEC_VISIT', '2098-07-01', ?, 'Moved to POC')`,
    [ids.p1, pm.id, ids.p1, pm.id],
  );

  /** @param {string} no @param {string} stage @param {number} value @param {string | null} closed */
  const deal = (no, stage, value, closed) =>
    insert(
      c,
      `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
         expected_close_date, owner_user_id, po_value, closed_at, validation_status)
       VALUES (?, ?, ?, 'PARTNER', ?, ?, 0, '2098-12-31', ?, ?, ?, 'VALID')`,
      [no, `Deal ${no}`, ids.acc, stage, value, exec.id, stage === 'WON' ? value : null, closed],
    );
  ids.won = await deal('P-OPP-W', 'WON', 4000000, '2098-08-01 06:30:00');
  ids.lost = await deal('P-OPP-L', 'LOST', 2000000, '2098-09-01 06:30:00');
  ids.open = await deal('P-OPP-O', 'PROPOSAL', 3000000, null);
  await c.query(
    `INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, is_primary)
     VALUES (?, ?, 'SOURCED', 1), (?, ?, 'SOURCED', 1), (?, ?, 'INFLUENCED', 1)`,
    [ids.won, ids.p1, ids.lost, ids.p1, ids.open, ids.p1],
  );
  await c.query(
    `INSERT INTO win_loss (opportunity_id, outcome, competition_replaced, recorded_by) VALUES (?, 'WON', 1, ?)`,
    [ids.won, exec.id],
  );
  await c.query(
    `INSERT INTO win_loss (opportunity_id, outcome, loss_reason_id, detail, recorded_by)
     SELECT ?, 'LOST', id, 'Lost on price', ? FROM reason WHERE reason_type = 'LOSS' AND code = 'PRICE'`,
    [ids.lost, exec.id],
  );
  ids.tender = await insert(
    c,
    `INSERT INTO tender (tender_no, authority, title, estimated_value, our_role, bidder_partner_id, submission_on, status,
       readiness_pct, opportunity_id, owner_user_id)
     VALUES ('P-TND-1', 'Test Authority', 'Test tender', 3000000, 'OEM', ?, '2098-11-30', 'CAPTURED', 60, ?, ?)`,
    [ids.p1, ids.open, exec.id],
  );
  await c.query(
    `INSERT INTO tender_checklist_item (tender_id, item_text, is_done, sort_order)
     VALUES (?, 'Eligibility', 1, 1), (?, 'EMD', 0, 2)`,
    [ids.tender, ids.tender],
  );
});
afterAll(closeAll);

/** @param {{ token: string }} who @param {string} path */
const get = (who, path) => api().get(`/api/v1${path}`).set(bearer(who.token));

describe('partners', () => {
  test('a partner manager sees the partners they own; the head sees all', async () => {
    const mine = (await get(pm, '/partners')).body;
    expect(mine.data.map((/** @type {any} */ p) => p.partnerNo)).toEqual(['P-PTR-1']);
    expect(mine.data[0]).toMatchObject({
      name: 'First Partner',
      types: 'SI',
      tier: 'GROWTH',
      activeDeals: 1,
      pipeline: '3000000.00',
    });

    const all = (await get(head, '/partners?search=P-PTR')).body.data
      .map((/** @type {any} */ p) => p.partnerNo)
      .sort();
    expect(all).toEqual(['P-PTR-1', 'P-PTR-2']);
    expect((await get(pm, `/partners/${ids.p2}`)).status).toBe(404);
    expect((await get(head, '/partners?tier=GOLD')).status).toBe(422);
  });

  test('the partner workspace lists sections, deals the user can see, engagements', async () => {
    const w = (await get(pm, `/partners/${ids.p1}`)).body.data;
    expect(w.partner).toMatchObject({ partnerNo: 'P-PTR-1', agreementStatus: 'SIGNED' });
    expect(w.types).toEqual([{ code: 'SI', name: 'SI' }]);
    // PARTNER_OWNED: every deal of the partner
    expect(w.deals.map((/** @type {any} */ d) => d.opportunityNo).sort()).toEqual([
      'P-OPP-L',
      'P-OPP-O',
      'P-OPP-W',
    ]);
    expect(w.engagements.map((/** @type {any} */ e) => e.engagementType)).toEqual([
      'CEC_VISIT',
      'QBR',
    ]);
  });
});

describe('partner performance', () => {
  test('the UM 7.2 measures and the provisional score for a fiscal year', async () => {
    const res = (await get(pm, `/partner-performance?fiscalYear=${FY}`)).body.data;
    expect(res.period).toMatchObject({
      fiscalYear: FY,
      quarter: null,
      fromDate: '2098-04-01',
      toDate: '2099-03-31',
    });
    const s = res.scorecards.find((/** @type {any} */ x) => x.partnerNo === 'P-PTR-1');
    expect(s).toMatchObject({
      sourcedCount: 2,
      influencedCount: 1,
      activeDeals: 1,
      wonDeals: 1,
      lostDeals: 1,
      winPct: 50,
      revenue: '4000000.00',
      competitionReplacement: 1,
      strategicAccounts: 1,
      gtmActivities: 0,
      cecEngagements: 1,
      tenderPipelineCount: 1,
    });
    // win 50 % -> 12.5; revenue = the best of the visible set... computed over all partners -> 0..25;
    // no payment -> 75 % -> 18.75; third layer 2 of 4 -> 12.5
    expect(s.score).toBeGreaterThan(40);
    expect(s.rating).toBeGreaterThanOrEqual(2);
    expect(res.scorecards.map((/** @type {any} */ x) => x.partnerNo)).not.toContain('P-PTR-2');

    const one = (await get(pm, `/partner-performance/${ids.p1}?fiscalYear=${FY}`)).body.data;
    expect(one.lossReasons).toEqual([expect.objectContaining({ reasonName: 'Price', count: 1 })]);
    expect(one.engagements).toHaveLength(2);
    expect((await get(pm, `/partner-performance/${ids.p2}?fiscalYear=${FY}`)).status).toBe(404);
    expect((await get(pm, '/partner-performance?quarter=3')).status).toBe(422);
  });
});

describe('tenders', () => {
  test('list with counts per status, the tender page, scope', async () => {
    const list = (await get(exec, '/tenders?search=P-TND')).body;
    expect(list.data[0]).toMatchObject({
      tenderNo: 'P-TND-1',
      status: 'CAPTURED',
      bidderPartnerName: 'First Partner',
    });
    expect(
      list.meta.statusCounts.find((/** @type {any} */ s) => s.status === 'CAPTURED').count,
    ).toBe(1);

    // the partner manager sees it through the bidder partner
    expect((await get(pm, `/tenders/${ids.tender}`)).status).toBe(200);
    const t = (await get(exec, `/tenders/${ids.tender}`)).body.data;
    expect(t.tender).toMatchObject({ authority: 'Test Authority', opportunityNo: 'P-OPP-O' });
    expect(t.checklist.map((/** @type {any} */ i) => i.isDone)).toEqual([true, false]);
    expect(t.stages.map((/** @type {any} */ s) => s.code)).toContain('AWARDED');

    expect((await get(other, `/tenders/${ids.tender}`)).status).toBe(404);
    expect((await get(exec, '/tenders?status=WON')).status).toBe(422);
  });
});
