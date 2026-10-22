'use strict';

/** Content check for uploads (17.9): the bytes must match the extension. */
const { contentMatches, checkFiles } = require('../../src/modules/documents/documents.upload');

const file = (name, bytes) => ({
  originalname: name,
  size: bytes.length,
  buffer: Buffer.from(bytes),
});
const limits = { maxSizeMb: 1, maxFiles: 2, allowedExtensions: 'pdf,docx,doc,png,csv' };

describe('contentMatches', () => {
  test.each([
    ['pdf', [0x25, 0x50, 0x44, 0x46, 0x2d], true],
    ['pdf', [0x50, 0x4b, 0x03, 0x04], false],
    ['docx', [0x50, 0x4b, 0x03, 0x04, 0x14], true],
    ['doc', [0xd0, 0xcf, 0x11, 0xe0, 0xa1], true],
    ['png', [0x89, 0x50, 0x4e, 0x47, 0x0d], true],
    ['jpg', [0xff, 0xd8, 0xff, 0xe0], true],
    ['csv', [0x61, 0x2c, 0x62], true],
    ['csv', [0x61, 0x00, 0x62], false],
    ['exe', [0x4d, 0x5a], false],
  ])('%s %j → %s', (ext, bytes, expected) => {
    expect(contentMatches(ext, Buffer.from(bytes))).toBe(expected);
  });
});

describe('checkFiles', () => {
  test('maps the content type from the extension, case-insensitive', () => {
    const [r] = checkFiles([file('A.PDF', [0x25, 0x50, 0x44, 0x46])], limits);
    expect(r).toMatchObject({ ext: 'pdf', mime: 'application/pdf' });
  });

  test('rejects too many files, a type outside the settings and an oversize file', () => {
    const pdf = file('a.pdf', [0x25, 0x50, 0x44, 0x46]);
    expect(() => checkFiles([pdf, pdf, pdf], limits)).toThrow(/at most 2 files/);
    expect(() => checkFiles([file('a.jpg', [0xff, 0xd8, 0xff])], limits)).toThrow(
      /Allowed file types/,
    );
    const big = { ...pdf, size: 2 * 1048576 };
    expect(() => checkFiles([big], limits)).toThrow(/at most 1 MB/);
    expect(() => checkFiles([], limits)).toThrow(/Choose a file/);
  });
});
