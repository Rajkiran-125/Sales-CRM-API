// @ts-check
'use strict';

/**
 * Excel exports (8.11) with exceljs. Cells that start with = + - @ (or tab / CR) are
 * prefixed with an apostrophe so a spreadsheet never runs them as formulas (17.5).
 */
const ExcelJS = require('exceljs');

/** @typedef {{ header: string, key: string, width?: number, format?: (value: any, row: any) => unknown }} Column */
/** @typedef {{ name: string, columns: Column[], rows: Array<Record<string, any>> }} Sheet */

/** @param {unknown} value */
function safeCell(value) {
  if (value === null || value === undefined) return '';
  if (value instanceof Date) return value;
  if (typeof value === 'object') return JSON.stringify(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(value)) return `'${value}`;
  return value;
}

/**
 * A workbook with one sheet per entry, each with a bold, frozen header row.
 * @param {Sheet[]} sheets
 */
function buildWorkbook(sheets) {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = 'Sales CRM';
  workbook.created = new Date();
  for (const { name, columns, rows } of sheets) {
    const sheet = workbook.addWorksheet(name.slice(0, 31), {
      views: [{ state: 'frozen', ySplit: 1 }],
    });
    sheet.columns = columns.map((c) => ({ header: c.header, key: c.key, width: c.width ?? 18 }));
    sheet.getRow(1).font = { bold: true };
    for (const row of rows) {
      /** @type {Record<string, unknown>} */
      const out = {};
      for (const c of columns)
        out[c.key] = safeCell(c.format ? c.format(row[c.key], row) : row[c.key]);
      sheet.addRow(out);
    }
  }
  return workbook;
}

/**
 * The workbook as an .xlsx buffer (email attachments).
 * @param {string} sheetName
 * @param {Column[]} columns
 * @param {Array<Record<string, any>>} rows
 */
async function workbookBuffer(sheetName, columns, rows) {
  return Buffer.from(await buildWorkbook([{ name: sheetName, columns, rows }]).xlsx.writeBuffer());
}

/**
 * Write sheets to the response as an .xlsx download.
 * @param {import('express').Response} res
 * @param {string} fileName  without extension
 * @param {Sheet[]} sheets
 */
async function sendSheets(res, fileName, sheets) {
  const workbook = buildWorkbook(sheets);
  const safeName = fileName.replace(/[^A-Za-z0-9_-]/g, '_');
  res.setHeader(
    'Content-Type',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  res.setHeader('Content-Disposition', `attachment; filename="${safeName}.xlsx"`);
  await workbook.xlsx.write(res);
  res.end();
}

/**
 * Write one sheet to the response as an .xlsx download.
 * @param {import('express').Response} res
 * @param {string} fileName  without extension
 * @param {string} sheetName
 * @param {Column[]} columns
 * @param {Array<Record<string, any>>} rows
 */
const sendWorkbook = (res, fileName, sheetName, columns, rows) =>
  sendSheets(res, fileName, [{ name: sheetName, columns, rows }]);

module.exports = { sendWorkbook, sendSheets, workbookBuffer, safeCell };
