'use strict';

const { checkRows } = require('../../src/modules/imports/imports.partners');

const lookups = {
  types: [
    { id: 1, code: 'MSP', name: 'MSP' },
    { id: 5, code: 'SI', name: 'System integrator' },
  ],
  users: [
    { id: 10, email: 'pm@x.test' },
    { id: 11, email: 'b@x.test' },
  ],
};
const row = (rowNo, raw) => ({ rowNo, raw: { country: '', ...raw } });

describe('partner import rows', () => {
  test('maps a good row; reports each problem; catches duplicates in the file and the CRM', async () => {
    const rows = [
      row(2, {
        legalName: 'Alpha Ltd',
        types: 'msp, System integrator',
        ownerEmail: 'PM@x.test',
        gstNo: '27aapca1234b1z5',
      }),
      row(3, { legalName: '', types: 'XYZ', ownerEmail: 'nobody@x.test' }),
      row(4, { legalName: 'alpha ltd', types: 'MSP', ownerEmail: 'pm@x.test' }),
      row(5, {
        legalName: 'Beta Ltd',
        types: 'MSP',
        ownerEmail: 'pm@x.test',
        backupOwnerEmail: 'pm@x.test',
      }),
      row(6, { legalName: 'Gamma Ltd', types: 'MSP', ownerEmail: 'pm@x.test' }),
    ];
    const inCrm = async (r) =>
      r.name === 'Gamma Ltd' ? { name: 'Gamma', partnerNo: 'PTR-0001', ownerName: 'Ravi' } : null;
    const out = await checkRows(rows, lookups, inCrm);

    expect(out[0]).toMatchObject({
      status: 'VALID',
      mapped: {
        legalName: 'Alpha Ltd',
        country: 'India',
        typeIds: [1, 5],
        relationshipOwnerUserId: 10,
        gstNo: '27AAPCA1234B1Z5',
      },
    });
    expect(out[1].errors).toEqual([
      'Legal name is required.',
      'Unknown partner type: XYZ.',
      'No active user with the email nobody@x.test.',
    ]);
    expect(out[2].errors).toEqual(['Same partner as row 2.']);
    expect(out[3].errors).toEqual(['The backup owner must differ from the owner.']);
    expect(out[4].errors?.[0]).toMatch(/^Already in the CRM: Gamma \(PTR-0001\), owner Ravi/);
  });
});
