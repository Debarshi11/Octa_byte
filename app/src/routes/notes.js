'use strict';

const express = require('express');

const MAX_TITLE = 200;
const MAX_BODY = 10_000;

function badRequest(message, code = 'validation_error') {
  const err = new Error(message);
  err.status = 400;
  err.code = code;
  return err;
}

function createNotesRouter({ pool, logger, metrics }) {
  const router = express.Router();

  async function query(text, params, operation) {
    try {
      return await pool.query(text, params);
    } catch (err) {
      metrics.dbErrors.inc({ operation });
      logger.error('db_query_failed', { operation, error: err.message });
      throw err;
    }
  }

  router.get('/', async (req, res, next) => {
    try {
      const { rows } = await query(
        'SELECT id, title, body, created_at, updated_at FROM notes ORDER BY id DESC LIMIT 100',
        [],
        'notes.list'
      );
      res.json({ data: rows });
    } catch (err) {
      next(err);
    }
  });

  router.get('/:id', async (req, res, next) => {
    try {
      const id = Number(req.params.id);
      if (!Number.isInteger(id) || id <= 0) throw badRequest('id must be a positive integer');

      const { rows } = await query(
        'SELECT id, title, body, created_at, updated_at FROM notes WHERE id = $1',
        [id],
        'notes.get'
      );
      if (rows.length === 0) {
        return res.status(404).json({ error: 'not_found', id });
      }
      res.json({ data: rows[0] });
    } catch (err) {
      next(err);
    }
  });

  router.post('/', async (req, res, next) => {
    try {
      const { title, body = '' } = req.body || {};
      if (typeof title !== 'string' || title.trim() === '') {
        throw badRequest('title is required and must be a non-empty string');
      }
      if (title.length > MAX_TITLE) throw badRequest(`title must be <= ${MAX_TITLE} characters`);
      if (typeof body !== 'string') throw badRequest('body must be a string');
      if (body.length > MAX_BODY) throw badRequest(`body must be <= ${MAX_BODY} characters`);

      const { rows } = await query(
        `INSERT INTO notes (title, body)
         VALUES ($1, $2)
         RETURNING id, title, body, created_at, updated_at`,
        [title.trim(), body],
        'notes.create'
      );
      res.status(201).json({ data: rows[0] });
    } catch (err) {
      next(err);
    }
  });

  router.put('/:id', async (req, res, next) => {
    try {
      const id = Number(req.params.id);
      if (!Number.isInteger(id) || id <= 0) throw badRequest('id must be a positive integer');

      const { title, body } = req.body || {};
      if (title === undefined && body === undefined) {
        throw badRequest('provide at least one of: title, body');
      }
      if (title !== undefined) {
        if (typeof title !== 'string' || title.trim() === '') {
          throw badRequest('title must be a non-empty string');
        }
        if (title.length > MAX_TITLE) throw badRequest(`title must be <= ${MAX_TITLE} characters`);
      }
      if (body !== undefined) {
        if (typeof body !== 'string') throw badRequest('body must be a string');
        if (body.length > MAX_BODY) throw badRequest(`body must be <= ${MAX_BODY} characters`);
      }

      const { rows } = await query(
        `UPDATE notes
            SET title      = COALESCE($2, title),
                body       = COALESCE($3, body),
                updated_at = now()
          WHERE id = $1
          RETURNING id, title, body, created_at, updated_at`,
        [id, title === undefined ? null : title.trim(), body === undefined ? null : body],
        'notes.update'
      );
      if (rows.length === 0) return res.status(404).json({ error: 'not_found', id });
      res.json({ data: rows[0] });
    } catch (err) {
      next(err);
    }
  });

  router.delete('/:id', async (req, res, next) => {
    try {
      const id = Number(req.params.id);
      if (!Number.isInteger(id) || id <= 0) throw badRequest('id must be a positive integer');

      const { rowCount } = await query('DELETE FROM notes WHERE id = $1', [id], 'notes.delete');
      if (rowCount === 0) return res.status(404).json({ error: 'not_found', id });
      res.status(204).end();
    } catch (err) {
      next(err);
    }
  });

  return router;
}

module.exports = { createNotesRouter };
