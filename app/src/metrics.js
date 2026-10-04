'use strict';

const client = require('prom-client');

function createMetrics({ service = process.env.SERVICE_NAME || 'notes-app' } = {}) {
  const registry = new client.Registry();
  registry.setDefaultLabels({ service });
  client.collectDefaultMetrics({ register: registry });

  const httpRequests = new client.Counter({
    name: 'http_requests_total',
    help: 'Total HTTP requests by method, route and status',
    labelNames: ['method', 'route', 'status'],
    registers: [registry],
  });

  const httpDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    labelNames: ['method', 'route', 'status'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
  });

  const dbErrors = new client.Counter({
    name: 'db_errors_total',
    help: 'Database errors observed by the application',
    labelNames: ['operation'],
    registers: [registry],
  });

  function middleware(req, res, next) {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      const route = req.route && req.route.path ? req.route.path : req.path;
      const labels = { method: req.method, route, status: String(res.statusCode) };
      httpRequests.inc(labels);
      httpDuration.observe(labels, Number(process.hrtime.bigint() - start) / 1e9);
    });
    next();
  }

  return { registry, httpRequests, httpDuration, dbErrors, middleware };
}

module.exports = { createMetrics };
