// @ts-check
'use strict';

/**
 * Multipart parsing and file checks for document uploads (17.9). The real limits come from
 * settings (sp_document_limits); multer only enforces the hard ceiling of the settings range.
 */
const multer = require('multer');
const path = require('path');
const { appError } = require('../../shared/errors');

const HARD_MAX_MB = 50; // file.max_size_mb may be set up to 50 (V002)
const HARD_MAX_FILES = 20; // file.max_files_per_request may be set up to 20

const parser = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: HARD_MAX_MB * 1048576, files: HARD_MAX_FILES, fields: 30 },
}).array('files', HARD_MAX_FILES);

/**
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function parseUpload(req, res, next) {
  parser(req, res, (/** @type {any} */ err) => {
    if (!err) return next();
    if (err.code === 'LIMIT_FILE_SIZE')
      return next(appError('FILE_TOO_LARGE', `A file may be at most ${HARD_MAX_MB} MB.`));
    if (err instanceof multer.MulterError)
      return next(
        appError('BAD_REQUEST', 'The upload could not be read.', [
          { field: 'files', message: err.message },
        ]),
      );
    return next(err);
  });
}

/** Content type by extension: the client's own type is never trusted. */
const MIME = /** @type {Record<string, string>} */ ({
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ppt: 'application/vnd.ms-powerpoint',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  zip: 'application/zip',
  csv: 'text/csv',
  txt: 'text/plain',
});

const ZIP = [0x50, 0x4b, 0x03, 0x04];
const OLE = [0xd0, 0xcf, 0x11, 0xe0];
/** Leading bytes each extension must start with (17.9 "MIME sniffing"). */
const MAGIC = /** @type {Record<string, number[]>} */ ({
  pdf: [0x25, 0x50, 0x44, 0x46],
  png: [0x89, 0x50, 0x4e, 0x47],
  jpg: [0xff, 0xd8, 0xff],
  jpeg: [0xff, 0xd8, 0xff],
  zip: ZIP,
  docx: ZIP,
  xlsx: ZIP,
  pptx: ZIP,
  doc: OLE,
  xls: OLE,
  ppt: OLE,
});

/** @param {string} name */
const extensionOf = (name) => path.extname(name).slice(1).toLowerCase();

/**
 * True when the bytes match the extension; text types must not contain NUL bytes.
 * @param {string} ext
 * @param {Buffer} data
 */
function contentMatches(ext, data) {
  const magic = MAGIC[ext];
  if (magic) return magic.every((b, i) => data[i] === b);
  if (ext === 'csv' || ext === 'txt') return !data.subarray(0, 8192).includes(0);
  return false;
}

/**
 * Check every file of the request against the settings before anything is stored.
 * @param {Express.Multer.File[]} files
 * @param {{ maxSizeMb: number, maxFiles: number, allowedExtensions: string }} limits
 * @returns {Array<{ file: Express.Multer.File, ext: string, mime: string }>}
 */
function checkFiles(files, limits) {
  if (!files.length)
    throw appError('VALIDATION_FAILED', 'Choose a file to upload.', [
      { field: 'files', message: 'Required.' },
    ]);
  if (files.length > limits.maxFiles)
    throw appError('VALIDATION_FAILED', `Upload at most ${limits.maxFiles} files at a time.`, [
      { field: 'files', message: `At most ${limits.maxFiles} files.` },
    ]);
  const allowed = limits.allowedExtensions.toLowerCase().split(',');
  return files.map((file) => {
    const ext = extensionOf(file.originalname);
    if (!allowed.includes(ext) || !MIME[ext])
      throw appError('UNSUPPORTED_FILE_TYPE', `Allowed file types: ${allowed.join(', ')}.`);
    if (file.size > limits.maxSizeMb * 1048576)
      throw appError('FILE_TOO_LARGE', `A file may be at most ${limits.maxSizeMb} MB.`);
    if (!contentMatches(ext, file.buffer))
      throw appError('UNSUPPORTED_FILE_TYPE', `${file.originalname} is not a real .${ext} file.`);
    return { file, ext, mime: MIME[ext] };
  });
}

module.exports = { parseUpload, checkFiles, contentMatches };
