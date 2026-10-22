'use strict';

/**
 * Activities write side (V014): create, update, delete.
 * Fixture: exec owns a lead + opportunity; head has ALL scope; viewer = MANAGEMENT (activity.create
 * but no update_own on others).
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head;
let leadId, oppId, accountId, industryId;

const nowIst = () => new Date(Date.now() + 330 * 60000).toISOString().slice(0, 19) + '+05:30';
const futureIst = () =>
  new Date(Date.now() + 330 * 60000 + 30 * 24 * 3600000).toISOString().slice(0, 10);

let seq = 0;

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'act.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'act.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI' LIMIT 1`))[0][0].id;

  // account
  accountId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
      [`ACT-ACC-${++seq}`, 'Activity Test Corp', industryId, exec.id],
    )
  )[0].insertId;

  // lead (stage_code defaults to NEW)
  leadId = (
    await c.query(
      `INSERT INTO sales_lead
         (lead_no, source, account_id, industry_id, contact_name, city, need_text,
          owner_user_id, next_action, next_action_due_on)
       VALUES (?, 'DIRECT', ?, ?, 'Lead Contact', 'Pune', 'Test need',
               ?, 'Follow up', ?)`,
      [`ACT-LD-${++seq}`, accountId, industryId, exec.id, futureIst()],
    )
  )[0].insertId;

  // opportunity — close date in 2099 so dashboard period filters exclude it
  oppId = (
    await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Activity Test Deal', ?, 'DIRECT', 'QUALIFIED', 2000000, 400000, '2099-01-01', ?)`,
      [`ACT-OPP-${++seq}`, accountId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('POST /activities (create)', () => {
  test('exec logs a call on an opportunity → 201', async () => {
    const res = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'CALL',
      activityAt: nowIst(),
      subject: 'First call with CTO',
      outcome: 'Positive interest',
    });
    expect(res.status).toBe(201);
    expect(res.body.data.id).toBeGreaterThan(0);
  });

  test('exec logs a note on a lead → 201 and lead moves NEW → CONTACTED', async () => {
    const c = await dba();
    const [[before]] = await c.query(`SELECT stage_code FROM sales_lead WHERE id = ?`, [leadId]);
    expect(before.stage_code).toBe('NEW');

    const res = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'LEAD',
      entityId: leadId,
      activityType: 'NOTE',
      activityAt: nowIst(),
      subject: 'Initial contact note',
    });
    expect(res.status).toBe(201);

    const [[after]] = await c.query(`SELECT stage_code FROM sales_lead WHERE id = ?`, [leadId]);
    expect(after.stage_code).toBe('CONTACTED');
  });

  test('next action without nextActionOn → 422', async () => {
    const res = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'MEETING',
      activityAt: nowIst(),
      subject: 'Demo meeting',
      nextAction: 'Send proposal',
    });
    expect(res.status).toBe(422);
  });

  test('next action + nextActionOn creates a follow-up task', async () => {
    const res = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'MEETING',
      activityAt: nowIst(),
      subject: 'Kickoff meeting',
      nextAction: 'Send deck',
      nextActionOn: futureIst(),
    });
    expect(res.status).toBe(201);

    const c = await dba();
    const [[task]] = await c.query(`SELECT id FROM task WHERE source_ref = ? AND status = 'OPEN'`, [
      `activity-${res.body.data.id}-followup`,
    ]);
    expect(task).toBeDefined();
  });

  test('unauthenticated → 401', async () => {
    const res = await api().post('/api/v1/activities').send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'CALL',
      activityAt: nowIst(),
      subject: 'x',
    });
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
describe('PATCH /activities/:id (update)', () => {
  let activityId;

  beforeAll(async () => {
    const res = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'EMAIL',
      activityAt: nowIst(),
      subject: 'Email to update',
    });
    activityId = res.body.data.id;
  });

  test('owner can update their own activity → 200', async () => {
    const res = await api().patch(`/api/v1/activities/${activityId}`).set(bearer(exec.token)).send({
      activityType: 'EMAIL',
      activityAt: nowIst(),
      subject: 'Updated subject',
    });
    expect(res.status).toBe(200);
  });

  test('head (ALL scope) can update any activity → 200', async () => {
    const res = await api().patch(`/api/v1/activities/${activityId}`).set(bearer(head.token)).send({
      activityType: 'EMAIL',
      activityAt: nowIst(),
      subject: 'Head updated',
    });
    expect(res.status).toBe(200);
  });

  test('another exec (not the owner) gets 403', async () => {
    const other = await createActiveUser(admin.token, {
      email: `act.other.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api()
      .patch(`/api/v1/activities/${activityId}`)
      .set(bearer(other.token))
      .send({
        activityType: 'EMAIL',
        activityAt: nowIst(),
        subject: 'Should fail',
      });
    expect(res.status).toBe(403);
  });
});

// ---------------------------------------------------------------------------
describe('DELETE /activities/:id', () => {
  test('owner can delete their own activity → 200', async () => {
    const create = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'VISIT',
      activityAt: nowIst(),
      subject: 'To be deleted',
    });
    const id = create.body.data.id;

    const res = await api().delete(`/api/v1/activities/${id}`).set(bearer(exec.token));
    expect(res.status).toBe(200);

    // soft-deleted: verify is_active = 0
    const c = await dba();
    const [[row]] = await c.query(`SELECT is_active FROM activity WHERE id = ?`, [id]);
    expect(Number(row.is_active)).toBe(0);
  });

  test('non-owner gets 403', async () => {
    const create = await api().post('/api/v1/activities').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      activityType: 'NOTE',
      activityAt: nowIst(),
      subject: 'Protected note',
    });
    const id = create.body.data.id;

    const other = await createActiveUser(admin.token, {
      email: `act.del.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api().delete(`/api/v1/activities/${id}`).set(bearer(other.token));
    expect(res.status).toBe(403);
  });
});
