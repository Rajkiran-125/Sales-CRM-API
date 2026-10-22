'use strict';

/**
 * Create a lead (12.4, V011): permission, mandatory fields (BR-LD-01), partner rule (BR-LD-02),
 * duplicate account name (BR-LD-09), owner limited to the creator's team, and what a create
 * writes (stage NEW, products, follow-up task, stage history, audit row).
 *
 * Fixture: manager <- exec (SALES_EXEC); other = SALES_EXEC outside the team; presales cannot create.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, manager, exec, other, presales;
let industryId, productId, partnerId, accountId;
const todayIst = new Date(Date.now() + 330 * 60000).toISOString().slice(0, 10);

const body = (/** @type {Record<string, unknown>} */ over = {}) => ({
  source: 'DIRECT',
  accountNameText: 'Brand New Prospect Ltd',
  industryId,
  contactName: 'Asha Rao',
  contactDesignation: 'IT Head',
  contactEmail: 'asha@prospect.example',
  contactPhone: '+919876543210',
  city: 'Pune',
  needText: 'Wants to replace MPLS links at 12 branches',
  roughValue: 2500000,
  roughTiming: 'This quarter',
  nextAction: 'First call',
  nextActionDueOn: todayIst,
  productIds: [productId],
  ...over,
});

/** @param {{ token: string }} who @param {Record<string, unknown>} payload */
const post = (who, payload) => api().post('/api/v1/leads').set(bearer(who.token)).send(payload);

beforeAll(async () => {
  admin = await adminSession();
  manager = await createActiveUser(admin.token, {
    email: 'lc.manager@test.local',
    roles: ['SALES_EXEC'],
  });
  exec = await createActiveUser(admin.token, {
    email: 'lc.exec@test.local',
    roles: ['SALES_EXEC'],
    reportingToUserId: manager.id,
  });
  other = await createActiveUser(admin.token, {
    email: 'lc.other@test.local',
    roles: ['SALES_EXEC'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'lc.presales@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI'`))[0][0].id;
  productId = (
    await c.query(`SELECT id FROM product WHERE is_active = 1 ORDER BY id LIMIT 1`)
  )[0][0].id;
  const [p] = await c.query(
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('LC-PTR-1', 'Lead Create Partner Pvt Ltd', 'LC Partner', 'India', ?)`,
    [manager.id],
  );
  partnerId = /** @type {any} */ (p).insertId;
  const [a] = await c.query(
    `INSERT INTO account (account_no, name, industry_id, owner_user_id)
     VALUES ('LC-ACC-1', 'Existing Lead Create Bank', ?, ?)`,
    [industryId, exec.id],
  );
  accountId = /** @type {any} */ (a).insertId;
});
afterAll(closeAll);

describe('create lead', () => {
  test('a sales executive creates a lead: stage NEW, number, owner, follow-up task, history, audit', async () => {
    const res = await post(exec, body());
    expect(res.status).toBe(201);
    expect(res.body.data.leadNo).toMatch(/^LD-\d{4}-\d{4,}$/);

    const page = await api().get(`/api/v1/leads/${res.body.data.id}`).set(bearer(exec.token));
    expect(page.status).toBe(200);
    expect(page.body.data.lead).toMatchObject({
      stageCode: 'NEW',
      accountName: 'Brand New Prospect Ltd',
      isNewAccount: true,
      contactName: 'Asha Rao',
      city: 'Pune',
      ownerName: expect.any(String),
      nextAction: 'First call',
      qualificationPct: 0,
    });
    expect(page.body.data.products).toHaveLength(1);
    expect(page.body.data.tasks).toEqual([
      expect.objectContaining({ taskType: 'FOLLOW_UP', title: 'First call', status: 'OPEN' }),
    ]);
    expect(page.body.data.history).toEqual([expect.objectContaining({ toStage: 'New' })]);

    const c = await dba();
    const [[audit]] = await c.query(
      `SELECT action, user_id AS userId FROM audit_log WHERE entity_type = 'LEAD' AND entity_id = ?`,
      [String(res.body.data.id)],
    );
    expect(audit).toMatchObject({ action: 'CREATE', userId: exec.id });
  });

  test('numbers are unique and the lead shows in the creator list', async () => {
    const a = await post(exec, body({ accountNameText: 'Number Test One Ltd' }));
    const b = await post(exec, body({ accountNameText: 'Number Test Two Ltd' }));
    expect(a.body.data.leadNo).not.toBe(b.body.data.leadNo);
    const list = await api().get('/api/v1/leads?search=Number%20Test').set(bearer(exec.token));
    expect(list.body.data.map((/** @type {any} */ l) => l.leadNo).sort()).toEqual(
      [a.body.data.leadNo, b.body.data.leadNo].sort(),
    );
  });

  test('an existing account can be chosen instead of a new name', async () => {
    const res = await post(exec, body({ accountId, accountNameText: null }));
    expect(res.status).toBe(201);
    const page = await api().get(`/api/v1/leads/${res.body.data.id}`).set(bearer(exec.token));
    expect(page.body.data.lead).toMatchObject({
      accountName: 'Existing Lead Create Bank',
      isNewAccount: false,
    });
  });

  test('BR-LD-09: a new name that is already an account is refused', async () => {
    const res = await post(exec, body({ accountNameText: 'Existing Lead Create Bank' }));
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('accountNameText');
  });

  test('BR-LD-01: account is required, and the mandatory fields are validated', async () => {
    const noAccount = await post(exec, body({ accountNameText: null }));
    expect(noAccount.status).toBe(422);
    expect(noAccount.body.error.details[0].field).toBe('accountNameText');

    const missing = await post(exec, body({ city: '', needText: '', nextAction: '' }));
    expect(missing.status).toBe(422);
    const fields = missing.body.error.details.map((/** @type {any} */ d) => d.field).sort();
    expect(fields).toEqual(['city', 'needText', 'nextAction']);

    const badPhone = await post(exec, body({ contactPhone: '12ab' }));
    expect(badPhone.status).toBe(422);
    const badValue = await post(exec, body({ roughValue: 0 }));
    expect(badValue.status).toBe(422);
  });

  test('the next-action date cannot be in the past', async () => {
    const res = await post(
      exec,
      body({ accountNameText: 'Past Date Ltd', nextActionDueOn: '2020-01-01' }),
    );
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('nextActionDueOn');
  });

  test('BR-LD-02: a partner lead needs a partner', async () => {
    const without = await post(
      exec,
      body({ accountNameText: 'Partner Lead A Ltd', source: 'PARTNER' }),
    );
    expect(without.status).toBe(422);
    expect(without.body.error.details[0].field).toBe('partnerId');

    const withPartner = await post(
      manager,
      body({
        accountNameText: 'Partner Lead B Ltd',
        source: 'PARTNER',
        partnerId,
        partnerContact: 'Ravi, +91 99',
      }),
    );
    expect(withPartner.status).toBe(201);
  });

  test('owner: self by default, a team member allowed, someone outside the team refused', async () => {
    const mine = await post(exec, body({ accountNameText: 'Owner Default Ltd' }));
    const mineRow = await api().get(`/api/v1/leads/${mine.body.data.id}`).set(bearer(exec.token));
    expect(mineRow.status).toBe(200);

    const toTeam = await post(
      manager,
      body({ accountNameText: 'Owner Team Ltd', ownerUserId: exec.id }),
    );
    expect(toTeam.status).toBe(201);
    const execSees = await api()
      .get(`/api/v1/leads/${toTeam.body.data.id}`)
      .set(bearer(exec.token));
    expect(execSees.status).toBe(200);

    const outside = await post(
      exec,
      body({ accountNameText: 'Owner Outside Ltd', ownerUserId: other.id }),
    );
    expect(outside.status).toBe(422);
    expect(outside.body.error.details[0].field).toBe('ownerUserId');
  });

  test('unknown products are refused', async () => {
    const res = await post(
      exec,
      body({ accountNameText: 'Bad Product Ltd', productIds: [99999999] }),
    );
    expect(res.status).toBe(422);
    expect(res.body.error.details[0].field).toBe('productIds');
  });

  test('a role without lead.create gets 403 and nothing is written', async () => {
    const res = await post(presales, body({ accountNameText: 'Presales Cannot Ltd' }));
    expect(res.status).toBe(403);
    const c = await dba();
    const [rows] = await c.query(
      `SELECT id FROM sales_lead WHERE account_name_text = 'Presales Cannot Ltd'`,
    );
    expect(rows).toHaveLength(0);
  });

  test('unknown fields in the body are rejected', async () => {
    const res = await post(exec, {
      ...body({ accountNameText: 'Extra Field Ltd' }),
      stageCode: 'QUALIFYING',
    });
    expect(res.status).toBe(422);
  });
});
