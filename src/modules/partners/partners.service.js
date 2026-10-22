// @ts-check
'use strict';

/**
 * Partners (12.7, UM 7.1) and partner performance (12.11, UM 7.2), read side (D-27). Every
 * measure is computed by the V009 procedures; the score is provisional until OD-42 (D-28).
 * Partner Master create and per-section edit: V030.
 */
const repo = require('./partners.repository');
const { shape, shapeAll } = require('../../shared/readModel');
const { offsetOf } = require('../../shared/schemas');
const { appError } = require('../../shared/errors');
const storage = require('../../integrations/fileStorage');
const documentsRepo = require('../documents/documents.repository');
const { quarterlyReportPdf } = require('./quarterlyReport.pdf');

const EXPORT_LIMIT = 10000;

/** partner.regions (JSON) as a list of codes, whether the driver parsed it or not. @param {unknown} v */
const regionList = (v) =>
  v === null || v === undefined ? [] : typeof v === 'string' ? JSON.parse(v) : v;

/** Decimal percentages and averages of a scorecard become numbers (they are not money). */
const CARD = {
  numbers: [
    'winPct',
    'score',
    'leadToDealDays',
    'orderToBookDays',
    'gmPct',
    'npPct',
    'onTimePaymentPct',
    'avgPaymentDelayDays',
    'tenderReadinessPct',
    'updateDisciplinePct',
  ],
};

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total, period } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: shapeAll(rows, { numbers: ['winPct', 'score', 'completenessPct'] }),
      meta: { page: q.page, pageSize: q.pageSize, total, sort: q.sort, period },
    };
  },

  /**
   * @param {number} userId
   * @param {number} id
   */
  async get(userId, id) {
    const [
      [partner],
      types,
      industries,
      certifications,
      customerCodes,
      contacts,
      [scorecard],
      deals,
      engagements,
      accountMap,
      activities,
      subPartners,
    ] = await repo.get(userId, id);
    const p = shape(partner, { numbers: ['ourSharePct', 'completenessPct'] });
    return {
      partner: { ...p, regions: regionList(p.regions) },
      types,
      industries,
      certifications: certifications.map((c) => c.name),
      customerCodes,
      contacts,
      scorecard: shape(scorecard, CARD),
      deals,
      engagements,
      accountMap,
      activities,
      subPartners: subPartners ?? [],
    };
  },

  /**
   * Generate the Partner Quarterly Report PDF and store it as a document of the partner
   * (type QUARTERLY_REPORT, V034); the same period again becomes the next version.
   * @param {number} partnerId
   * @param {{ fiscalYear: number, quarter: number }} q
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async quarterlyReport(partnerId, q, meta) {
    const userId = /** @type {number} */ (meta.actorUserId);
    const [[period], , cards] = await repo.performance(userId, q);
    const card = (cards ?? []).find((c) => Number(c.partnerId) === partnerId);
    if (!card)
      throw appError('NOT_FOUND', 'Partner not found.', [
        { field: 'id', message: 'Partner not found.' },
      ]);
    const [lossReasons, deals, engagements] = await repo.performanceOne(userId, partnerId, q);
    const label = `FY ${q.fiscalYear}-${String((q.fiscalYear + 1) % 100).padStart(2, '0')} Q${q.quarter}`;
    const data = {
      partner: card,
      period: { label, fromDate: period?.fromDate, toDate: period?.toDate },
      card: shape(card, CARD),
      lossReasons: lossReasons ?? [],
      deals: deals ?? [],
      engagements: engagements ?? [],
      generatedAt: new Date(),
    };
    const pdf = await quarterlyReportPdf(/** @type {any} */ (data));
    const { key, sha256 } = await storage.save(pdf);
    const title = `Quarterly report ${label}`;
    const fileName = `${card.partnerNo}_${label.replace(/\s+/g, '_')}.pdf`;
    try {
      const row = await documentsRepo.create(
        {
          entityType: 'PARTNER',
          entityId: partnerId,
          documentTypeCode: 'QUARTERLY_REPORT',
          sharedWith: 'INTERNAL',
          sharedWithPartnerId: null,
          sharedOn: null,
          notes: null,
          tags: ['quarterly-report'],
        },
        {
          title,
          originalName: fileName,
          ext: 'pdf',
          mime: 'application/pdf',
          size: pdf.length,
          sha256,
          key,
        },
        meta,
      );
      return { documentId: Number(row.id), versionNo: Number(row.versionNo), title, fileName };
    } catch (err) {
      await storage.remove(key);
      throw err;
    }
  },

  /**
   * The partner's stored quarterly reports, newest first.
   * @param {number} userId
   * @param {number} partnerId
   */
  async quarterlyReports(userId, partnerId) {
    const { rows } = await documentsRepo.list(userId, {
      type: 'QUARTERLY_REPORT',
      entityType: 'PARTNER',
      partnerId,
      offset: 0,
      limit: 50,
    });
    return rows.map((r) => ({
      documentId: r.id,
      title: r.title,
      versionNo: r.versionNo,
      fileName: r.fileName,
      createdAt: r.createdAt,
    }));
  },

  /** BR-PT-02: same name / GST / website among all partners, with the owner. @param {any} q */
  async duplicates(q) {
    const [rows] = await repo.duplicates(q);
    return rows ?? [];
  },

  /**
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  async create(body, meta, allowAny) {
    const row = await repo.create(body, meta, allowAny);
    return { id: Number(row?.id), partnerNo: row?.partnerNo };
  },

  /**
   * Log or edit an engagement; a dated next action plans the next one as a task (V031).
   * @param {number} partnerId @param {number | null} id
   * @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  async engagementSave(partnerId, id, body, meta, allowAny) {
    const row = await repo.engagementSave(partnerId, id, body, meta, allowAny);
    return { id: Number(row?.id) };
  },

  /**
   * @param {number} partnerId @param {number | null} id
   * @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  async accountMapSave(partnerId, id, body, meta, allowAny) {
    const row = await repo.accountMapSave(partnerId, id, body, meta, allowAny);
    return { id: Number(row?.id) };
  },

  /**
   * @param {number} partnerId @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  accountMapDelete: (partnerId, id, meta, allowAny) =>
    repo.accountMapDelete(partnerId, id, meta, allowAny),

  /**
   * "Partner code at customers" (V042).
   * @param {number} partnerId @param {number | null} id
   * @param {any} body @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  async customerCodeSave(partnerId, id, body, meta, allowAny) {
    const row = await repo.customerCodeSave(partnerId, id, body, meta, allowAny);
    return { id: Number(row?.id) };
  },

  /**
   * @param {number} partnerId @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta @param {boolean} allowAny
   */
  customerCodeDelete: (partnerId, id, meta, allowAny) =>
    repo.customerCodeDelete(partnerId, id, meta, allowAny),

  /** The editable values with ids (V030, V042). @param {number} userId @param {number} id */
  async editGet(userId, id) {
    const [[partner], types, industries, certifications, contacts, customerCodes] =
      await repo.editGet(userId, id);
    const p = shape(partner, {
      bools: ['canRunPoc', 'usesCrm'],
      numbers: ['ourSharePct', 'completenessPct'],
    });
    return {
      ...p,
      regions: regionList(p.regions),
      typeIds: types.map((t) => Number(t.id)),
      industryIds: industries.map((i) => Number(i.id)),
      certificationTypeIds: certifications
        .filter((c) => c.certificationTypeId !== null)
        .map((c) => Number(c.certificationTypeId)),
      otherCertifications: certifications.filter((c) => c.otherName).map((c) => c.otherName),
      contacts: contacts ?? [],
      customerCodes: customerCodes ?? [],
    };
  },

  /**
   * One section of the Partner Master (12.7); answers the new version and completeness.
   * @param {number} id
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  async saveSection(id, body, meta, allowAny) {
    const row = await repo.saveSection(id, body, meta, allowAny);
    return {
      id: Number(row?.id),
      rowVersion: Number(row?.rowVersion),
      completenessPct: Number(row?.completenessPct),
    };
  },

  /**
   * The filtered list for Excel (8.11).
   * shortcut: capped at EXPORT_LIMIT rows, move to an async job (20.2) past that
   * @param {number} userId
   * @param {any} q
   */
  async exportRows(userId, q) {
    const { rows } = await repo.list(userId, { ...q, offset: 0, limit: EXPORT_LIMIT });
    return shapeAll(rows, { numbers: ['winPct', 'score', 'completenessPct'] });
  },

  /**
   * @param {number} userId
   * @param {any} q
   */
  async performance(userId, q) {
    const [[period], [totals], scorecards] = await repo.performance(userId, q);
    return {
      period: { ...period, quarter: period.quarter === null ? null : Number(period.quarter) },
      totals: shape(totals, { numbers: ['winPct'] }),
      scorecards: shapeAll(scorecards, CARD),
    };
  },

  /**
   * @param {number} userId
   * @param {number} partnerId
   * @param {any} q
   */
  async performanceOne(userId, partnerId, q) {
    const [lossReasons, deals, engagements] = await repo.performanceOne(userId, partnerId, q);
    return { lossReasons, deals, engagements };
  },
};
