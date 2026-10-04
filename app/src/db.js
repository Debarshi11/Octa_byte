'use strict';

const { Pool } = require('pg');

const REQUIRED = ['PGHOST', 'PGUSER', 'PGPASSWORD', 'PGDATABASE'];

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `Missing required environment variable ${name}. ` +
        'Database credentials are injected from AWS Secrets Manager at task start; ' +
        'they are never read from a .env file and never defaulted in code.'
    );
  }
  return value;
}

function buildSsl() {
  const mode = (process.env.PG_SSL_MODE || '').toLowerCase();
  if (mode === 'require') return { rejectUnauthorized: false };
  if (mode === 'verify-full') return { rejectUnauthorized: true };
  return false;
}

function createPool() {
  for (const name of REQUIRED) requiredEnv(name);

  return new Pool({
    host: process.env.PGHOST,
    port: Number(process.env.PGPORT || 5432),
    user: process.env.PGUSER,
    password: process.env.PGPASSWORD,
    database: process.env.PGDATABASE,
    ssl: buildSsl(),
    max: Number(process.env.PG_POOL_MAX || 10),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    statement_timeout: 10_000,
  });
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS notes (
  id          BIGSERIAL PRIMARY KEY,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
`;

async function initSchema(pool) {
  await pool.query(SCHEMA);
}

module.exports = { createPool, initSchema, requiredEnv, REQUIRED };
