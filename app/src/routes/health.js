'use strict';

const express = require('express');

function createHealthRouter({ pool, logger }) {
  const router = express.Router();

  // Liveness: is the process up? Never touches the database.
  router.get('/healthz', (req, res) => {
    res.status(200).json({ status: 'ok', uptime: process.uptime() });
  });

  // Readiness: can we actually serve traffic? Checks the database.
  router.get('/readyz', async (req, res) => {
    try {
      await pool.query('SELECT 1');
      res.status(200).json({ status: 'ready', database: 'up' });
    } catch (err) {
      logger.warn('readiness_check_failed', { error: err.message });
      res.status(503).json({ status: 'not_ready', database: 'down' });
    }
  });

  return router;
}

module.exports = { createHealthRouter };
