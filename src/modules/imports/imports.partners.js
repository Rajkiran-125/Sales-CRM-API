// @ts-check
'use strict';

/**
 * Partner import rules (12.17): the template columns, reading the sheet and checking each row
 * with the same minimum as the New partner screen (BR-PT-01) plus duplicates in the file and
 * in the CRM (BR-PT-02). Pure functions; the service supplies the lookups.
 */

/** Template columns; * = required. Keys are the mapped field names. */
const COLUMNS = [
  { key: 'legalName', header: 'Legal name*', width: 36 },
  { key: 'shortName', header: 'Short name', width: 24 },
  { key: 'country', header: 'Country*', width: 14 },
  { key: 'types', header: 'Types* (codes or names, comma-separated)', width: 34 },
  { key: 'ownerEmail', header: 'Owner email*', width: 30 },
  { key: 'backupOwnerEmail', header: 'Backup owner email', width: 30 },
  { key: 'city', header: 'City', width: 16 },
  { key: 'website', header: 'Website', width: 28 },
  { key: 'gstNo', header: 'GST number', width: 18 },
];

const EXAMPLE = {
  legalName: 'Example Networks Pvt Ltd',
  shortName: 'Example Networks',
  country: 'India',
  types: 'MSP, SI',
  ownerEmail: 'owner@yourcompany.com',
  backupOwnerEmail: '',
  city: 'Pune',
  website: 'https://www.example-networks.in',
  gstNo: '27AAPCE1234B1Z5',
};

const MAX_ROWS = 2000;

/** @param {unknown} v */
const cell = (v) => {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object' && 'text' in /** @type {any} */ (v))
    return String(/** @type {any} */ (v).text).trim(); // hyperlinks
  if (typeof v === 'object' && 'result' in /** @type {any} */ (v))
    return String(/** @type {any} */ (v).result ?? '').trim(); // formulas
  return String(v).trim();
};

const site = (/** @type {string} */ w) =>
  w
    .toLowerCase()
    .replace(/^(https?:\/\/)?(www\.)?/, '')
    .replace(/\/+$/, '');

/**
 * The data rows of the first sheet, keyed by column (matched on the header text, so the
 * columns may be in any order). Empty rows are dropped.
 * @param {import('exceljs').Worksheet} sheet
 * @returns {{ rowNo: number, raw: Record<string, string> }[]}
 */
function readRows(sheet) {
  /** @type {Record<number, string>} */
  const keyOfCol = {};
  sheet.getRow(1).eachCell((c, col) => {
    const h = cell(c.value).toLowerCase();
    const match = COLUMNS.find(
      (k) => k.header.toLowerCase() === h || k.header.split(/[*(]/)[0].trim().toLowerCase() === h,
    );
    if (match) keyOfCol[col] = match.key;
  });
  const rows = [];
  for (let r = 2; r <= sheet.rowCount; r++) {
    /** @type {Record<string, string>} */
    const raw = {};
    for (const [col, key] of Object.entries(keyOfCol))
      raw[key] = cell(sheet.getRow(r).getCell(Number(col)).value);
    if (Object.values(raw).some(Boolean)) rows.push({ rowNo: r, raw });
  }
  return rows;
}

/**
 * @typedef {{ types: { id: number, code: string, name: string }[], users: { id: number, email: string }[] }} Lookups
 * @typedef {{ rowNo: number, raw: Record<string, string>, mapped: Record<string, unknown> | null, status: 'VALID' | 'INVALID', errors: string[] | null }} CheckedRow
 */

/**
 * Check every row; `inCrm` answers the CRM duplicate search for one row (name, GST, website).
 * @param {{ rowNo: number, raw: Record<string, string> }[]} rows
 * @param {Lookups} lookups
 * @param {(r: { name: string, gstNo: string, website: string }) => Promise<{ name: string, partnerNo: string, ownerName: string } | null>} inCrm
 * @returns {Promise<CheckedRow[]>}
 */
async function checkRows(rows, lookups, inCrm) {
  const typeByKey = new Map();
  for (const t of lookups.types) {
    typeByKey.set(t.code.toLowerCase(), t.id);
    typeByKey.set(t.name.toLowerCase(), t.id);
  }
  const userByEmail = new Map(lookups.users.map((u) => [u.email.toLowerCase(), u.id]));
  /** @type {Map<string, number>} first row of each name / GST / website in the file */
  const seen = new Map();
  /** @type {CheckedRow[]} */
  const out = [];

  for (const { rowNo, raw } of rows.slice(0, MAX_ROWS)) {
    const errors = [];
    const legalName = raw.legalName ?? '';
    const country = raw.country || 'India';
    if (!legalName) errors.push('Legal name is required.');
    if (legalName.length > 250) errors.push('Legal name: at most 250 characters.');
    if ((raw.shortName ?? '').length > 150) errors.push('Short name: at most 150 characters.');
    if (country.length > 80) errors.push('Country: at most 80 characters.');
    if ((raw.city ?? '').length > 100) errors.push('City: at most 100 characters.');
    if ((raw.website ?? '').length > 255) errors.push('Website: at most 255 characters.');

    const typeNames = (raw.types ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    const typeIds = [...new Set(typeNames.map((n) => typeByKey.get(n.toLowerCase())))];
    if (!typeNames.length) errors.push('At least one partner type is required.');
    const unknown = typeNames.filter((n) => !typeByKey.has(n.toLowerCase()));
    if (unknown.length) errors.push(`Unknown partner type: ${unknown.join(', ')}.`);

    const owner = userByEmail.get((raw.ownerEmail ?? '').toLowerCase());
    if (!raw.ownerEmail) errors.push('Owner email is required.');
    else if (!owner) errors.push(`No active user with the email ${raw.ownerEmail}.`);
    let backup = null;
    if (raw.backupOwnerEmail) {
      backup = userByEmail.get(raw.backupOwnerEmail.toLowerCase()) ?? null;
      if (!backup) errors.push(`No active user with the email ${raw.backupOwnerEmail}.`);
      else if (backup === owner) errors.push('The backup owner must differ from the owner.');
    }

    const gstNo = (raw.gstNo ?? '').toUpperCase();
    if (gstNo && !/^[0-9]{2}[A-Z0-9]{13}$/.test(gstNo))
      errors.push('A GST number has 15 characters, starting with 2 digits.');

    // duplicates inside the file, then in the CRM (only for rows that are otherwise fine)
    const keys = [
      legalName && `n:${legalName.toLowerCase()}`,
      gstNo && `g:${gstNo}`,
      raw.website && `w:${site(raw.website)}`,
    ].filter(Boolean);
    const earlier = keys.map((k) => seen.get(/** @type {string} */ (k))).find(Boolean);
    if (earlier) errors.push(`Same partner as row ${earlier}.`);
    for (const k of keys)
      if (!seen.has(/** @type {string} */ (k))) seen.set(/** @type {string} */ (k), rowNo);
    if (!errors.length) {
      const dup = await inCrm({ name: legalName, gstNo, website: raw.website ?? '' });
      if (dup)
        errors.push(`Already in the CRM: ${dup.name} (${dup.partnerNo}), owner ${dup.ownerName}.`);
    }

    out.push({
      rowNo,
      raw,
      mapped: errors.length
        ? null
        : {
            legalName,
            shortName: raw.shortName || null,
            country,
            typeIds,
            relationshipOwnerUserId: owner,
            backupOwnerUserId: backup,
            city: raw.city || null,
            website: raw.website || null,
            gstNo: gstNo || null,
          },
      status: errors.length ? 'INVALID' : 'VALID',
      errors: errors.length ? errors : null,
    });
  }
  return out;
}

module.exports = { COLUMNS, EXAMPLE, MAX_ROWS, readRows, checkRows };
