'use strict';

/**
 * Tasks write side (V016): create, update.
 * Fixture: exec creates tasks; head has ALL scope.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, head;
let oppId, accountId, industryId;
let seq = 0;

const futureIst = () =>
  new Date(Date.now() + 330 * 60000 + 7 * 24 * 3600000).toISOString().slice(0, 10) +
  'T09:00:00+05:30';

beforeAll(async () => {
  admin = await adminSession();
  exec = await createActiveUser(admin.token, {
    email: 'task.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  head = await createActiveUser(admin.token, {
    email: 'task.head@test.local',
    roles: ['SALES_HEAD'],
  });

  const c = await dba();
  industryId = (await c.query(`SELECT id FROM industry WHERE code = 'BFSI' LIMIT 1`))[0][0].id;

  accountId = (
    await c.query(
      `INSERT INTO account (account_no, name, industry_id, owner_user_id) VALUES (?,?,?,?)`,
      [`TSK-ACC-${++seq}`, 'Task Test Corp', industryId, exec.id],
    )
  )[0].insertId;

  oppId = (
    await c.query(
      `INSERT INTO opportunity
         (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
          expected_close_date, owner_user_id)
       VALUES (?, 'Task Test Deal', ?, 'DIRECT', 'QUALIFIED', 1000000, 200000, '2099-01-01', ?)`,
      [`TSK-OPP-${++seq}`, accountId, exec.id],
    )
  )[0].insertId;
});

afterAll(closeAll);

// ---------------------------------------------------------------------------
describe('POST /tasks (create)', () => {
  test('exec creates a standalone task → 201', async () => {
    const res = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      title: 'Follow up on proposal',
      dueAt: futureIst(),
    });
    expect(res.status).toBe(201);
    expect(res.body.data.id).toBeGreaterThan(0);
  });

  test('exec creates a task linked to an opportunity → 201', async () => {
    const res = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      entityType: 'OPP',
      entityId: oppId,
      title: 'Prepare demo',
      dueAt: futureIst(),
    });
    expect(res.status).toBe(201);

    const c = await dba();
    const [[row]] = await c.query(`SELECT task_type, status FROM task WHERE id = ? LIMIT 1`, [
      res.body.data.id,
    ]);
    expect(row.task_type).toBe('CUSTOM');
    expect(row.status).toBe('OPEN');
  });

  test('entityType without entityId → 422', async () => {
    const res = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      entityType: 'OPP',
      title: 'Missing id',
      dueAt: futureIst(),
    });
    expect(res.status).toBe(422);
  });

  test('missing title → 422', async () => {
    const res = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      dueAt: futureIst(),
    });
    expect(res.status).toBe(422);
  });

  test('unauthenticated → 401', async () => {
    const res = await api().post('/api/v1/tasks').send({ title: 'x', dueAt: futureIst() });
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------
describe('PATCH /tasks/:id (update)', () => {
  let taskId;

  beforeAll(async () => {
    const res = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      title: 'Task to update',
      dueAt: futureIst(),
    });
    taskId = res.body.data.id;
  });

  test('owner completes own task → 200, completed_at set', async () => {
    const res = await api().patch(`/api/v1/tasks/${taskId}`).set(bearer(exec.token)).send({
      title: 'Task to update',
      dueAt: futureIst(),
      ownerUserId: exec.id,
      status: 'DONE',
    });
    expect(res.status).toBe(200);

    const c = await dba();
    const [[row]] = await c.query(`SELECT status, completed_at FROM task WHERE id = ?`, [taskId]);
    expect(row.status).toBe('DONE');
    expect(row.completed_at).not.toBeNull();
  });

  test('owner reopens task → 200, completed_at cleared', async () => {
    const res = await api().patch(`/api/v1/tasks/${taskId}`).set(bearer(exec.token)).send({
      title: 'Task to update',
      dueAt: futureIst(),
      ownerUserId: exec.id,
      status: 'OPEN',
    });
    expect(res.status).toBe(200);

    const c = await dba();
    const [[row]] = await c.query(`SELECT status, completed_at FROM task WHERE id = ?`, [taskId]);
    expect(row.status).toBe('OPEN');
    expect(row.completed_at).toBeNull();
  });

  test('owner cancels task → 200', async () => {
    const cancelRes = await api().post('/api/v1/tasks').set(bearer(exec.token)).send({
      title: 'To cancel',
      dueAt: futureIst(),
    });
    const id = cancelRes.body.data.id;

    const res = await api().patch(`/api/v1/tasks/${id}`).set(bearer(exec.token)).send({
      title: 'To cancel',
      dueAt: futureIst(),
      ownerUserId: exec.id,
      status: 'CANCELLED',
    });
    expect(res.status).toBe(200);
  });

  test('non-owner gets 403', async () => {
    const other = await createActiveUser(admin.token, {
      email: `task.other.${++seq}@test.local`,
      roles: ['SALES_EXEC'],
    });
    const res = await api().patch(`/api/v1/tasks/${taskId}`).set(bearer(other.token)).send({
      title: 'Should fail',
      dueAt: futureIst(),
      ownerUserId: other.id,
      status: 'DONE',
    });
    expect(res.status).toBe(403);
  });

  test('head (ALL scope) can update any task → 200', async () => {
    const res = await api().patch(`/api/v1/tasks/${taskId}`).set(bearer(head.token)).send({
      title: 'Head updated',
      dueAt: futureIst(),
      ownerUserId: exec.id,
      status: 'OPEN',
    });
    expect(res.status).toBe(200);
  });

  test('non-existent task → 404', async () => {
    const res = await api().patch('/api/v1/tasks/99999999').set(bearer(exec.token)).send({
      title: 'Ghost',
      dueAt: futureIst(),
      ownerUserId: exec.id,
      status: 'DONE',
    });
    expect(res.status).toBe(404);
  });
});
