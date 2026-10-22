'use strict';

const { quarterlyReportPdf } = require('../../src/modules/partners/quarterlyReport.pdf');

describe('quarterlyReportPdf', () => {
  test('renders a PDF, breaking pages for long lists', async () => {
    const deals = Array.from({ length: 80 }, (_, i) => ({
      opportunityNo: `OPP-${i}`,
      title: 'A deal with a fairly long title that wraps',
      accountName: 'Acme',
      role: 'SOURCED',
    }));
    const pdf = await quarterlyReportPdf({
      partner: { partnerNo: 'PTR-0001', partnerName: 'Acme Partner' },
      period: { label: 'FY 2026-27 Q2', fromDate: '2026-07-01', toDate: '2026-09-30' },
      card: { rating: 4, score: 71.5, winPct: 60 },
      lossReasons: [{ reasonName: 'Price', count: 2 }],
      deals,
      engagements: [],
      generatedAt: new Date('2026-10-14T00:00:00Z'),
    });
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    expect((pdf.toString('latin1').match(/\/Type \/Page\b/g) ?? []).length).toBeGreaterThan(1);
  });
});
