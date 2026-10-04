'use strict';

const path = require('path');
const express = require('express');
const { createMetrics } = require('./metrics');
const { createNotesRouter } = require('./routes/notes');
const { createHealthRouter } = require('./routes/health');

function createApp({ pool, logger, metrics = createMetrics() }) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1);

  app.use(express.json({ limit: '100kb' }));
  app.use(metrics.middleware);

  app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    next();
  });

  app.use('/', createHealthRouter({ pool, logger }));
  app.use('/api/notes', createNotesRouter({ pool, logger, metrics }));
  app.use('/metrics', async (req, res) => {
    res.setHeader('Content-Type', metrics.registry.contentType);
    res.end(await metrics.registry.metrics());
  });

  app.use(express.static(path.join(__dirname, '..', 'public')));

  app.use((req, res) => {
    res.status(404).json({ error: 'not_found', path: req.originalUrl });
  });

  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    const status = err.status || 500;
    logger.error('request_failed', {
      method: req.method,
      path: req.originalUrl,
      status,
      error: err.message,
    });
    res.status(status).json({
      error: status === 500 ? 'internal_error' : err.code || 'request_error',
      message: status === 500 ? 'Something went wrong' : err.message,
    });
  });

  return app;
}

module.exports = { createApp };
