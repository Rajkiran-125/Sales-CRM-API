// @ts-check
'use strict';

/**
 * The Partner Quarterly Report (12.11, UM 7.2) as a PDF with pdfkit (the Orchestrator's
 * library, 0.20). One A4 page or more: header, rating, every scorecard measure, loss reasons,
 * the period's deals and engagements.
 */
const PDFDocument = require('pdfkit');

const TEAL = '#00796b';
const INK = '#1f2933';
const SOFT = '#6b7280';
const LINE = '#d9e2e1';

const inr = (/** @type {unknown} */ v) =>
  v === null || v === undefined || v === '' ? '—' : `INR ${Number(v).toLocaleString('en-IN')}`;
const pct = (/** @type {unknown} */ v) => (v === null || v === undefined ? '—' : `${Number(v)} %`);
const num = (/** @type {unknown} */ v) => (v === null || v === undefined ? '—' : String(v));
const day = (/** @type {unknown} */ v) =>
  v ? (v instanceof Date ? v.toISOString() : String(v)).slice(0, 10) : '—';

/**
 * @typedef {object} ReportData
 * @property {{ partnerNo: string, partnerName: string, types?: string | null, ownerName?: string | null, tier?: string | null }} partner
 * @property {{ label: string, fromDate: unknown, toDate: unknown }} period
 * @property {Record<string, any> | null} card   the scorecard row of the period
 * @property {{ reasonName: string, count: number }[]} lossReasons
 * @property {{ opportunityNo: string, title: string, accountName: string, role: string, stageName?: string, value?: unknown }[]} deals
 * @property {{ engagementType: string, engagementOn: unknown, withWhom: string | null, byName?: string }[]} engagements
 * @property {Date} generatedAt
 */

/**
 * @param {ReportData} data
 * @returns {Promise<Buffer>}
 */
function quarterlyReportPdf(data) {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 48, info: { Title: titleOf(data) } });
    /** @type {Buffer[]} */
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    const width = doc.page.width - 96;
    const card = data.card ?? {};

    // header
    doc.fillColor(TEAL).fontSize(18).text('Partner Quarterly Report', { continued: false });
    doc
      .moveDown(0.2)
      .fillColor(INK)
      .fontSize(13)
      .text(`${data.partner.partnerName} · ${data.partner.partnerNo}`);
    doc
      .fillColor(SOFT)
      .fontSize(9)
      .text(
        `${data.period.label} (${day(data.period.fromDate)} to ${day(data.period.toDate)})` +
          `${data.partner.types ? ` · ${data.partner.types}` : ''}` +
          `${data.partner.ownerName ? ` · owner ${data.partner.ownerName}` : ''}` +
          ` · generated ${data.generatedAt.toISOString().slice(0, 10)}`,
      );
    rule(doc, width);

    // rating
    doc
      .fillColor(INK)
      .fontSize(12)
      .text(
        `Rating ${card.rating ? `${card.rating} / 5` : '—'}   ·   Score ${num(card.score)}   ·   ` +
          `Recommended tier ${card.tierRecommendation ?? '—'}${data.partner.tier ? ` (now ${data.partner.tier})` : ''}`,
      );
    doc.moveDown(0.6);

    section(doc, 'Scorecard');
    table(doc, width, [
      ['Sourced deals', `${num(card.sourcedCount)} · ${inr(card.sourcedValue)}`],
      ['Influenced deals', `${num(card.influencedCount)} · ${inr(card.influencedValue)}`],
      ['Active deals / pipeline', `${num(card.activeDeals)} · ${inr(card.pipeline)}`],
      ['Closed: won / lost', `${num(card.wonDeals)} / ${num(card.lostDeals)}`],
      ['Win %', pct(card.winPct)],
      ['Revenue (won)', inr(card.revenue)],
      ['Average deal size', inr(card.avgDealSize)],
      ['GM % · NP %', `${pct(card.gmPct)} · ${pct(card.npPct)}`],
      ['Lead to deal (days)', num(card.leadToDealDays)],
      ['Order to booking (days)', num(card.orderToBookDays)],
      ['On-time payment', pct(card.onTimePaymentPct)],
      ['Average payment delay (days)', num(card.avgPaymentDelayDays)],
      [
        'Third layer: repeat · new logos · strategic · replacement',
        `${num(card.repeatBusiness)} · ${num(card.newLogos)} · ${num(card.strategicAccounts)} · ${num(card.competitionReplacement)}`,
      ],
      ['Product mix', num(card.productMix)],
      [
        'Tenders: pipeline · readiness',
        `${num(card.tenderPipelineCount)} · ${pct(card.tenderReadinessPct)}`,
      ],
      [
        'GTM activities · CEC engagements',
        `${num(card.gtmActivities)} · ${num(card.cecEngagements)}`,
      ],
      ['Weekly status discipline', pct(card.updateDisciplinePct)],
    ]);

    section(doc, 'Loss reasons');
    if (!data.lossReasons.length) note(doc, 'No lost deals in the period.');
    else
      table(
        doc,
        width,
        data.lossReasons.map((r) => [r.reasonName, String(r.count)]),
      );

    section(doc, 'Deals in the period');
    if (!data.deals.length) note(doc, 'No deals in the period.');
    else
      table(
        doc,
        width,
        data.deals.map((d) => [
          `${d.opportunityNo} · ${d.title}`,
          `${d.accountName} · ${d.role}${d.stageName ? ` · ${d.stageName}` : ''}`,
        ]),
      );

    section(doc, 'Engagements');
    if (!data.engagements.length) note(doc, 'No engagements logged in the period.');
    else
      table(
        doc,
        width,
        data.engagements.map((e) => [
          `${day(e.engagementOn)} · ${e.engagementType}`,
          `${e.withWhom ?? ''}${e.byName ? ` (by ${e.byName})` : ''}`,
        ]),
      );

    doc.end();
  });
}

/** @param {ReportData} data */
const titleOf = (data) => `Partner Quarterly Report ${data.partner.partnerNo} ${data.period.label}`;

/** @param {any} doc @param {number} width */
function rule(doc, width) {
  doc.moveDown(0.5);
  doc
    .moveTo(48, doc.y)
    .lineTo(48 + width, doc.y)
    .strokeColor(LINE)
    .stroke();
  doc.moveDown(0.6);
}

/** @param {any} doc @param {string} title */
function section(doc, title) {
  doc.moveDown(0.6).fillColor(TEAL).fontSize(11).text(title);
  doc.moveDown(0.3);
}

/** @param {any} doc @param {string} text */
function note(doc, text) {
  doc.fillColor(SOFT).fontSize(9).text(text);
}

/**
 * Two-column rows with a thin rule under each; breaks the page when needed.
 * @param {any} doc @param {number} width @param {string[][]} rows
 */
function table(doc, width, rows) {
  const left = width * 0.48;
  for (const [a, b] of rows) {
    const h = Math.max(
      doc.heightOfString(a, { width: left - 8 }),
      doc.heightOfString(b, { width: width - left }),
    );
    if (doc.y + h + 8 > doc.page.height - 48) doc.addPage();
    const y = doc.y;
    doc
      .fillColor(INK)
      .fontSize(9)
      .text(a, 48, y, { width: left - 8 });
    doc.text(b, 48 + left, y, { width: width - left });
    doc.y = y + h + 3;
    doc
      .moveTo(48, doc.y)
      .lineTo(48 + width, doc.y)
      .strokeColor(LINE)
      .lineWidth(0.5)
      .stroke();
    doc.y += 4;
  }
  doc.x = 48;
}

module.exports = { quarterlyReportPdf, titleOf };
