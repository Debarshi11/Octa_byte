'use strict';

const { createLogger } = require('./logger');
const { createPool, initSchema } = require('./db');
const { createApp } = require('./app');

async function main() {
  const logger = createLogger();
  const pool = createPool();

  try {
    await initSchema(pool);
    logger.info('schema_ready');
  } catch (err) {
    logger.error('schema_init_failed', { error: err.message });
    process.exit(1);
  }

  const app = createApp({ pool, logger });
  const port = Number(process.env.PORT || 3000);

  const server = app.listen(port, () => {
    logger.info('server_listening', { port, env: process.env.NODE_ENV || 'development' });
  });

  const shutdown = (signal) => {
    logger.info('shutdown_started', { signal });
    server.close(async () => {
      await pool.end().catch(() => {});
      logger.info('shutdown_complete');
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  process.stderr.write(`${JSON.stringify({ level: 'error', msg: 'fatal', error: err.message })}\n`);
  process.exit(1);
});
