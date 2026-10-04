'use strict';

const request = require('supertest');
const { createApp } = require('../src/app');
const { silentLogger } = require('../src/logger');
const { createMetrics } = require('../src/metrics');

function stubPool(handler) {
  return { query: jest.fn(handler), end: jest.fn(async () => {}) };
}

function buildApp(pool) {
  return createApp({ pool, logger: silentLogger(), metrics: createMetrics() });
}

const NOTE = {
  id: 1,
  title: 'hello',
  body: 'world',
  created_at: '2025-01-01T00:00:00.000Z',
  updated_at: '2025-01-01T00:00:00.000Z',
};

describe('GET /api/notes', () => {
  test('returns the list of notes', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [NOTE], rowCount: 1 })));
    const res = await request(app).get('/api/notes');
    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(1);
    expect(res.body.data[0].title).toBe('hello');
  });
});

describe('POST /api/notes', () => {
  test('creates a note and returns 201', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [NOTE], rowCount: 1 })));
    const res = await request(app).post('/api/notes').send({ title: 'hello', body: 'world' });
    expect(res.status).toBe(201);
    expect(res.body.data.title).toBe('hello');
  });

  test('rejects a missing title with 400', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).post('/api/notes').send({ body: 'no title' });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('validation_error');
  });

  test('rejects an oversized title with 400', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).post('/api/notes').send({ title: 'x'.repeat(201) });
    expect(res.status).toBe(400);
  });

  test('never writes a note without going through the pool', async () => {
    const pool = stubPool(async () => ({ rows: [NOTE], rowCount: 1 }));
    const app = buildApp(pool);
    await request(app).post('/api/notes').send({ title: 'hello', body: 'world' });
    expect(pool.query).toHaveBeenCalledTimes(1);
    expect(pool.query.mock.calls[0][0]).toContain('INSERT INTO notes');
  });
});

describe('GET /api/notes/:id', () => {
  test('returns a single note', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [NOTE], rowCount: 1 })));
    const res = await request(app).get('/api/notes/1');
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(1);
  });

  test('returns 404 for a missing note', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).get('/api/notes/999');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('not_found');
  });

  test('returns 400 for a non-numeric id', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).get('/api/notes/abc');
    expect(res.status).toBe(400);
  });
});

describe('PUT /api/notes/:id', () => {
  test('updates a note', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [NOTE], rowCount: 1 })));
    const res = await request(app).put('/api/notes/1').send({ title: 'hello again' });
    expect(res.status).toBe(200);
    expect(res.body.data.id).toBe(1);
  });

  test('returns 404 when the note does not exist', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).put('/api/notes/999').send({ title: 'x' });
    expect(res.status).toBe(404);
  });

  test('rejects an empty update with 400', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).put('/api/notes/1').send({});
    expect(res.status).toBe(400);
  });
});

describe('DELETE /api/notes/:id', () => {
  test('deletes a note and returns 204', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 1 })));
    const res = await request(app).delete('/api/notes/1');
    expect(res.status).toBe(204);
  });

  test('returns 404 when the note does not exist', async () => {
    const app = buildApp(stubPool(async () => ({ rows: [], rowCount: 0 })));
    const res = await request(app).delete('/api/notes/999');
    expect(res.status).toBe(404);
  });
});

describe('database failures', () => {
  test('a pool error surfaces as a 500 and increments db_errors_total', async () => {
    const pool = stubPool(async () => {
      throw new Error('connection reset');
    });
    const metrics = createMetrics();
    const app = createApp({ pool, logger: silentLogger(), metrics });

    const res = await request(app).get('/api/notes');
    expect(res.status).toBe(500);
    expect(res.body.error).toBe('internal_error');

    const snapshot = await metrics.registry.getMetricsAsJSON();
    const counter = snapshot.find((m) => m.name === 'db_errors_total');
    expect(counter.values.some((v) => v.value > 0)).toBe(true);
  });
});
