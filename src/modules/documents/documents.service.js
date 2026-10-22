// @ts-check
'use strict';

/**
 * Documents (12.13, UM 5 "every shared document, tagged"): search over the documents of every
 * visible record, upload (BR-DC-01/02, 17.9), download and soft delete. A document has the
 * visibility of its parent record (10.8 rule 3).
 */
const path = require('path');
const repo = require('./documents.repository');
const storage = require('../../integrations/fileStorage');
const { checkFiles } = require('./documents.upload');
const { offsetOf } = require('../../shared/schemas');

module.exports = {
  /**
   * @param {number} userId
   * @param {any} q
   */
  async list(userId, q) {
    const { rows, total, typeCounts, tags } = await repo.list(userId, {
      ...q,
      offset: offsetOf(q),
      limit: q.pageSize,
    });
    return {
      rows: rows.map((r) => ({
        ...r,
        sizeBytes: Number(r.sizeBytes),
        tags: r.tags ? String(r.tags).split(',') : [],
      })),
      meta: { page: q.page, pageSize: q.pageSize, total, typeCounts, tags },
    };
  },

  /**
   * Every file is checked before any is stored; each stored file whose record insert fails is
   * removed again. Several files share the body's metadata; the title applies to one file only.
   * @param {Express.Multer.File[]} files
   * @param {any} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async upload(files, body, meta) {
    const limits = await repo.limits();
    const checked = checkFiles(files, {
      maxSizeMb: Number(limits.maxSizeMb),
      maxFiles: Number(limits.maxFiles),
      allowedExtensions: String(limits.allowedExtensions),
    });
    const created = [];
    for (const { file, ext, mime } of checked) {
      const { key, sha256 } = await storage.save(file.buffer);
      const title =
        (checked.length === 1 && body.title) || path.parse(file.originalname).name.slice(0, 250);
      try {
        const row = await repo.create(
          body,
          { title, originalName: file.originalname, ext, mime, size: file.size, sha256, key },
          meta,
        );
        created.push({ id: row.id, versionNo: row.versionNo, title, fileName: file.originalname });
      } catch (err) {
        await storage.remove(key);
        throw err;
      }
    }
    return created;
  },

  /** @param {number} userId @param {number} id */
  file: (userId, id) => repo.file(userId, id),

  /**
   * Replace the tags and / or the notes of a visible document (V027).
   * @param {number} id
   * @param {{ tags?: string[], notes?: string | null }} body
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   */
  async update(id, body, meta) {
    const row = await repo.update(id, body, meta);
    return {
      id: Number(row?.id),
      tags: row?.tags ? String(row.tags).split(',') : [],
      notes: row?.notes ?? null,
    };
  },

  /**
   * @param {number} id
   * @param {import('../../shared/requestMeta').RequestMeta} meta
   * @param {boolean} allowAny
   */
  remove: (id, meta, allowAny) => repo.remove(id, meta, allowAny),
};
