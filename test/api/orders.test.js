'use strict';

/**
 * Orders, win / loss, documents and reports, read side (D-27): scope by the deal (10.8; finance
 * sees every deal with an order), the order workspace and the BR-OR-05 release check with
 * the partner commercial, win / loss figures, document
 * search with the parent's visibility, and the two catalogue reports.
 *
 * Fixture (fiscal year 2097-98, so the dashboard figures of the other tests never change):
 *   exec: deal W won (order O1 with partner P, two invoices: one paid, one overdue; partner
 *         share released after the customer paid) and deal L lost on price
 *   other: deal W2 won (order O2, direct)
 *   documents: a proposal on W (tag t-fixture), the PO on O1, a proposal on W2
 */
const { api, dba, closeAll, adminSession, createActiveUser, bearer } = require('../helpers');

let admin, exec, other, finance, presales;
const ids = /** @type {Record<string, number>} */ ({});
const FY = 2097;

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
  exec = await createActiveUser(admin.token, {
    email: 'ord.exec@test.local',
    roles: ['SALES_EXEC'],
  });
  other = await createActiveUser(admin.token, {
    email: 'ord.other@test.local',
    roles: ['SALES_EXEC'],
  });
  finance = await createActiveUser(admin.token, {
    email: 'ord.fin@test.local',
    roles: ['FINANCE'],
  });
  presales = await createActiveUser(admin.token, {
    email: 'ord.pre@test.local',
    roles: ['PRESALES'],
  });

  const c = await dba();
  ids.acc = await insert(
    c,
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('O-ACC-1', 'Order Test Bank', ?)`,
    [exec.id],
  );
  ids.acc2 = await insert(
    c,
    `INSERT INTO account (account_no, name, owner_user_id) VALUES ('O-ACC-2', 'Order Test Works', ?)`,
    [other.id],
  );
  ids.ptr = await insert(
    c,
    `INSERT INTO partner (partner_no, legal_name, short_name, country, relationship_owner_user_id)
     VALUES ('O-PTR-1', 'Order Partner Pvt Ltd', 'Order Partner', 'India', ?)`,
    [other.id],
  );

  /** @param {string} no @param {number} acc @param {number} owner @param {string} stage @param {number} value */
  const deal = (no, acc, owner, stage, value) =>
    insert(
      c,
      `INSERT INTO opportunity (opportunity_no, title, account_id, source, stage_code, expected_value, weighted_value,
         expected_close_date, owner_user_id, po_number, po_date, po_value, closed_at, validation_status)
       VALUES (?, ?, ?, 'DIRECT', ?, ?, 0, '2097-06-01', ?, ?, ?, ?, '2097-06-01 06:30:00', 'VALID')`,
      [
        no,
        `Deal ${no}`,
        acc,
        stage,
        value,
        owner,
        stage === 'WON' ? `PO-${no}` : null,
        stage === 'WON' ? '2097-06-01' : null,
        stage === 'WON' ? value : null,
      ],
    );
  ids.won = await deal('O-OPP-W', ids.acc, exec.id, 'WON', 1000000);
  ids.lost = await deal('O-OPP-L', ids.acc, exec.id, 'LOST', 500000);
  ids.won2 = await deal('O-OPP-W2', ids.acc2, other.id, 'WON', 300000);
  await c.query(
    `INSERT INTO opportunity_product (opportunity_id, product_id, is_primary)
     SELECT x.id, p.id, 1 FROM (SELECT ? AS id UNION ALL SELECT ? UNION ALL SELECT ?) x
       JOIN product p ON p.code = 'SDWAN'`,
    [ids.won, ids.lost, ids.won2],
  );
  await c.query(
    `INSERT INTO opportunity_partner (opportunity_id, partner_id, partner_role, is_primary) VALUES (?, ?, 'SOURCED', 1)`,
    [ids.won, ids.ptr],
  );
  await c.query(
    `INSERT INTO partner_commercial (opportunity_id, partner_id, account_id, partner_role, version_no, deal_size_basis,
       price_to_partner, partner_margin_pct, payment_terms, pay_partner_after_customer)
     VALUES (?, ?, ?, 'SOURCED', 1, 'Deal value', 880000, 12, '30 days after customer payment', 1)`,
    [ids.won, ids.ptr, ids.acc],
  );
  await c.query(
    `INSERT INTO win_loss (opportunity_id, outcome, lesson, recorded_by) VALUES (?, 'WON', 'Early POC won it', ?)`,
    [ids.won, exec.id],
  );
  await c.query(
    `INSERT INTO win_loss (opportunity_id, outcome, loss_reason_id, lesson, recorded_by)
     SELECT ?, 'LOST', id, 'Engage the buyer earlier', ? FROM reason WHERE reason_type = 'LOSS' AND code = 'PRICE'`,
    [ids.lost, exec.id],
  );

  ids.o1 = await insert(
    c,
    `INSERT INTO sales_order (order_no, opportunity_id, account_id, fulfilment_partner_id, po_number, po_date, po_value,
       pay_partner_after_customer, status, first_invoice_on, order_to_book_days, invoiced_value, received_value,
       released_to_partner_value, revenue, gross_margin_pct)
     VALUES ('T-ORD-1', ?, ?, ?, 'PO-O-OPP-W', '2097-06-01', 1000000, 1, 'INVOICED', '2097-07-01', 30, 1000000,
             800000, 96000, 1000000, 30.00)`,
    [ids.won, ids.acc, ids.ptr],
  );
  ids.o2 = await insert(
    c,
    `INSERT INTO sales_order (order_no, opportunity_id, account_id, po_number, po_date, po_value, status)
     VALUES ('T-ORD-2', ?, ?, 'PO-O-OPP-W2', '2097-06-01', 300000, 'PO_RECEIVED')`,
    [ids.won2, ids.acc2],
  );
  await c.query(
    `INSERT INTO order_event (order_id, status, event_date, by_user_id) VALUES (?, 'PO_RECEIVED', '2097-06-01', ?),
       (?, 'INVOICED', '2097-07-01', ?)`,
    [ids.o1, exec.id, ids.o1, exec.id],
  );
  // the second invoice fell due long ago and is unpaid: shown as OVERDUE
  ids.inv1 = await insert(
    c,
    `INSERT INTO invoice (order_id, invoice_no, invoice_date, due_date, amount, paid_amount, status)
     VALUES (?, 'T-INV-1', '2097-07-01', '2097-07-31', 800000, 800000, 'PAID')`,
    [ids.o1],
  );
  await c.query(
    `INSERT INTO invoice (order_id, invoice_no, invoice_date, due_date, amount, status)
     VALUES (?, 'T-INV-2', '2026-01-01', '2026-01-31', 200000, 'OPEN')`,
    [ids.o1],
  );
  await c.query(
    `INSERT INTO payment (order_id, invoice_id, direction, partner_id, amount, paid_on, delay_days)
     VALUES (?, ?, 'RECEIVED', NULL, 800000, '2097-08-05', 5), (?, ?, 'RELEASED', ?, 96000, '2097-08-15', NULL)`,
    [ids.o1, ids.inv1, ids.o1, ids.inv1, ids.ptr],
  );

  /** @param {string} entity @param {number} entityId @param {number|null} opp @param {number} acc @param {string} title @param {string} type @param {number} by */
  const doc = async (entity, entityId, opp, acc, title, type, by) => {
    const file = await insert(
      c,
      `INSERT INTO file_object (storage_key, original_name, mime_type, size_bytes, checksum_sha256, scan_status)
       VALUES (UUID(), ?, 'application/pdf', 12345, REPEAT('a', 64), 'CLEAN')`,
      [`${title}.pdf`],
    );
    return insert(
      c,
      `INSERT INTO document (entity_type, entity_id, opportunity_id, account_id, file_object_id, title, document_type_id,
         shared_with, shared_on, created_by)
       SELECT ?, ?, ?, ?, ?, ?, id, 'CUSTOMER', '2097-06-02', ? FROM document_type WHERE code = ?`,
      [entity, entityId, opp, acc, file, title, by, type],
    );
  };
  ids.d1 = await doc('OPP', ids.won, ids.won, ids.acc, 'T-DOC proposal W', 'PROPOSAL', exec.id);
  await c.query(
    `INSERT INTO document_tag (document_id, tag) VALUES (?, 't-fixture'), (?, 'sdwan')`,
    [ids.d1, ids.d1],
  );
  await doc(
    'ORDER',
    ids.o1,
    ids.won,
    ids.acc,
    'T-DOC purchase order O1',
    'PURCHASE_ORDER',
    exec.id,
  );
  await doc('OPP', ids.won2, ids.won2, ids.acc2, 'T-DOC proposal W2', 'PROPOSAL', other.id);
});
afterAll(closeAll);

/** @param {{ token: string }} who @param {string} path */
const get = (who, path) => api().get(`/api/v1${path}`).set(bearer(who.token));
/** @param {any} body */
const nos = (body) => body.data.map((/** @type {any} */ r) => r.orderNo).sort();

describe('orders', () => {
  test('scope: own deals for an executive, every order for finance, none without order.view', async () => {
    const mine = (await get(exec, '/orders?search=T-ORD')).body;
    expect(nos(mine)).toEqual(['T-ORD-1']);
    expect(mine.data[0]).toMatchObject({
      accountName: 'Order Test Bank',
      partnerName: 'Order Partner',
      poValue: '1000000.00',
      outstanding: '200000.00',
      overdueInvoices: 1,
      gmPct: 30,
    });
    expect(mine.meta.totals).toMatchObject({ orders: 1, received: '800000.00' });
    expect(
      mine.meta.statusCounts.find((/** @type {any} */ s) => s.status === 'INVOICED').count,
    ).toBe(1);

    expect(nos((await get(finance, '/orders?search=T-ORD')).body)).toEqual(['T-ORD-1', 'T-ORD-2']);
    expect(nos((await get(other, '/orders?search=T-ORD&status=PO_RECEIVED')).body)).toEqual([
      'T-ORD-2',
    ]);
    expect((await get(presales, '/orders')).status).toBe(403);
    expect((await get(exec, `/orders/${ids.o2}`)).status).toBe(404);
    expect((await get(exec, '/orders?status=SHIPPED')).status).toBe(422);
  });

  test('the order workspace: track, overdue invoice, BR-OR-05 check, partner commercial', async () => {
    const w = (await get(exec, `/orders/${ids.o1}`)).body.data;
    expect(w.order).toMatchObject({ orderNo: 'T-ORD-1', payPartnerAfterCustomer: true, gmPct: 30 });
    expect(w.track.map((/** @type {any} */ s) => s.code)).toEqual([
      'PO_RECEIVED',
      'PO_TO_MFR',
      'GOODS_DELIVERED',
      'DEPLOYED',
      'INVOICED',
      'PAID',
      'CLOSED',
    ]);
    expect(w.events).toHaveLength(2);
    expect(w.invoices.map((/** @type {any} */ i) => [i.invoiceNo, i.status])).toEqual([
      ['T-INV-2', 'OVERDUE'],
      ['T-INV-1', 'PAID'],
    ]);
    expect(w.payments.map((/** @type {any} */ p) => p.direction)).toEqual(['RECEIVED', 'RELEASED']);
    expect(w.partnerRelease).toMatchObject({
      payAfterCustomer: true,
      customerReceived: '800000.00',
      released: '96000.00',
      withinRule: true,
      partnerPrice: '880000.00',
      partnerMarginPct: 12,
    });

    // finance releases partner payments, so it sees the partner commercial too
    const f = (await get(finance, `/orders/${ids.o1}`)).body.data;
    expect(f.partnerRelease).toMatchObject({ withinRule: true, partnerPrice: '880000.00' });
  });
});

describe('win / loss', () => {
  test('summary and closed deals for a fiscal year, within scope', async () => {
    const s = (await get(exec, `/win-loss/summary?fiscalYear=${FY}`)).body.data;
    expect(s.period).toMatchObject({ fiscalYear: FY, quarter: null, fromDate: '2097-04-01' });
    expect(s.kpis).toMatchObject({
      wonCount: 1,
      wonValue: '1000000.00',
      lostCount: 1,
      winRatePct: 50,
    });
    expect(s.lossReasons).toEqual([expect.objectContaining({ reason: 'Price', count: 1 })]);
    expect(s.trend).toEqual([expect.objectContaining({ month: '2097-06', won: 1, lost: 1 })]);
    expect(s.lessons.map((/** @type {any} */ l) => l.isWon).sort()).toEqual([false, true]);

    const lost = (await get(exec, `/win-loss/deals?fiscalYear=${FY}&outcome=LOST`)).body;
    expect(lost.meta.total).toBe(1);
    expect(lost.data[0]).toMatchObject({ opportunityNo: 'O-OPP-L', lossReason: 'Price' });

    expect((await get(exec, '/win-loss/summary?quarter=2')).status).toBe(422);
    expect((await get(finance, `/win-loss/summary?fiscalYear=${FY}`)).status).toBe(403);
  });

  test('competitor filter (V035): deals with the competitor on them or lost to it', async () => {
    const c = await dba();
    const [[cp]] = await c.query('SELECT id FROM competitor ORDER BY id LIMIT 1');
    await c.query(
      'INSERT INTO opportunity_competitor (opportunity_id, competitor_id) VALUES (?, ?)',
      [ids.won, cp.id],
    );
    const s = (await get(exec, `/win-loss/summary?fiscalYear=${FY}&competitorId=${cp.id}`)).body
      .data;
    expect(s.kpis).toMatchObject({ wonCount: 1, lostCount: 0 });
  });

  test('export: xlsx of the closed deals, logged', async () => {
    const res = await api().get(`/api/v1/win-loss/export?fiscalYear=${FY}`).set(bearer(exec.token));
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/spreadsheetml/);
    const c = await dba();
    const [[log]] = await c.query(
      `SELECT COUNT(*) AS n FROM record_access_log WHERE user_id = ? AND entity_type = 'WIN_LOSS' AND access_type = 'EXPORT'`,
      [exec.id],
    );
    expect(log.n).toBe(1);
  });
});

describe('documents', () => {
  test('search over the visible records, by text, tag and record type', async () => {
    const mine = (await get(exec, '/documents?search=T-DOC')).body;
    expect(mine.data.map((/** @type {any} */ d) => d.title).sort()).toEqual([
      'T-DOC proposal W',
      'T-DOC purchase order O1',
    ]);
    const tagged = (await get(exec, '/documents?tag=t-fixture')).body.data;
    expect(tagged).toHaveLength(1);
    expect(tagged[0]).toMatchObject({
      typeCode: 'PROPOSAL',
      entityType: 'OPP',
      entityLabel: 'O-OPP-W · Deal O-OPP-W',
      sizeBytes: 12345,
      tags: ['sdwan', 't-fixture'],
    });
    const orders = (await get(exec, '/documents?search=T-DOC&entityType=ORDER')).body;
    expect(orders.data.map((/** @type {any} */ d) => d.entityLabel)).toEqual(['T-ORD-1']);

    expect(
      (await get(other, '/documents?search=T-DOC')).body.data.map(
        (/** @type {any} */ d) => d.title,
      ),
    ).toEqual(['T-DOC proposal W2']);
    expect((await get(exec, '/documents?sharedWith=EVERYONE')).status).toBe(422);
  });
});

describe('reports', () => {
  test('revenue and GM by dimension, product mix', async () => {
    const r = (await get(exec, `/reports/REVENUE_GM?fiscalYear=${FY}&dimension=PARTNER`)).body.data;
    expect(r.rows).toEqual([
      expect.objectContaining({
        label: 'Order Partner',
        deals: 1,
        revenue: '1000000.00',
        gmPct: 30,
      }),
    ]);
    expect(r.totals).toMatchObject({ deals: 1, grossMargin: '300000.00' });

    const all = (await get(finance, `/reports/REVENUE_GM?fiscalYear=${FY}`)).body.data;
    expect(all.totals).toMatchObject({ deals: 2, revenue: '1300000.00', gmPct: 30 });

    const mix = (await get(exec, `/reports/PRODUCT_MIX?fiscalYear=${FY}`)).body.data;
    expect(mix.partners).toEqual([
      expect.objectContaining({ partnerName: 'Order Partner', products: 1, won: 1 }),
    ]);
    expect(mix.accounts.map((/** @type {any} */ a) => a.accountName)).toContain('Order Test Bank');

    expect((await get(exec, '/reports/WEEKLY_STATUS')).status).toBe(422);
    expect((await get(exec, '/reports/REVENUE_GM?dimension=OWNER')).status).toBe(422);
  });
});

// ──────────────────────────────────────────────────────────────────────────────
// Write side (V019): events, invoices, payments, finance
// ──────────────────────────────────────────────────────────────────────────────

/** @param {{ token: string }} who @param {string} path @param {any} body */
const post = (who, path, body) => api().post(`/api/v1${path}`).set(bearer(who.token)).send(body);
/** @param {{ token: string }} who @param {string} path @param {any} body */
const patch = (who, path, body) => api().patch(`/api/v1${path}`).set(bearer(who.token)).send(body);

describe('order events (V019)', () => {
  test('advance order status and reject backwards transitions (BR-OR-02)', async () => {
    // o2 is PO_RECEIVED; advance to PO_TO_MFR
    const ok = await post(other, `/orders/${ids.o2}/events`, {
      status: 'PO_TO_MFR',
      eventDate: '2097-07-01',
    });
    expect(ok.status).toBe(200);
    expect(ok.body.data.status).toBe('PO_TO_MFR');

    // confirm new status in workspace
    const ws = (await get(other, `/orders/${ids.o2}`)).body.data;
    expect(ws.order.status).toBe('PO_TO_MFR');

    // cannot go backwards to PO_RECEIVED
    const back = await post(other, `/orders/${ids.o2}/events`, {
      status: 'PO_RECEIVED',
      eventDate: '2097-07-02',
    });
    expect(back.status).toBe(422);

    // event date before PO date is rejected
    const badDate = await post(other, `/orders/${ids.o2}/events`, {
      status: 'GOODS_DELIVERED',
      eventDate: '2096-01-01',
    });
    expect(badDate.status).toBe(422);

    // order.update required
    expect(
      (
        await post(finance, `/orders/${ids.o2}/events`, {
          status: 'GOODS_DELIVERED',
          eventDate: '2097-07-10',
        })
      ).status,
    ).toBe(403);
  });
});

describe('invoices (V019)', () => {
  test('create invoice and set order-to-book on first; reject duplicates (BR-OR-03)', async () => {
    // o2 has no invoices yet; first invoice sets order-to-book
    const inv = await post(finance, `/orders/${ids.o2}/invoices`, {
      invoiceNo: 'WRT-INV-1',
      invoiceDate: '2097-07-15',
      dueDate: '2097-08-14',
      amount: '150000',
    });
    expect(inv.status).toBe(201);
    const invId = inv.body.data.id;

    const ws = (await get(finance, `/orders/${ids.o2}`)).body.data;
    expect(ws.order.firstInvoiceOn).toBe('2097-07-15');
    expect(ws.order.orderToBookDays).toBe(44); // 2097-07-15 minus 2097-06-01
    expect(ws.invoices[0]).toMatchObject({
      invoiceNo: 'WRT-INV-1',
      amount: '150000.00',
      status: 'OPEN',
    });

    // duplicate invoice number
    const dup = await post(finance, `/orders/${ids.o2}/invoices`, {
      invoiceNo: 'WRT-INV-1',
      invoiceDate: '2097-07-16',
      dueDate: '2097-08-15',
      amount: '50000',
    });
    expect(dup.status).toBe(409);

    // due date before invoice date
    const badDates = await post(finance, `/orders/${ids.o2}/invoices`, {
      invoiceNo: 'WRT-INV-2',
      invoiceDate: '2097-08-01',
      dueDate: '2097-07-01',
      amount: '50000',
    });
    expect(badDates.status).toBe(422);

    // edit the invoice
    const updated = await patch(finance, `/orders/${ids.o2}/invoices/${invId}`, {
      invoiceNo: 'WRT-INV-1',
      invoiceDate: '2097-07-15',
      dueDate: '2097-08-14',
      amount: '160000',
    });
    expect(updated.status).toBe(200);

    // order.finance required
    expect(
      (
        await post(exec, `/orders/${ids.o2}/invoices`, {
          invoiceNo: 'X',
          invoiceDate: '2097-07-15',
          dueDate: '2097-08-14',
          amount: '1000',
        })
      ).status,
    ).toBe(403);
  });
});

describe('payments (V019)', () => {
  test('record payment; enforce BR-OR-05 when pay_partner_after_customer=1', async () => {
    // o1 has pay_partner_after_customer=1, received=800000, released=96000
    // trying to release more than received should fail
    const overRelease = await post(finance, `/orders/${ids.o1}/payments`, {
      direction: 'RELEASED',
      partnerId: ids.ptr,
      amount: '800000',
      paidOn: '2097-09-01',
    });
    expect(overRelease.status).toBe(422);
    expect(overRelease.body.error.code).toBe('BUSINESS_RULE_VIOLATION');

    // o2 has no pay_partner_after_customer restriction; record a customer payment
    const rcv = await post(finance, `/orders/${ids.o2}/payments`, {
      direction: 'RECEIVED',
      invoiceId: null,
      amount: '100000',
      paidOn: '2097-08-20',
    });
    expect(rcv.status).toBe(201);

    const ws = (await get(finance, `/orders/${ids.o2}`)).body.data;
    expect(ws.payments[0]).toMatchObject({ direction: 'RECEIVED', amount: '100000.00' });

    // order.finance required
    expect(
      (
        await post(exec, `/orders/${ids.o2}/payments`, {
          direction: 'RECEIVED',
          amount: '1000',
          paidOn: '2097-08-20',
        })
      ).status,
    ).toBe(403);
  });
});

describe('finance fields (V019)', () => {
  test('update revenue and GM %; enforce percentage range (BR-OR-06)', async () => {
    const ok = await patch(finance, `/orders/${ids.o2}/finance`, {
      revenue: '280000',
      gmPct: 25,
      npPct: 12,
      recognisedOn: '2097-09-30',
    });
    expect(ok.status).toBe(200);

    const ws = (await get(finance, `/orders/${ids.o2}`)).body.data;
    expect(ws.order.revenue).toBe('280000.00');
    expect(ws.order.gmPct).toBe(25);
    expect(ws.order.npPct).toBe(12);
    expect(ws.order.revenueRecognisedOn).toBe('2097-09-30');

    // out of range
    expect((await patch(finance, `/orders/${ids.o2}/finance`, { gmPct: 150 })).status).toBe(422);

    // order.finance required
    expect((await patch(exec, `/orders/${ids.o2}/finance`, { revenue: '1000' })).status).toBe(403);
  });
});
