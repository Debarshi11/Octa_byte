'use strict';

const request = require('supertest');
const { createApp } = require('../src/app');
const { silentLogger } = require('../src/logger');
const { createMetrics } = require('../src/metrics');

function stubPool(result = { rows: [], rowCount: 0 }) {
  return {
    query: jest.fn(async () => result),
    end: jest.fn(async () => {}),
  };
}

function buildApp(pool = stubPool()) {
  return { app: createApp({ pool, logger: silentLogger(), metrics: createMetrics() }), pool };
}

describe('health endpoints', () => {
  test('GET /healthz returns ok without touching the database', async () => {
    const { app, pool } = buildApp();
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(pool.query).not.toHaveBeenCalled();
  });

  test('GET /readyz returns 200 when the database is reachable', async () => {
    const { app } = buildApp(stubPool({ rows: [{ '?column?': 1 }], rowCount: 1 }));
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ready', database: 'up' });
  });

  test('GET /readyz returns 503 when the database is down', async () => {
    const pool = stubPool();
    pool.query = jest.fn(async () => {
      throw new Error('connection refused');
    });
    const { app } = buildApp(pool);
    const res = await request(app).get('/readyz');
    expect(res.status).toBe(503);
    expect(res.body.database).toBe('down');
  });
});

describe('metrics endpoint', () => {
  test('GET /metrics exposes Prometheus metrics including request counters', async () => {
    const { app } = buildApp();
    await request(app).get('/healthz');
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
    expect(res.text).toContain('process_cpu_user_seconds_total');
  });
});

describe('static frontend and 404', () => {
  test('GET / serves the notes page', async () => {
    const { app } = buildApp();
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.text).toContain('<title>Notes</title>');
  });

  test('unknown route returns JSON 404', async () => {
    const { app } = buildApp();
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('not_found');
  });
});

describe('security headers', () => {
  test('responses set basic hardening headers', async () => {
    const { app } = buildApp();
    const res = await request(app).get('/healthz');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['x-frame-options']).toBe('DENY');
  });
});
