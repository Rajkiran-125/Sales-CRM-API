'use strict';

/**
 * Tenders write (V037, 12.8): create with the default checklist, edit with owner rule and
 * version, BR-TD-04 dates, readiness from the checklist (BR-TD-02), the status track with
 * NOT_AWARDED / AWARDED rules (BR-TD-01), export.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, other;
const ids = /** @type {Record<string, number>} */ ({});

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'tw.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  other = await createActiveUser(admin.token, {
    email: 'tw.other@test.local',
    roles: ['SALES_EXEC'],
  });
  const c = await dba();
  const [acc] = await c.query(
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('TW-ACC-1', 'Tender Authority', ?)`,
    [exec.id],
  );
  ids.acc = /** @type {any} */ (acc).insertId;
  const [opp] = await c.query(
    `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value,
       weighted_value, expected_close_date, owner_user_id)
     VALUES ('TW-OPP-1', 'Tender deal', ?, 'DIRECT', 'PROPOSAL', 1000, 500, '2099-01-01', ?)`,
    [ids.acc, exec.id],
  );
  ids.opp = /** @type {any} */ (opp).insertId;
  const [[r]] = await c.query(
    `SELECT id FROM reason WHERE reason_type = 'LOSS' ORDER BY id LIMIT 1`,
  );
  ids.reason = r.id;
});

afterAll(closeAll);

const base = () => ({
  authority: 'State IT Department',
  title: 'Statewide SD-WAN',
  ourRole: 'BIDDER',
  accountId: ids.acc,
  estimatedValue: 25000000,
  preBidOn: '2099-01-10',
  submissionOn: '2099-02-01',
});
const move = (token, body) =>
  api().post(`/api/v1/tenders/${ids.t}/status-transitions`).set(bearer(token)).send(body);

describe('tenders write', () => {
  test('create: TND number, owner = creator, five default checklist items, readiness 0', async () => {
    const bad = await api()
      .post('/api/v1/tenders')
      .set(bearer(exec.token))
      .send({ ...base(), preBidOn: '2099-03-01' });
    expect(bad.status).toBe(422);
    const res = await api().post('/api/v1/tenders').set(bearer(exec.token)).send(base());
    expect(res.status).toBe(201);
    expect(res.body.data.tenderNo).toMatch(/^TND-\d{4,}$/);
    ids.t = res.body.data.id;
    const page = (await api().get(`/api/v1/tenders/${ids.t}`).set(bearer(exec.token))).body.data;
    expect(page.checklist).toHaveLength(5);
    expect(page.tender.readinessPct).toBe(0);
    ids.item = page.checklist[0].id;
  });

  test('checklist ticks drive readiness; another exec cannot change it', async () => {
    const tick = await api()
      .patch(`/api/v1/tenders/${ids.t}/checklist/${ids.item}`)
      .set(bearer(exec.token))
      .send({ itemText: 'Eligibility criteria met', isDone: true });
    expect(tick.status).toBe(200);
    expect(tick.body.data.readinessPct).toBe(20);
    const no = await api()
      .patch(`/api/v1/tenders/${ids.t}/checklist/${ids.item}`)
      .set(bearer(other.token))
      .send({ itemText: 'X', isDone: false });
    expect(no.status).toBe(403);
  });

  test('edit with the version; a stale version → 409', async () => {
    const e = await api().get(`/api/v1/tenders/${ids.t}/edit`).set(bearer(exec.token));
    expect(e.body.data).toMatchObject({
      rowVersion: 1,
      ownerUserId: exec.id,
      status: 'IDENTIFIED',
    });
    const ok = await api()
      .patch(`/api/v1/tenders/${ids.t}`)
      .set(bearer(exec.token))
      .send({ ...base(), rowVersion: 1, specInfluenced: true });
    expect(ok.status).toBe(200);
    const stale = await api()
      .patch(`/api/v1/tenders/${ids.t}`)
      .set(bearer(exec.token))
      .send({ ...base(), rowVersion: 1 });
    expect(stale.status).toBe(409);
  });

  test('track: forward only; NOT_AWARDED needs a loss reason; AWARDED needs the deal', async () => {
    expect((await move(exec.token, { rowVersion: 2, toStatus: 'SUBMITTED' })).status).toBe(200);
    expect((await move(exec.token, { rowVersion: 3, toStatus: 'CAPTURED' })).status).toBe(422);
    expect((await move(exec.token, { rowVersion: 3, toStatus: 'NOT_AWARDED' })).status).toBe(422);
    expect((await move(exec.token, { rowVersion: 3, toStatus: 'AWARDED' })).status).toBe(422);
    const won = await move(exec.token, {
      rowVersion: 3,
      toStatus: 'AWARDED',
      opportunityId: ids.opp,
      ourPrice: 24000000,
    });
    expect(won.status).toBe(200);
    expect(won.body.data).toMatchObject({
      status: 'AWARDED',
      opportunityId: ids.opp,
      opportunityStage: 'PROPOSAL',
    });
    // closed: nothing moves any more
    expect((await move(exec.token, { rowVersion: 4, toStatus: 'CANCELLED' })).status).toBe(422);
    const c = await dba();
    const [hist] = await c.query(
      `SELECT to_stage AS s FROM stage_history WHERE entity_type = 'TENDER' AND entity_id = ? ORDER BY id`,
      [ids.t],
    );
    expect(hist.map((h) => h.s)).toEqual(['IDENTIFIED', 'SUBMITTED', 'AWARDED']);
  });

  test('a second tender is lost with its reason; export works', async () => {
    const t = await api().post('/api/v1/tenders').set(bearer(exec.token)).send(base());
    const lost = await api()
      .post(`/api/v1/tenders/${t.body.data.id}/status-transitions`)
      .set(bearer(exec.token))
      .send({
        rowVersion: 1,
        toStatus: 'NOT_AWARDED',
        lossReasonId: ids.reason,
        winner: 'Rival Ltd',
      });
    expect(lost.status).toBe(200);
    const x = await api().get('/api/v1/tenders/export').set(bearer(exec.token));
    expect(x.status).toBe(200);
    expect(x.headers['content-type']).toMatch(/spreadsheetml/);
  });
});
