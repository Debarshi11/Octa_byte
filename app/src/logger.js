'use strict';

const LEVELS = { error: 3, warn: 4, info: 6, debug: 7 };

function levelValue(level) {
  return LEVELS[level] ?? LEVELS.info;
}

function createLogger({
  service = process.env.SERVICE_NAME || 'notes-app',
  level = process.env.LOG_LEVEL || 'info',
} = {}) {
  const min = levelValue(level);

  function write(lvl, msg, fields) {
    if (levelValue(lvl) < min) return;
    const line = Object.assign(
      { ts: new Date().toISOString(), level: lvl, service, msg },
      fields || {}
    );
    const stream = lvl === 'error' ? process.stderr : process.stdout;
    stream.write(`${JSON.stringify(line)}\n`);
  }

  return {
    error: (msg, fields) => write('error', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    info: (msg, fields) => write('info', msg, fields),
    debug: (msg, fields) => write('debug', msg, fields),
  };
}

function silentLogger() {
  const noop = () => {};
  return { error: noop, warn: noop, info: noop, debug: noop };
}

module.exports = { createLogger, silentLogger };
