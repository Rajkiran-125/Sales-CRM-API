'use strict';

/**
 * Custom fields (V032, 12.15): admin definitions with a fixed key and type, typed values per
 * record with visibility and the entity's update permission, mandatory fields per partner
 * section (BR-PT-06), deactivation keeps values but hides them.
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, pm, pm2, exec;
const ids = /** @type {Record<string, number>} */ ({});

beforeAll(async () => {
  admin = await adminSession();
  pm = await createActiveUser(admin.token, { email: 'cf.pm@test.local', roles: ['PARTNER_MGR'] });
  pm2 = await createActiveUser(admin.token, { email: 'cf.pm2@test.local', roles: ['PARTNER_MGR'] });
  exec = await createActiveUser(admin.token, {
    email: 'cf.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  const c = await dba();
  const [[t]] = await c.query(`SELECT id FROM partner_type WHERE code = 'MSP'`);
  const p = await api()
    .post('/api/v1/partners')
    .set(bearer(pm.token))
    .send({ legalName: 'Custom Field Partner', typeIds: [t.id] });
  ids.partner = p.body.data.id;
});

afterAll(closeAll);

const define = (body) => api().post('/api/v1/custom-fields').set(bearer(admin.token)).send(body);
const put = (token, body) =>
  api().put('/api/v1/custom-fields/values').set(bearer(token)).send(body);

describe('definitions', () => {
  test('admin adds partner fields; a partner field needs a section; a select needs options', async () => {
    const vendor = await define({
      entity: 'PARTNER',
      section: 'ENTITY',
      fieldKey: 'Vendor_Code',
      fieldType: 'TEXT',
      label: 'Vendor code',
      isMandatory: true,
    });
    expect(vendor.status).toBe(201);
    ids.vendor = vendor.body.data.id;
    const regions = await define({
      entity: 'PARTNER',
      section: 'ENTITY',
      fieldKey: 'regions',
      fieldType: 'MULTI_SELECT',
      label: 'Regions',
      options: ['North', 'South', 'West'],
    });
    expect(regions.status).toBe(201);
    expect(
      (await define({ entity: 'PARTNER', fieldKey: 'x_no_section', fieldType: 'TEXT', label: 'X' }))
        .status,
    ).toBe(422);
    expect(
      (
        await define({
          entity: 'ACCOUNT',
          fieldKey: 'tier_pick',
          fieldType: 'SINGLE_SELECT',
          label: 'Pick',
        })
      ).status,
    ).toBe(422);
    expect(
      (
        await define({
          entity: 'PARTNER',
          section: 'ENTITY',
          fieldKey: 'vendor_code',
          fieldType: 'TEXT',
          label: 'Dup',
        })
      ).status,
    ).toBe(422);
  });

  test('the key and type cannot change; non-admins cannot define', async () => {
    const res = await api()
      .patch(`/api/v1/custom-fields/${ids.vendor}`)
      .set(bearer(admin.token))
      .send({ label: 'Vendor code', fieldType: 'NUMBER' });
    expect(res.status).toBe(422);
    expect(
      (
        await api()
          .post('/api/v1/custom-fields')
          .set(bearer(pm.token))
          .send({ entity: 'ACCOUNT', fieldKey: 'k1', fieldType: 'TEXT', label: 'K' })
      ).status,
    ).toBe(403);
    const list = await api().get('/api/v1/custom-fields?entity=PARTNER').set(bearer(exec.token));
    expect(list.status).toBe(200);
    expect(list.body.data.map((f) => f.fieldKey)).toEqual(
      expect.arrayContaining(['vendor_code', 'regions']),
    );
  });
});

describe('values', () => {
  const base = () => ({ entity: 'PARTNER', recordId: ids.partner, section: 'ENTITY' });

  test('the mandatory field of the section must be filled (BR-PT-06); options are checked', async () => {
    const missing = await put(pm.token, { ...base(), values: { regions: ['North'] } });
    expect(missing.status).toBe(422);
    expect(missing.body.error.details).toEqual([expect.objectContaining({ field: 'vendor_code' })]);
    const badOption = await put(pm.token, {
      ...base(),
      values: { vendor_code: 'V-1', regions: ['East'] },
    });
    expect(badOption.status).toBe(422);
  });

  test('owner saves typed values and reads them back; audited', async () => {
    const res = await put(pm.token, {
      ...base(),
      values: { vendor_code: ' V-100 ', regions: ['North', 'West', 'North'] },
    });
    expect(res.status).toBe(200);
    const get = await api()
      .get(`/api/v1/custom-fields/values?entity=PARTNER&recordId=${ids.partner}`)
      .set(bearer(pm.token));
    expect(get.body.data.values).toEqual({ vendor_code: 'V-100', regions: ['North', 'West'] });
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM audit_log WHERE entity_type = 'partner' AND entity_id = ? AND action = 'CUSTOM_FIELDS_UPDATE'`,
      [ids.partner],
    );
    expect(log.n).toBe(1);
  });

  test('no update permission → 403; not visible → 404', async () => {
    expect((await put(exec.token, { ...base(), values: { vendor_code: 'X' } })).status).toBe(403);
    expect((await put(pm2.token, { ...base(), values: { vendor_code: 'X' } })).status).toBe(404);
  });

  test('a deactivated field is hidden but its value is kept', async () => {
    const off = await api()
      .patch(`/api/v1/custom-fields/${ids.vendor}`)
      .set(bearer(admin.token))
      .send({ label: 'Vendor code', section: 'ENTITY', isActive: false });
    expect(off.status).toBe(200);
    const get = await api()
      .get(`/api/v1/custom-fields/values?entity=PARTNER&recordId=${ids.partner}`)
      .set(bearer(pm.token));
    expect(get.body.data.values).toEqual({ regions: ['North', 'West'] });
    const c = await dba();
    const [[kept]] = await c.query(
      'SELECT value_text AS v FROM custom_field_value WHERE field_id = ?',
      [ids.vendor],
    );
    expect(kept.v).toBe('V-100');
  });
});
